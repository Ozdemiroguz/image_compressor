import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_compressor/image_compressor.dart';
import 'package:image_compressor/image_compressor_method_channel.dart';
import 'package:image_compressor/src/encode_request.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelImageCompressor();
  const channel = MethodChannel('image_compressor');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('encodeOnce forwards the request map and parses the result', () async {
    late MethodCall received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <Object?, Object?>{
        'bytes': Uint8List(123),
        'width': 100,
        'height': 80,
      };
    });

    final result = await platform.encodeOnce(
      EncodeRequest(
        bytes: Uint8List(999),
        quality: 65,
        format: ImageFormat.webp,
        autoOrient: true,
        maxWidth: 800,
      ),
    );

    expect(received.method, 'encodeOnce');
    final args = received.arguments as Map<Object?, Object?>;
    expect(args['quality'], 65);
    expect(args['format'], 'webp');
    expect(args['autoOrient'], true);
    expect(args['maxWidth'], 800);
    expect(result.bytes.length, 123);
    expect(result.width, 100);
    expect(result.height, 80);
  });

  test(
    'encodeToSize forwards size params and parses quality/reachedTarget',
    () async {
      late MethodCall received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return <Object?, Object?>{
          'bytes': Uint8List(456),
          'width': 200,
          'height': 150,
          'usedQuality': 37,
          'reachedTarget': false,
        };
      });

      final result = await platform.encodeToSize(
        EncodeSizeRequest(
          bytes: Uint8List(999),
          maxBytes: 500 * 1024,
          minQuality: 20,
          format: ImageFormat.jpeg,
          autoOrient: true,
        ),
      );

      expect(received.method, 'encodeToSize');
      final args = received.arguments as Map<Object?, Object?>;
      expect(args['maxBytes'], 500 * 1024);
      expect(args['minQuality'], 20);
      expect(result.bytes.length, 456);
      expect(result.usedQuality, 37);
      expect(result.reachedTarget, isFalse);
    },
  );

  test('malformed native reply (missing keys) throws DecodeError', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <Object?, Object?>{'bytes': Uint8List(10)}; // no width/height
    });

    expect(
      () => platform.encodeOnce(
        EncodeRequest(
          bytes: Uint8List(10),
          quality: 80,
          format: ImageFormat.jpeg,
          autoOrient: true,
        ),
      ),
      throwsA(isA<DecodeError>()),
    );
  });

  test(
    'maps unsupported_format PlatformException to UnsupportedFormatError',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unsupported_format');
      });

      expect(
        () => platform.encodeOnce(
          EncodeRequest(
            bytes: Uint8List(10),
            quality: 80,
            format: ImageFormat.heic,
            autoOrient: false,
          ),
        ),
        throwsA(isA<UnsupportedFormatError>()),
      );
    },
  );
}
