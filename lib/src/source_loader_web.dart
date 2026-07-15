import 'dart:typed_data';

import 'models.dart';

/// Web has no file-path filesystem: `ImageSource.file` is meaningless here.
/// Callers on web should use `ImageSource.bytes` or `ImageSource.xfile`.
Future<Uint8List> readFileBytes(String path) async {
  throw SourceNotFoundError(
    'ImageSource.file is not supported on web (no filesystem paths). '
    'Use ImageSource.bytes or ImageSource.xfile instead. Got: $path',
  );
}
