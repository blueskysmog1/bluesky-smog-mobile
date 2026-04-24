import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'local_db.dart';

class CustomerFormPage extends StatefulWidget {
  final String deviceId;
  final String? customerId;
  const CustomerFormPage({super.key, required this.deviceId, this.customerId});

  @override
  State<CustomerFormPage> createState() => _CustomerFormPageState();
}

class _CustomerFormPageState extends State<CustomerFormPage> {
  final db           = LocalDb.instance;
  final _formKey     = GlobalKey<FormState>();
  final _firstCtl    = TextEditingController();
  final _lastCtl     = TextEditingController();
  final _companyCtl  = TextEditingController();
  final _phoneCtl    = TextEditingController();
  final _emailCtl    = TextEditingController();
  final _addressCtl  = TextEditingController();
  final _cityCtl     = TextEditingController();
  final _stateCtl    = TextEditingController();
  final _zipCtl      = TextEditingController();
  bool _zipLoading   = false;
  bool _loading      = true, _saving = false;
  bool get _isEdit   => widget.customerId != null;

  // Duplicate detection
  List<Map<String, dynamic>> _matches  = [];
  bool   _searching    = false;
  String _lastSearched = '';

  @override
  void initState() {
    super.initState();
    _firstCtl.addListener(_onNameChanged);
    _lastCtl.addListener(_onNameChanged);
    _companyCtl.addListener(_onNameChanged);
    _load();
  }

