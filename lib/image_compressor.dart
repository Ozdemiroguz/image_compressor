import 'dart:async';

import 'image_compressor_platform_interface.dart';
import 'src/cancel_token.dart';
import 'src/encode_request.dart';
import 'src/format_sniff.dart';
import 'src/models.dart';
import 'src/source_loader.dart';

export 'src/byte_size.dart' show ByteSize;
export 'src/cancel_token.dart' show CancelToken;
export 'src/models.dart'
    show
        ImageFormat,
        ImageSource,
        SizePreset,
        CompressedImage,
        ImageProbe,
        BatchResult,
        BatchSuccess,
        BatchFailure,
        CompressError,
        UnsupportedFormatError,
        SourceNotFoundError,
        DecodeError,
        CancelledError;
export 'src/save.dart' show CompressedImageSave;

/// Compress images in Flutter with a single call.
///
/// The headline feature is [toSize]: give it a byte ceiling and it finds the
/// quality that lands the image under that size — no hand-rolled quality loop.
/// [toQuality] is the familiar fixed-quality mode. Both work the same across
/// Android, iOS and web, take any [ImageSource], and never return `null`
/// (hard failures throw a [CompressError]).
class ImageCompressor {
  ImageCompressor._();

  /// Read an image's dimensions, byte size and format WITHOUT decoding its
  /// pixels — cheap enough to run on every picked file before deciding whether
  /// (or how) to compress it.
  ///
  /// ```dart
  /// final info = await ImageCompressor.probe(ImageSource.xfile(picked));
  /// if (info.byteLength > 1.mb || info.width > 4000) {
  ///   await ImageCompressor.toSize(ImageSource.xfile(picked), maxBytes: 500.kb);
  /// }
  /// ```
  ///
  /// Throws [SourceNotFoundError] if the source can't be read, or [DecodeError]
  /// if the bytes aren't a readable image.
  static Future<ImageProbe> probe(ImageSource input) async {
    final bytes = await resolveSource(input);
    final (width, height) =
        await ImageCompressorPlatform.instance.probeSize(bytes);
    return ImageProbe(
      width: width,
      height: height,
      byteLength: bytes.length,
      format: sniffFormat(bytes),
    );
  }

  /// Compress [input] to a named [SizePreset] — a `maxBytes` + `maxWidth` pair
  /// for a common case, so you say what the image is *for* instead of tuning
  /// numbers.
  ///
  /// ```dart
  /// // "I need a web-sized version" — under 500 KB, max 1920 px.
  /// final image = await ImageCompressor.toPreset(
  ///   ImageSource.xfile(picked),
  ///   SizePreset.web,
  /// );
  /// ```
  static Future<CompressedImage> toPreset(
    ImageSource input,
    SizePreset preset, {
    ImageFormat format = ImageFormat.jpeg,
    bool autoOrient = true,
    CancelToken? cancelToken,
  }) {
    return toSize(
      input,
      maxBytes: preset.maxBytes,
      maxWidth: preset.maxWidth,
      format: format,
      autoOrient: autoOrient,
      cancelToken: cancelToken,
    );
  }

  /// Compress [input] until it fits under [maxBytes].
  ///
  /// The native backend decodes once and binary-searches quality (down to
  /// [minQuality]), returning the highest-quality result that still fits. If
  /// even [minQuality] is too big, it returns the smallest achievable result
  /// with [CompressedImage.reachedTarget] == false (never throws for that — you
  /// still get usable bytes).
  ///
  /// This targets a size in the requested [format]; it does not guarantee the
  /// output is smaller than the input. A source that is already tiny in a more
  /// efficient format (e.g. a small PNG re-encoded to JPEG) can grow while still
  /// fitting under [maxBytes]. Compare [CompressedImage.compressedBytes] to
  /// [CompressedImage.originalBytes] if you want to keep the smaller one.
  ///
  /// ```dart
  /// final image = await ImageCompressor.toSize(
  ///   ImageSource.xfile(pickedPhoto), // e.g. from image_picker
  ///   maxBytes: 500.kb,               // "get it under 500 KB"
  /// );
  /// print('${image.originalBytes} -> ${image.compressedBytes} bytes');
  /// await image.saveTo('/path/out.jpg');
  /// ```
  static Future<CompressedImage> toSize(
    ImageSource input, {
    required int maxBytes,
    ImageFormat format = ImageFormat.jpeg,
    int? maxWidth,
    int? maxHeight,
    bool autoOrient = true,
    int minQuality = 10,
    CancelToken? cancelToken,
  }) async {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
    }
    if (minQuality < 0 || minQuality > 100) {
      throw ArgumentError.value(minQuality, 'minQuality', 'must be 0..100');
    }

