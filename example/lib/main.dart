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
  CompressedImage? _result;
  String? _error;

  Future<void> _pickAndCompress() async {
    final picked = await picker.ImagePicker().pickImage(
      source: picker.ImageSource.gallery,
    );
    if (picked == null) return;

    try {
      // Compress the picked photo to under 500 KB — one call, no quality loop.
      // The picked XFile goes straight in via ImageSource.xfile.
      final result = await ImageCompressor.toSize(
        ImageSource.xfile(picked),
        maxBytes: 500.kb,
      );
      setState(() {
        _result = result;
        _error = null;
      });
    } on CompressError catch (e) {
      setState(() => _error = e.message);
    }
  }

  String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('image_compressor')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: _pickAndCompress,
                icon: const Icon(Icons.photo_library),
                label: const Text('Pick a photo & compress to 500 KB'),
              ),
              const SizedBox(height: 24),
              if (_error != null)
                Text('Error: $_error',
                    style: const TextStyle(color: Colors.red)),
              if (result != null) ...[
                Text(
                  '${_kb(result.originalBytes)}  →  ${_kb(result.compressedBytes)}'
                  '   (quality ${result.usedQuality})',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(result.bytes, width: 260),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
