# image_compressor — Design Doc

> Working folder name: `image_compressor`. **Final pub.dev package name is an OPEN DECISION** (see §7).
> Author's second pub.dev package after `document_scan`. Same audience (Flutter media/camera devs).
> Goal: real adoption (downloads + likes), NOT filling an empty niche. Formula = single clear task +
> simple API + high demand + weak/stale incumbent + solo-dev-buildable.

---

## 1. Why this package

PDF domain researched first → SATURATED (generation, merge, viewer, annotation, forms all covered). Dropped.

Broadened to three families (camera/image, file/storage, device-bridge). Findings:
- **Device/native-bridge = DEAD.** permission_handler (5.9k likes), connectivity_plus (4.07k), sensors_plus —
  all first-party / federated / Flutter Favorite. Solo dev cannot compete head-on.
- **File/storage = one real pain (zip streaming OOM), narrow demand.**
- **Camera/image = strongest signal, in the compression sub-area.**

## 2. Competitive landscape (verified, mid-2026)

| Package | Likes / weekly dl | Age | Target-size | Orientation | Web | OOM auto |
|---|---|---|---|---|---|---|
| flutter_image_compress | 1.8k / 803k | 18mo stale | ❌ | ❌ broken (strips EXIF, flips) | ⚠️ pica script-tag hell | ❌ |
| fast_image_compress | 44 / 631 | 19mo stale | ❌ | ✅ | ❌ (iOS/Android only) | ❌ |
| media_compressor | 37 / 573 | 8mo | ❌ | ✅ | ❌ (iOS/Android only) | ❌ |

Reading: the 803k-download incumbent is stale + broken (OOM, orientation). Small fixers exist but never
captured share (~600 downloads = invisible). **Fixing pain ≠ automatic adoption → discoverability decides.**

## 3. The three real differentiators (what sells the package)

1. **Target-size compression** — `toSize(maxBytes:)`. **Nobody has true byte-targeting.** All competitors use
   quality% + dimension limits. The "5MB→500KB" Medium article oversells; its package doesn't byte-target.
   Everyone hand-rolls a quality loop today. THIS is the headline feature.
2. **Zero-config web** — browser `canvas.toBlob(type, quality)` compresses natively, no script tag, no deps.
   Kills flutter_image_compress's pica `index.html` friction. Competitors have no web at all.
3. **Automatic OOM handling** — decode-time downsampling (never load full bitmap). All competitors say
   "set maxWidth to avoid OOM" = band-aid. We bake it in.

**Orientation (autoOrient) is BASELINE, not a differentiator** — two competitors already fix it. Must-have, won't sell.

## 4. Public API (LOCKED)

Decision: **named methods only.** Rejected: (a) 4-method flutter_image_compress style; (b) single
`compress(target: CompressTarget)` sealed-target — tighter surface count but less readable + less discoverable
(pub.dev indexes method identifiers → `toSize` is searchable, `CompressTarget` is not); (c) both at once = the
exact bloat we're fighting. Named methods give readability AND type safety (can't pass quality to toSize).

