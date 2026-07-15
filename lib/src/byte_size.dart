/// Readable byte sizes for `maxBytes`, so you write `500.kb` / `2.mb` instead
/// of `500 * 1024`.
///
/// ```dart
/// await ImageCompressor.toSize(input, maxBytes: 500.kb);
/// await ImageCompressor.toSize(input, maxBytes: 2.mb);
/// ```
///
/// Uses binary units (1 KB = 1024 bytes), matching how file-size limits are
/// usually meant.
extension ByteSize on int {
  /// This many kibibytes, in bytes (`* 1024`).
  int get kb => this * 1024;

  /// This many mebibytes, in bytes (`* 1024 * 1024`).
  int get mb => this * 1024 * 1024;
}
