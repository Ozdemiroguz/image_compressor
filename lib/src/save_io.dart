import 'dart:io';
import 'dart:typed_data';

/// Writes [bytes] to [path] and returns the written path. Native only.
Future<String> writeBytes(String path, Uint8List bytes) async {
  final file = File(path);
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