  @override
  void dispose() {
    _firstCtl.removeListener(_onNameChanged);
    _lastCtl.removeListener(_onNameChanged);
    _companyCtl.removeListener(_onNameChanged);
    _firstCtl.dispose(); _lastCtl.dispose(); _companyCtl.dispose();
    _phoneCtl.dispose(); _emailCtl.dispose(); _addressCtl.dispose();
    _cityCtl.dispose(); _stateCtl.dispose(); _zipCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_isEdit) {
      final c = await db.getCustomer(widget.customerId!);
      if (c != null && mounted) {
        // Support both old single-name and new first/last format
        final first = (c['first_name'] ?? '').toString();
        final last  = (c['last_name']  ?? '').toString();
        final name  = (c['name']       ?? '').toString();
        if (first.isNotEmpty || last.isNotEmpty) {
          _firstCtl.text = first;
          _lastCtl.text  = last;
        } else if (name.isNotEmpty) {
          // Legacy: split name into first/last
          final parts    = name.trim().split(' ');
          _firstCtl.text = parts.first;
          _lastCtl.text  = parts.length > 1 ? parts.sublist(1).join(' ') : '';
        }
        _companyCtl.text = (c['company_name'] ?? '').toString();
        _phoneCtl.text   = (c['phone']        ?? '').toString();
        _emailCtl.text   = (c['email']        ?? '').toString();
        _addressCtl.text = (c['address']      ?? '').toString();
        _cityCtl.text    = (c['city']         ?? '').toString();
        _stateCtl.text   = (c['state']        ?? '').toString();
        _zipCtl.text     = (c['zip']          ?? '').toString();
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _onNameChanged() {
    final query = '${_firstCtl.text.trim()} ${_lastCtl.text.trim()} '
                  '${_companyCtl.text.trim()}'.trim();
    if (query == _lastSearched || query.length < 2) {
      if (query.length < 2) setState(() => _matches = []);
      return;
    }
    _lastSearched = query;
    _doSearch(query);
  }

  Future<void> _doSearch(String query) async {
    setState(() => _searching = true);
    final results = await db.searchCustomers(query, excludeId: widget.customerId);
    if (!mounted) return;
    setState(() { _matches = results; _searching = false; });
  }

  Future<void> _lookupZip(String zip) async {
    if (zip.length != 5 || int.tryParse(zip) == null) return;
    if (_cityCtl.text.trim().isNotEmpty && _stateCtl.text.trim().isNotEmpty) return;
    setState(() => _zipLoading = true);
    try {
      final uri    = Uri.parse('https://api.zippopotam.us/us/$zip');
      final client = HttpClient();
      final req    = await client.getUrl(uri);
      req.headers.set('Accept', 'application/json');
      final resp   = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        final body  = await resp.transform(const Utf8Decoder()).join();
        final data  = jsonDecode(body);
        final city  = (data['places'][0]['place name'] as String).toUpperCase();
        final state = (data['places'][0]['state abbreviation'] as String).toUpperCase();
        if (mounted) {
          if (_cityCtl.text.trim().isEmpty)  _cityCtl.text  = city;
          if (_stateCtl.text.trim().isEmpty) _stateCtl.text = state;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _zipLoading = false);
  }

  String _t(TextEditingController c) => c.text.trim().toUpperCase();
  String? _n(TextEditingController c) {
    final v = c.text.trim(); return v.isEmpty ? null : v;
  }

  String _fmtPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) {
      return '${digits.substring(0,3)}-${digits.substring(3,6)}-${digits.substring(6)}';
    }
    if (digits.length == 11 && digits.startsWith('1')) {
      return '${digits.substring(1,4)}-${digits.substring(4,7)}-${digits.substring(7)}';
    }
    return raw.trim();
  }

  String? _validateNameOrCompany(String? _) {
    if (_firstCtl.text.trim().isEmpty &&
        _lastCtl.text.trim().isEmpty &&
        _companyCtl.text.trim().isEmpty) {
      return 'Enter a first name, last name, or company name';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    if (_matches.isNotEmpty && !_isEdit) {
      final proceed = await showDialog<bool>(context: context,
        builder: (_) => AlertDialog(
          title: const Text('Similar Customer Found'),
          content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('A customer with a similar name already exists:'),
              const SizedBox(height: 8),
              ..._matches.map((m) {
                final company = (m['company_name'] ?? '').toString();
                final first   = (m['first_name']   ?? '').toString();
                final last    = (m['last_name']    ?? '').toString();
                final name    = [first, last].where((s) => s.isNotEmpty).join(' ');
                final display = company.isNotEmpty ? company : name;
                final phone   = (m['phone'] ?? '').toString();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      border: Border.all(color: Colors.orange.shade200),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(display, style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (company.isNotEmpty && name.isNotEmpty)
                          Text(name, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                        if (phone.isNotEmpty)
                          Text(phone, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
              const Text('Do you want to create a new customer anyway?'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true),
                child: const Text('Create Anyway')),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    setState(() => _saving = true);
    try {
      final customerId = widget.customerId ?? const Uuid().v4();
      await db.upsertCustomer(
        customerId:  customerId,
        deviceId:    widget.deviceId,
        firstName:   _t(_firstCtl),
        lastName:    _t(_lastCtl),
        companyName: _n(_companyCtl),
        phone:       _fmtPhone(_phoneCtl.text),
        email:       _n(_emailCtl),
        address:     _n(_addressCtl),
        city:        _n(_cityCtl),
        state:       _n(_stateCtl),
        zip:         _n(_zipCtl),
        eventId:     const Uuid().v4(),
        seq:         DateTime.now().millisecondsSinceEpoch,
      );
      if (mounted) Navigator.of(context).pop(_isEdit ? true : customerId);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(TextEditingController ctl, String label,
      {IconData? icon, TextInputType? keyboard,
       String? Function(String?)? validator, int maxLines = 1,
       void Function(String)? onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: ctl, keyboardType: keyboard, maxLines: maxLines,
        textCapitalization: TextCapitalization.words,
        onChanged: onChanged,
        decoration: InputDecoration(labelText: label,
            border: const OutlineInputBorder(),
            prefixIcon: icon != null ? Icon(icon) : null),
        validator: validator,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Customer' : 'New Customer'),
        actions: [
          _saving
              ? const Padding(padding: EdgeInsets.all(16),
                  child: SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : TextButton(onPressed: _save,
                  child: const Text('Save',
                      style: TextStyle(fontWeight: FontWeight.bold))),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(padding: const EdgeInsets.all(16), children: [

                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer
                        .withOpacity(0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Enter a first/last name, company name, or both.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),

                // First / Last on same row
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: TextFormField(
                        controller: _firstCtl,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'First Name',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: _validateNameOrCompany,
                      )),
                      const SizedBox(width: 10),
                      Expanded(child: TextFormField(
                        controller: _lastCtl,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Last Name',
                          border: OutlineInputBorder(),
                        ),
                        validator: _validateNameOrCompany,
                      )),
                    ],
                  ),
                ),

                _field(_companyCtl, 'Company Name',
                    icon: Icons.business_outlined,
                    validator: _validateNameOrCompany),

                // Live duplicate warning
                if (_searching)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Row(children: [
                      SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 8),
                      Text('Checking for existing customers...',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ]),
                  )
                else if (_matches.isNotEmpty && !_isEdit)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      border: Border.all(color: Colors.orange.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.warning_amber_rounded,
                              color: Colors.orange.shade700, size: 16),
                          const SizedBox(width: 6),
                          Text('Similar customer${_matches.length > 1 ? 's' : ''} already exist:',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Colors.orange.shade800,
                                  fontSize: 12)),
                        ]),
                        const SizedBox(height: 6),
                        ..._matches.map((m) {
                          final company  = (m['company_name'] ?? '').toString();
                          final first    = (m['first_name']   ?? '').toString();
                          final last     = (m['last_name']    ?? '').toString();
                          final name     = [first, last].where((s) => s.isNotEmpty).join(' ');
                          final primary  = company.isNotEmpty ? company : name;
                          final secondary = company.isNotEmpty && name.isNotEmpty ? name : '';
                          final phone    = (m['phone'] ?? '').toString();
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(children: [
                              const Icon(Icons.person_outline,
                                  size: 14, color: Colors.grey),
                              const SizedBox(width: 6),
                              Expanded(child: Text(
                                '$primary${secondary.isNotEmpty ? ' — $secondary' : ''}${phone.isNotEmpty ? ' • $phone' : ''}',
                                style: const TextStyle(fontSize: 12),
                              )),
                            ]),
                          );
                        }),
                      ],
                    ),
                  ),

                _field(_phoneCtl, 'Phone',
                    icon: Icons.phone_outlined,
                    keyboard: TextInputType.phone,
                    onChanged: (v) {
                      final digits = v.replaceAll(RegExp(r'\D'), '');
                      if (digits.length == 10 && !v.contains('-')) {
                        final fmt = '${digits.substring(0,3)}-${digits.substring(3,6)}-${digits.substring(6)}';
                        _phoneCtl.value = TextEditingValue(
                          text: fmt,
                          selection: TextSelection.collapsed(offset: fmt.length),
                        );
                      }
                    }),
                _field(_emailCtl, 'Email',
                    icon: Icons.email_outlined,
                    keyboard: TextInputType.emailAddress),
                _field(_addressCtl, 'Address',
                    icon: Icons.location_on_outlined),

                // City / State / ZIP row
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 5, child: TextFormField(
                      controller: _cityCtl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'City', border: OutlineInputBorder()),
                    )),
                    const SizedBox(width: 8),
                    SizedBox(width: 64, child: TextFormField(
                      controller: _stateCtl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'State', border: OutlineInputBorder()),
                    )),
                    const SizedBox(width: 8),
                    SizedBox(width: 90, child: TextFormField(
                      controller: _zipCtl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'ZIP',
                        border: const OutlineInputBorder(),
                        suffixIcon: _zipLoading
                            ? const Padding(padding: EdgeInsets.all(12),
                                child: SizedBox(width: 16, height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2)))
                            : null,
                      ),
                      onChanged: (v) { if (v.length == 5) _lookupZip(v); },
                    )),
                  ]),
                ),

                const SizedBox(height: 16),
                SizedBox(height: 48, child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.check),
                  label: Text(_isEdit ? 'Update Customer' : 'Create Customer'),
                )),
              ]),
            ),
    );
  }
}
