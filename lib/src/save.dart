import 'models.dart';
// dart:io on native, a throwing stub on web.
import 'save_io.dart' if (dart.library.js_interop) 'save_web.dart';

/// Convenience for writing a [CompressedImage] to disk.
///
/// Returns the written path. Not available on web (throws [UnsupportedError] —
/// use [CompressedImage.bytes] directly there).
extension CompressedImageSave on CompressedImage {
  Future<String> saveTo(String path) => writeBytes(path, bytes);
}
