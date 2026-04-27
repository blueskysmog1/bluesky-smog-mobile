import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'account_page.dart';
import 'api_service.dart';
import 'login_page.dart';
import 'local_db.dart';
import 'customer_form_page.dart';
import 'customer_detail_page.dart';
import 'settings_page.dart';
import 'vehicles_due_page.dart';

const String _appVersion = '1.2.8';
const String _updateApiUrl =
    'https://api.github.com/repos/blueskysmog1/bluesky-smog-mobile/releases/latest';
const String _downloadUrl =
    'https://github.com/blueskysmog1/bluesky-smog-mobile/releases/latest/download/app-release.apk';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const BlueSkyApp());
}

// Singleton ApiService shared across the app
final _api = ApiService();


class BlueSkyApp extends StatelessWidget {
  const BlueSkyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blue Sky Smog',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();
  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _checking = true;
  bool _loggedIn  = false;

  @override
  void initState() {
    super.initState();
    _checkSession();
    // Check for app update 4 seconds after launch
    Future.delayed(const Duration(seconds: 4), _checkForUpdate);
  }

  Future<void> _checkForUpdate() async {
    try {
      final res = await http.get(
        Uri.parse(_updateApiUrl),
        headers: {'User-Agent': 'BlueSkyMobile'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String? ?? '').replaceAll(RegExp(r'[^0-9.]'), '');
      if (tag.isEmpty) return;

      List<int> parseVer(String v) =>
          v.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final latest  = parseVer(tag);
      final current = parseVer(_appVersion);
      bool isNewer = false;
      for (int i = 0; i < latest.length && i < current.length; i++) {
        if (latest[i] > current[i]) { isNewer = true; break; }
        if (latest[i] < current[i]) break;
      }
      if (!isNewer || !mounted) return;

      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Update Available'),
          content: Text(
            'Blue Sky Smog v$tag is available.\n'
            'You are running v$_appVersion.\n\n'
            'Download the new version to stay up to date.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Later'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                launchUrl(Uri.parse(_downloadUrl),
                    mode: LaunchMode.externalApplication);
              },
              child: const Text('Download'),
            ),
          ],
        ),
      );
    } catch (_) {
      // Silently ignore network errors
    }
  }

  Future<void> _checkSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token') ?? '';

    // Try token refresh first (silent persistent login).
    // Do NOT wipe local data here — only wipe on explicit login/logout.
    if (token.isNotEmpty) {
      try {
        final res = await _api.refreshToken(token);
        _api.setToken(token);
        await prefs.setString('company_id',   res['company_id']   ?? '');
        await prefs.setString('company_name', res['company_name'] ?? '');
        setState(() { _loggedIn = true; _checking = false; });
        return;
      } catch (_) {
        // Token expired — fall through to login screen
        await prefs.remove('auth_token');
      }
    }

    // Fall back to username/password if stored (legacy or first install)
    final username = prefs.getString('username') ?? '';
    final password = prefs.getString('password') ?? '';
    if (username.isNotEmpty && password.isNotEmpty) {
      try {
        final res = await _api.login(username, password);
        final newToken = res['token'] ?? '';
        _api.setCredentials(username, password, token: newToken);
        await prefs.setString('auth_token',   newToken);
        await prefs.setString('company_id',   res['company_id']   ?? '');
        await prefs.setString('company_name', res['company_name'] ?? '');
        setState(() { _loggedIn = true; _checking = false; });
        return;
      } catch (_) {
        // Credentials no longer valid
      }
    }

    setState(() { _checking = false; _loggedIn = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }
    if (!_loggedIn) {
      return LoginPage(
        api: _api,
        onLoggedIn: () => setState(() => _loggedIn = true),
      );
    }
    return CustomersPage(autoSync: true, api: _api,
          onLogout: () => setState(() => _loggedIn = false));
  }
}

class CustomersPage extends StatefulWidget {
  final bool autoSync;
  final ApiService? api;
  final VoidCallback? onLogout;
  const CustomersPage({super.key, required this.autoSync, this.api, this.onLogout});

