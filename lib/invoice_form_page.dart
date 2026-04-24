import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'local_db.dart';

class InvoiceFormPage extends StatefulWidget {
  final String deviceId;
  final String? invoiceId;
  final String? customerId;
  final Future<void> Function()? scheduleSync;

  const InvoiceFormPage({
    super.key, required this.deviceId,
    this.invoiceId, this.customerId, this.scheduleSync,
  });

  @override
  State<InvoiceFormPage> createState() => _InvoiceFormPageState();
}

class _InvoiceFormPageState extends State<InvoiceFormPage> {
  final db = LocalDb.instance;
  final _formKey  = GlobalKey<FormState>();
  final _notesCtl = TextEditingController();

  String _paymentMethod = '';
  String _status        = 'ESTIMATE';
  DateTime _invoiceDate = DateTime.now();
  String? _customerId;
  String  _customerName = '';
  List<Map<String, dynamic>> _vehicles = [];
  bool _loading = true, _saving = false;
  bool get _isEdit => widget.invoiceId != null;

  static const _paymentMethods = [
    'CASH', 'CARD', 'VISA', 'MASTERCARD', 'AMEX', 'DISCOVER',
    'CHECK', 'CHARGE', 'OTHER',
  ];
  static const _cardMethods = {'CARD', 'VISA', 'MASTERCARD', 'AMEX', 'DISCOVER'};
  static const _statuses = ['ESTIMATE'];

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _notesCtl.dispose(); super.dispose(); }

  Future<void> _load() async {
    if (_isEdit) {
      final inv = await db.getInvoice(widget.invoiceId!);
      if (inv != null && mounted) {
        _customerId   = (inv['customer_id']    ?? '').toString();
        _customerName = (inv['customer_name']  ?? '').toString();
        _paymentMethod = (inv['payment_method'] ?? 'CASH').toString();
        _status        = (inv['status']         ?? 'ESTIMATE').toString();
        _notesCtl.text = (inv['notes']          ?? '').toString();
        final ds = (inv['invoice_date'] ?? '').toString();
        if (ds.isNotEmpty) _invoiceDate = DateTime.tryParse(ds) ?? DateTime.now();
        if (_customerId != null && _customerId!.isNotEmpty)
          _vehicles = await db.getVehicles(_customerId!);
      }
    } else if (widget.customerId != null) {
      _customerId = widget.customerId;
      final c = await db.getCustomer(widget.customerId!);
      if (c != null) {
        final company = (c['company_name'] ?? '').toString();
        _customerName = company.isNotEmpty ? company : (c['name'] ?? '').toString();
      }
      _vehicles = await db.getVehicles(widget.customerId!);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(context: context,
        initialDate: _invoiceDate, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked != null && mounted) setState(() => _invoiceDate = picked);
  }

  String get _formattedDate =>
      '${_invoiceDate.year.toString().padLeft(4, '0')}-'
      '${_invoiceDate.month.toString().padLeft(2, '0')}-'
      '${_invoiceDate.day.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_customerId == null || _customerId!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a customer')));
      return;
    }
    setState(() => _saving = true);
    try {
      final seq     = DateTime.now().millisecondsSinceEpoch;
      final eventId = const Uuid().v4();
      final notes   = _notesCtl.text.trim().isEmpty ? null : _notesCtl.text.trim();
      if (_isEdit) {
        await db.updateInvoiceAndEnqueueUpsert(
          invoiceId: widget.invoiceId!, deviceId: widget.deviceId,
          customerId: _customerId!, customerName: _customerName,
          paymentMethod: _paymentMethod, status: _status,
          notes: notes, invoiceDate: _formattedDate, eventId: eventId, seq: seq,
        );
        await widget.scheduleSync?.call();
        if (mounted) Navigator.of(context).pop(true);
      } else {
        final newId = const Uuid().v4();
        // Look up first vehicle for this customer to include in the invoice header
        final vehs = await db.getVehicles(_customerId!);
        final veh  = vehs.isNotEmpty ? vehs.first : null;
        await db.createInvoiceAndEnqueueUpsert(
          invoiceId: newId, deviceId: widget.deviceId,
          customerId: _customerId!, customerName: _customerName,
          paymentMethod: _paymentMethod, status: _status,
          notes: notes, invoiceDate: _formattedDate, eventId: eventId, seq: seq,
          vin:   veh?['vin']?.toString(),
          plate: veh?['plate']?.toString(),
          year:  veh?['year']?.toString(),
          make:  veh?['make']?.toString(),
          model: veh?['model']?.toString(),
        );
        await widget.scheduleSync?.call();
        if (mounted) Navigator.of(context).pop(newId);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Invoice' : 'New Invoice'),
        actions: [
          _saving
              ? const Padding(padding: EdgeInsets.all(16),
                  child: SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : TextButton(onPressed: _save,
                  child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold))),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                // Customer display or picker
                if (_customerId != null && _customerId!.isNotEmpty)
                  Card(child: ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const Text('Customer'),
                    subtitle: Text(_customerName),
                  ))
                else
                  _CustomerPicker(onSelected: (id, name) async {
                    setState(() { _customerId = id; _customerName = name; _vehicles = []; });
                    final v = await db.getVehicles(id);
                    if (mounted) setState(() => _vehicles = v);
                  }),
                const SizedBox(height: 16),

                // Date picker
                InkWell(
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Invoice Date',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.calendar_today_outlined)),
                    child: Text(_formattedDate),
                  ),
                ),
                const SizedBox(height: 16),

                // Payment method
                DropdownButtonFormField<String>(
                  value: _paymentMethod.isEmpty ? null : _paymentMethod,
                  decoration: const InputDecoration(
                    labelText: 'Payment Method',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.payment_outlined),
                  ),
                  hint: const Text('Select payment method'),
                  items: _paymentMethods
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setState(() => _paymentMethod = v ?? ''),
                ),
                if (_paymentMethod == 'CHARGE') ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: Row(children: [
                      Icon(Icons.account_balance_wallet_outlined,
                          size: 16, color: Colors.blue.shade700),
                      const SizedBox(width: 8),
                      Expanded(child: Text(
                        'This invoice will be charged to the customer\'s account balance.',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade800),
                      )),
                    ]),
                  ),
                ],
                const SizedBox(height: 16),

                // Notes
                TextFormField(
                  controller: _notesCtl, maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Notes (optional)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.notes_outlined),
                      alignLabelWithHint: true),
                ),

                // Vehicles summary
                if (_vehicles.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(8)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Customer Vehicles',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      const Text('Assign service lines to vehicles on the invoice detail page.',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 8),
                      ..._vehicles.map((v) {
                        final parts = [
                          if ((v['year']  ?? '').toString().isNotEmpty) v['year'].toString(),
                          if ((v['make']  ?? '').toString().isNotEmpty) v['make'].toString(),
                          if ((v['model'] ?? '').toString().isNotEmpty) v['model'].toString(),
                        ];
                        final plate = (v['plate'] ?? '').toString();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(children: [
                            const Icon(Icons.directions_car_outlined, size: 14, color: Colors.grey),
                            const SizedBox(width: 6),
                            Text(
                              parts.isEmpty ? 'Vehicle'
                                  : '${parts.join(' ')}${plate.isNotEmpty ? ' ($plate)' : ''}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ]),
                        );
                      }),
                    ]),
                  ),
                ],

                const SizedBox(height: 32),
                SizedBox(height: 48, child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.check),
                  label: Text(_isEdit ? 'Update Invoice' : 'Create Invoice'),
                )),
              ]),
            ),
    );
  }
}