```dart
enum ImageFormat { jpeg, png, webp, heic }

sealed class ImageSource {
  factory ImageSource.bytes(Uint8List data) = _BytesSource;
  factory ImageSource.file(String path)      = _FileSource;
  factory ImageSource.asset(String key)      = _AssetSource;
  factory ImageSource.xfile(XFile file)      = _XFileSource;   // image_picker interop = DX win
}

class ImageCompressor {
  /// Headline feature: compress until under [maxBytes]. Binary-search over quality, capped at [minQuality].
  static Future<CompressedImage> toSize(
    ImageSource input, {
    required int maxBytes,
    ImageFormat format = ImageFormat.jpeg,
    int? maxWidth,
    int? maxHeight,
    bool autoOrient = true,
    int minQuality = 10,
  });

  /// Familiar quality mode. quality is meaningful on every format (fixes PNG-iOS silent-ignore).
  static Future<CompressedImage> toQuality(
    ImageSource input, {
    required int quality,
    ImageFormat format = ImageFormat.jpeg,
    int? maxWidth,
    int? maxHeight,
    bool autoOrient = true,
  });

  /// Batch — answers flutter_image_compress's "iOS crashes compressing in a loop". Native-side parallel,
  /// memory-bounded by [concurrency].
  static Future<List<CompressedImage>> toSizeAll(
    List<ImageSource> inputs, {
    required int maxBytes,
    ImageFormat format = ImageFormat.jpeg,
    int? maxWidth,
    int? maxHeight,
    bool autoOrient = true,
    int minQuality = 10,
    int concurrency = 3,
  });

  static Future<List<CompressedImage>> toQualityAll(
    List<ImageSource> inputs, {
    required int quality,
    ImageFormat format = ImageFormat.jpeg,
    int? maxWidth,
    int? maxHeight,
    bool autoOrient = true,
    int concurrency = 3,
  });
}

class CompressedImage {
  final Uint8List bytes;
  final int width, height;
  final int originalBytes;
  final int compressedBytes;
  final ImageFormat format;
  final bool reachedTarget;   // toSize only: false = smallest achievable, still returned (no throw)
  final int usedQuality;      // transparency: what quality it stopped at
  double get ratio => compressedBytes / originalBytes;

  // saveTo is a conditional-io extension (not a member) so web never imports
  // dart:io; returns the written path. Throws UnsupportedError on web.
  Future<String> saveTo(String path);   // writing is explicit + opt-in
}

// Error model: NEVER return null. Hard failures throw typed errors; target-miss is NOT an error
// (returns best-effort result with reachedTarget=false).
sealed class CompressError implements Exception {}
class UnsupportedFormatError extends CompressError { final ImageFormat format; UnsupportedFormatError(this.format); }
class SourceNotFoundError    extends CompressError { final String path;        SourceNotFoundError(this.path); }
class DecodeError            extends CompressError { final String reason;      DecodeError(this.reason); }
```

### Copy-paste example (README first block)
```dart
final img = await ImageCompressor.toSize(
  ImageSource.xfile(picked),      // straight from image_picker
  maxBytes: 500 * 1024,           // under 500 KB
);
print('${img.originalBytes} → ${img.compressedBytes} bytes (q=${img.usedQuality})');
await img.saveTo('/tmp/out.jpg');
```

## 5. Architecture — native-heavy (the target-size search runs native)

We committed to a native-heavy package. The `toSize` binary search runs **in native code**, not Dart, so the
image is decoded ONCE and its bytes cross the method channel ONCE — not once per quality probe. An earlier
"thin native, search in Dart" sketch was reverted: on a 10 MB image it meant ~7 full decodes + ~7 channel
copies of the source, wasteful exactly where the headline feature matters. Dart keeps only source resolution
and batch orchestration.

```
Dart (facade)                    Native (per platform — decode once, encode cheaply)
─────────────                    ──────────────────────────────────────────────────
toQuality()   ─────────────▶  encodeOnce(req)      decode → encode@quality → bytes
toSize()      ─────────────▶  encodeToSize(req)    decode ONCE → binary-search quality → best
toSizeAll()/toQualityAll()   iterate the above with a bounded Dart concurrency pool
                                                    ↑ downsample-on-decode = OOM fix
                                                    ↑ EXIF orientation baked into pixels
                                                    ↑ PNG (lossless) short-circuits the search
```

Trade-off accepted: the search is reimplemented in Kotlin/Swift/JS (~15 lines each) and is no longer
pure-Dart unit-testable — Dart tests cover facade wiring; search correctness is verified on-device. This is
the inherent cost of native-heavy, chosen deliberately for the decode-once performance win.

### Federated plugin layout
```
image_compressor                      facade + toSize/toQuality/*All Dart logic (binary search)
image_compressor_platform_interface   encodeOnce / encodeBatch contract
image_compressor_android   Kotlin      ImageDecoder/BitmapFactory + inSampleSize + Bitmap.compress
image_compressor_darwin    Swift       ImageIO CGImageDestination (iOS+macOS shared: jpeg/png/heic/webp)
image_compressor_web       Dart        canvas.toBlob(type, quality) — ZERO native, ZERO script tag
```

