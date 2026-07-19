import Flutter
import UIKit
import ImageIO
import MobileCoreServices

/// Native encode primitives.
///
/// `encodeOnce` = fixed quality. `encodeToSize` = decode ONCE, then binary-search
/// quality against a byte ceiling (the image is decoded a single time; each probe
/// only re-encodes the already-decoded CGImage).
public class ImageCompressorPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "image_compressor", binaryMessenger: registrar.messenger())
    let instance = ImageCompressorPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "encodeOnce":
      run(call, result) { image, args in
        let quality = args["quality"] as? Int ?? 80
        let typeId = try self.requireType(args["format"] as? String ?? "jpeg")
        let bytes = try self.encode(image, typeId: typeId, quality: quality)
        return self.resultMap(bytes, image, quality, true)
      }
    case "encodeToSize":
      run(call, result) { image, args in
        let typeId = try self.requireType(args["format"] as? String ?? "jpeg")
        return try self.searchToSize(
          image, typeId: typeId,
          maxBytes: args["maxBytes"] as? Int ?? Int.max,
          minQuality: args["minQuality"] as? Int ?? 10)
      }
    case "probe":
      probe(call, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Read dimensions from image properties only — no pixel decode.
  private func probe(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let typed = args["bytes"] as? FlutterStandardTypedData else {
      result(FlutterError(code: "decode_error", message: "No bytes provided.", details: nil))
      return
    }
    let data = typed.data
    DispatchQueue.global(qos: .userInitiated).async {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else {
        DispatchQueue.main.async {
          result(FlutterError(code: "decode_error", message: "Not a decodable image.", details: nil))
        }
        return
      }
      // EXIF orientation can swap the displayed dimensions.
      let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
      let swaps = orientation >= 5 && orientation <= 8
      DispatchQueue.main.async {
        result(["width": swaps ? h : w, "height": swaps ? w : h])
      }
    }
  }

  private struct CompressFailure: Error {
    let code: String
    let message: String
  }

  /// Shared entry: validate bytes, decode once off the main queue, run `work`.
  private func run(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult,
    _ work: @escaping (CGImage, [String: Any]) throws -> [String: Any]
  ) {
    guard let args = call.arguments as? [String: Any],
          let typed = args["bytes"] as? FlutterStandardTypedData else {
      result(FlutterError(code: "decode_error", message: "No bytes provided.", details: nil))
      return
    }
    let autoOrient = args["autoOrient"] as? Bool ?? true
    let maxWidth = args["maxWidth"] as? Int
    let maxHeight = args["maxHeight"] as? Int
    let data = typed.data

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let image = try self.decode(
          data: data, autoOrient: autoOrient, maxWidth: maxWidth, maxHeight: maxHeight)
        let out = try work(image, args)
        DispatchQueue.main.async { result(out) }
      } catch let err as CompressFailure {
        DispatchQueue.main.async {
          result(FlutterError(code: err.code, message: err.message, details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "decode_error", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  // ---- decode (once) --------------------------------------------------------

  private func decode(data: Data, autoOrient: Bool, maxWidth: Int?, maxHeight: Int?) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw CompressFailure(code: "decode_error", message: "Not a decodable image.")
    }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let rawW = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
    let rawH = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
    let orientation = (props?[kCGImagePropertyOrientation] as? Int) ?? 1

    // When autoOrient bakes in a 90/270 rotation, the output's dimensions are
    // swapped — fit the box against the ORIENTED dims so resize matches
    // Android/web (which fit after rotation).
    let swaps = autoOrient && (orientation >= 5 && orientation <= 8)
    let srcW = swaps ? rawH : rawW
    let srcH = swaps ? rawW : rawH

    // nil = pixel dimensions unknown and no bound → decode full size (never a
    // 1x1 thumbnail). Otherwise the longest-edge cap that fits the box.
    let maxPixel = targetMaxPixel(maxWidth: maxWidth, maxHeight: maxHeight, srcW: srcW, srcH: srcH)

    var options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: autoOrient,
    ]
    if let maxPixel = maxPixel {
      options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
    }
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw CompressFailure(code: "decode_error", message: "Failed to decode image.")
    }
    return image
  }

  // ---- encode (cheap, reuses the decoded image) ----------------------------

  private func encode(_ image: CGImage, typeId: CFString, quality: Int) throws -> Data {
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, typeId, 1, nil) else {
      throw CompressFailure(code: "unsupported_format", message: "Cannot encode this format on iOS.")
    }
    let props: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: Double(min(max(quality, 0), 100)) / 100.0,
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
      throw CompressFailure(code: "decode_error", message: "Failed to encode image.")
    }
    return out as Data
  }

  private func searchToSize(
    _ image: CGImage, typeId: CFString, maxBytes: Int, minQuality: Int
  ) throws -> [String: Any] {
    // PNG is lossless; quality does nothing — encode once.
    if typeId == ("public.png" as CFString) {
      let bytes = try encode(image, typeId: typeId, quality: 100)
      return resultMap(bytes, image, 100, bytes.count <= maxBytes)
    }

    var lo = min(max(minQuality, 0), 100)
    var hi = 100
    var best: Data?
    var bestQuality = 0
    var smallest: Data?
    var smallestQuality = lo

    while lo <= hi {
      let mid = (lo + hi) / 2
      let bytes = try encode(image, typeId: typeId, quality: mid)
      if smallest == nil || bytes.count < smallest!.count {
        smallest = bytes
        smallestQuality = mid
      }
      if bytes.count <= maxBytes {
        best = bytes
        bestQuality = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }

    if let best = best {
      return resultMap(best, image, bestQuality, true)
    }
    return resultMap(smallest!, image, smallestQuality, false)
  }

  private func resultMap(_ bytes: Data, _ image: CGImage, _ usedQuality: Int, _ reachedTarget: Bool) -> [String: Any] {
    return [
      "bytes": FlutterStandardTypedData(bytes: bytes),
      "width": image.width,
      "height": image.height,
      "usedQuality": usedQuality,
      "reachedTarget": reachedTarget,
    ]
  }

  // ---- helpers --------------------------------------------------------------

  /// Longest-edge pixel cap that makes BOTH width <= maxWidth and height <=
  /// maxHeight after scaling — matching the per-edge "fit inside the box"
  /// semantics used by the Android and web backends. Never upscales.
  /// Longest-edge pixel cap so both width <= maxWidth and height <= maxHeight
  /// after scaling (matches Android/web per-edge fit). Returns nil when there's
  /// nothing to cap — no bound, or source dimensions unknown — so the caller
  /// decodes at full size instead of emitting a degenerate 1x1 thumbnail.
  private func targetMaxPixel(maxWidth: Int?, maxHeight: Int?, srcW: Int, srcH: Int) -> Int? {
    // Non-positive bounds are meaningless; treat them as unconstrained.
    let mw = (maxWidth ?? 0) > 0 ? maxWidth : nil
    let mh = (maxHeight ?? 0) > 0 ? maxHeight : nil
    if mw == nil && mh == nil { return nil }
    if srcW <= 0 || srcH <= 0 {
      // Dimensions unknown: can't compute an exact scale. Fall back to the
      // larger bound as the cap rather than shrinking to 1px.
      return max(mw ?? 0, mh ?? 0)
    }
    let scaleW = mw != nil ? Double(mw!) / Double(srcW) : Double.infinity
    let scaleH = mh != nil ? Double(mh!) / Double(srcH) : Double.infinity
    let scale = min(scaleW, scaleH)
    if scale >= 1 { return nil } // fits already; don't upscale
    return max(Int((Double(max(srcW, srcH)) * scale).rounded()), 1)
  }

  private func requireType(_ format: String) throws -> CFString {
    guard let t = utType(for: format) else {
      throw CompressFailure(code: "unsupported_format",
                            message: "Format \(format) is not supported on iOS.")
    }
    return t
  }

  private func utType(for format: String) -> CFString? {
    switch format {
    case "jpeg": return "public.jpeg" as CFString
    case "png": return "public.png" as CFString
    case "heic": return "public.heic" as CFString
    // WebP: ImageIO on iOS decodes but does not encode WebP.
    default: return nil
    }
  }
}
