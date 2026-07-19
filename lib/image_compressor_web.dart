import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'image_compressor_platform_interface.dart';
import 'src/encode_request.dart';
import 'src/models.dart';

/// Web backend: encodes in-browser via `OffscreenCanvas.convertToBlob`. No
/// `pica` script tag, no extra deps — the differentiator vs flutter_image_compress
/// on web. HEIC cannot be encoded in a browser and returns
/// [UnsupportedFormatError].
class ImageCompressorWeb extends ImageCompressorPlatform {
  ImageCompressorWeb();

  static void registerWith(Registrar registrar) {
    ImageCompressorPlatform.instance = ImageCompressorWeb();
  }

  @override
  Future<(int, int)> probeSize(Uint8List bytes) async {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'application/octet-stream'),
    );
    final web.ImageBitmap bitmap;
    try {
      // Oriented dimensions, to match iOS/Android and the compressed output.
      bitmap = await web.window
          .createImageBitmap(
            blob,
            web.ImageBitmapOptions(imageOrientation: 'from-image'),
          )
          .toDart;
    } catch (e) {
      throw DecodeError('Could not read image: $e');
    }
    final size = (bitmap.width, bitmap.height);
    bitmap.close();
    return size;
  }

  @override
  Future<EncodeResult> encodeOnce(EncodeRequest request) async {
    final mime = _mime(request.format);
    if (mime == null) throw UnsupportedFormatError(request.format);
    final canvas = await _draw(
      request.bytes,
      request.autoOrient,
      request.maxWidth,
      request.maxHeight,
    );
    final bytes = await _encode(canvas, request.format, mime, request.quality);
    return EncodeResult(
      bytes: bytes,
      width: canvas.width,
      height: canvas.height,
      usedQuality: request.quality,
      reachedTarget: true,
    );
  }

  @override
  Future<EncodeResult> encodeToSize(EncodeSizeRequest request) async {
    final mime = _mime(request.format);
    if (mime == null) throw UnsupportedFormatError(request.format);
    final canvas = await _draw(
      request.bytes,
      request.autoOrient,
      request.maxWidth,
      request.maxHeight,
    );

    // PNG is lossless; quality does nothing — encode once.
    if (request.format == ImageFormat.png) {
      final bytes = await _encode(canvas, request.format, mime, 100);
      return _sized(canvas, bytes, 100, bytes.length <= request.maxBytes);
    }

    var lo = request.minQuality.clamp(0, 100);
    var hi = 100;
    Uint8List? best;
    var bestQuality = 0;
    Uint8List? smallest;
    var smallestQuality = lo;

    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final bytes = await _encode(canvas, request.format, mime, mid);
      if (smallest == null || bytes.length < smallest.length) {
        smallest = bytes;
        smallestQuality = mid;
      }
      if (bytes.length <= request.maxBytes) {
        best = bytes;
        bestQuality = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }

    return best != null
        ? _sized(canvas, best, bestQuality, true)
        : _sized(canvas, smallest!, smallestQuality, false);
  }

  EncodeResult _sized(
    web.OffscreenCanvas canvas,
    Uint8List bytes,
    int q,
    bool reached,
  ) => EncodeResult(
    bytes: bytes,
    width: canvas.width,
    height: canvas.height,
    usedQuality: q,
    reachedTarget: reached,
  );

  /// Decode the bytes once and draw them into an [web.OffscreenCanvas] fitted to
  /// the optional bounds. [autoOrient] controls whether EXIF orientation is
  /// applied (explicitly, not left to the browser default which varies).
  ///
  /// NOTE: requires OffscreenCanvas.convertToBlob — Safari 16.4+ / evergreen
  /// engines. Older WebViews are unsupported; see DESIGN.md.
  Future<web.OffscreenCanvas> _draw(
    Uint8List src,
    bool autoOrient,
    int? maxW,
    int? maxH,
  ) async {
    final blob = web.Blob(
      [src.toJS].toJS,
      web.BlobPropertyBag(type: 'application/octet-stream'),
    );
    // A browser rejects createImageBitmap on undecodable bytes with a JS
    // DOMException; map it to the package's typed error like native does.
    final web.ImageBitmap bitmap;
    try {
      bitmap = await web.window
          .createImageBitmap(
            blob,
            web.ImageBitmapOptions(
              imageOrientation: autoOrient ? 'from-image' : 'none',
            ),
          )
          .toDart;
    } catch (e) {
      throw DecodeError('Could not decode image: $e');
    }
    final fitted = _fit(bitmap.width, bitmap.height, maxW, maxH);
    final w = fitted.$1;
    final h = fitted.$2;

    final canvas = web.OffscreenCanvas(w, h);
    final rawCtx = canvas.getContext('2d');
    if (rawCtx == null) {
      bitmap.close();
      throw DecodeError('2D canvas context is unavailable on this browser.');
    }
    final ctx = rawCtx as web.OffscreenCanvasRenderingContext2D;
    ctx.drawImage(bitmap, 0, 0, w.toDouble(), h.toDouble());
    bitmap.close();
    return canvas;
  }

  /// Encode the already-drawn canvas at [quality] (cheap; no re-decode).
  Future<Uint8List> _encode(
    web.OffscreenCanvas canvas,
    ImageFormat format,
    String mime,
    int quality,
  ) async {
    final blob = await canvas
        .convertToBlob(
          web.ImageEncodeOptions(
            type: mime,
            quality: quality.clamp(0, 100) / 100.0,
          ),
        )
        .toDart;
    // Browsers that can't encode the requested type silently fall back to PNG
    // (notably WebP on older Safari). Don't hand back mislabeled bytes.
    if (blob.type != mime) {
      throw UnsupportedFormatError(format);
    }
    final buffer = await blob.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  (int, int) _fit(int w, int h, int? maxW, int? maxH) {
    // Non-positive bounds are meaningless; treat them as unconstrained.
    final mw = (maxW != null && maxW > 0) ? maxW : null;
    final mh = (maxH != null && maxH > 0) ? maxH : null;
    if (mw == null && mh == null) return (w, h);
    final scaleW = mw != null ? mw / w : double.infinity;
    final scaleH = mh != null ? mh / h : double.infinity;
    final scale = scaleW < scaleH ? scaleW : scaleH;
    if (scale >= 1) return (w, h);
    return ((w * scale).round().clamp(1, w), (h * scale).round().clamp(1, h));
  }

  String? _mime(ImageFormat format) {
    switch (format) {
      case ImageFormat.jpeg:
        return 'image/jpeg';
      case ImageFormat.png:
        return 'image/png';
      case ImageFormat.webp:
        return 'image/webp';
      case ImageFormat.heic:
        return null;
    }
  }
}
