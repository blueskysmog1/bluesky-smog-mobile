import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:printing/printing.dart';
import 'package:uuid/uuid.dart';
import 'local_db.dart';
import 'invoice_form_page.dart';
import 'pdf_service.dart';
import 'api_service.dart';
import 'signature_pad_page.dart';

class InvoiceDetailPage extends StatefulWidget {
  final String invoiceId;
  final String deviceId;
  final Future<void> Function()? scheduleSync;

  const InvoiceDetailPage({
    super.key, required this.invoiceId,
    required this.deviceId, this.scheduleSync,
  });

  @override
  State<InvoiceDetailPage> createState() => _InvoiceDetailPageState();
}

class _InvoiceDetailPageState extends State<InvoiceDetailPage> {
  final db  = LocalDb.instance;
  final api = ApiService();

  Map<String, dynamic>? invoice;
  List<Map<String, dynamic>> items               = [];
  List<Map<String, dynamic>> allCustomerVehicles = [];
  List<Map<String, dynamic>> services            = [];
  Map<String, dynamic>? customer;

  // Add-item form
  String? _selectedVehicleId;
  String? _selectedServiceId;
  String  _selectedResult = '';   // '', 'PASS', 'FAIL', 'EXEMPT', 'REJECT'
  final _customNameCtl  = TextEditingController();
  final _qtyCtl         = TextEditingController(text: '1');
  final _priceCtl       = TextEditingController();
  final _discountCtl    = TextEditingController();
  final _odometerCtl    = TextEditingController();
  final _certCtl        = TextEditingController();
  final _notesCtl       = TextEditingController();
  bool _useCustomService = false;

  bool _finalizing = false;
  bool _downloadingPdf = false;
  String? _signaturePath;   // path to saved signature PNG

  bool get _isFinalized =>
      (invoice?['finalized'] as int? ?? 0) == 1;

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() {
    _customNameCtl.dispose(); _qtyCtl.dispose(); _priceCtl.dispose();
    _discountCtl.dispose(); _odometerCtl.dispose(); _certCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final inv  = await db.getInvoice(widget.invoiceId);
    final its  = await db.getInvoiceItems(widget.invoiceId);
    final svcs = await db.listServices();
    List<Map<String, dynamic>> allVehs = [];
    Map<String, dynamic>? cust;
    if (inv != null) {
      final cid = (inv['customer_id'] ?? '').toString();
      if (cid.isNotEmpty) {
        cust    = await db.getCustomer(cid);
        allVehs = await db.getVehicles(cid);
      }
    }
    final sigPath = inv?['signature_path'] as String?;
    if (!mounted) return;
    setState(() {
      invoice             = inv;
      items               = its;
      services            = svcs;
      allCustomerVehicles = allVehs;
      customer            = cust;
      _signaturePath      = (sigPath != null && sigPath.isNotEmpty) ? sigPath : null;
      if (_selectedServiceId != null &&
          !svcs.any((s) => s['service_id'] == _selectedServiceId))
        _selectedServiceId = null;
      if (_selectedVehicleId != null &&
          !allVehs.any((v) => v['vehicle_id'] == _selectedVehicleId))
        _selectedVehicleId = null;
      // Auto-select vehicle if customer only has one
      if (_selectedVehicleId == null && allVehs.length == 1) {
        _selectedVehicleId = allVehs.first['vehicle_id']?.toString();
        // Auto-fill price from vehicle service_type if available
        final st = (allVehs.first['service_type'] ?? '').toString();
        if (st.isNotEmpty && svcs.any((s) => s['service_id'] == st)) {
          _selectedServiceId = st;
          final svc   = svcs.firstWhere((s) => s['service_id'] == st);
          final cents = (svc['default_price_cents'] as int?) ?? 0;
          _priceCtl.text = (cents / 100).toStringAsFixed(2);
        }
      }
    });
  }

  // ── Service / vehicle pickers ─────────────────────────────────────
  void _onVehicleSelected(String? vehicleId) {
    setState(() {
      _selectedVehicleId = vehicleId;
      if (vehicleId == null || _useCustomService) return;
      final v  = allCustomerVehicles.firstWhere(
          (v) => v['vehicle_id'] == vehicleId, orElse: () => {});
      final st = (v['service_type'] ?? '').toString();
      if (st.isNotEmpty && services.any((s) => s['service_id'] == st)) {
        _selectedServiceId = st;
        final svc   = services.firstWhere((s) => s['service_id'] == st);
        final cents = (svc['default_price_cents'] as int?) ?? 0;
        _priceCtl.text = (cents / 100).toStringAsFixed(2);
      }
    });
  }

