import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Full-screen signature capture.
/// Returns [Uint8List] PNG bytes on confirm, or null on cancel.
class SignaturePadPage extends StatefulWidget {
  const SignaturePadPage({super.key});

  @override
  State<SignaturePadPage> createState() => _SignaturePadPageState();
}

class _SignaturePadPageState extends State<SignaturePadPage> {
  final List<List<Offset?>> _strokes = [];
  bool _hasDrawn = false;
  final _repaintKey = GlobalKey();

  void _onPanStart(DragStartDetails d) {
    setState(() {
      _strokes.add([d.localPosition]);
      _hasDrawn = true;
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() => _strokes.last.add(d.localPosition));
  }

  void _onPanEnd(DragEndDetails _) {
    setState(() => _strokes.last.add(null)); // pen-up marker
  }

  void _clear() => setState(() { _strokes.clear(); _hasDrawn = false; });

  Future<Uint8List?> _capture() async {
    try {
      final boundary = _repaintKey.currentContext
          ?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data  = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> _confirm() async {
    if (!_hasDrawn) return;
    final bytes = await _capture();
    if (!mounted) return;
    Navigator.of(context).pop(bytes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text('Customer Signature'),
        actions: [
          TextButton(
            onPressed: _clear,
            child: const Text('Clear',
                style: TextStyle(color: Colors.white, fontSize: 15)),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(
            'Have the customer sign with their finger in the box below.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
        ),

        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: RepaintBoundary(
                key: _repaintKey,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: GestureDetector(
                    onPanStart:  _onPanStart,
                    onPanUpdate: _onPanUpdate,
                    onPanEnd:    _onPanEnd,
                    child: CustomPaint(
                      painter: _SignaturePainter(_strokes),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Row(children: [
            Expanded(
              child: SizedBox(height: 48,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('Cancel'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(height: 48,
                child: FilledButton(
                  onPressed: _hasDrawn ? _confirm : null,
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade700),
                  child: const Text('Confirm Signature'),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<List<Offset?>> strokes;
  const _SignaturePainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black87
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    // Draw a faint baseline to guide the signature
    canvas.drawLine(
      Offset(size.width * 0.05, size.height * 0.75),
      Offset(size.width * 0.95, size.height * 0.75),
      Paint()
        ..color = Colors.grey.shade300
        ..strokeWidth = 1.0,
    );

    for (final stroke in strokes) {
      final path = Path();
      bool penDown = false;
      for (final pt in stroke) {
        if (pt == null) { penDown = false; continue; }
        if (!penDown) { path.moveTo(pt.dx, pt.dy); penDown = true; }
        else          { path.lineTo(pt.dx, pt.dy); }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter _) => true;
}
