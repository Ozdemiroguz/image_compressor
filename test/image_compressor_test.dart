import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_compressor/image_compressor.dart';
import 'package:image_compressor/image_compressor_platform_interface.dart';
import 'package:image_compressor/src/encode_request.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Fake backend. The target-size search now runs natively, so these tests cover
/// the Dart facade's job: resolving sources, forwarding the right request, and
/// mapping the result. Search correctness itself is covered on-device.
class FakePlatform
    with MockPlatformInterfaceMixin
    implements ImageCompressorPlatform {
  EncodeSizeRequest? lastSizeRequest;
  final List<EncodeRequest> onceRequests = [];
  int concurrentNow = 0;
  int maxConcurrent = 0;

  /// If set, encodeOnce throws DecodeError for the request whose input bytes
  /// have exactly this length — used to simulate one bad image in a batch.
  int? failOnBytesLength;

  // Canned native result for encodeToSize.
  EncodeResult sizeResult = EncodeResult(
    bytes: Uint8List(4000),
    width: 640,
    height: 480,
    usedQuality: 42,
    reachedTarget: true,
  );

  @override
  Future<EncodeResult> encodeOnce(EncodeRequest request) async {
    concurrentNow++;
    maxConcurrent = concurrentNow > maxConcurrent
        ? concurrentNow
        : maxConcurrent;
    onceRequests.add(request);
    await Future<void>.delayed(Duration.zero);
    concurrentNow--;
    if (failOnBytesLength != null && request.bytes.length == failOnBytesLength) {
      throw DecodeError('simulated bad image');
    }
    return EncodeResult(
      bytes: Uint8List(2000),
      width: 640,
      height: 480,
      usedQuality: request.quality,
      reachedTarget: true,
    );
  }

  @override
  Future<EncodeResult> encodeToSize(EncodeSizeRequest request) async {
    lastSizeRequest = request;
    return sizeResult;
  }

  (int, int) probeResult = (1920, 1080);
  Uint8List? lastProbedBytes;

  @override
  Future<(int, int)> probeSize(Uint8List bytes) async {
    lastProbedBytes = bytes;
    return probeResult;
  }
}

Uint8List _input([int len = 50000]) => Uint8List(len);

