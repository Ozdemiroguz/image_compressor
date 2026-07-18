## 0.2.1

Docs only.

* Honest, sharper positioning. Target-size isn't unique anymore, so the README no
  longer claims "the thing no other package does". The real, defensible moat is
  the *combination*: the one package that does target-size **and** runs on web
  **and** ships zero native binaries.
* Added an FAQ and a chart showing why a target size beats guessing a quality
  number.

## 0.2.0

**Breaking:** `toSizeAll` / `toQualityAll` now return `List<BatchResult>`
(previously `List<CompressedImage>`).

* **Batch is no longer all-or-nothing.** One unreadable image used to throw and
  discard every other result. Each input now gets its own `BatchResult` —
  `BatchSuccess(source, image)` or `BatchFailure(source, error)` — in input
  order, so a single bad file can't sink the batch. Only a `CancelToken`
  cancellation still throws (it aborts the whole operation on purpose).
  * Migration: `results` → `results.whereType<BatchSuccess>().map((r) => r.image)`
    for just the compressed images; check `whereType<BatchFailure>()` for the rest.
* Simpler example: pick a photo and compress it to 500 KB — the 30-second story,
  instead of the old benchmark harness.
* Docs: inline `dart` examples on `toSize`, `toQuality`, and `toSizeAll` in the
  API reference; documented the remaining `CompressedImage` fields.
* Docs: `flutter pub add` in place of a pinned version in the README.
* Kept IDE files (`*.iml`, `.idea/`) out of the published archive.
* Added a ROADMAP.md (release cadence).

## 0.1.2

* **Retracted an unfair performance claim.** 0.1.1's README said we return a
  small file "instead of an uncontrolled multi-megabyte one" — that comparison
  had us downsampling a 27 MP photo while the other package was forced to full
  resolution. Given the same dimension cap it gets there too; the real advantage
  is that `toSize` *finds* the quality instead of making you guess it.
* **Corrected the speed claim.** The benchmark that reported us ~20% slower was
  unwarmed and always timed us first. Warmed, in both run orders, it's a dead
  heat (103 ms vs 102 ms on 6.75 MP) — and our number includes the EXIF
  orientation pass the other side skips. See BENCHMARK.md.
* Added the GitHub Sponsors funding link (missed the 0.1.1 cut).

## 0.1.1

* Docs: reworded the README's comparison to a name-free "us vs most other
  packages" table (no competitor names).
* Example: added a real compress → save-to-gallery flow (via `gal`).
* Added GitHub Sponsors funding link (`pubspec` `funding:`, README, FUNDING.yml).

## 0.1.0

Initial release.

* `ImageCompressor.toSize(input, maxBytes:)` — compress to a target file size.
  The quality search runs natively (decode once), so it stays fast on large
  images. Returns `reachedTarget` + `usedQuality` instead of throwing when a
  size can't be met.
* `ImageCompressor.toQuality(input, quality:)` — fixed-quality mode.
* `toSizeAll` / `toQualityAll` — batch with bounded `concurrency`, `onProgress`,
  and `CancelToken` support.
* Any input via `ImageSource` — bytes, file path, asset key, or an `XFile`
  straight from `image_picker`.
* `CompressedImage.saveTo(path)` extension (native only).
* Automatic EXIF orientation (`autoOrient`), decode-time downsampling to avoid
  OOM on large images, and consistent per-edge resize across platforms.
* Formats: JPEG/PNG everywhere, WebP on Android + web, HEIC on iOS.
* Platforms: Android, iOS, Web.
* Never returns `null` — hard failures throw a typed `CompressError`.
