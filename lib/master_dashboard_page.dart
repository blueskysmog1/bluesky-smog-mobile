import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'api_service.dart';

// ── Shared Dio instance for master calls ──────────────────────────────
final _masterDio = Dio(BaseOptions(
  baseUrl: 'https://api.blueskysmog.net',
  connectTimeout: const Duration(seconds: 15),
  receiveTimeout: const Duration(seconds: 15),
));
const _masterHeaders = {
  'x-username': 'bluesky_master',
  'x-password': 'BlueSky2026!Admin',
};

// ── Master Dashboard ──────────────────────────────────────────────────
class MasterDashboardPage extends StatefulWidget {
  const MasterDashboardPage({super.key});
  @override
  State<MasterDashboardPage> createState() => _MasterDashboardPageState();
}

class _MasterDashboardPageState extends State<MasterDashboardPage> {
  static const _pass = 'BlueSky2026!Admin';
  final _api     = ApiService();
  final _passCtl = TextEditingController();

  bool   _authed  = false;
  bool   _loading = false;
  String? _error;

  List<Map<String, dynamic>> _companies = [];
  List<String> _exemptUsernames = [];
  int _totalInvoices = 0;

  @override
  void dispose() { _passCtl.dispose(); super.dispose(); }

  Future<void> _login() async {
    if (_passCtl.text.trim() != _pass) {
      setState(() => _error = 'Incorrect master password');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await _load();
      setState(() => _authed = true);
    } catch (e) {
      setState(() => _error = 'Error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _fetchCompanies(),
      _api.masterExemptList().catchError((_) => <Map<String, dynamic>>[]),
    ]);

    final companiesRes = results[0] as List<Map<String, dynamic>>;
    final exemptList   = results[1] as List<Map<String, dynamic>>;
    final exemptNames  = exemptList.map((e) => e['username'].toString()).toList();

    int total = 0;
    for (final c in companiesRes) total += (c['invoice_count'] as int? ?? 0);

    if (mounted) setState(() {
      _companies       = companiesRes;
      _exemptUsernames = exemptNames;
      _totalInvoices   = total;
    });
  }

