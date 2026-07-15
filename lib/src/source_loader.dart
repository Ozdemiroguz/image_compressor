import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'models.dart';
// dart:io is unavailable on web, so file reads go through a conditional import:
// the IO backend on native, a throwing stub on web.
import 'source_loader_io.dart'
    if (dart.library.js_interop) 'source_loader_web.dart'
    as file_io;

/// Resolves any [ImageSource] to raw bytes, throwing [SourceNotFoundError] when
/// it cannot be read.
Future<Uint8List> resolveSource(ImageSource source) async {
  switch (source) {
    case BytesSource(:final data):
      return data;
    case AssetSource(:final key):
      try {
        final data = await rootBundle.load(key);
        return data.buffer.asUint8List();
      } catch (_) {
        throw SourceNotFoundError(key);
      }
    case XFileSource(:final file):
      try {
        return await file.readAsBytes();
      } catch (_) {
        throw SourceNotFoundError(file.path);
      }
    case FileSource(:final path):
      return file_io.readFileBytes(path);
  }
}
