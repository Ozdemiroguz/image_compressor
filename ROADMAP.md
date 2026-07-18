# Roadmap

A living document. `image_compressor` is actively maintained — small, regular
releases over big, rare ones. Dates are targets, not promises, and priorities
shift with real-world feedback. Have a request?
[Open an issue](https://github.com/Ozdemiroguz/image_compressor/issues).

## Release cadence

A patch or minor release **roughly every 3–4 weeks** while active — Flutter-SDK
compatibility bumps, bug fixes, docs, and a small item or two from the list
below. Urgent fixes (a real bug, a broken build) ship out-of-band, immediately.
The package won't go silent for months, and issues get a first response quickly.

## Shipped

- **0.2.0** — Batch is no longer all-or-nothing: `toSizeAll` / `toQualityAll`
  return `List<BatchResult>` (success or failure per input), so one bad image
  can't discard the rest. Simpler example, inline API examples.
- **0.1.2** — Corrected the benchmark methodology (warmed, both run orders — it's
  a dead heat, not "slower"), retracted an unfair size comparison, added the
  GitHub Sponsors funding link.
- **0.1.0 / 0.1.1** — First release. `toSize` (target-file-size, native quality
  search — decode once), `toQuality`, batch (`toSizeAll` / `toQualityAll`) with
  bounded concurrency + `onProgress` + `CancelToken`, `saveTo`, `.kb`/`.mb`
  helpers, decode-time downsampling, automatic EXIF orientation. Android, iOS,
  Web. Typed `CompressError`, never `null`.

## Planned — near term (quick wins)

- **Simpler example** — a pick-a-photo → compress-to-500 KB demo, minimal deps.
- **Housekeeping** — `flutter pub add` in the README instead of a pinned version;
  keep IDE files (`*.iml`, `.idea/`) out of the published archive.
- **SDK compatibility** — track Flutter/Dart stable bumps as they land.

## Planned — later (bigger, demand-driven)

- **Web fallback for older Safari** — `HTMLCanvasElement.toBlob` when
  `OffscreenCanvas.convertToBlob` is unavailable (< Safari 16.4). Needs real
  old-browser testing before it ships.
- **WebP on iOS** — only worthwhile by bundling libwebp (~1 MB native). Held
  until enough people ask; JPEG/HEIC cover most iOS cases today.
- **HEIC on Android** — via `HeifWriter` (API 28+).
- **Metadata preservation** — an opt-in to keep EXIF in the output. Removed in
  v1 rather than ship a flag that silently did nothing; re-add it done right.

## Not planned

- **Video.** That's a separate package if it happens — bundling a video codec
  would bloat every image-only user's app. Kept out on purpose.

Priorities here are driven by issues and real use. If something on the "later"
list is blocking you, say so on the tracker — that's what moves it up.
