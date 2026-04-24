import 'package:flutter/material.dart';

/// Scannable Code 128B barcode — pure Flutter, no external packages.
/// Encoding table verified against Code 128 specification.
class VinBarcode extends StatelessWidget {
  final String vin;
  const VinBarcode({super.key, required this.vin});

  @override
  Widget build(BuildContext context) {
    if (vin.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      SizedBox(
        height: 70,
        width: double.infinity,
        child: CustomPaint(painter: _Code128Painter(vin.toUpperCase())),
      ),
      const SizedBox(height: 4),
      Text(
        vin.toUpperCase(),
        style: const TextStyle(
          fontSize: 9,
          letterSpacing: 2.0,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
        ),
      ),
    ]);
  }
}

class _Code128Painter extends CustomPainter {
  final String data;
  _Code128Painter(this.data);

  // Code 128 full pattern table — indices 0–105
  // Each pattern is 6 elements (BSBSBS) summing to exactly 11 modules.
  // Index 103 = START A, 104 = START B, 105 = START C
  // STOP is special: pattern '233111' (11 modules) + 2-module termination bar
  static const List<String> _pat = [
    '212222','222122','222221','121223','121322','131222','122213', // 0-6
    '122312','132212','221213','221312','231212','112232','122132', // 7-13
    '122231','113222','123122','123221','223211','221132','221231', // 14-20
    '213212','223112','312131','311222','321122','321221','312212', // 21-27
    '322112','322211','212123','212321','232121','111323','131123', // 28-34
    '131321','112313','132113','132311','211313','231113','231311', // 35-41
    '112133','112331','132131','113123','113321','133121','313121', // 42-48
    '211331','231131','213113','213311','213131','311123','311321', // 49-55
    '331121','312113','312311','332111','314111','221411','431111', // 56-62
    '111224','111422','121124','121421','141122','141221','112214', // 63-69
    '112412','122114','122411','142112','142211','241211','221114', // 70-76
    '413111','241112','134111','111242','121142','121241','114212', // 77-83
    '124112','124211','411212','421112','421211','212141','214121', // 84-90
    '412121','111143','111341','131141','114113','114311','411113', // 91-97
    '411311','113141','114131','311141','411131','211412','211214', // 98-104 (104=START B)
    '211232', // 105 = START C
  ];

  static const String _stopPattern = '233111'; // + 2-module termination bar
  static const int _startB = 104;

  @override
  void paint(Canvas canvas, Size size) {
    final barPaint   = Paint()..color = Colors.black;
    final spacePaint = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), spacePaint);

    // Build symbol list: START B + data values + checksum
    final List<int> symbols = [_startB];
    int checksum = _startB;

    for (int i = 0; i < data.length; i++) {
      final code = data.codeUnitAt(i);
      if (code < 32 || code > 126) return; // unencodable char
      final v = code - 32;
      symbols.add(v);
      checksum += v * (i + 1);
    }
    checksum = checksum % 103;
    symbols.add(checksum);

    // Count total modules to scale bar width
    int totalModules = 0;
    for (final s in symbols) {
      for (final ch in _pat[s].split('')) totalModules += int.parse(ch);
    }
    for (final ch in _stopPattern.split('')) totalModules += int.parse(ch);
    totalModules += 2; // termination bar

    final mw = size.width / totalModules;
    double x = 0;

    void drawPat(String pat) {
      bool isBar = true;
      for (final ch in pat.split('')) {
        final w = mw * int.parse(ch);
        if (isBar) {
          canvas.drawRect(Rect.fromLTWH(x, 0, w, size.height), barPaint);
        }
        x += w;
        isBar = !isBar;
      }
    }

    for (final s in symbols) drawPat(_pat[s]);
    drawPat(_stopPattern);
    // 2-module termination bar
    canvas.drawRect(Rect.fromLTWH(x, 0, mw * 2, size.height), barPaint);
  }

  @override
  bool shouldRepaint(_Code128Painter old) => old.data != data;
}
