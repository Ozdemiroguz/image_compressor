import 'dart:typed_data';

/// Web has no writable filesystem paths. Callers should use the bytes directly
/// (an `<a download>`, an upload, a blob URL) instead of `saveTo`.
Future<String> writeBytes(String path, Uint8List bytes) async {
  throw UnsupportedError(
    'saveTo is not available on web (no filesystem). Use CompressedImage.bytes '
    'directly — e.g. an anchor download or an upload.',
  );
}