  @override
  State<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<CustomersPage> {
  final db  = LocalDb.instance;
  ApiService get api => widget.api ?? _api;
  Timer? _timer;
  final _scrollCtl = ScrollController();

  String _deviceId = 'UNKNOWN';
  int    _sinceSeq = 0;
  bool   _syncing  = false;
  String? _lastSyncMsg;

  List<Map<String, dynamic>> _customers = [];
  String _search = '';
  Map<String, dynamic> _subStatus = {};
  String _subWarning = '';
  bool   _subLocked  = false;

  @override
  void initState() { super.initState(); _init(); }

  @override
  void dispose() { _timer?.cancel(); _scrollCtl.dispose(); super.dispose(); }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString('device_id');
    deviceId ??= 'PHONE-${const Uuid().v4().substring(0, 8).toUpperCase()}';
    await prefs.setString('device_id', deviceId);
    final sinceSeq = prefs.getInt('since_seq') ?? 0;
    setState(() { _deviceId = deviceId!; _sinceSeq = sinceSeq; });
    await _refreshCustomers();
    await _checkSubStatus();
    if (widget.autoSync) {
      _timer?.cancel();
      // Sync immediately on startup, then continue on 8-second interval
      _syncNow(showSnack: false);
      _timer = Timer.periodic(const Duration(seconds: 8), (_) => _syncNow(showSnack: false));
    }
  }

  Future<void> _checkSubStatus() async {
    try {
      final status = await api.subscriptionStatus();
      if (!mounted || status.isEmpty) return;
      final warning = (status['warning'] ?? '').toString();
      final locked  = status['can_create'] == false;
      setState(() {
        _subStatus  = status;
        _subWarning = warning;
        _subLocked  = locked;
      });
    } catch (_) {}
  }

  Future<void> _refreshCustomers() async {
    final rows = await db.listCustomers();
    if (!mounted) return;
    setState(() => _customers = rows);
  }

  List<Map<String, dynamic>> get _filtered {
    if (_search.isEmpty) return _customers;
    final q = _search.toLowerCase();
    return _customers.where((c) =>
        (c['first_name']   ?? '').toString().toLowerCase().contains(q) ||
        (c['last_name']    ?? '').toString().toLowerCase().contains(q) ||
        (c['company_name'] ?? '').toString().toLowerCase().contains(q) ||
        (c['name']         ?? '').toString().toLowerCase().contains(q) ||
        (c['phone']        ?? '').toString().toLowerCase().contains(q)).toList();
  }

  Future<void> _syncNow({bool showSnack = true}) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    int pushed = 0, pulled = 0;
    try {
      // Push outbox
      final pending = await db.getPendingOutbox(_deviceId);
      if (pending.isNotEmpty) {
        final events = pending.map((r) => {
          'event_id': r['event_id'], 'seq': r['seq'],
          'entity': r['entity'],    'action': r['action'],
          'payload': Map<String, dynamic>.from(
            (r['payload_json'] as String).isEmpty
                ? {} : jsonDecode(r['payload_json'] as String) as Map),
        }).toList();
        final maxSeq = pending.map((e) => (e['seq'] as num).toInt()).reduce((a, b) => a > b ? a : b);
        await api.push(deviceId: _deviceId, events: events);
        await db.markOutboxSent(_deviceId, maxSeq);
        pushed = events.length;
      }
      // Pull
      final pullRes = await api.pull(deviceId: _deviceId, sinceSeq: _sinceSeq);
      final events  = (pullRes['events'] as List?) ?? [];
      final newMax  = await db.applyRemoteEvents(deviceId: _deviceId, events: events);
      pulled = events.length;

      // Only advance since_seq — never regress to 0 on an empty pull
      if (newMax > _sinceSeq) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('since_seq', newMax);
        _sinceSeq = newMax;
      }