  Future<List<Map<String, dynamic>>> _fetchCompanies() async {
    final res = await _masterDio.get(
      '/v1/master/companies',
      options: Options(headers: _masterHeaders),
    );
    return List<Map<String, dynamic>>.from(
        ((res.data['companies'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Master Dashboard'),
      backgroundColor: Colors.grey.shade900,
      foregroundColor: Colors.white,
      actions: _authed ? [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
      ] : null,
    ),
    backgroundColor: Colors.grey.shade100,
    body: _authed ? _dashboard() : _loginPrompt(),
  );

  Widget _loginPrompt() => Center(
    child: Card(
      margin: const EdgeInsets.all(32),
      child: Padding(padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.admin_panel_settings_outlined, size: 48, color: Colors.blueGrey),
          const SizedBox(height: 12),
          const Text('Master Access',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          TextField(
            controller: _passCtl, obscureText: true,
            decoration: const InputDecoration(
                labelText: 'Master Password',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline)),
            onSubmitted: (_) => _login(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: FilledButton(
            onPressed: _loading ? null : _login,
            style: FilledButton.styleFrom(backgroundColor: Colors.grey.shade800),
            child: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Enter'),
          )),
        ]),
      ),
    ),
  );

  Widget _dashboard() => RefreshIndicator(
    onRefresh: _load,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Summary cards ─────────────────────────────────────────
        Row(children: [
          _summaryCard('Companies', '${_companies.length}',
              Icons.business_outlined, Colors.blue),
          const SizedBox(width: 12),
          _summaryCard('Total Invoices', '$_totalInvoices',
              Icons.receipt_long_outlined, Colors.green),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          _summaryCard('Exempt Accounts', '${_exemptUsernames.length}',
              Icons.star_outline, Colors.amber.shade700),
          const SizedBox(width: 12),
          _summaryCard('Suspended',
              '${_companies.where((c) => c['is_suspended'] == true || c['is_suspended'] == 1).length}',
              Icons.block_outlined, Colors.red),
        ]),

        const SizedBox(height: 20),

        // ── Exemptions quick panel ─────────────────────────────────
        Card(
          child: Padding(padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.star, color: Colors.amber, size: 18),
                const SizedBox(width: 6),
                const Expanded(child: Text('Subscription Exemptions',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                TextButton.icon(
                  onPressed: _addExemptDialog,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add', style: TextStyle(fontSize: 12)),
                ),
              ]),
              const Divider(height: 12),
              if (_exemptUsernames.isEmpty)
                const Text('No exempt accounts', style: TextStyle(color: Colors.grey, fontSize: 12))
              else
                Wrap(
                  spacing: 6, runSpacing: 4,
                  children: _exemptUsernames.map((u) => Chip(
                    label: Text('@$u', style: const TextStyle(fontSize: 11)),
                    backgroundColor: Colors.amber.shade50,
                    side: BorderSide(color: Colors.amber.shade300),
                    deleteIcon: const Icon(Icons.close, size: 14),
                    onDeleted: u == 'bluesky_master' ? null : () => _removeExempt(u),
                  )).toList(),
                ),
            ]),
          ),
        ),

        const SizedBox(height: 16),

        // ── Company list ───────────────────────────────────────────
        Text('Companies', style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),

        if (_companies.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(32),
              child: Text('No companies registered yet')))
        else
          ..._companies.asMap().entries.map((entry) {
            final i      = entry.key;
            final c      = entry.value;
            final name   = (c['company_name'] ?? '').toString();
            final uname  = (c['username']     ?? '').toString();
            final count  = c['invoice_count'] as int? ?? 0;
            final pct    = _totalInvoices > 0 ? count / _totalInvoices : 0.0;
            final susp   = c['is_suspended'] == true || c['is_suspended'] == 1;
            final exempt = _exemptUsernames.contains(uname);

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              color: susp ? Colors.red.shade50 : null,
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: susp ? Colors.red.shade300
                      : i == 0 ? Colors.amber
                      : i == 1 ? Colors.grey.shade400
                      : Colors.brown.shade300,
                  child: Text('${i + 1}',
                      style: const TextStyle(color: Colors.white,
                          fontWeight: FontWeight.bold, fontSize: 12)),
                ),
                title: Row(children: [
                  Expanded(child: Text(name.isNotEmpty ? name : uname,
                      style: const TextStyle(fontWeight: FontWeight.w600))),
                  if (exempt) const Tooltip(
                    message: 'Exempt from billing',
                    child: Icon(Icons.star, size: 14, color: Colors.amber)),
                  if (susp) const SizedBox(width: 4),
                  if (susp) const Tooltip(
                    message: 'Suspended',
                    child: Icon(Icons.block, size: 14, color: Colors.red)),
                ]),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('@$uname  •  $count invoice${count == 1 ? '' : 's'}',
                        style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: pct, minHeight: 5,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation(
                            susp ? Colors.red
                                : i == 0 ? Colors.blue
                                : i == 1 ? Colors.green : Colors.orange),
                      ),
                    ),
                  ],
                ),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CompanyDetailPage(
                      company: c,
                      api: _api,
                      isExempt: exempt,
                      onChanged: _load,
                    ),
                  ));
                  await _load();
                },
              ),
            );
          }),
      ],
    ),
  );

  Future<void> _addExemptDialog() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add Exempt Account'),
        content: TextField(
          controller: ctl, autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Username', border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline)),
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || ctl.text.trim().isEmpty || !mounted) return;
    try {
      await _api.masterExemptAdd(ctl.text.trim().toLowerCase());
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('@${ctl.text.trim()} added to exemptions')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _removeExempt(String username) async {
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Exemption?'),
        content: Text('Remove @$username from billing exemptions?\n\nThey will go back to normal trial/subscription rules.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.masterExemptRemove(username);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
    }
  }

  Widget _summaryCard(String label, String value, IconData icon, Color color) =>
      Expanded(child: Card(
        child: Padding(padding: const EdgeInsets.all(14),
          child: Column(children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 24,
                fontWeight: FontWeight.bold, color: color)),
            Text(label, style: TextStyle(fontSize: 11,
                color: Colors.grey.shade600), textAlign: TextAlign.center),
          ]),
        ),
      ));
}


// ── Company Detail Page ───────────────────────────────────────────────
class CompanyDetailPage extends StatefulWidget {
  final Map<String, dynamic> company;
  final ApiService api;
  final bool isExempt;
  final Future<void> Function() onChanged;

