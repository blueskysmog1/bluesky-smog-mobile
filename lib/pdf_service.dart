import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'local_db.dart';

class PdfService {
  static const _teal = PdfColor.fromInt(0xFF0097A7);

  static Future<void> generateAndShare({
    required Map<String, dynamic> invoice,
    required List<Map<String, dynamic>> items,
    required List<Map<String, dynamic>> vehicles,
    Map<String, dynamic>? customer,
    String? logoPath,
    Uint8List? signatureBytes,
  }) async {
    final resolvedLogo = logoPath ?? await LocalDb.instance.getSetting('logo_path');
    final bytes = await generateBytes(
        invoice: invoice, items: items,
        vehicles: vehicles, customer: customer,
        logoPath: resolvedLogo, signatureBytes: signatureBytes);

    final custName = (invoice['customer_name'] ?? 'Customer')
        .toString().replaceAll(RegExp(r'[^\w\s]'), '').replaceAll(' ', '_');
    final date     = (invoice['invoice_date'] ?? '').toString().replaceAll('-', '');
    final filename = 'Invoice_${custName}_$date.pdf';

    final dir  = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes);
    await Printing.sharePdf(bytes: bytes, filename: filename);
  }

  static Future<Uint8List> generateBytes({
    required Map<String, dynamic> invoice,
    required List<Map<String, dynamic>> items,
    required List<Map<String, dynamic>> vehicles,
    Map<String, dynamic>? customer,
    String? logoPath,
    Uint8List? signatureBytes,
  }) async {
    // ── Logo ─────────────────────────────────────────────────────────
    final resolvedLogoPath = logoPath ?? await LocalDb.instance.getSetting('logo_path');
    pw.MemoryImage? logoImage;
    double logoW = 82, logoH = 72;
    if (resolvedLogoPath != null && resolvedLogoPath.isNotEmpty) {
      final f = File(resolvedLogoPath);
      if (await f.exists()) {
        try {
          final rawBytes = await f.readAsBytes();
          final decoded  = img.decodeImage(rawBytes);
          if (decoded != null) {
            const maxW = 164, maxH = 144;
            final scale = [maxW / decoded.width, maxH / decoded.height]
                .reduce((a, b) => a < b ? a : b);
            final resized = img.copyResize(decoded,
                width:  (decoded.width  * scale).round(),
                height: (decoded.height * scale).round(),
                interpolation: img.Interpolation.linear);
            logoImage = pw.MemoryImage(img.encodePng(resized));
            logoW = resized.width  / 2.0;
            logoH = resized.height / 2.0;
          }
        } catch (_) {}
      }
    }

    // ── Business settings ─────────────────────────────────────────────
    final bizName  = await LocalDb.instance.getSetting('co_name')  ?? 'BLUE SKY SMOG';
    final bizAddr1 = await LocalDb.instance.getSetting('co_addr')  ?? '';
    final bizAddr2 = await LocalDb.instance.getSetting('co_city')  ?? '';
    final bizPhone = await LocalDb.instance.getSetting('co_phone') ?? '';
    final bizEmail = await LocalDb.instance.getSetting('co_email') ?? '';
    final bizArd   = await LocalDb.instance.getSetting('co_ard')   ?? '';
    final noticeRaw  = await LocalDb.instance.getSetting('invoice_notice') ?? '';
    final noticeText = noticeRaw.replaceAll('{business_name}', bizName);

    // ── Invoice fields ────────────────────────────────────────────────
    final rawNum      = invoice['invoice_number'];
    final numStr      = (rawNum != null && rawNum != 0) ? '$rawNum' : 'PENDING';
    final invoiceDate = (invoice['invoice_date']   ?? '').toString();
    final payMethod   = (invoice['payment_method'] ?? '').toString();
    final status      = (invoice['status']         ?? '').toString();
    final notes       = (invoice['notes']          ?? '').toString().trim();
    final totalCents  = (invoice['amount_cents']   as int?) ?? 0;
    final totalDollars = (totalCents / 100).toStringAsFixed(2);
    final isEstimate  = status == 'ESTIMATE';
    final title       = isEstimate ? 'ESTIMATE' : 'INVOICE';

    // ── Customer fields ───────────────────────────────────────────────
    final custCompany  = (customer?['company_name'] ?? '').toString().trim();
    final custFirst    = (customer?['first_name']   ?? '').toString().trim();
    final custLast     = (customer?['last_name']    ?? '').toString().trim();
    final custName2    = [custFirst, custLast].where((s) => s.isNotEmpty).join(' ');
    final custAddr     = (customer?['address']      ?? '').toString().trim();
    final custCityLine = [
      customer?['city'], customer?['state'], customer?['zip']
    ].where((s) => (s ?? '').toString().isNotEmpty)
     .map((s) => s.toString()).join(' ');
    final custPhone    = (customer?['phone'] ?? '').toString().trim();
    final custEmail    = (customer?['email'] ?? '').toString().trim();

    // ── Invoice-level vehicle fallback ────────────────────────────────
    final hdrVin   = (invoice['vin']   ?? '').toString().trim();
    final hdrPlate = (invoice['plate'] ?? '').toString().trim();
    final hdrYear  = (invoice['year']  ?? '').toString().trim();
    final hdrMake  = (invoice['make']  ?? '').toString().trim();
    final hdrModel = (invoice['model'] ?? '').toString().trim();

    // ── Vehicle lookup map ────────────────────────────────────────────
    final vehicleMap = <String, Map<String, dynamic>>{
      for (final v in vehicles) (v['vehicle_id'] ?? '').toString(): v
    };

    // ── Styles ────────────────────────────────────────────────────────
    const black  = PdfColors.black;
    final grey   = PdfColor.fromHex('#555555');
    final divClr = PdfColor.fromHex('#CCCCCC');

    pw.TextStyle ts(double size, {bool bold = false, PdfColor? color}) =>
        pw.TextStyle(fontSize: size,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            color: color ?? black);

    // ── Fee-only service names (no vehicle info) ──────────────────────
    const feeServices = {'Credit Card Fee', 'Card Fee', 'CC Fee'};

    // ── Build service line widgets ────────────────────────────────────
    final List<pw.Widget> lineWidgets = [];
    String? lastVehicleKey;

    for (final item in items) {
      final name  = (item['name'] ?? '').toString().trim();
      final isFee = feeServices.contains(name);

      String vin = '', plate = '', odo = '', year = '', make = '', model = '';
      if (!isFee) {
        vin   = (item['vin']      ?? '').toString().trim();
        plate = (item['plate']    ?? '').toString().trim();
        odo   = (item['odometer'] ?? '').toString().trim();
        year  = (item['year']     ?? '').toString().trim();
        make  = (item['make']     ?? '').toString().trim();
        model = (item['model']    ?? '').toString().trim();

        if (vin.isEmpty && plate.isEmpty) {
          final vid = (item['vehicle_id'] ?? '').toString();
          final v   = vehicleMap[vid] ?? {};
          vin   = (v['vin']      ?? '').toString().trim();
          plate = (v['plate']    ?? '').toString().trim();
          odo   = (v['odometer'] ?? '').toString().trim();
          year  = (v['year']     ?? '').toString().trim();
          make  = (v['make']     ?? '').toString().trim();
          model = (v['model']    ?? '').toString().trim();
        }

        if (vin.isEmpty && plate.isEmpty) {
          vin   = hdrVin;
          plate = hdrPlate;
          year  = year.isEmpty  ? hdrYear  : year;
          make  = make.isEmpty  ? hdrMake  : make;
          model = model.isEmpty ? hdrModel : model;
        }
      }

      final vehicleKey = '$vin|$plate|$year|$make|$model';

      if (!isFee && vehicleKey != lastVehicleKey &&
          (vin.isNotEmpty || plate.isNotEmpty || year.isNotEmpty)) {
        lastVehicleKey = vehicleKey;

        final vinPlate = [
          if (vin.isNotEmpty)   'VIN: $vin',
          if (plate.isNotEmpty) 'Plate: $plate',
          if (odo.isNotEmpty)   'Odometer: $odo',
        ].join('    ');
        final ymm = [
          if (year.isNotEmpty)  'Year: $year',
          if (make.isNotEmpty)  'Make: $make',
          if (model.isNotEmpty) 'Model: $model',
        ].join('   ');

        if (vinPlate.isNotEmpty)
          lineWidgets.add(pw.Text(vinPlate, style: ts(9, bold: true)));
        if (ymm.isNotEmpty)
          lineWidgets.add(pw.Text(ymm, style: ts(9)));
      }

      // Service + price row
      final cents   = (item['unit_price_cents'] as int?) ?? 0;
      final qty     = (item['qty'] as num?)?.toDouble() ?? 1.0;
      final lineAmt = '\$${(qty * cents / 100).toStringAsFixed(2)}';
      final result  = (item['result'] ?? '').toString().trim();
      final cert    = (item['cert']   ?? '').toString().trim();
      var   svcLabel = 'Service: $name';
      if (result.isNotEmpty && name == 'Smog Test') svcLabel += ' ($result)';
      if (cert.isNotEmpty) svcLabel += '  Cert: $cert';

      lineWidgets.add(pw.Padding(
        padding: const pw.EdgeInsets.only(left: 20, top: 2, bottom: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Expanded(child: pw.Text(svcLabel, style: ts(9))),
            pw.Text(lineAmt, style: ts(9)),
          ],
        ),
      ));

      // Discount row
      final discCents = (item['discount_cents'] as int?) ?? 0;
      if (discCents > 0) {
        final discAmt = '-\$${(discCents / 100).toStringAsFixed(2)}';
        lineWidgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(left: 20, top: 0, bottom: 2),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Discount', style: ts(9)),
              pw.Text(discAmt, style: ts(9)),
            ],
          ),
        ));
      }
    }

    // ── Barcode value — VIN only for maximum scannability ─────────────
    // Using only the VIN (≤17 chars) keeps bars wide enough for handheld
    // scanners. Fall back to invoice number when no VIN is present.
    final String barcodeValue = hdrVin.trim().isNotEmpty
        ? hdrVin.trim()
        : 'INV$numStr';

    // ── Build PDF ─────────────────────────────────────────────────────
    final pdf = pw.Document();

    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.letter,
      margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 72),
      footer: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // Barcode pinned at bottom (matches desktop Code128)
          try_build_barcode(barcodeValue),
        ],
      ),
      build: (context) => [
        // ── Header ──────────────────────────────────────────────────
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          // Left: logo + biz info
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            if (logoImage != null)
              pw.Image(logoImage, width: logoW, height: logoH),
            if (logoImage != null) pw.SizedBox(height: 4),
            pw.Text(bizName, style: ts(14, bold: true)),
            if (bizAddr1.isNotEmpty) pw.Text(bizAddr1, style: ts(9)),
            if (bizAddr2.isNotEmpty) pw.Text(bizAddr2, style: ts(9)),
            if (bizPhone.isNotEmpty)
              pw.Text('Phone: $bizPhone', style: ts(9)),
            if (bizEmail.isNotEmpty)
              pw.Text(bizEmail, style: ts(9)),
            if (bizArd.isNotEmpty) pw.Text('ARD #: $bizArd', style: ts(9)),
          ]),
          pw.Spacer(),
          // Right: title + invoice # + date
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text(title, style: ts(15, bold: true)),
            pw.SizedBox(height: 4),
            pw.Text('$title #: $numStr', style: ts(9, bold: true)),
            pw.Text('Date: $invoiceDate', style: ts(9)),
          ]),
        ]),
        pw.SizedBox(height: 6),
        // Teal separator (matches desktop draw_header teal line)
        pw.Container(
          height: 1.5,
          color: _teal,
        ),
        pw.SizedBox(height: 10),

        // ── Bill To ─────────────────────────────────────────────────
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('Bill To:  ', style: ts(10, bold: true)),
          pw.Expanded(child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (custCompany.isNotEmpty)
                pw.Text('Company: $custCompany', style: ts(10, bold: true)),
              if (custName2.isNotEmpty)
                pw.Text(custName2, style: ts(9)),
              if (custAddr.isNotEmpty)
                pw.Text('Address: $custAddr', style: ts(9)),
              if (custCityLine.isNotEmpty)
                pw.Text(custCityLine, style: ts(9)),
              if (custPhone.isNotEmpty)
                pw.Text('Phone: $custPhone', style: ts(9)),
              if (custEmail.isNotEmpty)
                pw.Text('Email: $custEmail', style: ts(9)),
            ],
          )),
        ]),
        pw.SizedBox(height: 8),
        pw.Divider(color: divClr, thickness: 0.8),
        pw.SizedBox(height: 6),

        // ── Column headers ──────────────────────────────────────────
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Vehicle / Service Performed', style: ts(10, bold: true)),
            pw.Text('Amount', style: ts(10, bold: true)),
          ],
        ),
        pw.Divider(color: divClr, thickness: 0.5),
        pw.SizedBox(height: 4),

        // ── Line items ──────────────────────────────────────────────
        ...lineWidgets,
        pw.SizedBox(height: 8),
        pw.Divider(color: divClr, thickness: 0.8),
        pw.SizedBox(height: 6),

        // ── Totals ──────────────────────────────────────────────────
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('Subtotal: \$$totalDollars', style: ts(10, bold: true)),
              pw.SizedBox(height: 3),
              pw.Text('Grand Total: \$$totalDollars', style: ts(13, bold: true)),
            ],
          ),
        ),

        if (payMethod.isNotEmpty && !isEstimate) ...[
          pw.SizedBox(height: 8),
          pw.Text('Payment Method: $payMethod', style: ts(9)),
        ],

        if (notes.isNotEmpty) ...[
          pw.SizedBox(height: 6),
          pw.Text('Notes:', style: ts(9, bold: true)),
          pw.Text(notes, style: ts(9)),
        ],

        // ── Notice — shown on ALL documents (matches desktop) ───────
        if (noticeText.trim().isNotEmpty) ...[
          pw.SizedBox(height: 8),
          pw.Text(noticeText, style: ts(8, color: grey)),
        ],

        // ── Customer signature — shown on ALL documents (matches desktop) ─
        pw.SizedBox(height: 20),
        if (signatureBytes != null) ...[
          pw.Text('Customer Signature:', style: ts(9)),
          pw.SizedBox(height: 6),
          pw.Image(pw.MemoryImage(signatureBytes),
              width: double.infinity, height: 90,
              fit: pw.BoxFit.contain,
              alignment: pw.Alignment.centerLeft),
        ] else ...[
          pw.Row(children: [
            pw.Text('Customer Signature:', style: ts(9)),
            pw.SizedBox(width: 8),
            pw.Expanded(child: pw.Container(
              decoration: pw.BoxDecoration(
                  border: pw.Border(
                      bottom: pw.BorderSide(color: black, width: 0.8))),
              height: 14,
            )),
          ]),
          pw.SizedBox(height: 2),
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 122),
            child: pw.Text('X', style: ts(9)),
          ),
        ],
      ],
    ));

    return Uint8List.fromList(await pdf.save());
  }

  /// Renders a Code128 barcode widget for the page footer.
  /// Returns an empty SizedBox if barcode rendering fails.
  static pw.Widget try_build_barcode(String data) {
    try {
      // width: double.infinity on BarcodeWidget itself causes bars to stretch
      // across the full available page width, matching the desktop's scale_x approach.
      return pw.BarcodeWidget(
        barcode: pw.Barcode.code128(),
        data: data,
        width: double.infinity,
        height: 48,
        drawText: true,
        textStyle: pw.TextStyle(fontSize: 7),
      );
    } catch (_) {
      return pw.SizedBox();
    }
  }
}
