import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'image_compressor_method_channel.dart';
import 'src/encode_request.dart';

/// The contract every platform backend implements.
///
/// Two native operations: [encodeOnce] (fixed quality) and [encodeToSize]
/// (decode once, binary-search quality to a byte ceiling). Source resolution
/// and batching stay in the Dart facade; the compute-heavy work is native so a
/// target-size search decodes the image only once.
abstract class ImageCompressorPlatform extends PlatformInterface {
  ImageCompressorPlatform() : super(token: _token);

  static final Object _token = Object();

  static ImageCompressorPlatform _instance = MethodChannelImageCompressor();

  static ImageCompressorPlatform get instance => _instance;

  static set instance(ImageCompressorPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Encode [request] exactly once and return the resulting bytes plus decoded
  /// dimensions. Backends must decode at a reduced size when `maxWidth`/
  /// `maxHeight` are set (downsample-on-decode) to avoid loading huge bitmaps
  /// into memory.
  Future<EncodeResult> encodeOnce(EncodeRequest request) {
    throw UnimplementedError('encodeOnce() has not been implemented.');
  }

  /// Decode [request] once, then binary-search quality down to `minQuality`
  /// until the output fits under `maxBytes`. Returns the best fitting result,
  /// or (if nothing fits) the smallest achievable with `reachedTarget` false.
  Future<EncodeResult> encodeToSize(EncodeSizeRequest request) {
    throw UnimplementedError('encodeToSize() has not been implemented.');
  }
}