  const CompanyDetailPage({super.key,
      required this.company,
      required this.api,
      required this.isExempt,
      required this.onChanged});

  @override
  State<CompanyDetailPage> createState() => _CompanyDetailPageState();
}

class _CompanyDetailPageState extends State<CompanyDetailPage> {
  List<Map<String, dynamic>> _monthly = [];
  Map<String, dynamic> _subStatus = {};
  bool _loadingMonthly = true;
  bool _loadingSubStatus = true;
  String? _monthlyError;
  late bool _isExempt;
  late bool _isSuspended;
  late String _adminNotes;
  final _notesCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _isExempt    = widget.isExempt;
    _isSuspended = widget.company['is_suspended'] == true ||
                   widget.company['is_suspended'] == 1;
    _adminNotes  = (widget.company['admin_notes'] ?? '').toString();
    _notesCtl.text = _adminNotes;
    _loadMonthly();
    _loadSubStatus();
  }

  @override
  void dispose() { _notesCtl.dispose(); super.dispose(); }

  String get _username => (widget.company['username'] ?? '').toString();
  String get _companyName => (widget.company['company_name'] ?? _username).toString();

  Future<void> _loadMonthly() async {
    try {
      final res = await _masterDio.get(
        '/v1/master/company/$_username/monthly',
        options: Options(headers: _masterHeaders),
      );
      final list = List<Map<String, dynamic>>.from(
          ((res.data['monthly'] as List?) ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map)));
      if (mounted) setState(() { _monthly = list; _loadingMonthly = false; });
    } catch (e) {
      if (mounted) setState(() { _loadingMonthly = false; });
    }
  }

  Future<void> _loadSubStatus() async {
    try {
      final s = await widget.api.masterGetSubscription(_username);
      if (mounted) setState(() { _subStatus = s; _loadingSubStatus = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingSubStatus = false);
    }
  }

  Future<void> _toggleExempt() async {
    try {
      if (_isExempt) {
        final ok = await showDialog<bool>(context: context,
          builder: (_) => AlertDialog(
            title: const Text('Remove Exemption?'),
            content: Text('Remove billing exemption for @$_username?\nThey will go back to normal trial/subscription rules.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(backgroundColor: Colors.orange),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await widget.api.masterExemptRemove(_username);
      } else {
        await widget.api.masterExemptAdd(_username);
      }
      setState(() => _isExempt = !_isExempt);
      await widget.onChanged();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_isExempt
              ? '@$_username is now exempt from billing'
              : '@$_username billing exemption removed')));
      await _loadSubStatus();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _toggleSuspend() async {
    final verb = _isSuspended ? 'Unsuspend' : 'Suspend';
    final ok   = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: Text('$verb Account?'),
        content: Text(_isSuspended
            ? 'Restore access for @$_username?'
            : 'Block all access for @$_username immediately?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
                backgroundColor: _isSuspended ? Colors.green : Colors.red),
            child: Text(verb),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      if (_isSuspended) {
        await widget.api.masterUnsuspend(_username);
      } else {
        await widget.api.masterSuspend(_username);
      }
      setState(() => _isSuspended = !_isSuspended);
      await widget.onChanged();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('@$_username ${_isSuspended ? 'suspended' : 'unsuspended'}')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _saveNotes() async {
    try {
      await widget.api.masterUpdateNotes(_username, _notesCtl.text.trim());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notes saved')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _resetPassword() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: Text('Reset Password — @$_username'),
        content: TextField(
          controller: ctl, obscureText: true, autofocus: true,
          decoration: const InputDecoration(
              labelText: 'New Password', border: OutlineInputBorder()),
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (ctl.text.trim().length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password must be at least 6 characters')));
      return;
    }
    try {
      await _masterDio.post(
        '/v1/master/reset_password',
        data: {'username': _username, 'new_password': ctl.text.trim()},
        options: Options(headers: _masterHeaders),
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Password reset for @$_username')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _setSubscriptionPlan(String plan) async {
    try {
      await widget.api.masterSetSubscription(_username, plan);
      await _loadSubStatus();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Subscription set to "$plan" for @$_username')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _viewInvoices() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CompanyInvoicesPage(username: _username, api: widget.api),
    ));
  }

  Future<void> _deleteCompany() async {
    final confirm = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Company?'),
        content: Text(
            'Permanently delete "$_companyName" (@$_username) and ALL their '
            'invoices, data, and PDFs.\n\nThis cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete Forever'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await _masterDio.delete(
        '/v1/master/company/$_username',
        options: Options(headers: _masterHeaders),
      );
      await widget.onChanged();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final count   = widget.company['invoice_count'] as int? ?? 0;
    final created = (widget.company['created_at'] ?? '').toString();
    final dateStr = created.length >= 10 ? created.substring(0, 10) : created;

    final now          = DateTime.now();
    final currentMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    int totalAllTime = 0, curMonthInv = 0, curMonthCents = 0;
    for (final m in _monthly) {
      totalAllTime += (m['total_cents'] as int? ?? 0);
      if ((m['month'] ?? '') == currentMonth) {
        curMonthInv   = m['invoice_count'] as int? ?? 0;
        curMonthCents = m['total_cents']   as int? ?? 0;
      }
    }
    final perInv    = curMonthInv * 0.15;
    final amountDue = perInv < 40.0 ? 40.0 : perInv;

    final subPlan     = (_subStatus['plan']   ?? '—').toString();
    final subStatus   = (_subStatus['status'] ?? '—').toString();
    final canCreate   = _subStatus['can_create'] != false;
    final trialLeft   = _subStatus['trial_remaining'] as int? ?? 0;
    final graceDays   = _subStatus['grace_days_remaining'] as int? ?? 0;
    final subWarning  = (_subStatus['warning'] ?? '').toString();

    Color subColor = Colors.green;
    if (subStatus == 'locked') subColor = Colors.red;
    else if (subStatus == 'grace') subColor = Colors.orange;
    else if (subStatus == 'trial') subColor = Colors.blue;

    return Scaffold(
      appBar: AppBar(
        title: Text(_companyName),
        backgroundColor: Colors.grey.shade900,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long_outlined),
            tooltip: 'View Invoices',
            onPressed: _viewInvoices,
          ),
          IconButton(
            icon: const Icon(Icons.lock_reset_outlined),
            tooltip: 'Reset Password',
            onPressed: _resetPassword,
          ),
        ],
      ),
      backgroundColor: Colors.grey.shade100,
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [

          // ── Account Info ──────────────────────────────────────────
          Card(child: Padding(padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Account Info',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Divider(height: 14),
              _infoRow(Icons.person_outline,           'Username',   '@$_username'),
              _infoRow(Icons.business_outlined,        'Company',    _companyName),
              _infoRow(Icons.calendar_today_outlined,  'Member Since', dateStr),
              _infoRow(Icons.receipt_long_outlined,    'Total Invoices', '$count'),
              _infoRow(
                _isSuspended ? Icons.block : Icons.check_circle_outline,
                'Status',
                _isSuspended ? '🔴 SUSPENDED' : '🟢 Active',
              ),
              _infoRow(
                _isExempt ? Icons.star : Icons.credit_card_outlined,
                'Billing',
                _isExempt ? '⭐ Exempt — No Billing' : '💳 Trial / Subscription',
              ),
            ]),
          )),

          const SizedBox(height: 10),

          // ── Subscription Status ────────────────────────────────────
          Card(child: Padding(padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Subscription Status',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Divider(height: 14),
              if (_loadingSubStatus)
                const Center(child: Padding(padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator()))
              else ...[
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: subColor.withOpacity(0.12),
                      border: Border.all(color: subColor.withOpacity(0.4)),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(subStatus.toUpperCase(),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                            color: subColor)),
                  ),
                  const SizedBox(width: 8),
                  Text('Plan: $subPlan', style: const TextStyle(fontSize: 12)),
                  const Spacer(),
                  Icon(canCreate ? Icons.check_circle : Icons.lock,
                      size: 16,
                      color: canCreate ? Colors.green : Colors.red),
                  const SizedBox(width: 4),
                  Text(canCreate ? 'Can create' : 'Read-only',
                      style: TextStyle(fontSize: 11,
                          color: canCreate ? Colors.green : Colors.red)),
                ]),
                if (trialLeft > 0) ...[
                  const SizedBox(height: 6),
                  Text('Trial invoices remaining: $trialLeft',
                      style: const TextStyle(fontSize: 12, color: Colors.blue)),
                ],
                if (graceDays > 0) ...[
                  const SizedBox(height: 6),
                  Text('Grace period: $graceDays day(s) left',
                      style: const TextStyle(fontSize: 12, color: Colors.orange)),
                ],
                if (subWarning.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(subWarning,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ],
                const SizedBox(height: 12),
                const Text('Override Plan:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final plan in ['trial', 'grace', 'locked', 'monthly', 'per_invoice'])
                    ChoiceChip(
                      label: Text(plan, style: const TextStyle(fontSize: 11)),
                      selected: subPlan == plan || subStatus == plan,
                      onSelected: (_) => _setSubscriptionPlan(plan),
                      selectedColor: subColor.withOpacity(0.2),
                    ),
                ]),
              ],
            ]),
          )),

          const SizedBox(height: 10),

          // ── Admin Notes ────────────────────────────────────────────
          Card(child: Padding(padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Admin Notes',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Divider(height: 14),
              TextField(
                controller: _notesCtl,
                maxLines: 3,
                decoration: const InputDecoration(
                    hintText: 'Internal notes about this account…',
                    border: OutlineInputBorder(), isDense: true),
              ),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _saveNotes,
                  child: const Text('Save Notes'),
                )),
            ]),
          )),

          const SizedBox(height: 10),

          // ── Billing Summary ────────────────────────────────────────
          Card(child: Padding(padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Billing Summary',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Divider(height: 14),
              Row(children: [
                Expanded(child: _billingBox('This Month',
                    '$curMonthInv invoices',
                    '\$${(curMonthCents / 100).toStringAsFixed(2)}',
                    Colors.blue)),
                const SizedBox(width: 10),
                Expanded(child: _billingBox('All Time',
                    '$count invoices',
                    '\$${(totalAllTime / 100).toStringAsFixed(2)}',
                    Colors.green)),
              ]),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  border: Border.all(color: Colors.orange.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Row(children: [
                    Icon(Icons.attach_money, color: Colors.orange, size: 18),
                    SizedBox(width: 6),
                    Text('Amount Due This Month',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ]),
                  const SizedBox(height: 8),
                  Text('\$${amountDue.toStringAsFixed(2)}',
                      style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold,
                          color: Colors.orange.shade800)),
                  const SizedBox(height: 4),
                  Text(
                    perInv < 40.0
                        ? 'Flat rate — $curMonthInv × \$0.15 = \$${perInv.toStringAsFixed(2)} (min \$40.00)'
                        : '$curMonthInv invoices × \$0.15/invoice',
                    style: TextStyle(fontSize: 11, color: Colors.orange.shade700),
                  ),
                ]),
              ),
            ]),
          )),

          const SizedBox(height: 10),

          // ── Monthly breakdown ──────────────────────────────────────
          Card(child: Padding(padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Monthly Breakdown',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Divider(height: 14),
              if (_loadingMonthly)
                const Center(child: Padding(padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator()))
              else if (_monthly.isEmpty)
                const Text('No invoices yet', style: TextStyle(color: Colors.grey))
              else
                Table(
                  columnWidths: const {
                    0: FlexColumnWidth(2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(2),
                  },
                  children: [
                    TableRow(
                      decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: Colors.grey.shade300))),
                      children: [_tableHeader('Month'), _tableHeader('Invoices'),
                        _tableHeader('Revenue')],
                    ),
                    ..._monthly.map((m) {
                      final month  = (m['month'] ?? '').toString();
                      final inv    = m['invoice_count'] as int? ?? 0;
                      final cents  = m['total_cents']   as int? ?? 0;
                      final isCur  = month == currentMonth;
                      return TableRow(
                        decoration: isCur
                            ? BoxDecoration(color: Colors.blue.shade50) : null,
                        children: [
                          _tableCell(month, bold: isCur),
                          _tableCell('$inv',  bold: isCur),
                          _tableCell('\$${(cents / 100).toStringAsFixed(2)}', bold: isCur),
                        ],
                      );
                    }),
                  ],
                ),
            ]),
          )),

          const SizedBox(height: 16),

          // ── Action buttons ─────────────────────────────────────────
          Row(children: [
            Expanded(child: FilledButton.icon(
              onPressed: _toggleExempt,
              icon: Icon(_isExempt ? Icons.star_border : Icons.star),
              label: Text(_isExempt ? 'Remove Exemption' : 'Set as Exempt'),
              style: FilledButton.styleFrom(
                  backgroundColor: _isExempt ? Colors.grey : Colors.amber.shade700),
            )),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.icon(
              onPressed: _toggleSuspend,
              icon: Icon(_isSuspended ? Icons.lock_open : Icons.block),
              label: Text(_isSuspended ? 'Unsuspend' : 'Suspend'),
              style: FilledButton.styleFrom(
                  backgroundColor: _isSuspended ? Colors.green : Colors.orange),
            )),
          ]),

          const SizedBox(height: 8),

          OutlinedButton.icon(
            onPressed: _deleteCompany,
            icon: const Icon(Icons.delete_forever_outlined, color: Colors.red),
            label: const Text('Delete This Company',
                style: TextStyle(color: Colors.red)),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      Icon(icon, size: 15, color: Colors.blueGrey),
      const SizedBox(width: 8),
      Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
      Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
    ]),
  );

  Widget _billingBox(String title, String sub, String amount, Color color) =>
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          border: Border.all(color: color.withOpacity(0.3)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          const SizedBox(height: 4),
          Text(amount, style: TextStyle(fontSize: 18,
              fontWeight: FontWeight.bold, color: color)),
          Text(sub, style: const TextStyle(fontSize: 11)),
        ]),
      );

  Widget _tableHeader(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
  );

  Widget _tableCell(String text, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
    child: Text(text, style: TextStyle(fontSize: 12,
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        color: bold ? Colors.blue.shade700 : null)),
  );
}


