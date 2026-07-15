// End-to-end tests that exercise the REAL native backend on a device/emulator.
// Unlike the unit tests (fake platform), these feed genuine image bytes through
// the platform channel into Kotlin/Swift/JS and verify the bytes that come back
// are actually a smaller, decodable image of the right size.
//
// Run: flutter test integration_test -d <device>
// https://flutter.dev/to/integration-testing

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_compressor/image_compressor.dart';
import 'package:integration_test/integration_test.dart';

/// A real, decodable PNG of [w]x[h] with a smooth gradient — photo-like and
/// compressible (not high-frequency noise, which JPEG handles poorly and which
/// wouldn't represent a real camera image).
Uint8List makePng(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, x * 255 ~/ w, y * 255 ~/ h, 128);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

/// Raw uncompressed RGB size — any real JPEG/PNG output is smaller than this.
int rawSize(int w, int h) => w * h * 3;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('toQuality returns a smaller, decodable JPEG of the same size',
      (tester) async {
    final src = makePng(1600, 1200);
    final result = await ImageCompressor.toQuality(
      ImageSource.bytes(src),
      quality: 40,
      format: ImageFormat.jpeg,
    );

    expect(result.width, 1600);
    expect(result.height, 1200);
    expect(result.compressedBytes, greaterThan(0));
    expect(result.compressedBytes, lessThan(rawSize(1600, 1200)),
        reason: 'JPEG q40 must be smaller than raw RGB');

    // The bytes must be a genuinely decodable JPEG at the right dimensions.
    final decoded = img.decodeJpg(result.bytes);
    expect(decoded, isNotNull);
    expect(decoded!.width, 1600);
    expect(decoded.height, 1200);
  });

  testWidgets('toSize lands under the byte ceiling', (tester) async {
    final src = makePng(2400, 1800);
    final result = await ImageCompressor.toSize(
      ImageSource.bytes(src),
      maxBytes: 150.kb,
      format: ImageFormat.jpeg,
    );

    expect(result.reachedTarget, isTrue,
        reason: 'a compressible gradient should fit under 150 KB');
    expect(result.compressedBytes, lessThanOrEqualTo(150 * 1024));
    expect(result.usedQuality, inInclusiveRange(10, 100));
    expect(img.decodeJpg(result.bytes), isNotNull);
  });

  testWidgets('maxWidth caps output dimensions, aspect preserved',
      (tester) async {
    final src = makePng(2000, 1000);
    final result = await ImageCompressor.toQuality(
      ImageSource.bytes(src),
      quality: 80,
      format: ImageFormat.jpeg,
      maxWidth: 500,
    );

    expect(result.width, lessThanOrEqualTo(500));
    // 2:1 aspect preserved (allow ±1px rounding).
    expect((result.width / 2 - result.height).abs(), lessThanOrEqualTo(1));
  });
}
