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

  final int width;
  final int height;

  /// Byte length of the input, before compression.
  final int originalBytes;

  /// Byte length after compression — i.e. `bytes.length`.
  int get compressedBytes => bytes.length;

  final ImageFormat format;

  /// The quality (0–100) the encoder stopped at. For a `toSize` call this is
  /// where the binary search landed.
  final int usedQuality;

  /// `toSize` only: whether the [maxBytes] ceiling was actually met. When
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
