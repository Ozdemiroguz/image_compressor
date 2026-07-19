import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';

/// Output encoding for a compressed image.
///
/// Encoder support is per-platform — requesting an unsupported one throws
/// [UnsupportedFormatError]:
///
/// | Format | Android | iOS | Web |
/// |--------|:-------:|:---:|:---:|
/// | [jpeg] |   ✓     |  ✓  |  ✓  |
/// | [png]  |   ✓     |  ✓  |  ✓  |
/// | [webp] |   ✓     |  ✗  |  ✓  |
/// | [heic] |   ✗     |  ✓  |  ✗  |
///
/// So jpeg/png are safe everywhere, webp is Android + web, and heic is iOS only.
enum ImageFormat { jpeg, png, webp, heic }

/// Named target sizes for the common cases, so you can say what an image is
/// *for* instead of picking a byte ceiling and a dimension cap by hand.
///
/// Each preset is just a `maxBytes` + `maxWidth` pair fed to
/// `ImageCompressor.toPreset`. Unlike quality presets (low/medium/high — a vague
/// number by another name), these stay true to the point of the package: you
/// name a size, it finds the quality.
enum SizePreset {
  /// A list/grid thumbnail — under 50 KB, max 400 px.
  thumbnail(maxBytes: 50 * 1024, maxWidth: 400),

  /// A profile avatar — under 150 KB, max 800 px.
  avatar(maxBytes: 150 * 1024, maxWidth: 800),

  /// A general web/upload image — under 500 KB, max 1920 px.
  web(maxBytes: 500 * 1024, maxWidth: 1920),

  /// A high-detail image — under 2 MB, max 4000 px.
  hd(maxBytes: 2 * 1024 * 1024, maxWidth: 4000);

  const SizePreset({required this.maxBytes, required this.maxWidth});

  /// The byte ceiling this preset targets.
  final int maxBytes;

  /// The longest-edge pixel cap this preset applies.
  final int maxWidth;
}

/// Where the bytes to compress come from.
///
/// One sealed type instead of four overloaded methods: a caller passes bytes, a
/// file path, an asset key, or an [XFile] (e.g. straight from `image_picker`),
/// and the same [ImageCompressor] call handles all of them.
sealed class ImageSource {
  const ImageSource();

  /// Raw bytes already in memory.
  const factory ImageSource.bytes(Uint8List data) = BytesSource;

  /// A file on disk, by path. Not supported on web (throws
  /// [SourceNotFoundError] there — the web platform has no file paths).
  const factory ImageSource.file(String path) = FileSource;

  /// A bundled asset, by key (e.g. `assets/photo.jpg`).
  const factory ImageSource.asset(String key) = AssetSource;

  /// An [XFile], the type `image_picker` / `file_picker` hand back.
  const factory ImageSource.xfile(XFile file) = XFileSource;
}

class BytesSource extends ImageSource {
  final Uint8List data;
  const BytesSource(this.data);
}

class FileSource extends ImageSource {
  final String path;
  const FileSource(this.path);
}

class AssetSource extends ImageSource {
  final String key;
  const AssetSource(this.key);
}

class XFileSource extends ImageSource {
  final XFile file;
  const XFileSource(this.file);
}

/// The result of a compression. Always returned on success — the API never
/// returns `null`. Hard failures throw a [CompressError] instead.
@immutable
class CompressedImage {
  const CompressedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.originalBytes,
    required this.format,
    required this.usedQuality,
    required this.reachedTarget,
  });

  /// The compressed image data.
  final Uint8List bytes;

  /// Width of the output in pixels (after any resize / orientation).
  final int width;

  /// Height of the output in pixels (after any resize / orientation).
  final int height;

  /// Byte length of the input, before compression.
  final int originalBytes;

  /// Byte length after compression — i.e. `bytes.length`.
  int get compressedBytes => bytes.length;

  /// The encoded format of [bytes].
  final ImageFormat format;

  /// The quality (0–100) the encoder stopped at. For a `toSize` call this is
  /// where the binary search landed.
  final int usedQuality;

  /// `toSize` only: whether the `maxBytes` ceiling was actually met. When
  /// `false`, [bytes] is the smallest result achievable at `minQuality` — still
  /// usable, never null, but above the requested size.
  final bool reachedTarget;

  /// Compressed size as a fraction of the original (0–1). Smaller is better.
  double get ratio => originalBytes == 0 ? 1 : compressedBytes / originalBytes;

  @override
  String toString() =>
      'CompressedImage(${width}x$height, $originalBytes -> $compressedBytes '
      'bytes, q=$usedQuality, format=$format, reachedTarget=$reachedTarget)';
}

/// Lightweight facts about an image, read WITHOUT fully decoding its pixels —
/// what `ImageCompressor.probe` returns. Useful for "how big is this before I
/// process it" checks (dimensions, byte size, format) on the cheap.
@immutable
class ImageProbe {
  const ImageProbe({
    required this.width,
    required this.height,
    required this.byteLength,
    required this.format,
  });

  /// Pixel width of the source image.
  final int width;

  /// Pixel height of the source image.
  final int height;

  /// Byte length of the source data.
  final int byteLength;

  /// The detected format, sniffed from the file header — or `null` if it isn't
  /// one this package recognizes (e.g. GIF, BMP).
  final ImageFormat? format;

  /// Total pixels (`width * height`).
  int get pixelCount => width * height;

  @override
  String toString() =>
      'ImageProbe(${width}x$height, $byteLength bytes, format=$format)';
}

/// The outcome of one image in a batch (`toSizeAll` / `toQualityAll`).
///
/// A batch never fails as a whole because one image is bad — each input gets its
/// own result, so a single corrupt file can't discard the others. Match on the
/// subtypes, or pull just the successes:
///
/// ```dart
/// final results = await ImageCompressor.toSizeAll(inputs, maxBytes: 500.kb);
/// final images = results.whereType<BatchSuccess>().map((r) => r.image).toList();
/// for (final r in results.whereType<BatchFailure>()) {
///   debugPrint('failed: ${r.source} — ${r.error.message}');
/// }
/// ```
sealed class BatchResult {
  const BatchResult(this.source);

  /// The input this result corresponds to.
  final ImageSource source;
}

/// A batch item that compressed successfully.
class BatchSuccess extends BatchResult {
  const BatchSuccess(super.source, this.image);

  /// The compressed result for [BatchResult.source].
  final CompressedImage image;
}

/// A batch item that failed — the others in the batch are unaffected.
class BatchFailure extends BatchResult {
  const BatchFailure(super.source, this.error);

  /// Why [BatchResult.source] could not be compressed.
  final CompressError error;
}

/// Base type for every failure this package throws. Callers can catch
/// [CompressError] broadly or match on the specific subtypes below.
sealed class CompressError implements Exception {
  const CompressError(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The requested [ImageFormat] cannot be encoded on the current platform
/// (e.g. `heic` on web).
class UnsupportedFormatError extends CompressError {
  UnsupportedFormatError(this.format)
    : super('Format $format is not supported on this platform.');
  final ImageFormat format;
}

/// The [ImageSource] could not be read (missing file, bad asset key, or a
/// file path on web).
class SourceNotFoundError extends CompressError {
  SourceNotFoundError(this.path) : super('Could not read image source: $path');
  final String path;
}

/// The bytes were read but could not be decoded as an image.
class DecodeError extends CompressError {
  DecodeError(super.reason);
}

/// Thrown when a call is cancelled via a `CancelToken`.
class CancelledError extends CompressError {
  const CancelledError() : super('The compress operation was cancelled.');
}
