package com.oguzhan.image_compressor

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * ImageCompressorPlugin — native encode primitives.
 *
 * `encodeOnce` = fixed quality. `encodeToSize` = decode ONCE, then binary-search
 * quality against a byte ceiling (the image is decoded a single time, each probe
 * only re-encodes the already-decoded bitmap).
 */
class ImageCompressorPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var cacheDir: java.io.File? = null

    private val executor = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "image_compressor")
        channel.setMethodCallHandler(this)
        cacheDir = binding.applicationContext.cacheDir
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "encodeOnce" -> run(call, result) { bitmap, args ->
                val quality = args["quality"] as? Int ?: 80
                val formatName = args["format"] as? String ?: "jpeg"
                val format = compressFormatFor(formatName) ?: throw UnsupportedFormat()
                var bytes = encode(bitmap, format, quality)
                bytes = maybeCopyExif(bytes, args, formatName)
                resultMap(bytes, bitmap, quality, true)
            }
            "encodeToSize" -> run(call, result) { bitmap, args ->
                val formatName = args["format"] as? String ?: "jpeg"
                val format = compressFormatFor(formatName) ?: throw UnsupportedFormat()
                val out = searchToSize(
                    bitmap,
                    format,
                    maxBytes = args["maxBytes"] as? Int ?: Int.MAX_VALUE,
                    minQuality = args["minQuality"] as? Int ?: 10,
                )
                // Metadata is copied onto the final result only (may add a few KB
                // over maxBytes — EXIF is small; JPEG only).
                val bytes = maybeCopyExif(out["bytes"] as ByteArray, args, formatName)
                out.toMutableMap().apply { this["bytes"] = bytes }
            }
            "probe" -> probe(call, result)
            else -> result.notImplemented()
        }
    }

    /** Read dimensions from the header only (inJustDecodeBounds), no pixels. */
    private fun probe(call: MethodCall, result: Result) {
        @Suppress("UNCHECKED_CAST")
        val args = call.arguments as? Map<String, Any?>
        val bytes = args?.get("bytes") as? ByteArray
        if (bytes == null) {
            result.error("decode_error", "No bytes provided.", null)
            return
        }
        executor.execute {
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
            if (opts.outWidth <= 0 || opts.outHeight <= 0) {
                main.post { result.error("decode_error", "Not a decodable image.", null) }
                return@execute
            }
            // Report the UPRIGHT (EXIF-oriented) dimensions, matching iOS/web and
            // the dimensions a compressed output would have.
            val orientation = try {
                ExifInterface(ByteArrayInputStream(bytes))
                    .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            } catch (_: Throwable) {
                ExifInterface.ORIENTATION_NORMAL
            }
            val swaps = orientation == ExifInterface.ORIENTATION_ROTATE_90 ||
                orientation == ExifInterface.ORIENTATION_ROTATE_270 ||
                orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
                orientation == ExifInterface.ORIENTATION_TRANSVERSE
            val w = if (swaps) opts.outHeight else opts.outWidth
            val h = if (swaps) opts.outWidth else opts.outHeight
            main.post { result.success(mapOf("width" to w, "height" to h)) }
        }
    }

    /** Shared entry: validate bytes, decode once on a worker, run [work], reply. */
    private fun run(
        call: MethodCall,
        result: Result,
        work: (Bitmap, Map<String, Any?>) -> Map<String, Any>,
    ) {
        @Suppress("UNCHECKED_CAST")
        val args = call.arguments as? Map<String, Any?>
        val bytes = args?.get("bytes") as? ByteArray
        if (args == null || bytes == null) {
            result.error("decode_error", "No bytes provided.", null)
            return
        }
        val autoOrient = args["autoOrient"] as? Boolean ?: true
        val maxWidth = args["maxWidth"] as? Int
        val maxHeight = args["maxHeight"] as? Int

        executor.execute {
            try {
                val bitmap = decode(bytes, autoOrient, maxWidth, maxHeight)
                val out = try {
                    work(bitmap, args)
                } finally {
                    bitmap.recycle()
                }
                main.post { result.success(out) }
            } catch (e: UnsupportedFormat) {
                main.post { result.error("unsupported_format", e.message, null) }
            } catch (e: OutOfMemoryError) {
                main.post { result.error("decode_error", "Out of memory: ${e.message}", null) }
            } catch (e: Throwable) {
                main.post { result.error("decode_error", e.message ?: "Failed to encode image.", null) }
            }
        }
    }

    private class UnsupportedFormat : Exception("Format is not supported on Android.")

    // ---- decode (once) -------------------------------------------------------

    private fun decode(
        bytes: ByteArray,
        autoOrient: Boolean,
        maxWidth: Int?,
        maxHeight: Int?,
    ): Bitmap {
        // Non-positive bounds are meaningless; treat them as unconstrained.
        val mw = maxWidth?.takeIf { it > 0 }
        val mh = maxHeight?.takeIf { it > 0 }

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw IllegalStateException("Not a decodable image.")
        }
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, mw, mh)
        }
        var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
            ?: throw IllegalStateException("Failed to decode image.")
        // If a transform throws (e.g. OOM in createBitmap), recycle the current
        // bitmap so native memory isn't leaked exactly when it's scarce.
        return try {
            if (autoOrient) {
                bitmap = applyExifOrientation(bytes, bitmap)
            }
            scaleToBounds(bitmap, mw, mh)
        } catch (e: Throwable) {
            bitmap.recycle()
            throw e
        }
    }

    // ---- encode (cheap, reuses the decoded bitmap) --------------------------

    /** EXIF tags worth preserving. NOT orientation (reset — pixels are baked). */
    private val exifTags = listOf(
        ExifInterface.TAG_DATETIME, ExifInterface.TAG_DATETIME_ORIGINAL,
        ExifInterface.TAG_DATETIME_DIGITIZED, ExifInterface.TAG_MAKE,
        ExifInterface.TAG_MODEL, ExifInterface.TAG_SOFTWARE, ExifInterface.TAG_ARTIST,
        ExifInterface.TAG_COPYRIGHT, ExifInterface.TAG_IMAGE_DESCRIPTION,
        ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF,
        ExifInterface.TAG_GPS_LONGITUDE, ExifInterface.TAG_GPS_LONGITUDE_REF,
        ExifInterface.TAG_GPS_ALTITUDE, ExifInterface.TAG_GPS_ALTITUDE_REF,
        ExifInterface.TAG_GPS_TIMESTAMP, ExifInterface.TAG_GPS_DATESTAMP,
        ExifInterface.TAG_EXPOSURE_TIME, ExifInterface.TAG_F_NUMBER,
        ExifInterface.TAG_ISO_SPEED, ExifInterface.TAG_FOCAL_LENGTH,
        ExifInterface.TAG_WHITE_BALANCE, ExifInterface.TAG_FLASH,
        ExifInterface.TAG_LENS_MAKE, ExifInterface.TAG_LENS_MODEL,
    )

    /**
     * Copies the source's EXIF tags onto [out] when keepMetadata is on (JPEG
     * only — ExifInterface can't write PNG/WebP reliably). Orientation is reset
     * to normal since rotation is baked into the pixels. Best-effort: any failure
     * returns the un-tagged bytes rather than throwing.
     */
    private fun maybeCopyExif(out: ByteArray, args: Map<String, Any?>, formatName: String): ByteArray {
        if (args["keepMetadata"] as? Boolean != true || formatName != "jpeg") return out
        val src = args["bytes"] as? ByteArray ?: return out
        val dir = cacheDir ?: return out
        val tmp = java.io.File.createTempFile("ic_exif", ".jpg", dir)
        return try {
            tmp.writeBytes(out)
            val srcExif = ExifInterface(ByteArrayInputStream(src))
            val dstExif = ExifInterface(tmp.absolutePath)
            for (tag in exifTags) srcExif.getAttribute(tag)?.let { dstExif.setAttribute(tag, it) }
            dstExif.setAttribute(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL.toString(),
            )
            dstExif.saveAttributes()
            tmp.readBytes()
        } catch (_: Throwable) {
            out
        } finally {
            tmp.delete()
        }
    }

    private fun encode(bitmap: Bitmap, format: Bitmap.CompressFormat, quality: Int): ByteArray {
        val stream = ByteArrayOutputStream()
        if (!bitmap.compress(format, quality.coerceIn(0, 100), stream)) {
            throw IllegalStateException("Bitmap.compress failed for $format.")
        }
        return stream.toByteArray()
    }

    private fun searchToSize(
        bitmap: Bitmap,
        format: Bitmap.CompressFormat,
        maxBytes: Int,
        minQuality: Int,
    ): Map<String, Any> {
        // Lossless formats ignore quality; a search is pointless — encode once.
        if (format == Bitmap.CompressFormat.PNG) {
            val bytes = encode(bitmap, format, 100)
            return resultMap(bytes, bitmap, 100, bytes.size <= maxBytes)
        }

        var lo = minQuality.coerceIn(0, 100)
        var hi = 100
        var bestBytes: ByteArray? = null
        var bestQuality = 0
        var smallestBytes: ByteArray? = null
        var smallestQuality = lo

        while (lo <= hi) {
            val mid = (lo + hi) / 2
            val bytes = encode(bitmap, format, mid)
            if (smallestBytes == null || bytes.size < smallestBytes!!.size) {
                smallestBytes = bytes
                smallestQuality = mid
            }
            if (bytes.size <= maxBytes) {
                bestBytes = bytes
                bestQuality = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        return if (bestBytes != null) {
            resultMap(bestBytes, bitmap, bestQuality, true)
        } else {
            resultMap(smallestBytes!!, bitmap, smallestQuality, false)
        }
    }

    private fun resultMap(
        bytes: ByteArray,
        bitmap: Bitmap,
        usedQuality: Int,
        reachedTarget: Boolean,
    ): Map<String, Any> = mapOf(
        "bytes" to bytes,
        "width" to bitmap.width,
        "height" to bitmap.height,
        "usedQuality" to usedQuality,
        "reachedTarget" to reachedTarget,
    )

    // ---- helpers -------------------------------------------------------------

    private fun sampleSize(width: Int, height: Int, maxWidth: Int?, maxHeight: Int?): Int {
        if (maxWidth == null && maxHeight == null) return 1
        // Largest power-of-two where every SET bound still stays >= its target
        // after downsampling, so scaleToBounds can finish exactly. A null bound
        // is unconstrained and must NOT block sampling driven by the other axis.
        var sample = 1
        while (true) {
            val next = sample * 2
            val widthOk = maxWidth == null || width / next >= maxWidth
            val heightOk = maxHeight == null || height / next >= maxHeight
            if (widthOk && heightOk) sample = next else break
        }
        return sample
    }

    private fun scaleToBounds(bitmap: Bitmap, maxWidth: Int?, maxHeight: Int?): Bitmap {
        if (maxWidth == null && maxHeight == null) return bitmap
        val w = bitmap.width
        val h = bitmap.height
        val scaleW = if (maxWidth != null) maxWidth.toFloat() / w else Float.MAX_VALUE
        val scaleH = if (maxHeight != null) maxHeight.toFloat() / h else Float.MAX_VALUE
        val scale = minOf(scaleW, scaleH)
        if (scale >= 1f) return bitmap
        // Round (not floor) to match the iOS/web backends for pixel parity.
        val scaled = Bitmap.createScaledBitmap(
            bitmap,
            (w * scale).roundToInt().coerceAtLeast(1),
            (h * scale).roundToInt().coerceAtLeast(1),
            true,
        )
        if (scaled != bitmap) bitmap.recycle()
        return scaled
    }

    private fun applyExifOrientation(bytes: ByteArray, bitmap: Bitmap): Bitmap {
        val orientation = try {
            ExifInterface(ByteArrayInputStream(bytes))
                .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (_: Throwable) {
            ExifInterface.ORIENTATION_NORMAL
        }
        if (orientation == ExifInterface.ORIENTATION_NORMAL ||
            orientation == ExifInterface.ORIENTATION_UNDEFINED
        ) {
            return bitmap
        }
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                m.postRotate(90f); m.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                m.postRotate(270f); m.postScale(-1f, 1f)
            }
            else -> return bitmap
        }
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
        if (rotated != bitmap) bitmap.recycle()
        return rotated
    }

    private fun compressFormatFor(format: String): Bitmap.CompressFormat? = when (format) {
        "jpeg" -> Bitmap.CompressFormat.JPEG
        "png" -> Bitmap.CompressFormat.PNG
        "webp" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Bitmap.CompressFormat.WEBP_LOSSY
        } else {
            @Suppress("DEPRECATION")
            Bitmap.CompressFormat.WEBP
        }
        else -> null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
