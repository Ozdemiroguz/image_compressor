import 'package:flutter/material.dart';
import 'package:image_compressor/image_compressor.dart';
// Both packages export an `ImageSource`; prefix image_picker's to avoid the clash.
import 'package:image_picker/image_picker.dart' as picker;

void main() => runApp(const MyApp());

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
  SizePreset _preset = SizePreset.web;
  bool _keepMetadata = false;

  ImageProbe? _before;
  CompressedImage? _after;
  String? _error;
  bool _busy = false;

  Future<void> _pick() async {
    final picked = await picker.ImagePicker().pickImage(
      source: picker.ImageSource.gallery,
    );
    if (picked == null) return;
    final input = ImageSource.xfile(picked);

    setState(() {
      _busy = true;
      _error = null;
      _before = null;
      _after = null;
    });
    try {
      // 1. Probe: read size/dimensions/format WITHOUT decoding.
      final before = await ImageCompressor.probe(input);
      // 2. Compress to the chosen preset (optionally keeping EXIF).
      final after = await ImageCompressor.toPreset(
        input,
        _preset,
        keepMetadata: _keepMetadata,
      );
      setState(() {
        _before = before;
        _after = after;
      });
    } on CompressError catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';

  @override
  Widget build(BuildContext context) {
    final before = _before;
    final after = _after;
    return Scaffold(
      appBar: AppBar(title: const Text('image_compressor')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Preset picker.
              SegmentedButton<SizePreset>(
                segments: const [
                  ButtonSegment(value: SizePreset.thumbnail, label: Text('thumb')),
                  ButtonSegment(value: SizePreset.avatar, label: Text('avatar')),
                  ButtonSegment(value: SizePreset.web, label: Text('web')),
                  ButtonSegment(value: SizePreset.hd, label: Text('hd')),
                ],
                selected: {_preset},
                onSelectionChanged: (s) => setState(() => _preset = s.first),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Keep EXIF metadata'),
                subtitle: const Text('Android + iOS · JPEG'),
                value: _keepMetadata,
                onChanged: (v) => setState(() => _keepMetadata = v),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _pick,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_library),
                label: Text('Pick a photo → ${_preset.name}'),
              ),
              const SizedBox(height: 20),
              if (_error != null)
                Text('Error: $_error',
                    style: const TextStyle(color: Colors.red)),
              if (before != null && after != null) ...[
                _Row('Before', '${before.width}×${before.height} · '
                    '${_kb(before.byteLength)} · ${before.format?.name ?? '?'}'),
                _Row('After', '${after.width}×${after.height} · '
                    '${_kb(after.compressedBytes)} · ${after.format.name}'),
                _Row('Reduction',
                    '${((1 - after.ratio) * 100).toStringAsFixed(0)}%  '
                    '(quality ${after.usedQuality})'),
                _Row('Reached target', '${after.reachedTarget}'),
                const SizedBox(height: 16),
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(after.bytes, width: 240),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