## 6. Scope discipline

**v1 = Android + iOS + Web only.** macOS/HEIC deferred. Native path = 4 platforms + federated boilerplate + CI;
more surface than document_scan. Narrow v1 or it never ships.

## 7. OPEN DECISIONS

- [x] **Package name → `image_compressor`** (LOCKED 2026-07-14). Free on pub.dev; best exact-match for the
      highest-volume "flutter image compress" search; zero rename cost (scaffold/pluginClass/channel already
      use it). Differentiator (target-size) lives in description/README, not the name.
- [x] Native contract: `encodeOnce(EncodeRequest)` + `encodeToSize(EncodeSizeRequest{...,maxBytes,minQuality})`
      → `EncodeResult{bytes,width,height,usedQuality,reachedTarget}`; errors via `unsupported_format` /
      `decode_error` PlatformException. Target-size search runs native (decode once) — see §5.
- [x] Format support is per-platform (encoders differ; unsupported combos return `unsupported_format`):
      - **Android** (Bitmap.compress): jpeg, png, webp — NO heic (needs HeifWriter, deferred).
      - **iOS** (ImageIO): jpeg, png, heic — NO webp (ImageIO has no WebP encoder on iOS).
      - **web** (canvas.toBlob): jpeg, png, webp — NO heic.
      → jpeg/png work everywhere; webp = Android+web; heic = iOS only. Document this table in README.
- [ ] `minQuality` default is 10; binary-search termination confirmed by unit tests (~7 probes).
- [ ] Isolate strategy on Dart side for large-image work (avoid jank) — native already runs off the platform
      thread (Android executor); revisit if Dart-side source resolution janks on huge assets.

## 7b. Shipped beyond the core API (0.1.0 polish)

- `saveTo(path)` — conditional-io extension, returns the written path; web throws.
- `onProgress(done, total)` on `toSizeAll`/`toQualityAll` — batch progress.
- `CancelToken` + `CancelledError` — cooperative cancellation at boundaries (before source
  read, before native dispatch, before each batch item). A single in-flight native encode is
  not interruptible; batches stop launching new work on cancel.
- Robustness: cross-platform resize parity, single-axis OOM-guard fix (Android), non-positive
  bounds guard (all), web WebP silent-PNG-fallback guard, Android `Bitmap.compress` failure check.

## 7c. Known limitations (documented, deferred)

- **Web needs OffscreenCanvas.convertToBlob → Safari 16.4+ / evergreen engines.** Older WebViews are
  unsupported. A feature-detected `HTMLCanvasElement.toBlob` fallback is deferred to the browser-testing
  session (writing it blind, untestable here, would fail silently on exactly the old engines it targets).
- **`autoOrient: false` on iOS** drops the EXIF orientation tag (thumbnail path re-renders without it); pixels
  are unrotated. Fine for the default `true`; documented for the rare `false`.
- **Native never built on-device yet** — Kotlin/Swift compile + real round-trip (bytes shrink, orientation,
  target-size hit) is unverified until the device session. Highest remaining risk.

## 8. Honest risks

- Native = per-platform code + maintenance heavier than document_scan (codecs break on OS updates).
- Small stale competitors fixed orientation yet stayed at ~600 downloads → **adoption needs discoverability
  work (README, tutorials, Reddit/SO), not just better code.** Same lesson as document_scan's growth plan.
- easy_video_editor / media_compressor prove the no-FFmpeg native path works but adoption is modest → space
  winnable but not a slam dunk.

## 9. Sibling package (later, NOT bundled)

`video_compressor` = separate package, shared brand/API shape (`toSize`, same Result type). Rejected bundling:
video pulls heavy native deps (binary bloat forced on image-only users) + fragile release cadence (video bugs
would force version bumps on image users) + `image_compress`/`video_compress` rank cleaner as separate SEO
entries. Ship image first (easier, faster adoption), video as sibling.