  void _onServiceSelected(String? serviceId) {
    setState(() {
      _selectedServiceId = serviceId;
      if (serviceId == null) return;
      final svc   = services.firstWhere(
          (s) => s['service_id'] == serviceId, orElse: () => {});
      if (svc.isNotEmpty) {
        final cents = (svc['default_price_cents'] as int?) ?? 0;
        _priceCtl.text = (cents / 100).toStringAsFixed(2);
      }
    });
  }

  // ── Add item ──────────────────────────────────────────────────────
  Future<void> _addItem() async {
    String name;
    if (_useCustomService) {
      name = _customNameCtl.text.trim();
    } else if (_selectedServiceId != null) {
      final svc     = services.firstWhere(
          (s) => s['service_id'] == _selectedServiceId, orElse: () => {});
      final svcName = (svc['name'] ?? '').toString();
      final svcType = (svc['service_type'] ?? '').toString();
      name = svcType.isNotEmpty ? '$svcName $svcType' : svcName;
    } else {
      name = _customNameCtl.text.trim();
    }
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select or enter a service')));
      return;
    }
    final qty          = double.tryParse(_qtyCtl.text.trim()) ?? 1.0;
    final cents        = ((double.tryParse(_priceCtl.text.trim()) ?? 0.0) * 100).round();
    final discountCents = ((double.tryParse(_discountCtl.text.trim()) ?? 0.0) * 100).round();
    final odometer = _odometerCtl.text.trim().isEmpty
        ? null : _odometerCtl.text.trim();
    final cert = _certCtl.text.trim();

    Map<String, dynamic>? vehicle;
    if (_selectedVehicleId != null) {
      vehicle = allCustomerVehicles.firstWhere(
        (v) => v['vehicle_id'] == _selectedVehicleId,
        orElse: () => <String, dynamic>{},
      );
      if (vehicle.isEmpty) vehicle = null;
    }

