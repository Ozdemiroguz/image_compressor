import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'image_compressor_platform_interface.dart';
import 'src/encode_request.dart';
import 'src/models.dart';

/// Method-channel backend used on Android and iOS.
class MethodChannelImageCompressor extends ImageCompressorPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('image_compressor');

  @override
  Future<EncodeResult> encodeOnce(EncodeRequest request) {
    return _invoke('encodeOnce', request.toMap(), request.format);
  }

  @override
  Future<EncodeResult> encodeToSize(EncodeSizeRequest request) {
    return _invoke('encodeToSize', request.toMap(), request.format);
  }

  Future<EncodeResult> _invoke(
    String method,
    Map<String, Object?> args,
    ImageFormat format,
  ) async {
    try {
      final map = await methodChannel.invokeMethod<Map<Object?, Object?>>(
        method,
        args,
      );
      if (map == null) {
        throw DecodeError('Native $method returned no data.');
      }
      return EncodeResult.fromMap(map);
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'unsupported_format':
          throw UnsupportedFormatError(format);
        case 'decode_error':
          throw DecodeError(e.message ?? 'Failed to decode image.');
        default:
          throw DecodeError(e.message ?? e.code);
      }
    }
  }
}
