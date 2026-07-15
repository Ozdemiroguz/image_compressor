import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:image_compressor/image_compressor.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'image_compressor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  Uint8List? _original;
  CompressedImage? _result;
  String? _error;
  bool _busy = false;

  /// A realistic "already a photo" source: a detailed gradient encoded as a
  /// high-quality JPEG, so the original is a few hundred KB — like a camera
  /// shot — and compressing it down actually shrinks it.
  Uint8List _sampleImage() {
    const w = 1600, h = 1200;
    final image = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        // Gradient + fine detail so JPEG has real content to work on.
        final detail = ((x ~/ 4 + y ~/ 4) % 2) * 24;
        image.setPixelRgb(
          x,
          y,
          (x * 255 ~/ w + detail).clamp(0, 255),
          (y * 255 ~/ h + detail).clamp(0, 255),
          128,
        );
      }
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 100));
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final source = _sampleImage();
      final result = await ImageCompressor.toSize(
        ImageSource.bytes(source),
        maxBytes: 200.kb,
      );
      setState(() {
        _original = source;
        _result = result;
      });
    } on CompressError catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _saveToGallery() async {
    final result = _result;
    if (result == null) return;
    try {
      // gal saves the compressed bytes straight to the device photo gallery.
      await Gal.putImageBytes(result.bytes, name: 'image_compressor_demo');
      _snack('Saved ${_kb(result.compressedBytes)} to the gallery.');
    } on GalException catch (e) {
      _snack('Save failed: ${e.type.message}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('image_compressor')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Compress a 1600×1200 sample to under 200 KB',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _run,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.compress),
                label: const Text('Compress to 200 KB'),
              ),
              const SizedBox(height: 24),
              if (_error != null)
                Text('Error: $_error',
                    style: const TextStyle(color: Colors.red)),
              if (result != null && _original != null) ...[
                _StatRow('Original', _kb(result.originalBytes)),
                _StatRow('Compressed', _kb(result.compressedBytes)),
                _StatRow('Reduction',
                    '${((1 - result.ratio) * 100).toStringAsFixed(1)}%'),
                _StatRow('Quality used', '${result.usedQuality}'),
                _StatRow('Reached target', '${result.reachedTarget}'),
                _StatRow('Dimensions',
                    '${result.width}×${result.height} · ${result.format.name}'),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(result.bytes, width: 220),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _saveToGallery,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Save to gallery'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
