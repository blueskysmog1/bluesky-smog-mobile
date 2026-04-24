import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Opens the VIN scanner. Returns the scanned string or null if cancelled.
Future<String?> openVinScanner(BuildContext context) {
  return Navigator.of(context).push<String>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => const VinScannerPage(),
  ));
}

class VinScannerPage extends StatefulWidget {
  const VinScannerPage({super.key});
  @override
  State<VinScannerPage> createState() => _VinScannerPageState();
}

class _VinScannerPageState extends State<VinScannerPage> {
  final _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final _picker         = ImagePicker();

  File?           _capturedFile;
  Size            _imageSize = Size.zero;
  List<_OcrBlock> _blocks    = [];
  String?         _selected;
  bool            _scanning  = false;
  final _manualCtl = TextEditingController();

  @override
  void dispose() {
    _textRecognizer.close();
    _manualCtl.dispose();
    super.dispose();
  }

  // ── OCR: take photo then run recognition ─────────────────────────
  Future<void> _captureAndOcr() async {
    final picked = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 90,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (picked == null || !mounted) return;

    setState(() { _scanning = true; _blocks = []; _selected = null; });

    try {
      final file        = File(picked.path);
      final inputImage  = InputImage.fromFile(file);
      final result      = await _textRecognizer.processImage(inputImage);

      final decoded = await decodeImageFromList(await file.readAsBytes());
      final imgW    = decoded.width.toDouble();
      final imgH    = decoded.height.toDouble();

      final blocks = <_OcrBlock>[];
      for (final block in result.blocks) {
        for (final line in block.lines) {
          final text = line.text.trim();
          if (text.length < 3) continue;
          blocks.add(_OcrBlock(
            text: text,
            rectFrac: Rect.fromLTWH(
              line.boundingBox.left   / imgW,
              line.boundingBox.top    / imgH,
              line.boundingBox.width  / imgW,
              line.boundingBox.height / imgH,
            ),
          ));
        }
      }

      // Auto-detect VIN (17-char) and CA plate (digit + 3 letters + 3 digits)
      String? autoVin;
      String? autoPlate;
      final _vinRe   = RegExp(r'[A-HJ-NPR-Z0-9]{17}');
      final _plateRe = RegExp(r'[0-9][A-Z]{3}[0-9]{3}');
      for (final b in blocks) {
        // Strip spaces and uppercase for matching
        final t = b.text.replaceAll(RegExp(r'\s+'), '').toUpperCase();
        // Search for VIN pattern anywhere in the string (handles "VIN/NIV:3AK…")
        if (autoVin == null) {
          final m = _vinRe.firstMatch(t);
          if (m != null) autoVin = m.group(0)!;
        }
        if (autoPlate == null) {
          final m = _plateRe.firstMatch(t);
          if (m != null) autoPlate = m.group(0)!;
        }
      }

      String? autoSelected;
      if (autoVin != null) {
        autoSelected = autoPlate != null ? '$autoVin|$autoPlate' : autoVin;
      }

      setState(() {
        _capturedFile = file;
        _imageSize    = Size(imgW, imgH);
        _blocks       = blocks;
        _scanning     = false;
        if (autoSelected != null) {
          _selected = autoSelected;
          _manualCtl.text = autoSelected;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _scanning = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('OCR error: $e')));
      }
    }
  }

  /// Strip common VIN label prefixes and return only the alphanumeric content.
  String _cleanVinText(String raw) {
    var s = raw.toUpperCase().trim();
    // Remove label prefixes like "VIN/NIV:", "VIN:", "VIN ", "NIV:", etc.
    s = s.replaceFirst(RegExp(r'^(VIN/NIV|VIN|NIV)\s*[:/]?\s*'), '');
    // Keep only alphanumeric characters
    s = s.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return s;
  }

  void _selectBlock(_OcrBlock block) {
    final cleaned = _cleanVinText(block.text);
    setState(() {
      _selected = cleaned;
      _manualCtl.text = cleaned;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan VIN / Plate'),
      ),
      body: Column(children: [
        Expanded(
          flex: 3,
          child: _capturedFile == null
              ? _ocrPlaceholder()
              : _ocrImageWithBoxes(),
        ),
        Container(
          color: Colors.grey.shade900,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _manualCtl,
              style: const TextStyle(color: Colors.white,
                  fontSize: 15, fontFamily: 'monospace'),
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'Tap a highlighted word or type manually',
                hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                filled: true, fillColor: Colors.grey.shade800,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear, color: Colors.grey),
                  onPressed: () {
                    _manualCtl.clear();
                    setState(() => _selected = null);
                  },
                ),
              ),
              onChanged: (v) => _selected = v,
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.grey)),
                onPressed: _scanning ? null : _captureAndOcr,
                icon: _scanning
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            color: Colors.white))
                    : const Icon(Icons.camera_alt_outlined, size: 16),
                label: Text(_capturedFile == null ? 'Take Photo' : 'Retake'),
              )),
              const SizedBox(width: 10),
              Expanded(child: FilledButton(
                onPressed: () {
                  final text = _manualCtl.text.trim();
                  if (text.isNotEmpty) {
                    Navigator.of(context).pop(_cleanVinText(text));
                  }
                },
                child: const Text('Use This'),
              )),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _ocrPlaceholder() => Center(child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(Icons.document_scanner_outlined,
          size: 64, color: Colors.grey.shade600),
      const SizedBox(height: 16),
      Text('Take a photo of the VIN plate\nor DMV registration paperwork',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
      const SizedBox(height: 8),
      Text('VIN and plate will be detected automatically',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: _scanning ? null : _captureAndOcr,
        icon: const Icon(Icons.camera_alt_outlined),
        label: const Text('Take Photo'),
      ),
    ],
  ));

  Widget _ocrImageWithBoxes() => LayoutBuilder(
    builder: (ctx, constraints) {
      final dispW = constraints.maxWidth;
      final dispH = constraints.maxHeight;

      double imgAspect  = _imageSize.width / _imageSize.height;
      double dispAspect = dispW / dispH;
      double renderW, renderH, offsetX = 0, offsetY = 0;
      if (imgAspect > dispAspect) {
        renderW = dispW;
        renderH = dispW / imgAspect;
        offsetY = (dispH - renderH) / 2;
      } else {
        renderH = dispH;
        renderW = dispH * imgAspect;
        offsetX = (dispW - renderW) / 2;
      }

      return Stack(children: [
        Positioned.fill(
          child: Image.file(_capturedFile!, fit: BoxFit.contain)),

        ..._blocks.map((block) {
          final isSelected = block.text == _selected ||
              _manualCtl.text.contains(block.text);
          final left   = offsetX + block.rectFrac.left   * renderW;
          final top    = offsetY + block.rectFrac.top    * renderH;
          final width  =          block.rectFrac.width   * renderW;
          final height =          block.rectFrac.height  * renderH;

          return Positioned(
            left: left, top: top, width: width, height: height,
            child: GestureDetector(
              onTap: () => _selectBlock(block),
              child: Container(
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.blue.withOpacity(0.4)
                      : Colors.yellow.withOpacity(0.25),
                  border: Border.all(
                    color: isSelected ? Colors.blue : Colors.yellow,
                    width: isSelected ? 2.5 : 1.5,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          );
        }),

        Positioned(top: 8, left: 0, right: 0,
          child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _blocks.isEmpty
                  ? 'No text detected — try retaking'
                  : 'Tap a highlighted area to select',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          )),
        ),
      ]);
    },
  );
}

class _OcrBlock {
  final String text;
  final Rect   rectFrac;
  const _OcrBlock({required this.text, required this.rectFrac});
}
