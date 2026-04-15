import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'vin_barcode_widget.dart';
import 'package:printing/printing.dart';
import 'package:uuid/uuid.dart';
import 'local_db.dart';
import 'api_service.dart';
import 'pdf_service.dart';
import 'vehicle_form_page.dart';
import 'invoice_form_page.dart';
import 'invoice_detail_page.dart';
import 'customer_form_page.dart';

class CustomerDetailPage extends StatefulWidget {
  final String customerId;
  final String deviceId;
  final Future<void> Function()? scheduleSync;

  const CustomerDetailPage({
    super.key, required this.customerId,
    required this.deviceId, this.scheduleSync,
  });

  @override
  State<CustomerDetailPage> createState() => _CustomerDetailPageState();
}

class _CustomerDetailPageState extends State<CustomerDetailPage> {
  final db  = LocalDb.instance;
  final api = ApiService();
  String? _downloadingPdfId;

  Map<String, dynamic>? customer;
  List<Map<String, dynamic>> vehicles = [];
  List<Map<String, dynamic>> invoices = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final c = await db.getCustomer(widget.customerId);
    final v = await db.getVehicles(widget.customerId);
    final i = await db.latestInvoices(customerId: widget.customerId);
    if (!mounted) return;
    setState(() { customer = c; vehicles = v; invoices = i; });
  }

  Future<void> _editCustomer() async {
    final result = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => CustomerFormPage(
          deviceId: widget.deviceId, customerId: widget.customerId),
    ));
    if (result == true) { await _load(); await widget.scheduleSync?.call(); }
  }

  Future<void> _addVehicle() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VehicleFormPage(
          customerId: widget.customerId, deviceId: widget.deviceId),
    ));
    await _load(); await widget.scheduleSync?.call();
  }

  Future<void> _editVehicle(String vehicleId) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VehicleFormPage(
          customerId: widget.customerId,
          deviceId: widget.deviceId, vehicleId: vehicleId),
    ));
    await _load(); await widget.scheduleSync?.call();
  }

  Future<void> _deleteVehicle(String vehicleId) async {
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Vehicle'),
        content: const Text('Remove this vehicle?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    await db.deleteVehicle(
      vehicleId: vehicleId, deviceId: widget.deviceId,
      eventId: const Uuid().v4(), seq: DateTime.now().millisecondsSinceEpoch,
    );
    await _load(); await widget.scheduleSync?.call();
  }

  Future<void> _deleteCustomer() async {
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Customer?'),
        content: const Text(
            'This will permanently delete this customer, all their '
            'vehicles, and all their invoices on every device.\n\n'
            'This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete Everything'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await db.deleteCustomer(
      customerId: widget.customerId,
      deviceId:   widget.deviceId,
      seq:        DateTime.now().millisecondsSinceEpoch,
    );
    await widget.scheduleSync?.call();
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _newInvoice() async {
    // Create invoice immediately and jump straight to the detail/add-services page
    final db = LocalDb.instance;
    final c  = await db.getCustomer(widget.customerId);
    if (!mounted) return;
    if (c == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Customer not found')));
      return;
    }
    final company      = (c['company_name'] ?? '').toString();
    final first        = (c['first_name']   ?? '').toString();
    final last         = (c['last_name']    ?? '').toString();
    final fullName     = [first, last].where((s) => s.isNotEmpty).join(' ');
    final customerName = company.isNotEmpty ? company : (fullName.isNotEmpty ? fullName : (c['name'] ?? '').toString());
    final invoiceId    = const Uuid().v4();
    final eventId      = const Uuid().v4();
    final seq          = DateTime.now().millisecondsSinceEpoch;
    final today        = DateTime.now();
    final invoiceDate  = '${today.year.toString().padLeft(4,'0')}-'
                         '${today.month.toString().padLeft(2,'0')}-'
                         '${today.day.toString().padLeft(2,'0')}';

    // Look up first vehicle for auto-fill
    final vehicles = await db.getVehicles(widget.customerId);
    String? vin, plate, year, make, model;
    if (vehicles.length == 1) {
      vin   = (vehicles.first['vin']   ?? '').toString();
      plate = (vehicles.first['plate'] ?? '').toString();
      year  = (vehicles.first['year']  ?? '').toString();
      make  = (vehicles.first['make']  ?? '').toString();
      model = (vehicles.first['model'] ?? '').toString();
    }

    await db.createInvoiceAndEnqueueUpsert(
      invoiceId:     invoiceId,
      deviceId:      widget.deviceId,
      customerId:    widget.customerId,
      customerName:  customerName,
      paymentMethod: '',
      status:        'ESTIMATE',
      invoiceDate:   invoiceDate,
      eventId:       eventId,
      seq:           seq,
      vin: vin, plate: plate, year: year, make: make, model: model,
    );
    await widget.scheduleSync?.call();
    if (!mounted) return;
    await _load();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InvoiceDetailPage(
        invoiceId: invoiceId, deviceId: widget.deviceId,
        scheduleSync: widget.scheduleSync,
      ),
    ));
    await _load();
  }

  Future<void> _downloadPdf(String invoiceId, dynamic invoiceNum) async {
    setState(() => _downloadingPdfId = invoiceId);
    try {
      final bytes = await api.downloadPdf(invoiceId);
      if (bytes == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PDF not found on server')));
        return;
      }
      await Printing.sharePdf(
          bytes: bytes,
          filename: 'invoice_${invoiceNum ?? invoiceId}.pdf');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Download failed: $e')));
    } finally {
      if (mounted) setState(() => _downloadingPdfId = null);
    }
  }

  Future<void> _localPdf(Map<String, dynamic> inv) async {
    try {
      final id         = inv['invoice_id'].toString();
      final freshItems = await db.getInvoiceItems(id);
      final allVehs    = await db.getVehicles(widget.customerId);
      final usedIds    = freshItems
          .map((i) => (i['vehicle_id'] ?? '').toString())
          .where((x) => x.isNotEmpty).toSet();
      final invVehs    = allVehs
          .where((v) => usedIds.contains(v['vehicle_id'].toString()))
          .toList();
      final logoPath   = await db.getSetting('logo_path');
      await PdfService.generateAndShare(
          invoice: inv, items: freshItems,
          vehicles: invVehs, customer: customer,
          logoPath: logoPath);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('PDF error: $e')));
    }
  }

  Color _statusColor(String? s) {
    switch (s) {
      case 'PAID': return Colors.green;
      default:     return Colors.orange; // ESTIMATE
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = customer;
    return Scaffold(
      appBar: AppBar(
        title: Text(c == null ? 'Customer' : () {
              final first   = (c['first_name']   ?? '').toString();
              final last    = (c['last_name']    ?? '').toString();
              final company = (c['company_name'] ?? '').toString();
              final name    = [first, last].where((s) => s.isNotEmpty).join(' ');
              return company.isNotEmpty ? company : (name.isNotEmpty ? name : 'Customer');
            }()),
        actions: [
          IconButton(icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit customer', onPressed: _editCustomer),
          IconButton(icon: const Icon(Icons.receipt_long_outlined),
              tooltip: 'New Invoice', onPressed: _newInvoice),
          IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: 'Delete customer',
              onPressed: _deleteCustomer),
        ],
      ),
      body: c == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(16), children: [

                // ── Customer info ───────────────────────────────────
                Card(child: Padding(padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    // Full name
                    Builder(builder: (_) {
                      final first   = (c['first_name']   ?? '').toString();
                      final last    = (c['last_name']    ?? '').toString();
                      final company = (c['company_name'] ?? '').toString();
                      final name    = [first, last].where((s) => s.isNotEmpty).join(' ');
                      final primary = company.isNotEmpty ? company : name;
                      final secondary = company.isNotEmpty && name.isNotEmpty ? name : '';
                      return Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(primary, style: const TextStyle(fontSize: 18,
                              fontWeight: FontWeight.w700)),
                          if (secondary.isNotEmpty)
                            _row(Icons.person_outline, secondary),
                        ]);
                    }),
                    if ((c['phone'] ?? '').toString().isNotEmpty)
                      _row(Icons.phone_outlined,
                          (c['phone'] ?? '').toString(),
                          onTap: () => launchUrl(Uri.parse(
                              'tel:${(c['phone'] ?? '').toString().replaceAll(RegExp(r'[^\d+]'), '')}'))),
                    if ((c['email'] ?? '').toString().isNotEmpty)
                      _row(Icons.email_outlined,
                          (c['email'] ?? '').toString(),
                          onTap: () => launchUrl(Uri.parse(
                              'mailto:${(c['email'] ?? '').toString()}'))),
                    if ((c['address'] ?? '').toString().isNotEmpty)
                      _row(Icons.location_on_outlined,
                          (c['address'] ?? '').toString()),

                  ]),
                )),
                const SizedBox(height: 16),

                // ── Vehicles ────────────────────────────────────────
                Row(children: [
                  const Text('Vehicles',
                      style: TextStyle(fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton.icon(onPressed: _addVehicle,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add')),
                ]),
                if (vehicles.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No vehicles yet.',
                          style: TextStyle(color: Colors.grey)))
                else
                  ...vehicles.map((v) {
                    final vid   = (v['vehicle_id'] ?? '').toString();
                    final parts = [
                      if ((v['year']  ?? '').toString().isNotEmpty)
                        v['year'].toString(),
                      if ((v['make']  ?? '').toString().isNotEmpty)
                        v['make'].toString(),
                      if ((v['model'] ?? '').toString().isNotEmpty)
                        v['model'].toString(),
                    ];
                    final plate = (v['plate']    ?? '').toString();
                    final vin   = (v['vin']       ?? '').toString();
                    final odo   = (v['odometer']  ?? '').toString();
                    final svcType = (v['service_type'] ?? '').toString();
                    final title = parts.isEmpty ? 'Vehicle' : parts.join(' ');
                    final sub   = [
                      if (plate.isNotEmpty) 'Plate: $plate',
                      if (vin.isNotEmpty)   'VIN: $vin',
                      if (odo.isNotEmpty)   'Odo: $odo mi',
                    ].join('  •  ');
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              const Icon(Icons.directions_car_outlined,
                                  color: Colors.blueGrey),
                              const SizedBox(width: 12),
                              Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(title, style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15)),
                                  if (sub.isNotEmpty)
                                    Text(sub, style: const TextStyle(
                                        fontSize: 12, color: Colors.black54)),
                                  if (svcType.isNotEmpty)
                                    Text('Service: \$svcType',
                                        style: TextStyle(fontSize: 11,
                                            color: Colors.blue.shade700)),
                                ],
                              )),
                              PopupMenuButton<String>(
                                onSelected: (val) {
                                  if (val == 'edit')   _editVehicle(vid);
                                  if (val == 'delete') _deleteVehicle(vid);
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(value: 'edit',
                                      child: Text('Edit')),
                                  const PopupMenuItem(value: 'delete',
                                      child: Text('Delete')),
                                ],
                              ),
                            ]),
                            // VIN barcode
                            if (vin.isNotEmpty && vin.length == 17) ...[
                              const SizedBox(height: 10),
                              const Divider(height: 1),
                              const SizedBox(height: 10),
                              VinBarcode(vin: vin),
                            ],
                          ],
                        ),
                      ),
                    );
                  }),
                const SizedBox(height: 16),

                // ── Invoices ────────────────────────────────────────
                Row(children: [
                  const Text('Invoices',
                      style: TextStyle(fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton.icon(onPressed: _newInvoice,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('New')),
                ]),
                if (invoices.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No invoices yet.',
                          style: TextStyle(color: Colors.grey)))
                else
                  ...invoices.map((inv) {
                    final id        = (inv['invoice_id'] ?? '').toString();
                    final num       = inv['invoice_number'];
                    final numStr    = num != null ? '#$num' : '#—';
                    final status    = (inv['status'] ?? 'ESTIMATE').toString();
                    final cents     = (inv['amount_cents'] as int?) ?? 0;
                    final total     = (cents / 100).toStringAsFixed(2);
                    final date      = (inv['invoice_date'] ?? '').toString();
                    final finalized = (inv['finalized'] as int? ?? 0) == 1;

                    // ── FINALIZED card ──────────────────────────────
                    if (finalized) {
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                              color: Colors.green.shade300, width: 1.5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(children: [
                            // Lock badge
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.lock,
                                  color: Colors.green.shade700, size: 20),
                            ),
                            const SizedBox(width: 12),
                            // Invoice info
                            Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Text(numStr,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15)),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                        color: Colors.green.shade100,
                                        borderRadius:
                                            BorderRadius.circular(4)),
                                    child: Text('PAID',
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.green.shade800,
                                            fontWeight: FontWeight.w700)),
                                  ),
                                ]),
                                const SizedBox(height: 2),
                                Text('\$$total  •  $date',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey)),
                              ],
                            )),
                            const SizedBox(width: 8),
                            // PDF button — server if available, local fallback
                            Builder(builder: (_) {
                              final pdfReady     = (inv['pdf_uploaded'] as int? ?? 0) == 1;
                              final isDownloading = _downloadingPdfId == id;
                              if (pdfReady) {
                                return isDownloading
                                    ? const SizedBox(width: 24, height: 24,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                    : FilledButton.icon(
                                        style: FilledButton.styleFrom(
                                          backgroundColor: Colors.green.shade700,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 6),
                                          minimumSize: Size.zero,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          textStyle: const TextStyle(fontSize: 12),
                                        ),
                                        onPressed: () => _downloadPdf(id, num),
                                        icon: const Icon(Icons.download_outlined, size: 15),
                                        label: const Text('PDF'),
                                      );
                              }
                              return OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  textStyle: const TextStyle(fontSize: 12),
                                ),
                                onPressed: () => _localPdf(inv),
                                icon: const Icon(Icons.picture_as_pdf_outlined, size: 15),
                                label: const Text('PDF'),
                              );
                            }),
                          ]),
                        ),
                      );
                    }

                    // ── DRAFT / IN-PROGRESS card ────────────────────
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor:
                              _statusColor(status).withOpacity(0.12),
                          child: Icon(Icons.receipt_outlined,
                              color: _statusColor(status), size: 18),
                        ),
                        title: Row(children: [
                          Text(numStr,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15)),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                                color:
                                    _statusColor(status).withOpacity(0.13),
                                borderRadius: BorderRadius.circular(4)),
                            child: Text(status,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: _statusColor(status),
                                    fontWeight: FontWeight.w600)),
                          ),
                        ]),
                        subtitle: Text(date,
                            style: const TextStyle(fontSize: 12)),
                        trailing: Text('\$$total',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15)),
                        onTap: () async {
                          await Navigator.of(context)
                              .push(MaterialPageRoute(
                            builder: (_) => InvoiceDetailPage(
                              invoiceId: id,
                              deviceId: widget.deviceId,
                              scheduleSync: widget.scheduleSync,
                            ),
                          ));
                          await _load();
                        },
                      ),
                    );
                  }),
              ]),
            ),
    );
  }

  Widget _row(IconData icon, String text, {VoidCallback? onTap}) {
    final content = Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        Icon(icon, size: 15, color: onTap != null ? Colors.blue.shade600 : Colors.grey),
        const SizedBox(width: 6),
        Expanded(child: Text(text,
            style: TextStyle(
              color: onTap != null ? Colors.blue.shade600 : Colors.grey,
              fontSize: 13,
              decoration: onTap != null ? TextDecoration.underline : null,
            ))),
      ]),
    );
    if (onTap == null) return content;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(4), child: content);
  }
}