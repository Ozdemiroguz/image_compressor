// Head-to-head benchmark vs the incumbent (flutter_image_compress) on identical
// inputs, on the real native backend.
//
// METHODOLOGY (learned the hard way — the first version of this file was biased):
//  * WARM UP both sides before timing. Whoever runs first eats JIT / native lib
//    load / allocator warmup. The original ran us first, every time, and made us
//    look ~20% slower than we are.
//  * Run BOTH orders (A→B and B→A) and report both, so ordering bias is visible
//    rather than hidden.
//  * Compare like for like: the incumbent does not do EXIF orientation, so the
//    apples-to-apples row is ours with autoOrient: false. The default-on row is
//    also reported — that's the honest "what you actually get" number.
//
// Run: flutter test integration_test/benchmark_test.dart -d <device>
// Numbers are device-dependent; the RELATIVE comparison on one device is the point.

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

/// Median elapsed ms over [runs], after [warmup] untimed runs.
Future<int> _median(
  int runs,
  Future<void> Function() body, {
  int warmup = 2,
}) async {
  for (var i = 0; i < warmup; i++) {
    await body();
  }
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

  testWidgets('timing vs the incumbent, warmed up and in both orders', (
    tester,
  ) async {
    const sizes = [
      [800, 600],
      [1600, 1200],
      [3000, 2250],
    ];

    // Global warmup: load both plugins' native paths before anything is timed.
    final seed = _jpg(800, 600);
    await ImageCompressor.toQuality(ImageSource.bytes(seed), quality: 80);
    await fic.FlutterImageCompress.compressWithList(seed, quality: 80);

    // ignore: avoid_print
    print('BENCH ─ ours(orient off) | ours(orient on) | incumbent ─ ms');
    for (final s in sizes) {
      final w = s[0], h = s[1];
      final src = _jpg(w, h);

      Future<void> oursPlain() => ImageCompressor.toQuality(
        ImageSource.bytes(src),
        quality: 80,
        autoOrient: false, // like-for-like: the incumbent doesn't orient
      );
      Future<void> oursDefault() =>
          ImageCompressor.toQuality(ImageSource.bytes(src), quality: 80);
      Future<void> theirs() => fic.FlutterImageCompress.compressWithList(
        src,
        quality: 80,
        minWidth: w,
        minHeight: h,
      );

      // Order A: ours first, then theirs.
      final aOurs = await _median(5, oursPlain);
      final aTheirs = await _median(5, theirs);
      // Order B: theirs first, then ours — exposes any residual ordering bias.
      final bTheirs = await _median(5, theirs);
      final bOurs = await _median(5, oursPlain);

      final oursOrient = await _median(5, oursDefault);

      // ignore: avoid_print
      print(
        'BENCH ${w}x$h | ours $aOurs/$bOurs | theirs $aTheirs/$bTheirs '
        '| ours+orient $oursOrient',
      );
    }
  });
}