class _CustomerPicker extends StatefulWidget {
  final void Function(String id, String name) onSelected;
  const _CustomerPicker({required this.onSelected});

  @override
  State<_CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends State<_CustomerPicker> {
  List<Map<String, dynamic>> _customers = [];
  String? _selectedId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    LocalDb.instance.listCustomers().then((c) {
      if (mounted) setState(() { _customers = c; _loading = false; });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LinearProgressIndicator();
    return DropdownButtonFormField<String>(
      value: _selectedId,
      decoration: const InputDecoration(labelText: 'Customer *',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.person_outline)),
      hint: const Text('Select a customer'),
      items: _customers.map((c) => DropdownMenuItem<String>(
        value: c['customer_id'].toString(),
        child: Text('${(c['name'] ?? '').toString()}'
            '${(c['company_name'] ?? '').toString().isNotEmpty ? ' — ${c['company_name']}' : ''}'),
      )).toList(),
      onChanged: (id) {
        if (id == null) return;
        setState(() => _selectedId = id);
        final c = _customers.firstWhere((c) => c['customer_id'] == id);
        final co = (c['company_name'] ?? '').toString();
        final nm = (c['name'] ?? '').toString();
        widget.onSelected(id, co.isNotEmpty ? co : nm);
      },
      validator: (v) => v == null ? 'Please select a customer' : null,
    );
  }
}