    await db.addItem(
      invoiceId: widget.invoiceId, itemId: const Uuid().v4(),
      deviceId: widget.deviceId,
      seq: DateTime.now().millisecondsSinceEpoch,
      eventId: const Uuid().v4(),
      name: name, qty: qty, unitPriceCents: cents,
      discountCents: discountCents,
      result: _selectedResult,
      cert: cert,
      vehicleId: _selectedVehicleId, odometer: odometer,
      vin: vehicle?['vin']?.toString(),
      plate: vehicle?['plate']?.toString(),
      year: vehicle?['year']?.toString(),
      make: vehicle?['make']?.toString(),
      model: vehicle?['model']?.toString(),
    );
    _customNameCtl.clear(); _qtyCtl.text = '1';
    _priceCtl.clear(); _discountCtl.clear(); _odometerCtl.clear();
    _certCtl.clear();
    setState(() { _selectedServiceId = null; _selectedResult = ''; });
    await _load();
    await widget.scheduleSync?.call();
  }

  Future<void> _deleteItem(int localId, String itemId) async {
    await db.deleteItem(localId, itemId, widget.invoiceId,
        widget.deviceId, DateTime.now().millisecondsSinceEpoch,
        const Uuid().v4());
    await _load();
    await widget.scheduleSync?.call();
  }

  // ── Save notes ────────────────────────────────────────────────────
  Future<void> _saveNotes() async {
    final inv = invoice;
    if (inv == null) return;
    final notes = _notesCtl.text.trim().isEmpty ? null : _notesCtl.text.trim();
    final seq     = DateTime.now().millisecondsSinceEpoch;
    final eventId = const Uuid().v4();
    await db.updateInvoiceAndEnqueueUpsert(
      invoiceId:     widget.invoiceId,
      deviceId:      widget.deviceId,
      customerId:    (inv['customer_id'] ?? '').toString(),
      customerName:  (inv['customer_name'] ?? '').toString(),
      paymentMethod: (inv['payment_method'] ?? '').toString(),
      status:        (inv['status'] ?? 'ESTIMATE').toString(),
      notes:         notes,
      invoiceDate:   (inv['invoice_date'] ?? '').toString(),
      eventId:       eventId,
      seq:           seq,
    );
    await widget.scheduleSync?.call();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notes saved'), duration: Duration(seconds: 1)));
  }

  // ── Finalize ──────────────────────────────────────────────────────
  Future<void> _finalizeInvoice() async {
    final inv = invoice;
    if (inv == null) return;

    // Load card surcharge settings
    final surchargeType  = await db.getSetting('card_surcharge_type')  ?? 'percent';
    final surchargeVal   = await db.getSetting('card_surcharge_value') ?? '0';
    final surchargeNum   = double.tryParse(surchargeVal) ?? 0.0;
    final surchargeIsPercent = surchargeType != 'fixed';

    // Show finalize dialog with payment method picker
    String selectedPayment = 'CASH';
    bool applySurcharge = true;   // user can uncheck to skip
    final confirmed = await showDialog<bool>(context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setst) {
            final subtotalCents = (inv['amount_cents'] as int?) ?? 0;
            const _cardMethods = {'CARD', 'VISA', 'MASTERCARD', 'AMEX', 'DISCOVER'};
            int surchargeCents = 0;
            if (_cardMethods.contains(selectedPayment) && surchargeNum > 0 && applySurcharge) {
              surchargeCents = surchargeIsPercent
                  ? (subtotalCents * surchargeNum / 100).round()
                  : (surchargeNum * 100).round();
            }
            final totalCents = subtotalCents + surchargeCents;
            return AlertDialog(
              title: const Text('Finalize Invoice'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text(
                    'Select payment method then finalize. '
                    'This converts the estimate to a paid invoice, '
                    'locks it permanently, and uploads the PDF.'),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: selectedPayment,
                  decoration: const InputDecoration(
                    labelText: 'Payment Method',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.payment_outlined),
                  ),
                  items: [
                    'CASH', 'CARD', 'VISA', 'MASTERCARD', 'AMEX', 'DISCOVER',
                    'CHECK', 'CHARGE', 'OTHER',
                  ].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                  onChanged: (v) =>
                      setst(() { selectedPayment = v!; applySurcharge = true; }),
                ),
                if (_cardMethods.contains(selectedPayment) && surchargeNum > 0) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: applySurcharge
                          ? Colors.orange.shade50
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: applySurcharge
                              ? Colors.orange.shade200
                              : Colors.grey.shade300),
                    ),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      // Toggle row
                      Row(children: [
                        Checkbox(
                          value: applySurcharge,
                          visualDensity: VisualDensity.compact,
                          onChanged: (v) =>
                              setst(() => applySurcharge = v ?? true),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            surchargeIsPercent
                                ? 'Apply ${surchargeNum.toStringAsFixed(1)}% card surcharge'
                                : 'Apply \$${surchargeNum.toStringAsFixed(2)} card surcharge',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: applySurcharge
                                    ? Colors.orange.shade800
                                    : Colors.grey),
                          ),
                        ),
                      ]),
                      if (applySurcharge) ...[
                        const SizedBox(height: 6),
                        Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                          const Text('Subtotal:',
                              style: TextStyle(fontSize: 12)),
                          Text(
                              '\$${(subtotalCents / 100).toStringAsFixed(2)}',
                              style: const TextStyle(fontSize: 12)),
                        ]),
                        Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                          Text(
                            surchargeIsPercent
                                ? 'Surcharge (${surchargeNum.toStringAsFixed(1)}%):'
                                : 'Surcharge (flat):',
                            style: const TextStyle(fontSize: 12),
                          ),
                          Text(
                            '+\$${(surchargeCents / 100).toStringAsFixed(2)}',
                            style: TextStyle(
                                fontSize: 12, color: Colors.orange.shade700),
                          ),
                        ]),
                        const Divider(height: 8),
                        Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                          const Text('Total:',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 13)),
                          Text(
                            '\$${(totalCents / 100).toStringAsFixed(2)}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 13),
                          ),
                        ]),
                      ],
                    ]),
                  ),
                ],
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true),
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700),
                    child: const Text('Finalize & Upload')),
              ],
            );
          },
        ));
    if (confirmed != true || !mounted) return;

    // Auto-add card surcharge line item before finalizing (only if checkbox was on)
    const _cardMethodsFinal = {'CARD', 'VISA', 'MASTERCARD', 'AMEX', 'DISCOVER'};
    if (_cardMethodsFinal.contains(selectedPayment) && surchargeNum > 0 && applySurcharge) {
      final subtotalCents = (invoice?['amount_cents'] as int?) ?? 0;
      final surchargeCents = surchargeIsPercent
          ? (subtotalCents * surchargeNum / 100).round()
          : (surchargeNum * 100).round();
      final surchargeLabel = surchargeIsPercent
          ? 'Credit Card Surcharge (${surchargeNum.toStringAsFixed(1)}%)'
          : 'Credit Card Surcharge (\$${surchargeNum.toStringAsFixed(2)})';
      if (surchargeCents > 0) {
        await db.addItem(
          invoiceId: widget.invoiceId,
          itemId: const Uuid().v4(),
          deviceId: widget.deviceId,
          seq: DateTime.now().millisecondsSinceEpoch,
          eventId: const Uuid().v4(),
          name: surchargeLabel,
          qty: 1,
          unitPriceCents: surchargeCents,
          discountCents: 0,
          result: '',
          cert: '',
        );
        await _load();
      }
    }

    setState(() => _finalizing = true);
    try {
      final eventId = const Uuid().v4();
      final seq     = DateTime.now().millisecondsSinceEpoch;

      // 1. Lock locally (sets PAID + finalized=1, queues outbox event)
      await db.finalizeInvoice(
        invoiceId: widget.invoiceId, deviceId: widget.deviceId,
        eventId: eventId, seq: seq,
        paymentMethod: selectedPayment,
      );
      await _load();

      // 2. Push outbox to server RIGHT NOW (server assigns invoice_number)
      final pending = await db.getPendingOutbox(widget.deviceId);
      if (pending.isNotEmpty) {
        final events = pending.map((r) => {
          'event_id': r['event_id'], 'seq': r['seq'],
          'entity': r['entity'],    'action': r['action'],
          'payload': Map<String, dynamic>.from(
            (r['payload_json'] as String).isEmpty
                ? {} : jsonDecode(r['payload_json'] as String) as Map),
        }).toList();
        final maxSeq = pending
            .map((e) => (e['seq'] as num).toInt())
            .reduce((a, b) => a > b ? a : b);
        await api.push(deviceId: widget.deviceId, events: events);
        await db.markOutboxSent(widget.deviceId, maxSeq);
      }

      // 3. Pull from server to get assigned invoice_number back
      final prefs   = await SharedPreferences.getInstance();
      final sinceSeq = prefs.getInt('since_seq') ?? 0;
      final pullRes  = await api.pull(
          deviceId: widget.deviceId, sinceSeq: sinceSeq);
      final remoteEvents = (pullRes['events'] as List?) ?? [];
      final newMax = await db.applyRemoteEvents(
          deviceId: widget.deviceId, events: remoteEvents);
      await prefs.setInt('since_seq', newMax);
      await _load(); // now has invoice_number

      // 4. Generate PDF with the real invoice number
      final freshInv   = await db.getInvoice(widget.invoiceId);
      final freshItems = await db.getInvoiceItems(widget.invoiceId);
      final invoiceVehicles = _vehiclesUsedInItems(freshItems);
      final logoPath   = await db.getSetting('logo_path');

      final sigBytes = await _loadSignatureBytes();
      final pdfBytes = await PdfService.generateBytes(
        invoice: freshInv!, items: freshItems,
        vehicles: invoiceVehicles, customer: customer,
        logoPath: logoPath, signatureBytes: sigBytes,
      );

      // 5. Upload PDF to server with human-readable filename
      final custName  = (freshInv['customer_name'] ?? '').toString();
      final invDate   = (freshInv['invoice_date']  ?? '').toString();
      await api.uploadPdf(
        invoiceId:    widget.invoiceId,
        pdfBytes:     pdfBytes,
        customerName: custName,
        invoiceDate:  invDate,
      );
      await db.markPdfUploaded(widget.invoiceId);
      // Update next_test_due for all vehicles in this invoice
      await _updateVehicleTestDues(freshInv!, freshItems);
      await _load();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Invoice finalized and PDF saved ✓'),
            backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Finalize failed: $e'),
          backgroundColor: Colors.red.shade700));
    } finally {
      if (mounted) setState(() => _finalizing = false);
      await _load();
    }
  }

  // ── Download finalized PDF from server ────────────────────────────
  Future<void> _downloadPdf() async {
    setState(() => _downloadingPdf = true);
    try {
      final bytes = await api.downloadPdf(widget.invoiceId);
      if (bytes == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PDF not found on server yet')));
        return;
      }
      final num = invoice?['invoice_number'] ?? 'invoice';
      await Printing.sharePdf(bytes: bytes, filename: 'invoice_$num.pdf');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Download failed: $e')));
    } finally {
      if (mounted) setState(() => _downloadingPdf = false);
    }
  }

  // ── Collect customer signature ────────────────────────────────────
  Future<void> _collectSignature() async {
    final bytes = await Navigator.of(context).push<Uint8List?>(
      MaterialPageRoute(builder: (_) => const SignaturePadPage()),
    );
    if (bytes == null || !mounted) return;
    try {
      final dir  = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/sig_${widget.invoiceId}.png';
      await File(path).writeAsBytes(bytes);
      await db.saveSignaturePath(widget.invoiceId, path);
      setState(() => _signaturePath = path);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Signature saved'),
              backgroundColor: Colors.green, duration: Duration(seconds: 2)));
      // If already finalized, re-upload PDF with new signature
      if ((invoice?['finalized'] as int? ?? 0) == 1) {
        _regeneratePdfWithSignature();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save signature: $e')));
    }
  }

  Future<void> _regeneratePdfWithSignature() async {
    try {
      final freshInv   = await db.getInvoice(widget.invoiceId);
      if (freshInv == null) return;
      final freshItems = await db.getInvoiceItems(widget.invoiceId);
      final invoiceVehicles = _vehiclesUsedInItems(freshItems);
      final logoPath   = await db.getSetting('logo_path');
      final sigBytes   = await _loadSignatureBytes();
      final pdfBytes   = await PdfService.generateBytes(
        invoice: freshInv, items: freshItems,
        vehicles: invoiceVehicles, customer: customer,
        logoPath: logoPath, signatureBytes: sigBytes,
      );
      final custName = (freshInv['customer_name'] ?? '').toString();
      final invDate  = (freshInv['invoice_date']  ?? '').toString();
      await api.uploadPdf(
        invoiceId:    widget.invoiceId,
        pdfBytes:     pdfBytes,
        customerName: custName,
        invoiceDate:  invDate,
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF updated with signature ✓'),
              backgroundColor: Colors.green, duration: Duration(seconds: 2)));
    } catch (e) {
      // silently ignore re-upload errors
    }
  }

  // ── Load signature bytes from disk ─────────────────────────────────
  Future<Uint8List?> _loadSignatureBytes() async {
    final path = _signaturePath;
    if (path == null) return null;
    try {
      final f = File(path);
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {}
    return null;
  }

  // ── Share PDF (local generate + share sheet) ──────────────────────
  Future<void> _sharePdf() async {
    final inv = invoice;
    if (inv == null) return;
    try {
      final freshItems      = await db.getInvoiceItems(widget.invoiceId);
      final invoiceVehicles = _vehiclesUsedInItems(freshItems);
      final logoPath        = await db.getSetting('logo_path');
      final sigBytes        = await _loadSignatureBytes();
      await PdfService.generateAndShare(
        invoice: inv, items: freshItems,
        vehicles: invoiceVehicles, customer: customer,
        logoPath: logoPath, signatureBytes: sigBytes,
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('PDF error: $e')));
    }
  }

  // ── Delete ────────────────────────────────────────────────────────
  Future<void> _deleteInvoice() async {
    final ok = await showDialog<bool>(context: context,
        builder: (_) => AlertDialog(
          title: const Text('Delete Invoice'),
          content: const Text('Delete this invoice on all devices?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete',
                    style: TextStyle(color: Colors.red))),
          ],
        ));
    if (ok != true || !mounted) return;
    await db.deleteInvoice(
      invoiceId: widget.invoiceId, deviceId: widget.deviceId,
      eventId: const Uuid().v4(), seq: DateTime.now().millisecondsSinceEpoch,
    );
    await widget.scheduleSync?.call();
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _openEdit() async {
    final result = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => InvoiceFormPage(
        deviceId: widget.deviceId, invoiceId: widget.invoiceId,
        scheduleSync: widget.scheduleSync,
      ),
    ));
    if (result == true) await _load();
  }

  // ── Helpers ───────────────────────────────────────────────────────
  List<Map<String, dynamic>> _vehiclesUsedInItems(
      List<Map<String, dynamic>> its) {
    final usedIds = its
        .map((i) => (i['vehicle_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    return allCustomerVehicles
        .where((v) => usedIds.contains(v['vehicle_id'].toString()))
        .toList();
  }

  Future<void> _updateVehicleTestDues(
      Map<String, dynamic> inv, List<Map<String, dynamic>> items) async {
    final invoiceDateStr = (inv['invoice_date'] ?? '').toString();
    if (invoiceDateStr.isEmpty) return;
    try {
      final invoiceDate = DateTime.parse(invoiceDateStr);
      // Collect unique vehicle IDs from items
      final vehicleIds = items
          .map((i) => (i['vehicle_id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      for (final vid in vehicleIds) {
        final v = await db.getVehicle(vid);
        if (v == null) continue;
        final interval = v['test_interval_days'] as int?;
        if (interval == null || interval <= 0) continue;
        final nextDue = invoiceDate.add(Duration(days: interval));
        final nextDueStr = nextDue.toIso8601String().substring(0, 10);
        await db.updateVehicleTestDue(vid, nextDueStr);
      }
    } catch (_) {}
  }

  Color _statusColor(String? s) {
    switch (s) {
      case 'PAID': return Colors.green;
      default:     return Colors.orange; // ESTIMATE
    }
  }

  String _vehicleLabel(String? vehicleId) {
    if (vehicleId == null || vehicleId.isEmpty) return 'General';
    final v = allCustomerVehicles.firstWhere(
        (v) => v['vehicle_id'] == vehicleId, orElse: () => {});
    if (v.isEmpty) return 'Vehicle';
    final parts = [
      if ((v['year']  ?? '').toString().isNotEmpty) v['year'].toString(),
      if ((v['make']  ?? '').toString().isNotEmpty) v['make'].toString(),
      if ((v['model'] ?? '').toString().isNotEmpty) v['model'].toString(),
    ];
    final plate = (v['plate'] ?? '').toString();
    return parts.isEmpty
        ? 'Vehicle'
        : '${parts.join(' ')}${plate.isNotEmpty ? ' ($plate)' : ''}';
  }

  // ── Build ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final inv    = invoice;
    final numStr = inv?['invoice_number'] != null
        ? '#${inv!['invoice_number']}' : '#—';
    final pdfUploaded = (inv?['pdf_uploaded'] as int? ?? 0) == 1;

    return Scaffold(
      appBar: AppBar(
        title: Text('Invoice $numStr'),
        actions: [
          // Share / preview PDF (always available)
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Preview PDF',
            onPressed: inv == null ? null : _sharePdf,
          ),
          if (_isFinalized) ...[
            _downloadingPdf
                ? const Padding(padding: EdgeInsets.all(12),
                    child: SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(
                    icon: const Icon(Icons.cloud_download_outlined),
                    tooltip: 'Download PDF from server',
                    onPressed: _downloadPdf,
                  ),
          ] else ...[
            IconButton(icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit', onPressed: inv == null ? null : _openEdit),
          ],
          // Delete always available (finalized or not)
          IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: 'Delete Invoice',
              onPressed: inv == null ? null : _deleteInvoice),
        ],
      ),
      body: inv == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(children: [
              // ── Finalized banner (fixed) ─────────────────────
              if (_isFinalized)
                Container(
                  width: double.infinity,
                  color: Colors.green.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  child: Row(children: [
                    const Icon(Icons.lock, color: Colors.white, size: 16),
                    const SizedBox(width: 8),
                    const Text('FINALIZED — Invoice is locked',
                        style: TextStyle(color: Colors.white,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (!pdfUploaded)
                      const Text('PDF pending upload',
                          style: TextStyle(color: Colors.white70, fontSize: 11)),
                  ]),
                ),

              // ── Scrollable content ───────────────────────────
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  children: [
                    _headerCard(inv),
                    const SizedBox(height: 8),
                    _totalBar(inv),
                    const SizedBox(height: 8),
                    if (!_isFinalized) ...[
                      _addServiceCard(),
                      const SizedBox(height: 8),
                    ],
                    // ── Service lines ─────────────────────────
                    ..._itemsInline(),
                    const SizedBox(height: 8),
                    // ── Notes field ───────────────────────────
                    TextField(
                      controller: _notesCtl,
                      maxLines: 2,
                      readOnly: _isFinalized,
                      decoration: InputDecoration(
                        labelText: 'Notes (optional)',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.notes_outlined),
                        alignLabelWithHint: true,
                        suffixIcon: _isFinalized ? null : IconButton(
                          icon: const Icon(Icons.save_outlined),
                          tooltip: 'Save notes',
                          onPressed: _saveNotes,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),

              // ── Fixed bottom buttons (hidden when finalized) ─
              if (!_isFinalized)
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    boxShadow: [BoxShadow(
                      color: Colors.black.withOpacity(0.07),
                      blurRadius: 6, offset: const Offset(0, -2))],
                  ),
                  child: Column(children: [
                    SizedBox(
                      width: double.infinity, height: 44,
                      child: OutlinedButton.icon(
                        onPressed: _collectSignature,
                        icon: Icon(
                          _signaturePath != null ? Icons.draw : Icons.gesture,
                          size: 18,
                          color: _signaturePath != null
                              ? Colors.green.shade700 : null,
                        ),
                        label: Text(
                          _signaturePath != null
                              ? 'Signature Collected ✓  (tap to redo)'
                              : 'Collect Customer Signature',
                          style: TextStyle(
                              color: _signaturePath != null
                                  ? Colors.green.shade700 : null),
                        ),
                        style: _signaturePath != null
                            ? OutlinedButton.styleFrom(
                                side: BorderSide(color: Colors.green.shade700))
                            : null,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: SizedBox(height: 48,
                        child: OutlinedButton.icon(
                          onPressed: _sharePdf,
                          icon: const Icon(Icons.print_outlined),
                          label: const Text('Print Estimate'),
                        ),
                      )),
                      const SizedBox(width: 10),
                      Expanded(child: SizedBox(height: 48,
                        child: FilledButton.icon(
                          onPressed: _finalizing || items.isEmpty
                              ? null : _finalizeInvoice,
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.green.shade700),
                          icon: _finalizing
                              ? const SizedBox(width: 18, height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.lock_outline),
                          label: Text(_finalizing ? 'Finalizing…' : 'Finalize'),
                        ),
                      )),
                    ]),
                  ]),
                ),
            ]),
          ),
    );
  }

  Widget _headerCard(Map<String, dynamic> inv) {
    final status    = (inv['status'] ?? 'ESTIMATE').toString();
    final payMethod = (inv['payment_method'] ?? '').toString();
    final date      = (inv['invoice_date'] ?? '').toString();
    // Show company name as primary if available, individual name as secondary
    final companyName  = (customer?['company_name'] ?? '').toString();
    final customerName = (inv['customer_name'] ?? 'Customer').toString();
    final primaryName  = companyName.isNotEmpty ? companyName : customerName;
    final secondaryName = companyName.isNotEmpty ? customerName : '';
    return Card(child: Padding(padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(primaryName,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        if (secondaryName.isNotEmpty && secondaryName != primaryName)
          Text(secondaryName,
              style: const TextStyle(color: Colors.grey, fontSize: 13)),
        if (customer != null &&
            (customer!['phone'] ?? '').toString().isNotEmpty)
          Text((customer!['phone'] ?? '').toString(),
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 4, children: [
          _chip(status, _statusColor(status)),
          if (payMethod.isNotEmpty) _chip(payMethod, Colors.grey),
          if (date.isNotEmpty) _chip(date, Colors.grey),
        ]),
      ]),
    ));
  }

  Widget _chip(String label, Color color) => Chip(
    label: Text(label, style: TextStyle(
        color: color, fontWeight: FontWeight.w600, fontSize: 11)),
    backgroundColor: color.withOpacity(0.12),
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  Widget _totalBar(Map<String, dynamic> inv) {
    final cents = (inv['amount_cents'] as int?) ?? 0;
    final total = (cents / 100).toStringAsFixed(2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Total',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        Text('\$$total',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      ]),
    );
  }

  Widget _addServiceCard() {
    return Card(child: Padding(padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Add Service Line',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const Spacer(),
          TextButton(
            style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            onPressed: () => setState(() {
              _useCustomService = !_useCustomService;
              _selectedServiceId = null;
              _customNameCtl.clear();
            }),
            child: Text(_useCustomService ? 'Use catalogue' : 'Custom name',
                style: const TextStyle(fontSize: 11)),
          ),
        ]),
        const SizedBox(height: 6),

        // Vehicle picker
        if (allCustomerVehicles.isNotEmpty) ...[
          DropdownButtonFormField<String?>(
            value: _selectedVehicleId,
            isExpanded: true,   // ← fixes overflow
            decoration: const InputDecoration(
              labelText: 'Vehicle', border: OutlineInputBorder(),
              isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              prefixIcon: Icon(Icons.directions_car_outlined, size: 18),
            ),
            items: [
              const DropdownMenuItem<String?>(
                  value: null, child: Text('— No specific vehicle —',
                      overflow: TextOverflow.ellipsis)),
              ...allCustomerVehicles.map((v) => DropdownMenuItem<String?>(
                value: v['vehicle_id'].toString(),
                child: Text(_vehicleLabel(v['vehicle_id'].toString()),
                    overflow: TextOverflow.ellipsis),
              )),
            ],
            onChanged: _onVehicleSelected,
          ),
          const SizedBox(height: 6),
        ],  // end vehicle picker spread

        // Odometer field — only shown when a vehicle is selected
        if (_selectedVehicleId != null) ...[
          TextField(
            controller: _odometerCtl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Odometer (miles)',
              border: OutlineInputBorder(), isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              prefixIcon: Icon(Icons.speed_outlined, size: 18),
              hintText: 'e.g. 85000',
            ),
          ),
          const SizedBox(height: 6),
        ],

        // Service picker or free-text
        if (!_useCustomService && services.isNotEmpty)
          DropdownButtonFormField<String?>(
            value: _selectedServiceId,
            isExpanded: true,   // ← fixes overflow
            decoration: const InputDecoration(
              labelText: 'Service', border: OutlineInputBorder(),
              isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              prefixIcon: Icon(Icons.build_outlined, size: 18),
            ),
            items: [
              const DropdownMenuItem<String?>(
                  value: null, child: Text('— Select service —')),
              ...services.map((s) {
                final type  = (s['service_type'] ?? '').toString();
                final label = '${(s['name'] ?? '').toString()}'
                    '${type.isNotEmpty ? ' — $type' : ''}';
                final cents = (s['default_price_cents'] as int?) ?? 0;
                final price = '\$${(cents / 100).toStringAsFixed(2)}';
                return DropdownMenuItem<String?>(
                  value: s['service_id'].toString(),
                  child: Text('$label  ($price)',
                      overflow: TextOverflow.ellipsis),
                );
              }),
            ],
            onChanged: _onServiceSelected,
          )
        else
          TextField(
            controller: _customNameCtl,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Service description',
              border: OutlineInputBorder(), isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
          ),
        const SizedBox(height: 6),

        // Qty + Price row
        Row(children: [
          SizedBox(width: 64, child: TextField(
            controller: _qtyCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Qty', border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10)),
          )),
          const SizedBox(width: 6),
          Expanded(child: TextField(
            controller: _priceCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Price (\$)', border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10)),
          )),
          const SizedBox(width: 6),
          Expanded(child: TextField(
            controller: _discountCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: 'Discount (\$)', border: const OutlineInputBorder(),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                prefixText: '- ',
                prefixStyle: TextStyle(color: Colors.red.shade700)),
          )),
        ]),
        const SizedBox(height: 6),

        // Inspection result + certificate row
        Row(children: [
          Expanded(child: DropdownButtonFormField<String>(
            value: _selectedResult.isEmpty ? null : _selectedResult,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Result', border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              prefixIcon: Icon(Icons.fact_check_outlined, size: 18),
            ),
            hint: const Text('— Optional —'),
            items: const [
              DropdownMenuItem(value: 'PASS',   child: Text('PASS')),
              DropdownMenuItem(value: 'FAIL',   child: Text('FAIL')),
              DropdownMenuItem(value: 'EXEMPT', child: Text('EXEMPT')),
              DropdownMenuItem(value: 'REJECT', child: Text('REJECT')),
            ],
            onChanged: (v) => setState(() => _selectedResult = v ?? ''),
          )),
          const SizedBox(width: 6),
          Expanded(child: TextField(
            controller: _certCtl,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Cert #', border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              prefixIcon: Icon(Icons.numbers_outlined, size: 18),
            ),
          )),
        ]),
        const SizedBox(height: 6),

        SizedBox(width: double.infinity, height: 40,
          child: ElevatedButton(
              onPressed: _addItem,
              style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14)),
              child: const Text('Add Service Line')),
        ),
      ]),
    ));
  }

  /// Returns items as inline widgets (for use inside a parent ListView).
  List<Widget> _itemsInline() {
    if (items.isEmpty) {
      return [const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: Text('No service lines yet.',
            style: TextStyle(color: Colors.grey))),
      )];
    }
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final it in items) {
      final vid = (it['vehicle_id'] ?? '').toString();
      grouped.putIfAbsent(vid, () => []).add(it);
    }
    final widgets = <Widget>[];
    for (final entry in grouped.entries) {
      final label = _vehicleLabel(entry.key.isEmpty ? null : entry.key);
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          const Icon(Icons.directions_car_outlined, size: 13, color: Colors.grey),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(
              fontWeight: FontWeight.w600, color: Colors.grey, fontSize: 12)),
        ]),
      ));
      for (final it in entry.value) {
        final name         = (it['name'] ?? '').toString();
        final qty          = (it['qty'] as num?)?.toDouble() ?? 1.0;
        final cents        = (it['unit_price_cents'] as int?) ?? 0;
        final discCents    = (it['discount_cents'] as int?) ?? 0;
        final price        = (cents / 100).toStringAsFixed(2);
        final lineTotal    = (((qty * cents) - discCents) / 100).toStringAsFixed(2);
        final localId      = it['id'] as int;
        final itemId       = (it['item_id'] ?? '').toString();
        final odo          = (it['odometer'] ?? '').toString();
        final result       = (it['result'] ?? '').toString();
        final cert         = (it['cert'] ?? '').toString();
        Color? resultColor;
        if (result == 'PASS')   resultColor = Colors.green.shade700;
        if (result == 'FAIL' || result == 'REJECT') resultColor = Colors.red.shade700;
        if (result == 'EXEMPT') resultColor = Colors.orange.shade700;
        final subtitleParts = [
          '${qty % 1 == 0 ? qty.toInt() : qty}  ×  \$$price'
              '${discCents > 0 ? '  −\$${(discCents / 100).toStringAsFixed(2)}' : ''}'
              '  =  \$$lineTotal',
          if (odo.isNotEmpty) 'Odo: $odo mi',
          if (cert.isNotEmpty) 'Cert: $cert',
        ];
        widgets.add(Card(
          margin: const EdgeInsets.only(bottom: 4),
          child: ListTile(
            dense: true,
            title: Row(children: [
              Expanded(child: Text(name)),
              if (result.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: (resultColor ?? Colors.grey).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: resultColor ?? Colors.grey, width: 0.8),
                  ),
                  child: Text(result,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                        color: resultColor ?? Colors.grey)),
                ),
            ]),
            subtitle: Text(subtitleParts.join('\n')),
            isThreeLine: subtitleParts.length > 1,
            trailing: _isFinalized
                ? null
                : IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _deleteItem(localId, itemId),
                  ),
          ),
        ));
      }
      widgets.add(const Divider(height: 12));
    }
    return widgets;
  }
}