    cancelToken?.throwIfCancelled();
    final bytes = await resolveSource(input);
    cancelToken?.throwIfCancelled();
    final result = await ImageCompressorPlatform.instance.encodeToSize(
      EncodeSizeRequest(
        bytes: bytes,
        maxBytes: maxBytes,
        minQuality: minQuality,
        format: format,
        autoOrient: autoOrient,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ),
    );
    return _toCompressed(
      result,
      originalBytes: bytes.length,
      format: format,
      usedQuality: result.usedQuality,
      reachedTarget: result.reachedTarget,
    );
  }

  /// Compress [input] at a fixed [quality] (0–100).
  ///
  /// ```dart
  /// final image = await ImageCompressor.toQuality(
  ///   ImageSource.file('/path/photo.jpg'),
  ///   quality: 80,
  ///   maxWidth: 1920, // optional: also cap dimensions, aspect preserved
  /// );
  /// ```
  static Future<CompressedImage> toQuality(
    ImageSource input, {
    required int quality,
    ImageFormat format = ImageFormat.jpeg,
    int? maxWidth,
    int? maxHeight,
    bool autoOrient = true,
    CancelToken? cancelToken,
  }) async {
    if (quality < 0 || quality > 100) {
      throw ArgumentError.value(quality, 'quality', 'must be 0..100');
    }

    cancelToken?.throwIfCancelled();
    final bytes = await resolveSource(input);
    cancelToken?.throwIfCancelled();
    final result = await ImageCompressorPlatform.instance.encodeOnce(
      EncodeRequest(
        bytes: bytes,
        quality: quality,
        format: format,
        autoOrient: autoOrient,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ),
    );
    return _toCompressed(
      result,
      originalBytes: bytes.length,
      format: format,
      usedQuality: quality,
      reachedTarget: true,
    );
  }

  /// [toSize] over many images, at most [concurrency] in flight at once (keeps
  /// peak memory bounded — the fix for "iOS crashes compressing in a loop").
  ///
  /// ```dart
  /// final results = await ImageCompressor.toSizeAll(
  ///   photos.map(ImageSource.xfile).toList(),
  ///   maxBytes: 300.kb,
  ///   concurrency: 3,
  ///   onProgress: (done, total) => print('$done / $total'),
  /// );
  /// final images = results.whereType<BatchSuccess>().map((r) => r.image);
  /// ```
  /// Returns one [BatchResult] per input, in order — a [BatchSuccess] or a
  /// [BatchFailure]. A single unreadable image can't sink the batch; only a
  /// [CancelToken] cancellation throws (aborting the whole operation).
  static Future<List<BatchResult>> toSizeAll(
    List<ImageSource> inputs, {
    required int maxBytes,
    ImageFormat format = ImageFormat.jpeg,
    int? maxWidth,
    int? maxHeight,
    bool autoOrient = true,
    int minQuality = 10,
    int concurrency = 3,
    void Function(int done, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return _pooled(
      inputs,
      concurrency,
      (input) => _guard(
        input,
        () => toSize(
          input,
          maxBytes: maxBytes,
          format: format,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          autoOrient: autoOrient,
          minQuality: minQuality,
          cancelToken: cancelToken,
        ),
      ),
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// [toQuality] over many images, at most [concurrency] in flight at once.
  ///
  /// Returns one [BatchResult] per input, in order (see [toSizeAll]).
  static Future<List<BatchResult>> toQualityAll(
    List<ImageSource> inputs, {
    required int quality,
    ImageFormat format = ImageFormat.jpeg,
    int? maxWidth,
    int? maxHeight,
    bool autoOrient = true,
    int concurrency = 3,
    void Function(int done, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return _pooled(
      inputs,
      concurrency,
      (input) => _guard(
        input,
        () => toQuality(
          input,
          quality: quality,
          format: format,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          autoOrient: autoOrient,
          cancelToken: cancelToken,
        ),
      ),
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Runs one compress and turns its outcome into a [BatchResult]. A
  /// [CancelledError] is rethrown so it aborts the whole batch; every other
  /// [CompressError] becomes a [BatchFailure] so one bad image is isolated.
  static Future<BatchResult> _guard(
    ImageSource input,
    Future<CompressedImage> Function() run,
  ) async {
    try {
      return BatchSuccess(input, await run());
    } on CancelledError {
      rethrow;
    } on CompressError catch (e) {
      return BatchFailure(input, e);
    }
  }

  static CompressedImage _toCompressed(
    EncodeResult result, {
    required int originalBytes,
    required ImageFormat format,
    required int usedQuality,
    required bool reachedTarget,
  }) {
    return CompressedImage(
      bytes: result.bytes,
      width: result.width,
      height: result.height,
      originalBytes: originalBytes,
      format: format,
      usedQuality: usedQuality,
      reachedTarget: reachedTarget,
    );
  }

  /// Runs [task] over [items] with a bounded number of concurrent futures,
  /// preserving input order in the result. Reports completions via [onProgress]
  /// as `(done, total)` after each item finishes.
  static Future<List<R>> _pooled<T, R>(
    List<T> items,
    int concurrency,
    Future<R> Function(T) task, {
    void Function(int done, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'must be >= 1');
    }
    final results = List<R?>.filled(items.length, null);
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        // Stop pulling new work once cancelled; in-flight items finish.
        cancelToken?.throwIfCancelled();
        final i = next++;
        if (i >= items.length) return;
        results[i] = await task(items[i]);
        onProgress?.call(++done, items.length);
      }
    }

    final count = concurrency < items.length ? concurrency : items.length;
    final workers = List.generate(count, (_) => worker());
    await Future.wait(workers);
    return results.cast<R>();
  }
}
