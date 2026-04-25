import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'master_dashboard_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'local_db.dart';
import 'reports_page.dart';

class SettingsPage extends StatefulWidget {
  final VoidCallback? onLogout;
  final VoidCallback? onForceResync;
  const SettingsPage({super.key, this.onLogout, this.onForceResync});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final db = LocalDb.instance;
  String? _logoPath;
  List<Map<String, dynamic>> _services = [];
  bool _loading = true;
  bool _isMaster = false;

  // Company info controllers
  final _coNameCtl    = TextEditingController();
  final _coAddrCtl    = TextEditingController();
  final _coCityCtl    = TextEditingController();
  final _coPhoneCtl   = TextEditingController();
  final _coEmailCtl   = TextEditingController();
  final _coArdCtl          = TextEditingController();
  final _noticeCtl         = TextEditingController();
  final _cardSurchargeCtl  = TextEditingController();
  bool _surchargeIsPercent = true;   // true = %, false = fixed $
  bool _coInfoSaving  = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final logo   = await db.getSetting('logo_path');
    final svcs   = await db.listServices();
    final prefs  = await SharedPreferences.getInstance();
    final uname  = prefs.getString('username') ?? '';
    if (!mounted) return;
    final coName   = await db.getSetting('co_name')         ?? '';
    final coAddr   = await db.getSetting('co_addr')         ?? '';
    final coCity   = await db.getSetting('co_city')         ?? '';
    final coPhone  = await db.getSetting('co_phone')        ?? '';
    final coEmail  = await db.getSetting('co_email')        ?? '';
    final coArd         = await db.getSetting('co_ard')               ?? '';
    final notice        = await db.getSetting('invoice_notice')       ?? '';
    final surchargeVal  = await db.getSetting('card_surcharge_value') ?? '';
    final surchargeType = await db.getSetting('card_surcharge_type')  ?? 'percent';
    if (!mounted) return;
    setState(() {
      _logoPath           = logo;
      _services           = svcs;
      _isMaster           = uname == 'bluesky_master';
      _surchargeIsPercent = surchargeType != 'fixed';
      _loading            = false;
    });
    _coNameCtl.text         = coName;
    _coAddrCtl.text         = coAddr;
    _coCityCtl.text         = coCity;
    _coPhoneCtl.text        = coPhone;
    _coEmailCtl.text        = coEmail;
    _coArdCtl.text          = coArd;
    _noticeCtl.text         = notice;
    _cardSurchargeCtl.text  = surchargeVal;
  }

  // ── Logo ──────────────────────────────────────────────────────────
  Future<void> _pickLogo() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final dir  = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/company_logo.png');
    await File(picked.path).copy(dest.path);
    await db.setSetting('logo_path', dest.path);
    if (mounted) setState(() => _logoPath = dest.path);
  }

  Future<void> _removeLogo() async {
    await db.setSetting('logo_path', '');
    if (mounted) setState(() => _logoPath = null);
  }

  // ── Services ──────────────────────────────────────────────────────
  Future<void> _showServiceDialog({Map<String, dynamic>? existing}) async {
    final nameCtl  = TextEditingController(
        text: existing != null ? (existing['name'] ?? '').toString() : '');
    final typeCtl  = TextEditingController(
        text: existing != null ? (existing['service_type'] ?? '').toString() : '');
    final priceCtl = TextEditingController(
        text: existing != null
            ? (((existing['default_price_cents'] as int?) ?? 0) / 100)
                .toStringAsFixed(2)
            : '');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add Service' : 'Edit Service'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Service Name *',
                  hintText: 'e.g. Clean Truck',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: typeCtl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Service Type',
                  hintText: 'e.g. Opacity, OBDII, Smog Check',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: priceCtl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Default Price (\$)',
                  border: OutlineInputBorder(),
                  prefixText: '\$ '),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (result != true) return;
    final name = nameCtl.text.trim();
    if (name.isEmpty) return;
    final type  = typeCtl.text.trim().isEmpty ? null : typeCtl.text.trim();
    final cents = ((double.tryParse(priceCtl.text.trim()) ?? 0.0) * 100).round();
    final sid   = existing != null
        ? existing['service_id'].toString()
        : const Uuid().v4();
    final order = existing != null
        ? ((existing['sort_order'] as int?) ?? 0)
        : _services.length;

    await db.upsertService(
        serviceId: sid, name: name, serviceType: type,
        defaultPriceCents: cents, sortOrder: order);
    await _load();
  }

  Future<void> _deleteService(String serviceId, String name) async {
    final ok = await showDialog<bool>(context: context,
        builder: (_) => AlertDialog(
          title: const Text('Delete Service'),
          content: Text('Remove "$name" from the catalogue?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete',
                    style: TextStyle(color: Colors.red))),
          ],
        ));
    if (ok != true) return;
    await db.deleteService(serviceId);
    await _load();
  }

  Future<void> _saveCompanyInfo() async {
    setState(() => _coInfoSaving = true);
    await db.setSetting('co_name',        _coNameCtl.text.trim());
    await db.setSetting('co_addr',        _coAddrCtl.text.trim());
    await db.setSetting('co_city',        _coCityCtl.text.trim());
    await db.setSetting('co_phone',       _coPhoneCtl.text.trim());
    await db.setSetting('co_email',       _coEmailCtl.text.trim());
    await db.setSetting('co_ard',         _coArdCtl.text.trim());
    await db.setSetting('invoice_notice',       _noticeCtl.text.trim());
    await db.setSetting('card_surcharge_value', _cardSurchargeCtl.text.trim());
    await db.setSetting('card_surcharge_type',  _surchargeIsPercent ? 'percent' : 'fixed');
    if (mounted) {
      setState(() => _coInfoSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Company info saved')));
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign Out?'),
        content: const Text('You will need to sign in again to sync with the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final prefs    = await SharedPreferences.getInstance();
    final deviceId = prefs.getString('device_id') ?? '';
    await prefs.remove('username');
    await prefs.remove('password');
    await prefs.remove('auth_token');
    await prefs.remove('company_id');
    await prefs.remove('company_name');
    await prefs.remove('since_seq');
    // Wipe all local data so the next account starts clean
    if (deviceId.isNotEmpty) {
      await LocalDb.instance.clearAllLocalData(deviceId);
    }
    if (mounted) {
      widget.onLogout?.call();
    }
  }

  Future<void> _forceResync() async {
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Force Re-Sync?'),
        content: const Text(
          'This resets the sync position to the beginning and re-downloads all '
          'records from the server. Use this if payments or invoices are missing '
          'on this device.\n\nThis is safe — no data will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Force Re-Sync'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('since_seq', 0);
    if (mounted) {
      Navigator.of(context).pop();          // close settings
      widget.onForceResync?.call();         // trigger immediate sync on caller
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Re-syncing from the beginning…')));
    }
  }

  Future<void> _manageSubscription() async {
    final prefs   = await SharedPreferences.getInstance();
    final apiBase = 'https://api.blueskysmog.net';
    final token   = prefs.getString('auth_token') ?? '';
    final uname   = prefs.getString('username') ?? '';
    final pass    = prefs.getString('password') ?? '';

    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token.isNotEmpty) {
      headers['x-token'] = token;
    } else {
      headers['x-username'] = uname;
      headers['x-password'] = pass;
    }

    try {
      final res = await http.post(
        Uri.parse('$apiBase/v1/subscription/portal'),
        headers: headers,
      ).timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final portalUrl = (body['portal_url'] as String?) ?? '';
        if (portalUrl.isNotEmpty) {
          final uri = Uri.parse(portalUrl);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not open billing portal URL.')));
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No portal URL returned from server.')));
        }
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>? ?? {};
        final detail = (body['detail'] as String?) ?? res.reasonPhrase ?? 'Unknown error';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Manage Subscription error: $detail')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Manage Subscription error: $e')));
      }
    }
  }

  Widget _coField(TextEditingController ctl, String label, IconData icon,
      {TextInputType keyboard = TextInputType.text}) =>
      TextField(
        controller: ctl,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          prefixIcon: Icon(icon, size: 18),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart_outlined),
            tooltip: 'Reports',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ReportsPage())),
          ),
          if (_isMaster)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              tooltip: 'Master Dashboard',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const MasterDashboardPage())),
            ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.red),
            tooltip: 'Sign Out',
            onPressed: _logout,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [

              // ── Logo section ───────────────────────────────────────
              const Text('Company Logo',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Card(child: Padding(padding: const EdgeInsets.all(16),
                child: Row(children: [
                  // Preview
                  Container(
                    width: 80, height: 80,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _logoPath != null && _logoPath!.isNotEmpty &&
                            File(_logoPath!).existsSync()
                        ? Image.file(File(_logoPath!), fit: BoxFit.contain)
                        : const Center(child: Icon(Icons.image_outlined,
                            size: 36, color: Colors.grey)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _pickLogo,
                        icon: const Icon(Icons.upload_outlined, size: 18),
                        label: const Text('Upload Logo'),
                      ),
                      if (_logoPath != null && _logoPath!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        TextButton.icon(
                          onPressed: _removeLogo,
                          icon: const Icon(Icons.delete_outline,
                              size: 16, color: Colors.red),
                          label: const Text('Remove',
                              style: TextStyle(color: Colors.red)),
                        ),
                      ],
                      const SizedBox(height: 4),
                      const Text('Appears on all generated PDFs',
                          style: TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  )),
                ]),
              )),


              const SizedBox(height: 24),

              // ── Company Info section ────────────────────────────────
              const Text('Company Info',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('This information appears on every invoice. Leave blank to omit a line.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const SizedBox(height: 12),
              _coField(_coNameCtl,  'Company Name',   Icons.business_outlined),
              const SizedBox(height: 10),
              _coField(_coAddrCtl,  'Street Address', Icons.location_on_outlined),
              const SizedBox(height: 10),
              _coField(_coCityCtl,  'City, State ZIP', Icons.map_outlined),
              const SizedBox(height: 10),
              _coField(_coPhoneCtl, 'Phone Number',   Icons.phone_outlined,
                  keyboard: TextInputType.phone),
              const SizedBox(height: 10),
              _coField(_coEmailCtl, 'Email',          Icons.email_outlined,
                  keyboard: TextInputType.emailAddress),
              const SizedBox(height: 10),
              _coField(_coArdCtl,   'ARD Number',     Icons.badge_outlined),
              const SizedBox(height: 10),
              TextField(
                controller: _noticeCtl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Invoice Notice',
                  hintText: 'Text printed at the bottom of every invoice…',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  prefixIcon: Icon(Icons.info_outline, size: 18),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 4),
              Text('Use {business_name} where your company name should appear.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              const SizedBox(height: 16),

              // ── Card Surcharge ─────────────────────────────────
              Row(
                children: [
                  const Icon(Icons.credit_card_outlined, size: 18,
                      color: Colors.grey),
                  const SizedBox(width: 8),
                  const Text('Credit Card Surcharge',
                      style: TextStyle(fontWeight: FontWeight.w500)),
                ],
              ),
              const SizedBox(height: 8),
              // Toggle: Percent / Fixed
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _surchargeIsPercent = true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _surchargeIsPercent
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: Text('Percentage (%)',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _surchargeIsPercent
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                            )),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _surchargeIsPercent = false),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: !_surchargeIsPercent
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: Text('Fixed Amount (\$)',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: !_surchargeIsPercent
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                            )),
                      ),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _cardSurchargeCtl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: _surchargeIsPercent
                      ? 'Surcharge Percentage'
                      : 'Surcharge Amount',
                  hintText: _surchargeIsPercent ? 'e.g. 3.0' : 'e.g. 2.50',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  prefixText: _surchargeIsPercent ? '' : '\$ ',
                  suffixText: _surchargeIsPercent ? '%' : '',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Auto-added as a line item when CARD is selected at finalize. '
                'Set to 0 or leave blank to disable.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 14),
              SizedBox(width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _coInfoSaving ? null : _saveCompanyInfo,
                  icon: _coInfoSaving
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_outlined, size: 18),
                  label: Text(_coInfoSaving ? 'Saving...' : 'Save Company Info'),
                ),
              ),

              // ── Force Re-Sync ──────────────────────────────────────
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _forceResync,
                icon: const Icon(Icons.sync_problem_outlined, color: Colors.orange),
                label: const Text('Force Re-Sync From Server',
                    style: TextStyle(color: Colors.orange)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.orange),
                  minimumSize: const Size(double.infinity, 44),
                ),
              ),
              const SizedBox(height: 4),
              Text('Use if payments or invoices are missing on this device.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),

              const SizedBox(height: 16),
              // ── Manage Subscription ────────────────────────────────
              ElevatedButton.icon(
                onPressed: _manageSubscription,
                icon: const Icon(Icons.credit_card_outlined, size: 18),
                label: const Text('Manage Subscription'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0D9488),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 44),
                ),
              ),
              const SizedBox(height: 4),
              Text('Update payment method, cancel, or view billing history.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),

              const SizedBox(height: 24),
              // ── Services section ───────────────────────────────────
              Row(children: [
                const Text('Services',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => _showServiceDialog(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ]),
              const SizedBox(height: 4),
              const Text(
                'Services appear as a dropdown when adding lines to an invoice. '
                'The service type (e.g. Opacity, OBDII) can also be set on each vehicle '
                'so it pre-selects automatically.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 10),

              if (_services.isEmpty)
                Card(child: Padding(padding: const EdgeInsets.all(20),
                  child: Column(children: [
                    Icon(Icons.build_outlined,
                        size: 40, color: Colors.grey.shade400),
                    const SizedBox(height: 8),
                    const Text('No services yet',
                        style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 4),
                    const Text('Tap Add to create your first service',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ]),
                ))
              else
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _services.length,
                  onReorder: (oldIdx, newIdx) async {
                    if (newIdx > oldIdx) newIdx--;
                    final list = List<Map<String, dynamic>>.from(_services);
                    final item = list.removeAt(oldIdx);
                    list.insert(newIdx, item);
                    for (int i = 0; i < list.length; i++) {
                      await db.upsertService(
                        serviceId: list[i]['service_id'].toString(),
                        name: (list[i]['name'] ?? '').toString(),
                        serviceType: (list[i]['service_type'] ?? '').toString().isEmpty
                            ? null : list[i]['service_type'].toString(),
                        defaultPriceCents:
                            (list[i]['default_price_cents'] as int?) ?? 0,
                        sortOrder: i,
                      );
                    }
                    await _load();
                  },
                  itemBuilder: (ctx, i) {
                    final s    = _services[i];
                    final sid  = s['service_id'].toString();
                    final name = (s['name'] ?? '').toString();
                    final type = (s['service_type'] ?? '').toString();
                    final cents = (s['default_price_cents'] as int?) ?? 0;
                    final price = '\$${(cents / 100).toStringAsFixed(2)}';

                    return Card(
                      key: ValueKey(sid),
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        leading: const Icon(Icons.build_outlined),
                        title: Text(name,
                            style: const TextStyle(fontWeight: FontWeight.w500)),
                        subtitle: Text([
                          if (type.isNotEmpty) type,
                          'Default: $price',
                        ].join('  •  ')),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () => _showServiceDialog(existing: s),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                size: 20, color: Colors.red),
                            onPressed: () => _deleteService(sid, name),
                          ),
                          const Icon(Icons.drag_handle,
                              color: Colors.grey, size: 20),
                        ]),
                      ),
                    );
                  },
                ),
            ]),
    );
  }
}
