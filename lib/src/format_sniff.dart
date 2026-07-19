import 'dart:typed_data';

import 'models.dart';

/// Detects an image [ImageFormat] from the file header (magic bytes), without
/// decoding. Returns `null` for anything this package doesn't enumerate (GIF,
/// BMP, TIFF, …). Platform-independent, so probe reports the same format
/// everywhere.
ImageFormat? sniffFormat(Uint8List b) {
  // JPEG: FF D8 FF
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return ImageFormat.jpeg;
  }
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A) {
    return ImageFormat.png;
  }
  // WebP: "RIFF" .... "WEBP"
  if (b.length >= 12 &&
      b[0] == 0x52 && // R
      b[1] == 0x49 && // I
      b[2] == 0x46 && // F
      b[3] == 0x46 && // F
      b[8] == 0x57 && // W
      b[9] == 0x45 && // E
      b[10] == 0x42 && // B
      b[11] == 0x50) {
    // P
    return ImageFormat.webp;
  }
  // HEIC / HEIF: ISOBMFF box "ftyp" at offset 4, brand heic/heix/hevc/mif1/msf1
  if (b.length >= 12 &&
      b[4] == 0x66 && // f
      b[5] == 0x74 && // t
      b[6] == 0x79 && // y
      b[7] == 0x70) {
    // p
    final brand = String.fromCharCodes(b.sublist(8, 12));
    const heicBrands = {'heic', 'heix', 'hevc', 'heim', 'heis', 'mif1', 'msf1'};
    if (heicBrands.contains(brand)) return ImageFormat.heic;
  }
  return null;
}
