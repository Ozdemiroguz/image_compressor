// Edge-case + differentiator verification on the real native backend:
// large-image (OOM resistance + rough timing), EXIF orientation, corrupt input,
// and per-platform format round-trips.
//
// Run: flutter test integration_test/edge_cases_test.dart -d <device>

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_compressor/image_compressor.dart';
import 'package:integration_test/integration_test.dart';

Uint8List _jpg(img.Image image) =>
    Uint8List.fromList(img.encodeJpg(image, quality: 95));

img.Image _detailed(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = ((x ~/ 4 + y ~/ 4) % 2) * 24;
      image.setPixelRgb(x, y, (x * 255 ~/ w + d).clamp(0, 255),
          (y * 255 ~/ h + d).clamp(0, 255), 128);
    }
  }
  return image;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('toPreset.web lands under the preset ceiling + width',
      (tester) async {
    final src = _jpg(_detailed(4000, 3000));
    final result = await ImageCompressor.toPreset(
      ImageSource.bytes(src),
      SizePreset.web,
    );
    expect(result.compressedBytes, lessThanOrEqualTo(SizePreset.web.maxBytes));
    expect(result.width, lessThanOrEqualTo(SizePreset.web.maxWidth));
    expect(img.decodeJpg(result.bytes), isNotNull);
  });

  testWidgets('keepMetadata preserves multiple tags + resets orientation',
      (tester) async {
    final image = _detailed(800, 600);
    image.exif.imageIfd['Make'] = 'ICCam';
    image.exif.imageIfd['Model'] = 'X1';
    image.exif.imageIfd['Software'] = 'test-suite';
    image.exif.imageIfd['Orientation'] = 6; // must NOT survive (baked into pixels)
    final src = Uint8List.fromList(img.encodeJpg(image, quality: 95));

    final kept = await ImageCompressor.toQuality(
      ImageSource.bytes(src),
      quality: 80,
      keepMetadata: true,
    );
    final exif = img.decodeJpg(kept.bytes)!.exif.imageIfd;
    // ignore: avoid_print
    print('META kept -> Make=${exif['Make']} Software=${exif['Software']} '
        'Orientation=${exif['Orientation']}');
    expect('${exif['Make']}', 'ICCam');
    expect('${exif['Software']}', 'test-suite');
    // Orientation reset to upright (1) or absent — never the source's 6.
    expect(exif['Orientation'], anyOf(isNull, equals(1)));
  });

  testWidgets('batch of real photos + keepMetadata, all succeed on device',
      (tester) async {
    final inputs = List.generate(
        4, (i) => ImageSource.bytes(_jpg(_detailed(600 + i * 100, 400))));
    var progress = 0;
    final results = await ImageCompressor.toSizeAll(
      inputs,
      maxBytes: 100.kb,
      keepMetadata: true,
      onProgress: (done, total) => progress = done,
    );
    expect(results.whereType<BatchSuccess>().length, 4);
    expect(progress, 4);
    for (final r in results.whereType<BatchSuccess>()) {
      expect(r.image.compressedBytes, lessThanOrEqualTo(100 * 1024 + 8 * 1024));
    }
  });

  testWidgets('reachedTarget is false when the ceiling is impossible',
      (tester) async {
    final src = _jpg(_detailed(2000, 1500));
    // 1 KB for a 2000x1500 photo at min quality — unreachable.
    final result = await ImageCompressor.toSize(
      ImageSource.bytes(src),
      maxBytes: 1024,
    );
    expect(result.reachedTarget, isFalse);
    expect(result.compressedBytes, greaterThan(0)); // still a usable result
    expect(img.decodeJpg(result.bytes), isNotNull);
  });

  testWidgets('probe reads a PNG source', (tester) async {
    final png = Uint8List.fromList(img.encodePng(_detailed(640, 480)));
    final info = await ImageCompressor.probe(ImageSource.bytes(png));
    expect(info.width, 640);
    expect(info.height, 480);
    expect(info.format, ImageFormat.png);
  });

  testWidgets('platform format matrix: webp=Android, heic=iOS, other throws',
      (tester) async {
    final src = _jpg(_detailed(400, 300));
    Future<CompressedImage> compress(ImageFormat f) => ImageCompressor.toQuality(
        ImageSource.bytes(src), quality: 80, format: f);

    if (Platform.isAndroid) {
      final webp = await compress(ImageFormat.webp);
      expect(webp.format, ImageFormat.webp);
      expect(webp.compressedBytes, greaterThan(0));
      expect(() => compress(ImageFormat.heic),
          throwsA(isA<UnsupportedFormatError>()));
    } else if (Platform.isIOS) {
      final heic = await compress(ImageFormat.heic);
      expect(heic.format, ImageFormat.heic);
      expect(heic.compressedBytes, greaterThan(0));
      expect(() => compress(ImageFormat.webp),
          throwsA(isA<UnsupportedFormatError>()));
    }
  });

  testWidgets('batch isolates a bad image (0.2.0 BatchResult, on real native)',
      (tester) async {
    // Three real photos with one genuinely-undecodable blob in the middle.
    final inputs = [
      ImageSource.bytes(_jpg(_detailed(800, 600))),
      ImageSource.bytes(Uint8List.fromList(List.generate(4096, (i) => i % 256))),
      ImageSource.bytes(_jpg(_detailed(640, 480))),
    ];

    final results = await ImageCompressor.toSizeAll(inputs, maxBytes: 200.kb);

    // Every input has a result, in order; the bad one is isolated.
    expect(results.length, 3);
    expect(results[0], isA<BatchSuccess>());
    expect(results[1], isA<BatchFailure>());
    expect(results[2], isA<BatchSuccess>());
    expect((results[1] as BatchFailure).error, isA<DecodeError>());
    // ignore: avoid_print
    print('BATCH ${results.whereType<BatchSuccess>().length} ok, '
        '${results.whereType<BatchFailure>().length} failed — batch survived');
  });

  testWidgets('keepMetadata copies EXIF onto the output (real native)',
      (tester) async {
    final image = _detailed(800, 600);
    image.exif.imageIfd['Make'] = 'ImageCompressorCam';
    image.exif.imageIfd['Model'] = 'Test100';
    final src = Uint8List.fromList(img.encodeJpg(image, quality: 95));

    // Control: stripped by default.
    final stripped = await ImageCompressor.toQuality(
      ImageSource.bytes(src),
      quality: 80,
      keepMetadata: false,
    );
    expect(img.decodeJpg(stripped.bytes)!.exif.imageIfd['Make'], isNull,
        reason: 'metadata is stripped by default');

    // Treatment: preserved.
    final kept = await ImageCompressor.toQuality(
      ImageSource.bytes(src),
      quality: 80,
      keepMetadata: true,
    );
    final exif = img.decodeJpg(kept.bytes)!.exif;
    // ignore: avoid_print
    print('EXIF kept -> Make=${exif.imageIfd['Make']} Model=${exif.imageIfd['Model']}');
    expect('${exif.imageIfd['Make']}', 'ImageCompressorCam');
    expect('${exif.imageIfd['Model']}', 'Test100');
  });

  testWidgets('probe reads real dimensions + format without decoding',
      (tester) async {
    final src = _jpg(_detailed(1600, 1200));

    final info = await ImageCompressor.probe(ImageSource.bytes(src));

    // ignore: avoid_print
    print('PROBE ${info.width}x${info.height}, ${info.byteLength} bytes, '
        '${info.format}');
    expect(info.width, 1600);
    expect(info.height, 1200);
    expect(info.format, ImageFormat.jpeg);
    expect(info.byteLength, src.length);
  });

  testWidgets('large ~27MP image compresses without OOM (the differentiator)',
      (tester) async {
    // 6000x4500 = 27 MP. A naive "decode full bitmap" approach spikes ~108 MB
    // just for the ARGB buffer; this must survive via downsample-on-decode.
    final src = _jpg(_detailed(6000, 4500));

    final sw = Stopwatch()..start();
    final result = await ImageCompressor.toSize(
      ImageSource.bytes(src),
      maxBytes: 400.kb,
      maxWidth: 2000, // exercise decode-time downsampling
    );
    sw.stop();

    // ignore: avoid_print
    print('LARGE 27MP -> ${result.compressedBytes ~/ 1024} KB in ${sw.elapsedMilliseconds} ms '
        '(q=${result.usedQuality}, ${result.width}x${result.height})');

    expect(result.reachedTarget, isTrue);
    expect(result.compressedBytes, lessThanOrEqualTo(400 * 1024));
    expect(result.width, lessThanOrEqualTo(2000));
    expect(img.decodeJpg(result.bytes), isNotNull);
  });

  testWidgets('EXIF orientation is baked in (rotated source -> upright output)',
      (tester) async {
    // Stored 800x400 landscape, EXIF orientation 6 = "rotate 90° CW to display".
    // Upright is therefore 400x800 — autoOrient must produce swapped dims.
    final image = _detailed(800, 400);
    image.exif.imageIfd['Orientation'] = 6;
    final src = Uint8List.fromList(img.encodeJpg(image, quality: 95));

    final result = await ImageCompressor.toQuality(
      ImageSource.bytes(src),
      quality: 85,
      // no autoOrient arg => default true
    );

    // ignore: avoid_print
    print('ORIENT src 800x400 exif=6 -> out ${result.width}x${result.height}');
    expect(result.width, 400, reason: 'orientation should swap to upright');
    expect(result.height, 800);
  });

  testWidgets('corrupt bytes throw DecodeError, not a raw crash',
      (tester) async {
    final garbage = Uint8List.fromList(List.generate(4096, (i) => i % 256));
    expect(
      () => ImageCompressor.toQuality(
        ImageSource.bytes(garbage),
        quality: 80,
      ),
      throwsA(isA<DecodeError>()),
    );
  });

  testWidgets('platform format round-trips (jpeg + png always work)',
      (tester) async {
    final src = _jpg(_detailed(800, 600));

    for (final format in [ImageFormat.jpeg, ImageFormat.png]) {
      final result = await ImageCompressor.toQuality(
        ImageSource.bytes(src),
        quality: 80,
        format: format,
      );
      expect(result.format, format);
      expect(result.compressedBytes, greaterThan(0));
    }
  });
}