void main() {
  late FakePlatform fake;

  setUp(() {
    fake = FakePlatform();
    ImageCompressorPlatform.instance = fake;
  });

  group('toSize', () {
    test(
      'forwards maxBytes/minQuality/format to the native size request',
      () async {
        await ImageCompressor.toSize(
          ImageSource.bytes(_input()),
          maxBytes: 500 * 1024,
          minQuality: 25,
          format: ImageFormat.webp,
          maxWidth: 1024,
        );

        final req = fake.lastSizeRequest!;
        expect(req.maxBytes, 500 * 1024);
        expect(req.minQuality, 25);
        expect(req.format, ImageFormat.webp);
        expect(req.maxWidth, 1024);
        expect(req.bytes.length, 50000);
      },
    );

    test(
      'maps the native result (quality + reachedTarget) onto CompressedImage',
      () async {
        fake.sizeResult = EncodeResult(
          bytes: Uint8List(9000),
          width: 100,
          height: 80,
          usedQuality: 17,
          reachedTarget: false,
        );

        final result = await ImageCompressor.toSize(
          ImageSource.bytes(_input(20000)),
          maxBytes: 1000,
        );

        expect(result.compressedBytes, 9000);
        expect(result.originalBytes, 20000);
        expect(result.usedQuality, 17);
        expect(result.reachedTarget, isFalse);
        expect(result.ratio, 9000 / 20000);
      },
    );
  });

  group('toQuality', () {
    test('passes the exact quality through encodeOnce', () async {
      final result = await ImageCompressor.toQuality(
        ImageSource.bytes(_input()),
        quality: 72,
      );
      expect(fake.onceRequests.single.quality, 72);
      expect(result.usedQuality, 72);
      expect(result.reachedTarget, isTrue);
      expect(result.width, 640);
    });
  });

  group('toQualityAll', () {
    test('preserves input order and bounds concurrency', () async {
      final inputs = List.generate(10, (i) => ImageSource.bytes(_input(i + 1)));
      final results = await ImageCompressor.toQualityAll(
        inputs,
        quality: 80,
        concurrency: 3,
      );

      expect(results.length, 10);
      expect(results.every((r) => r is BatchSuccess), isTrue);
      expect(
        results.every((r) => (r as BatchSuccess).image.usedQuality == 80),
        isTrue,
      );
      expect(fake.maxConcurrent, lessThanOrEqualTo(3));
      expect(fake.maxConcurrent, greaterThan(1));
    });

    test('one bad item becomes a BatchFailure; the rest still succeed',
        () async {
      // Make the 3rd input fail natively; the other four must survive.
      fake.failOnBytesLength = 3;
      final inputs = List.generate(5, (i) => ImageSource.bytes(_input(i + 1)));

      final results = await ImageCompressor.toQualityAll(inputs, quality: 80);

      expect(results.length, 5, reason: 'every input has a result');
      expect(results.whereType<BatchSuccess>().length, 4);
      final failure = results.whereType<BatchFailure>().single;
      expect(failure.error, isA<DecodeError>());
      // Index/order preserved: the failure is the 3rd input.
      expect(results.indexOf(failure), 2);
    });

    test('reports progress as (done, total) for every item', () async {
      final inputs = List.generate(5, (i) => ImageSource.bytes(_input(i + 1)));
      final seen = <int>[];
      await ImageCompressor.toQualityAll(
        inputs,
        quality: 70,
        concurrency: 2,
        onProgress: (done, total) {
          expect(total, 5);
          seen.add(done);
        },
      );
      // One callback per item, ending at the total, monotonically.
      expect(seen.length, 5);
      expect(seen.last, 5);
      expect(seen, List.generate(5, (i) => i + 1));
    });
  });

  group('keepMetadata', () {
    test('defaults to false and forwards true to the native request', () async {
      await ImageCompressor.toQuality(ImageSource.bytes(_input()), quality: 80);
      expect(fake.onceRequests.last.keepMetadata, isFalse);

      await ImageCompressor.toSize(
        ImageSource.bytes(_input()),
        maxBytes: 500.kb,
        keepMetadata: true,
      );
      expect(fake.lastSizeRequest!.keepMetadata, isTrue);
    });

    test('toPreset forwards keepMetadata too', () async {
      await ImageCompressor.toPreset(
        ImageSource.bytes(_input()),
        SizePreset.avatar,
        keepMetadata: true,
      );
      expect(fake.lastSizeRequest!.keepMetadata, isTrue);
      expect(fake.lastSizeRequest!.maxBytes, SizePreset.avatar.maxBytes);
    });
  });

  group('toPreset', () {
    test('web preset forwards its maxBytes + maxWidth to the size request',
        () async {
      await ImageCompressor.toPreset(
        ImageSource.bytes(_input()),
        SizePreset.web,
      );
      final req = fake.lastSizeRequest!;
      expect(req.maxBytes, SizePreset.web.maxBytes); // 500 KB
      expect(req.maxWidth, SizePreset.web.maxWidth); // 1920
    });

    test('preset values are the documented size-first pairs', () {
      expect(SizePreset.thumbnail.maxBytes, 50 * 1024);
      expect(SizePreset.thumbnail.maxWidth, 400);
      expect(SizePreset.hd.maxBytes, 2 * 1024 * 1024);
      expect(SizePreset.hd.maxWidth, 4000);
    });
  });

  group('probe', () {
    test('returns native dims + sniffed format + byte length', () async {
      fake.probeResult = (4000, 3000);
      // JPEG magic bytes (FF D8 FF) + padding.
      final jpeg = Uint8List.fromList(
          [0xFF, 0xD8, 0xFF, ...List.filled(97, 0)]);

      final info = await ImageCompressor.probe(ImageSource.bytes(jpeg));

      expect(info.width, 4000);
      expect(info.height, 3000);
      expect(info.byteLength, 100);
      expect(info.format, ImageFormat.jpeg);
      expect(info.pixelCount, 12000000);
      expect(fake.lastProbedBytes, jpeg);
    });

    test('format is null for an unrecognized header', () async {
      final unknown = Uint8List.fromList(List.filled(64, 0x42));
      final info = await ImageCompressor.probe(ImageSource.bytes(unknown));
      expect(info.format, isNull);
    });

    test('sniffs png / webp / heic from their headers', () async {
      Future<ImageFormat?> fmt(List<int> header) async {
        final b = Uint8List.fromList([...header, ...List.filled(64, 0)]);
        return (await ImageCompressor.probe(ImageSource.bytes(b))).format;
      }

      expect(await fmt([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
          ImageFormat.png);
      // "RIFF" + 4 size bytes + "WEBP"
      expect(
        await fmt([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]),
        ImageFormat.webp,
      );
      // 4 size bytes + "ftyp" + "heic"
      expect(
        await fmt([0, 0, 0, 0, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]),
        ImageFormat.heic,
      );
    });
  });

  group('ByteSize helpers', () {
    test('.kb and .mb use binary units', () {
      expect(500.kb, 500 * 1024);
      expect(2.mb, 2 * 1024 * 1024);
      expect(1.mb, 1024.kb);
    });
  });

  group('validation (release-safe, not just asserts)', () {
    test('toSize rejects non-positive maxBytes', () {
      expect(
        () => ImageCompressor.toSize(ImageSource.bytes(_input()), maxBytes: 0),
        throwsArgumentError,
      );
    });

    test('toQuality rejects out-of-range quality', () {
      expect(
        () => ImageCompressor.toQuality(
          ImageSource.bytes(_input()),
          quality: 150,
        ),
        throwsArgumentError,
      );
    });

    test('batch rejects concurrency < 1', () {
      expect(
        () => ImageCompressor.toQualityAll(
          [ImageSource.bytes(_input())],
          quality: 80,
          concurrency: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('cancellation', () {
    test('a pre-cancelled token makes toSize throw CancelledError', () async {
      final token = CancelToken()..cancel();
      expect(
        () => ImageCompressor.toSize(
          ImageSource.bytes(_input()),
          maxBytes: 1000,
          cancelToken: token,
        ),
        throwsA(isA<CancelledError>()),
      );
    });

    test('cancelling mid-batch stops launching new work', () async {
      final inputs = List.generate(20, (i) => ImageSource.bytes(_input(i + 1)));
      final token = CancelToken();

      expect(
        () => ImageCompressor.toQualityAll(
          inputs,
          quality: 80,
          concurrency: 2,
          cancelToken: token,
          onProgress: (done, total) {
            if (done >= 2) token.cancel();
          },
        ),
        throwsA(isA<CancelledError>()),
      );
    });
  });

  group('saveTo', () {
    test('writes the compressed bytes to disk and returns the path', () async {
      final result = await ImageCompressor.toQuality(
        ImageSource.bytes(_input()),
        quality: 80,
      );

      final dir = await Directory.systemTemp.createTemp(
        'image_compressor_test',
      );
      final path = '${dir.path}/out.jpg';
      final written = await result.saveTo(path);

      expect(written, path);
      final onDisk = await File(path).readAsBytes();
      expect(onDisk, result.bytes);

      await dir.delete(recursive: true);
    });
  });
}
