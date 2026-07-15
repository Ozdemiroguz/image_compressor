import 'models.dart';

/// Cooperative cancellation handle for compress calls.
///
/// Cancellation is checked at boundaries — before a source is read, before the
/// native call is dispatched, and before each item of a batch starts. A native
/// call already in flight runs to completion: for `toSize` that is the WHOLE
/// quality search (up to a handful of sequential encodes), not a single encode,
/// since the platform codecs are not interruptible. A large `toSizeAll`/
/// `toQualityAll` stops launching new work as soon as it is cancelled.
///
/// ```dart
/// final token = CancelToken();
/// // later, e.g. user leaves the screen:
/// token.cancel();
/// ```
class CancelToken {
  bool _cancelled = false;

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// Request cancellation. Idempotent.
  void cancel() => _cancelled = true;

  /// Throws [CancelledError] if this token has been cancelled.
  void throwIfCancelled() {
    if (_cancelled) throw const CancelledError();
  }
}
