// Two measurements that keep the marketing honest:
//
// 1. FAIR 27MP comparison — both sides capped to the SAME 2000px. The earlier
//    benchmark let us downsample while forcing the alternative to full res,
//    which is not a fair fight. With both capped, does target-size still matter?
// 2. The cost of autoOrient — is the ~10-20% gap actually the EXIF pass, or was
//    that a guess?
//
// Run: flutter test integration_test/fairness_test.dart -d <device>

import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart' as fic;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_compressor/image_compressor.dart';
import 'package:integration_test/integration_test.dart';

Uint8List _jpg(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = ((x ~/ 4 + y ~/ 4) % 2) * 24;
      image.setPixelRgb(
        x,
        y,
        (x * 255 ~/ w + d).clamp(0, 255),
        (y * 255 ~/ h + d).clamp(0, 255),
        128,
      );
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 100));
}

Future<int> _median(int runs, Future<void> Function() body) async {
  final times = <int>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    await body();
    sw.stop();
    times.add(sw.elapsedMilliseconds);
  }
  times.sort();
  return times[times.length ~/ 2];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('FAIR: both capped to 2000px — does target-size still matter?', (
    tester,
  ) async {
    final src = _jpg(6000, 4500);

    final ours = await ImageCompressor.toSize(
      ImageSource.bytes(src),
      maxBytes: 400.kb,
      maxWidth: 2000,
    );

    // Same dimension cap for the alternative — the fair fight. It still can
    // only take a quality number, so we try a few and see what a caller would
    // actually get without hand-rolling a search.
    final rows = <String>[];
    for (final q in [90, 80, 70, 50]) {
      final out = await fic.FlutterImageCompress.compressWithList(
        src,
        quality: q,
        minWidth: 2000,
        minHeight: 1500,
      );
      final fits = out.length <= 400 * 1024 ? 'fits' : 'OVER';
      rows.add('q$q -> ${out.length ~/ 1024} KB ($fits)');
    }

    // ignore: avoid_print
    print(
      'FAIR ours(toSize 400kb, 2000px) -> ${ours.compressedBytes ~/ 1024} KB '
      'at q=${ours.usedQuality}, reachedTarget=${ours.reachedTarget}',
    );
    // ignore: avoid_print
    print('FAIR alternative(2000px, quality only): ${rows.join(" | ")}');

    expect(ours.compressedBytes, lessThanOrEqualTo(400 * 1024));
  });

  testWidgets('COST: how much does autoOrient actually cost?', (tester) async {
    final src = _jpg(3000, 2250);

    final withOrient = await _median(5, () async {
      await ImageCompressor.toQuality(
        ImageSource.bytes(src),
        quality: 80,
      ); // autoOrient defaults true
    });

    final withoutOrient = await _median(5, () async {
      await ImageCompressor.toQuality(
        ImageSource.bytes(src),
        quality: 80,
        autoOrient: false,
      );
    });

    // ignore: avoid_print
    print(
      'COST autoOrient=true: $withOrient ms | autoOrient=false: '
      '$withoutOrient ms | delta: ${withOrient - withoutOrient} ms',
    );

    expect(withOrient, greaterThan(0));
  });
}
