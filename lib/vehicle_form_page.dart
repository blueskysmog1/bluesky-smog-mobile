import 'dart:convert';
import 'package:flutter/material.dart';
import 'vin_scanner_page.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'local_db.dart';

class VehicleFormPage extends StatefulWidget {
  final String customerId;
  final String deviceId;
  final String? vehicleId;

  const VehicleFormPage({
    super.key, required this.customerId,
    required this.deviceId, this.vehicleId,
  });

  @override
  State<VehicleFormPage> createState() => _VehicleFormPageState();
}

class _VehicleFormPageState extends State<VehicleFormPage> {
  final db = LocalDb.instance;

  final _vinCtl      = TextEditingController();
  final _plateCtl    = TextEditingController();
  final _makeCtl     = TextEditingController();
  final _modelCtl    = TextEditingController();
  final _yearCtl     = TextEditingController();
  final _odometerCtl = TextEditingController();

  String? _serviceType;         // from the services catalogue
  int? _testIntervalDays;  // null=none, 90, 183, 365, 730
  List<Map<String, dynamic>> _services = [];
  bool _loading = true, _saving = false, _decoding = false;
  String? _decodeMsg;
  bool _decodeSuccess = false;
  bool get _isEdit => widget.vehicleId != null;

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() {
    _vinCtl.dispose(); _plateCtl.dispose(); _makeCtl.dispose();
    _modelCtl.dispose(); _yearCtl.dispose(); _odometerCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final services = await db.listServices();
    if (_isEdit) {
      final v = await db.getVehicle(widget.vehicleId!);
      if (v != null && mounted) {
        _vinCtl.text      = (v['vin']          ?? '').toString();
        _plateCtl.text    = (v['plate']        ?? '').toString();
        _makeCtl.text     = (v['make']         ?? '').toString();
        _modelCtl.text    = (v['model']        ?? '').toString();
        _yearCtl.text     = (v['year']         ?? '').toString();
        _odometerCtl.text = (v['odometer']     ?? '').toString();
        _serviceType      = (v['service_type'] ?? '').toString().isEmpty
            ? null : (v['service_type'] ?? '').toString();
        final rawInterval = v['test_interval_days'];
        _testIntervalDays = rawInterval != null ? (rawInterval as int) : null;
      }
    }
    if (mounted) setState(() { _services = services; _loading = false; });
  }

  Future<void> _decodeVin() async {
    final vin = _vinCtl.text.trim().toUpperCase();
    if (vin.length != 17) {
      setState(() { _decodeMsg = 'VIN must be exactly 17 characters'; _decodeSuccess = false; });
      return;
    }
    setState(() { _decoding = true; _decodeMsg = null; });
    try {
      final url = Uri.parse(
          'https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/$vin?format=json');
      final res = await http.get(url).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final json = jsonDecode(res.body) as Map;
      final result = (json['Results'] as List?)?.first as Map?;
      if (result == null) throw Exception('No results');

      final year  = (result['ModelYear'] ?? '').toString().trim();
      final make  = (result['Make']      ?? '').toString().trim();
      final model = (result['Model']     ?? '').toString().trim();

      if (year.isEmpty && make.isEmpty && model.isEmpty) {
        setState(() { _decodeMsg = 'VIN not recognised — fill in manually'; _decodeSuccess = false; });
        return;
      }
      if (year.isNotEmpty)  _yearCtl.text  = year;
      if (make.isNotEmpty)  _makeCtl.text  = make;
      if (model.isNotEmpty) _modelCtl.text = model;
      setState(() { _decodeMsg = 'Decoded: $year $make $model'; _decodeSuccess = true; });
    } catch (e) {
      setState(() { _decodeMsg = 'Decode failed: check connection'; _decodeSuccess = false; });
    } finally {
      if (mounted) setState(() => _decoding = false);
    }
  }

