# 🗜️ image_compressor

Compress images in Flutter — **to a target file size**, in one call.

[![pub package](https://img.shields.io/pub/v/image_compressor.svg)](https://pub.dev/packages/image_compressor)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![platforms](https://img.shields.io/badge/platforms-Android%20|%20iOS%20|%20Web-blue)
[![sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors)](https://github.com/sponsors/Ozdemiroguz)

```dart
final image = await ImageCompressor.toSize(
  ImageSource.xfile(pickedImage), // straight from image_picker
  maxBytes: 500.kb,                // "get it under 500 KB"
);
await image.saveTo('/path/out.jpg');
```

No hand-rolled quality loop, no guessing a magic quality number. Give it a byte
ceiling and it finds the highest quality that fits — natively, decoding the
image only once.

<p align="center">
  <img src="doc/demo.png" width="300" alt="image_compressor demo: a 2.2 MB photo compressed to under 200 KB, 91% smaller, in one call">
</p>

Android · iOS · Web. MIT licensed.

---

## 🤔 Why this exists

Every other Flutter compressor makes you pick a `quality: 0–100` and hope the
result is small enough. But what you actually need is almost always *"make this
fit under X KB"* — for an upload limit, an avatar, an attachment. So everyone
writes the same quality-guessing loop by hand.

`image_compressor` makes that the headline feature (`toSize`), and runs the
search in native code so it stays fast on large photos.

A few packages can hit a target size now. What none of them do is hit it **on
the web too, without shipping a single native binary** — `image_compressor` is
the one that does all three:

- 🎯 **Target file size** — ask for "under X KB", not a quality number to guess.
- 🌐 **Real web support** — in-browser encoding via `OffscreenCanvas`, no `pica`
  script tag, no setup. (FFI-based compressors can't run on web at all.)
- 🪶 **Zero bundled binaries** — it uses each platform's own codecs, so your app
  doesn't grow by a megabyte of Rust/C per architecture.

Plus the papercuts fixed along the way:

- **No OOM on big images** — downsamples during decode instead of loading a
  full bitmap and then shrinking it.
- **Orientation just works** — EXIF rotation is baked into the pixels by default.
- **Batch that survives a bad image** — every input gets its own result; one
  corrupt file can't discard the other 49.
- **Never returns `null`** — hard failures throw a typed `CompressError`.

### The combination

Any given row below, some package has. The point is that **one** package has all
of them at once:

| | image_compressor |
|---|:---:|
| Compress to a **target file size** | ✅ |
| Works on **web** (not just mobile) | ✅ |
| **No** bundled native binary (uses platform codecs) | ✅ |
| Large images without OOM (decode-time downsample) | ✅ |
| Automatic EXIF orientation | ✅ |
| Batch that isolates failures + progress + cancel | ✅ |
| Typed errors, never `null` | ✅ |
| One API, not several overlapping methods | ✅ |

The popular quality-only compressor is missing the first row. The fast FFI ones
are missing the second and third. This package is the intersection.

Speed is a dead heat with the popular packages (103 ms vs 102 ms on a 6.75 MP
photo — and ours includes the orientation pass theirs skips). What it adds is
*control*. Give a 27 MP photo a 2000px cap and a 400 KB budget: quality 90/80/70
all blow the budget, quality 50 fits but throws away 92 KB — and you'd have to
guess which. `toSize` searches, finds quality 55, lands at **394 KB**. Numbers
and method in [BENCHMARK.md](BENCHMARK.md).

## 📦 Install

```bash
flutter pub add image_compressor
```

```dart
import 'package:image_compressor/image_compressor.dart';
```

## 🎯 Compress to a target size

```dart
final image = await ImageCompressor.toSize(
  ImageSource.file('/path/photo.jpg'),
  maxBytes: 500.kb,
);

print('${image.originalBytes} → ${image.compressedBytes} bytes');
print('quality ${image.usedQuality}, reachedTarget ${image.reachedTarget}');

final bytes = image.bytes;             // Uint8List, ready to upload
await image.saveTo('/path/out.jpg');   // or write it to disk (native only)
```

If even the lowest quality can't reach `maxBytes`, you still get the smallest
achievable result back with `reachedTarget == false` — never an exception, never
`null`.

Why this beats a quality number: a fixed quality overshoots or blows the budget,
and you'd have to guess which. `toSize` finds the one that fits.

![Same photo, same cap: quality 90/80/70 all blow a 400 KB budget, quality 50 fits but wastes 92 KB; toSize finds quality 55 and lands right at 394 KB](doc/bench-size.png)

> `maxBytes` is a plain byte count. Importing the package adds `.kb` / `.mb`
> helpers so you can write `500.kb` or `2.mb` instead of `500 * 1024`.

`toSize` produces an image **in the requested `format`, under `maxBytes`** — it
targets a size, it does not guarantee the output is smaller than the input. For
a normal camera photo it always shrinks. The one exception is a source that is
already tiny in a more efficient format (e.g. a small PNG re-encoded to JPEG):
the format conversion can make it larger while still fitting under the ceiling.
Compare `compressedBytes` to `originalBytes` if you want to keep the smaller of
the two.

## 📐 Size presets

Say what the image is *for* instead of tuning numbers. Each preset is a byte
ceiling + a dimension cap — still size-first, no quality to guess:

```dart
final image = await ImageCompressor.toPreset(
  ImageSource.xfile(picked),
  SizePreset.web,   // thumbnail · avatar · web · hd
);
```

| Preset | Max size | Max width |
|--------|:--------:|:---------:|
| `thumbnail` | 50 KB  | 400 px  |
| `avatar`    | 150 KB | 800 px  |
| `web`       | 500 KB | 1920 px |
| `hd`        | 2 MB   | 4000 px |

## 🎚️ Fixed quality

```dart
final image = await ImageCompressor.toQuality(
  ImageSource.bytes(sourceBytes),
  quality: 80,
  maxWidth: 1920,   // optional: also cap dimensions (aspect preserved)
);
```

## 🔎 Probe before you compress

Read an image's size, dimensions and format **without decoding it** — cheap
enough to run on every picked file:

```dart
final info = await ImageCompressor.probe(ImageSource.xfile(picked));
// info.width, info.height, info.byteLength, info.format (ImageFormat?)

if (info.byteLength > 1.mb || info.width > 4000) {
  // only bother compressing the big ones
}
```

## 🗂️ Any input source

```dart
ImageSource.bytes(uint8List)   // already in memory
ImageSource.file('/path.jpg')  // a file on disk (not on web)
ImageSource.asset('a/b.png')   // a bundled asset
ImageSource.xfile(xfile)       // an XFile from image_picker / file_picker
```

## 📚 Batch, with progress and cancellation

```dart
final token = CancelToken();

final results = await ImageCompressor.toSizeAll(
  pickedFiles.map(ImageSource.xfile).toList(),
  maxBytes: 300.kb,
  concurrency: 3,                    // how many at once (bounds memory)
  onProgress: (done, total) => setState(() => _p = done / total),
  cancelToken: token,               // token.cancel() stops launching new work
);

// One result per input — a single bad image can't sink the batch.
final images = results.whereType<BatchSuccess>().map((r) => r.image).toList();
for (final failure in results.whereType<BatchFailure>()) {
  debugPrint('skipped ${failure.source}: ${failure.error.message}');
}
```

## 🖼️ Formats

Requesting an unsupported format throws `UnsupportedFormatError` — never silent
wrong output.

| Format | Android | iOS | Web |
|--------|:-------:|:---:|:---:|
| JPEG   |   ✓     |  ✓  |  ✓  |
| PNG    |   ✓     |  ✓  |  ✓  |
| WebP   |   ✓     |  ✗  |  ✓  |
| HEIC   |   ✗     |  ✓  |  ✗  |

JPEG/PNG are safe everywhere. WebP is Android + web (iOS ImageIO has no WebP
encoder). HEIC is iOS only.

```dart
await ImageCompressor.toSize(input, maxBytes: 500.kb,
    format: ImageFormat.webp);
```

## 📤 What you get back

`CompressedImage`:

| Field | Meaning |
|-------|---------|
| `bytes` | the compressed image (`Uint8List`) |
| `width` / `height` | decoded output dimensions |
| `originalBytes` / `compressedBytes` | before / after size |
| `ratio` | `compressedBytes / originalBytes` |
| `usedQuality` | the quality the encoder landed on |
| `reachedTarget` | `toSize` only — did it fit under `maxBytes`? |
| `saveTo(path)` | write to disk, returns the path (native only) |

## ⚖️ Platform notes

- **Native-heavy by design.** The target-size search runs in Kotlin / Swift /
  the browser, so an image is decoded once, not once per quality probe.
- **Web** needs `OffscreenCanvas.convertToBlob` (Safari 16.4+ / evergreen
  engines).
- **`autoOrient`** defaults to `true` (EXIF rotation baked into pixels). On iOS,
  `autoOrient: false` also drops the orientation tag.

## 🚫 Errors

Everything throws a subtype of the sealed `CompressError`:

```dart
try {
  final img = await ImageCompressor.toSize(input, maxBytes: 500.kb);
} on UnsupportedFormatError { /* format not encodable on this platform */ }
on SourceNotFoundError    { /* missing file / bad asset / file on web */ }
on DecodeError            { /* not a decodable image */ }
on CancelledError         { /* cancelled via CancelToken */ }
```

## ❓ FAQ

**Does it hit the target size exactly?**
It gets as close under the ceiling as the format allows. The native side
binary-searches quality and returns the highest one that still fits, so you use
the budget instead of undershooting it. If even the lowest quality is too big,
you get the smallest achievable result with `reachedTarget: false` — never an
exception, never `null`.

**Will it bloat my app?**
No. It uses each platform's own image codecs (BitmapFactory, ImageIO,
`OffscreenCanvas`) — there's no Rust/C library bundled per architecture, so your
app size doesn't change meaningfully.

**Does the web support actually work?**
Yes — real in-browser encoding via `OffscreenCanvas.convertToBlob`, no `pica`
script tag or `index.html` setup. Needs Safari 16.4+ / any evergreen engine.
(Compressors built on `dart:ffi` can't run on web at all.)

**One image in my batch is corrupt — do I lose the rest?**
No. `toSizeAll` / `toQualityAll` return one `BatchResult` per input; the bad one
comes back as a `BatchFailure` and the rest still succeed.

**Does it keep EXIF metadata (GPS, camera, date)?**
By default no — it's stripped, which is usually what you want (EXIF carries
location and timestamps you rarely want to hand to a backend). Pass
`keepMetadata: true` to preserve it:

```dart
await ImageCompressor.toSize(input, maxBytes: 500.kb, keepMetadata: true);
```

Works on **Android and iOS** (JPEG). The orientation tag is always reset — since
rotation is baked into the pixels, keeping it would double-rotate. **Web can't
preserve metadata** (the canvas encoder strips it), so `keepMetadata` has no
effect there. On Android the copied metadata can push the output a few KB over
`maxBytes` (EXIF is small).

**Is it slower than the native alternatives?**
No — it's a dead heat (103 ms vs 102 ms on a 6.75 MP photo), and that includes
the EXIF orientation pass most alternatives skip. See [BENCHMARK.md](BENCHMARK.md).

## 🛠️ Troubleshooting

**"It returns `null`."**
It doesn't — that's the old quality-only packages. Failures throw a typed
`CompressError`; a `toSize` that can't reach the ceiling returns a real result
with `reachedTarget: false`.

**`UnsupportedFormatError` on iOS with WebP (or Android with HEIC).**
Encoder support is per-platform (see the table above). WebP has no iOS encoder;
HEIC has no Android one. Use JPEG/PNG for cross-platform output.

**Web: `DecodeError` or nothing happens.**
Web needs `OffscreenCanvas.convertToBlob` — Safari 16.4+ or any evergreen engine.
Older WebViews aren't supported.

**Picked image comes out sideways.**
It shouldn't — `autoOrient` is `true` by default and bakes EXIF rotation into the
pixels. If you set `autoOrient: false`, you own the orientation.

**A big batch is slow / spikes memory.**
Lower `concurrency` on `toSizeAll` / `toQualityAll` (it bounds how many decode at
once). The default is 3.

## 💛 Support

This package is free and MIT-licensed, maintained solo in my spare time. If it
saved you time, [a coffee via GitHub Sponsors](https://github.com/sponsors/Ozdemiroguz)
helps keep it maintained and new packages coming.

## 👤 Author

Oğuzhan Özdemir · [github.com/Ozdemiroguz](https://github.com/Ozdemiroguz)

## 📄 License

MIT — see [LICENSE](LICENSE).
