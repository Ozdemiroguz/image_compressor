import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

/// Native file read (dart:io). Throws [SourceNotFoundError] if the path is
/// missing or unreadable.
Future<Uint8List> readFileBytes(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    throw SourceNotFoundError(path);
  }
  try {
    return await file.readAsBytes();
  } catch (_) {
    throw SourceNotFoundError(path);
  }
}