  String? _n(TextEditingController c) {
    final v = c.text.trim(); return v.isEmpty ? null : v;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final vehicleId = widget.vehicleId ?? const Uuid().v4();
      await db.upsertVehicle(
        vehicleId: vehicleId, customerId: widget.customerId,
        deviceId: widget.deviceId,
        vin: _n(_vinCtl), plate: _n(_plateCtl),
        make: _n(_makeCtl), model: _n(_modelCtl),
        year: _n(_yearCtl), odometer: _n(_odometerCtl),
        serviceType: _serviceType,
        testIntervalDays: _testIntervalDays,
        eventId: const Uuid().v4(),
        seq: DateTime.now().millisecondsSinceEpoch,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(TextEditingController ctl, String label,
      {IconData? icon, TextInputType? keyboard, bool upper = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: ctl, keyboardType: keyboard,
        textCapitalization: upper
            ? TextCapitalization.characters
            : TextCapitalization.words,
        decoration: InputDecoration(labelText: label,
            border: const OutlineInputBorder(),
            prefixIcon: icon != null ? Icon(icon) : null),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Vehicle' : 'Add Vehicle'),
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
          : ListView(padding: const EdgeInsets.all(16), children: [

              // ── VIN + Scan + Decode buttons ───────────────────────
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: TextField(
                    controller: _vinCtl,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'VIN',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.numbers_outlined),
                    ),
                    onChanged: (_) => setState(() {
                      _decodeMsg = null; _decodeSuccess = false;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                // Scan button
                SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    onPressed: () async {
                      final result = await openVinScanner(context);
                      if (result != null && result.isNotEmpty && mounted) {
                        // DMV barcodes may return "VIN|PLATE"
                        if (result.contains('|')) {
                          final parts = result.split('|');
                          _vinCtl.text   = parts[0].trim();
                          _plateCtl.text = parts[1].trim();
                        } else {
                          _vinCtl.text = result.trim();
                        }
                        setState(() { _decodeMsg = null; _decodeSuccess = false; });
                        await _decodeVin();
                      }
                    },
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade700,
                        padding: const EdgeInsets.symmetric(horizontal: 14)),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.qr_code_scanner, size: 18,
                            color: Colors.white),
                        Text('Scan', style: TextStyle(fontSize: 11,
                            color: Colors.white)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Decode button
                SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _decoding ? null : _decodeVin,
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14)),
                    child: _decoding
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2,
                                color: Colors.white))
                        : const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.search, size: 18),
                              Text('Decode', style: TextStyle(fontSize: 11)),
                            ],
                          ),
                  ),
                ),
              ]),

              if (_decodeMsg != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: Text(_decodeMsg!,
                      style: TextStyle(
                          fontSize: 12,
                          color: _decodeSuccess
                              ? Colors.green.shade700
                              : Colors.red)),
                ),
              const SizedBox(height: 14),

              // ── Auto-filled fields ────────────────────────────────
              _field(_yearCtl,     'Year',              keyboard: TextInputType.number),
              _field(_makeCtl,     'Make'),
              _field(_modelCtl,    'Model'),
              _field(_plateCtl,    'License Plate',     upper: true,
                  icon: Icons.credit_card_outlined),
              _field(_odometerCtl, 'Odometer (miles)',  keyboard: TextInputType.number,
                  icon: Icons.speed_outlined),

              // ── Service type (from catalogue) ─────────────────────
              const SizedBox(height: 4),
              if (_services.isEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.shade200)),
                  child: Row(children: [
                    Icon(Icons.info_outline, color: Colors.orange.shade700, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(child: Text(
                        'No services defined yet.\nGo to Settings → Services to add them.',
                        style: TextStyle(fontSize: 13))),
                  ]),
                )
              else
                DropdownButtonFormField<String?>(
                  value: _serviceType,
                  decoration: const InputDecoration(
                    labelText: 'Default Service Type',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.build_outlined),
                    helperText: 'Pre-fills when adding this vehicle to an invoice',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('— None —')),
                    ..._services.map((s) {
                      final label = '${(s['name'] ?? '').toString()}'
                          '${(s['service_type'] ?? '').toString().isNotEmpty
                              ? ' (${s['service_type']})'
                              : ''}';
                      return DropdownMenuItem<String?>(
                          value: s['service_id'].toString(),
                          child: Text(label));
                    }),
                  ],
                  onChanged: (v) => setState(() => _serviceType = v),
                ),

              // ── Test interval ─────────────────────────────────────
              const SizedBox(height: 20),
              const Text('Next Test Due',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Wrap(spacing: 8, children: [
                for (final opt in const [
                  {'label': 'None',     'days': null},
                  {'label': '90 Days',  'days': 90},
                  {'label': '6 Months', 'days': 183},
                  {'label': '1 Year',   'days': 365},
                  {'label': '2 Years',  'days': 730},
                ])
                  ChoiceChip(
                    label: Text(opt['label'] as String),
                    selected: _testIntervalDays == opt['days'],
                    onSelected: (_) => setState(() =>
                        _testIntervalDays = opt['days'] as int?),
                  ),
              ]),
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'Sets reminder based on last finalized invoice date.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),

              const SizedBox(height: 16),
              SizedBox(height: 48, child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.check),
                label: Text(_isEdit ? 'Update Vehicle' : 'Add Vehicle'),
              )),
            ]),
    );
  }
}