      await _refreshCustomers();
      final msg = 'Sync ok — pushed $pushed, pulled $pulled';
      setState(() => _lastSyncMsg = msg);
      if (showSnack && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
      }
    } catch (e) {
      final msg = 'Sync failed: $e';
      setState(() => _lastSyncMsg = msg);
      if (showSnack && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _forceResyncNow() async {
    // Reset seq in state (prefs already reset by settings page before calling this)
    setState(() { _sinceSeq = 0; });
    await _syncNow(showSnack: true);
  }

  Future<void> _newCustomer() async {
    if (_subLocked) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Subscription Required'),
          content: Text(_subWarning.isNotEmpty
              ? _subWarning
              : 'Your free trial has ended. Please subscribe to create new customers and invoices.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context),
                child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    final result = await Navigator.of(context).push<dynamic>(MaterialPageRoute(
      builder: (_) => CustomerFormPage(deviceId: _deviceId),
    ));
    if (result != null) {
      await _syncNow(showSnack: false);
      await _refreshCustomers();
      // If result is a new customer ID, open their detail page
      if (result is String && mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CustomerDetailPage(
            customerId:   result,
            deviceId:     _deviceId,
            scheduleSync: () => _syncNow(showSnack: false),
          ),
        ));
        await _refreshCustomers();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Blue Sky Smog'),
        actions: [
          IconButton(
            icon: _syncing
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            tooltip: 'Sync',
            onPressed: _syncing ? null : () => _syncNow(showSnack: true),
          ),
          IconButton(
            icon: const Icon(Icons.event_outlined),
            tooltip: 'Vehicles Due',
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => VehiclesDuePage(
                    deviceId: _deviceId))),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => SettingsPage(
                    onLogout: widget.onLogout,
                    onForceResync: _forceResyncNow,
                  ))),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newCustomer,
        icon: const Icon(Icons.person_add_outlined),
        label: const Text('New Customer'),
      ),
      body: Column(children: [
        // Subscription warning banner
        if (_subWarning.isNotEmpty)
          Material(
            color: _subLocked ? Colors.red.shade800 : Colors.orange.shade800,
            child: InkWell(
              onTap: () => showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Subscription Status'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_subWarning),
                      const SizedBox(height: 12),
                      Text('Invoices used: ${_subStatus['invoice_count'] ?? '—'}',
                          style: const TextStyle(fontSize: 13)),
                      if ((_subStatus['grace_days_remaining'] as int? ?? 0) > 0)
                        Text('Grace days remaining: ${_subStatus['grace_days_remaining']}',
                            style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context),
                        child: const Text('OK')),
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Icon(_subLocked ? Icons.lock_outlined : Icons.warning_amber_rounded,
                      color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_subWarning,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      maxLines: 2)),
                  const Icon(Icons.info_outline, color: Colors.white70, size: 16),
                ]),
              ),
            ),
          ),

        // Device + sync status bar
        Container(
          color: Theme.of(context).colorScheme.surfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          child: Row(children: [
            const Icon(Icons.phone_android, size: 13),
            const SizedBox(width: 4),
            Expanded(child: Text(_deviceId, style: const TextStyle(fontSize: 11),
                overflow: TextOverflow.ellipsis)),
            if (_lastSyncMsg != null)
              Text(_lastSyncMsg!,
                  style: TextStyle(fontSize: 11,
                      color: (_lastSyncMsg!.contains('failed'))
                          ? Colors.red : Colors.green.shade700)),
          ]),
        ),

        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search customers…',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),

        // Customer list
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Text(_customers.isEmpty
                  ? 'No customers yet. Tap + to add one.'
                  : 'No results for "$_search"'))
              : Scrollbar(
                  controller: _scrollCtl,
                  thumbVisibility: true,
                  thickness: 4,
                  radius: const Radius.circular(4),
                  child: ListView.separated(
                  controller: _scrollCtl,
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c       = filtered[i];
                    final first   = (c['first_name']   ?? '').toString();
                    final last    = (c['last_name']    ?? '').toString();
                    final company = (c['company_name'] ?? '').toString();
                    final phone   = (c['phone']        ?? '').toString();
                    final fullName = [first, last].where((s) => s.isNotEmpty).join(' ');
                    final display  = fullName.isNotEmpty ? fullName : company;
                    final avatarLetter = display.isNotEmpty ? display[0].toUpperCase() : '?';
                    return ListTile(
                      leading: CircleAvatar(child: Text(avatarLetter)),
                      title: Text(display.isNotEmpty ? display : company,
                          style: const TextStyle(fontWeight: FontWeight.w500)),
                      subtitle: Text([
                        if (company.isNotEmpty && fullName.isNotEmpty) company,
                        if (phone.isNotEmpty) phone,
                      ].join('  •  ')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => CustomerDetailPage(
                            customerId:   (c['customer_id']).toString(),
                            deviceId:     _deviceId,
                            scheduleSync: () => _syncNow(showSnack: false),
                          ),
                        ));
                        await _refreshCustomers();
                      },
                    );
                  },
                )),
        ),
      ]),
    );
  }
}