// ── Company Invoices Page ─────────────────────────────────────────────
class CompanyInvoicesPage extends StatefulWidget {
  final String username;
  final ApiService api;
  const CompanyInvoicesPage({super.key, required this.username, required this.api});
  @override
  State<CompanyInvoicesPage> createState() => _CompanyInvoicesPageState();
}

class _CompanyInvoicesPageState extends State<CompanyInvoicesPage> {
  List<Map<String, dynamic>> _invoices = [];
  bool _loading = true;
  String _search = '';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final list = await widget.api.masterGetInvoices(widget.username);
      if (mounted) setState(() { _invoices = list; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_search.isEmpty) return _invoices;
    final q = _search.toLowerCase();
    return _invoices.where((inv) =>
        (inv['invoice_number']?.toString() ?? '').contains(q) ||
        (inv['customer_name'] ?? '').toString().toLowerCase().contains(q) ||
        (inv['plate']         ?? '').toString().toLowerCase().contains(q) ||
        (inv['invoice_date']  ?? '').toString().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: Text('Invoices — @${widget.username}'),
        backgroundColor: Colors.grey.shade900,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search invoices…',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(), isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : filtered.isEmpty
                ? Center(child: Text(_invoices.isEmpty
                    ? 'No invoices found' : 'No results for "$_search"'))
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final inv      = filtered[i];
                      final num      = inv['invoice_number']?.toString() ?? '—';
                      final date     = (inv['invoice_date'] ?? '').toString();
                      final customer = (inv['customer_name'] ??
                          '${inv['first_name'] ?? ''} ${inv['last_name'] ?? ''}'.trim()).toString();
                      final plate    = (inv['plate'] ?? '').toString();
                      final amt      = (inv['amount_cents'] as int? ?? 0);
                      final amtStr   = amt > 0 ? '\$${(amt / 100).toStringAsFixed(2)}' : '—';
                      final isEst    = inv['is_estimate'] == true || inv['is_estimate'] == 1;
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: isEst
                              ? Colors.purple.shade100 : Colors.blue.shade100,
                          child: Text(isEst ? 'E' : '#',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                                  color: isEst ? Colors.purple : Colors.blue)),
                        ),
                        title: Text(
                          '${isEst ? 'Est' : 'Inv'} #$num  •  ${customer.isNotEmpty ? customer : '—'}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                        subtitle: Text(
                          '${date.length >= 10 ? date.substring(0, 10) : date}'
                          '${plate.isNotEmpty ? '  •  $plate' : ''}',
                          style: const TextStyle(fontSize: 11)),
                        trailing: Text(amtStr,
                            style: const TextStyle(fontSize: 13,
                                fontWeight: FontWeight.bold)),
                      );
                    },
                  )),
      ]),
    );
  }
}
