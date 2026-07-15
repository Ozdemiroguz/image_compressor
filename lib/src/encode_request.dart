import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'models.dart';

/// A fixed-quality encode: "encode these bytes once, at this quality, into this
/// format, optionally downscaled and orientation-corrected." Backs `toQuality`.
@internal
@immutable
class EncodeRequest {
  const EncodeRequest({
    required this.bytes,
    required this.quality,
    required this.format,
    required this.autoOrient,
    this.maxWidth,
    this.maxHeight,
  });

  /// Raw source image bytes (already resolved from the [ImageSource]).
  final Uint8List bytes;

  /// Target quality, 0–100.
  final int quality;

  final ImageFormat format;

  /// Rotate pixels to match EXIF orientation and drop the orientation tag, so
  /// the output looks upright everywhere. Backends must decode at reduced size
  /// (never load the full bitmap) to keep large images from OOM-ing.
  final bool autoOrient;

  /// Optional bound on the long/each edge; aspect ratio is preserved.
  final int? maxWidth;
  final int? maxHeight;

  /// Serialized form sent across the method channel.
  Map<String, Object?> toMap() => {
    'bytes': bytes,
    'quality': quality,
    'format': format.name,
    'autoOrient': autoOrient,
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
  };
}

/// A target-size encode: "decode these bytes ONCE, then binary-search quality
/// down to [minQuality] until the output fits under [maxBytes]." Backs `toSize`.
///
/// The search runs natively so the image is decoded a single time (not once per
/// quality probe) and the bytes cross the method channel a single time — the
/// efficient path for the headline feature on large images.
@internal
@immutable
class EncodeSizeRequest {
  const EncodeSizeRequest({
    required this.bytes,
    required this.maxBytes,
    required this.minQuality,
    required this.format,
    required this.autoOrient,
    this.maxWidth,
    this.maxHeight,
  });

  final Uint8List bytes;
  final int maxBytes;
  final int minQuality;
  final ImageFormat format;
  final bool autoOrient;
  final int? maxWidth;
  final int? maxHeight;

  Map<String, Object?> toMap() => {
    'bytes': bytes,
    'maxBytes': maxBytes,
    'minQuality': minQuality,
    'format': format.name,
    'autoOrient': autoOrient,
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
  };
}

/// What a backend returns from an encode: the bytes, the decoded dimensions,
/// the quality actually used, and whether a target-size search met its ceiling.
///
/// For a fixed-quality [EncodeRequest] the backend echoes the requested quality
/// and sets [reachedTarget] true. For an [EncodeSizeRequest] the backend fills
/// in the quality the search landed on and whether it fit under `maxBytes`.
@internal
@immutable
class EncodeResult {
  const EncodeResult({
    required this.bytes,
    required this.width,
    required this.height,
    required this.usedQuality,
    required this.reachedTarget,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int usedQuality;
  final bool reachedTarget;

  factory EncodeResult.fromMap(Map<Object?, Object?> map) {
    final bytes = map['bytes'];
    final width = map['width'];
    final height = map['height'];
    if (bytes is! Uint8List || width is! num || height is! num) {
      throw DecodeError('Malformed native encode result: $map');
    }
    return EncodeResult(
      bytes: bytes,
      width: width.toInt(),
      height: height.toInt(),
      usedQuality: (map['usedQuality'] as num?)?.toInt() ?? 0,
      reachedTarget: (map['reachedTarget'] as bool?) ?? true,
    );
  }
}
