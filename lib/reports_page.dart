import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'local_db.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage>
    with SingleTickerProviderStateMixin {
  final db = LocalDb.instance;

  late TabController _tabCtl;
  DateTime _selectedDate = DateTime.now();

  // Results per tab
  _ReportData? _dayData;
  _ReportData? _weekData;
  _ReportData? _monthData;
  List<Map<String, dynamic>> _balances = [];

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _tabCtl = TabController(length: 4, vsync: this);
    _tabCtl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _tabCtl.dispose();
    super.dispose();
  }

  // ── Date helpers ──────────────────────────────────────────────────────────

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _dayRange() {
    final s = _fmt(_selectedDate);
    return '$s to $s';
  }

  String _weekRange() {
    final start = _selectedDate;
    final end   = start.add(const Duration(days: 6));
    return '${_fmt(start)} to ${_fmt(end)}';
  }

  String _monthRange() {
    final first = DateTime(_selectedDate.year, _selectedDate.month, 1);
    final last  = DateTime(_selectedDate.year, _selectedDate.month + 1, 0);
    return '${_fmt(first)} to ${_fmt(last)}';
  }

  // ── Data loading ──────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await _loadReport(_fmt(_selectedDate), _fmt(_selectedDate));
      final wStart = _selectedDate;
      final wEnd   = _selectedDate.add(const Duration(days: 6));
      final w = await _loadReport(_fmt(wStart), _fmt(wEnd));
      final mFirst = DateTime(_selectedDate.year, _selectedDate.month, 1);
      final mLast  = DateTime(_selectedDate.year, _selectedDate.month + 1, 0);
      final m = await _loadReport(_fmt(mFirst), _fmt(mLast));
      final allAccts = await db.listAccountCustomers();
      final bal = allAccts.where((r) => ((r['balance_cents'] as int?) ?? 0) > 0).toList();
      if (mounted) setState(() {
        _dayData = d; _weekData = w; _monthData = m; _balances = bal;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<_ReportData> _loadReport(String startDate, String endDate) async {
    final dbConn = await db.database;

    // Summary totals
    final rows = await dbConn.rawQuery('''
      SELECT
        COUNT(*) AS invoice_count,
        COALESCE(SUM(amount_cents), 0) AS total_cents,
        COALESCE(SUM(CASE WHEN payment_method='CASH'    THEN amount_cents ELSE 0 END), 0) AS cash_cents,
        COALESCE(SUM(CASE WHEN payment_method='CARD'    THEN amount_cents ELSE 0 END), 0) AS card_cents,
        COALESCE(SUM(CASE WHEN payment_method='CHECK'   THEN amount_cents ELSE 0 END), 0) AS check_cents,
        COALESCE(SUM(CASE WHEN payment_method='ACCOUNT' OR COALESCE(account_id,'')!='' THEN amount_cents ELSE 0 END), 0) AS account_cents,
        COALESCE(SUM(CASE WHEN (payment_method IS NULL OR payment_method='') AND COALESCE(account_id,'')='' THEN amount_cents ELSE 0 END), 0) AS other_cents
      FROM invoices
      WHERE deleted=0
        AND finalized=1
        AND status != 'ESTIMATE'
        AND invoice_date >= ?
        AND invoice_date <= ?
    ''', [startDate, endDate]);

    // Per-day breakdown (for weekly/monthly views)
    final byDay = await dbConn.rawQuery('''
      SELECT
        invoice_date,
        COUNT(*) AS invoice_count,
        COALESCE(SUM(amount_cents), 0) AS total_cents
      FROM invoices
      WHERE deleted=0
        AND finalized=1
        AND status != 'ESTIMATE'
        AND invoice_date >= ?
        AND invoice_date <= ?
      GROUP BY invoice_date
      ORDER BY invoice_date ASC
    ''', [startDate, endDate]);

    // Per-invoice detail list
    final invoices = await dbConn.rawQuery('''
      SELECT
        invoice_number,
        invoice_date,
        customer_name,
        payment_method,
        amount_cents,
        account_id
      FROM invoices
      WHERE deleted=0
        AND finalized=1
        AND status != 'ESTIMATE'
        AND invoice_date >= ?
        AND invoice_date <= ?
      ORDER BY invoice_date ASC, invoice_number ASC
    ''', [startDate, endDate]);

    final summary = rows.first;
    return _ReportData(
      invoiceCount : (summary['invoice_count'] as int?) ?? 0,
      totalCents   : (summary['total_cents']   as int?) ?? 0,
      cashCents    : (summary['cash_cents']     as int?) ?? 0,
      cardCents    : (summary['card_cents']     as int?) ?? 0,
      checkCents   : (summary['check_cents']    as int?) ?? 0,
      accountCents : (summary['account_cents']  as int?) ?? 0,
      otherCents   : (summary['other_cents']    as int?) ?? 0,
      byDay        : byDay,
      invoices     : invoices,
    );
  }

  // ── Email report ──────────────────────────────────────────────────────────

  _ReportData? get _currentData {
    switch (_tabCtl.index) {
      case 0:  return _dayData;
      case 1:  return _weekData;
      default: return _monthData;
    }
  }

  String get _currentPeriodLabel {
    switch (_tabCtl.index) {
      case 0:
        return '${_monthName(_selectedDate.month)} ${_selectedDate.day}, ${_selectedDate.year}';
      case 1:
        final end = _selectedDate.add(const Duration(days: 6));
        return '${_monthName(_selectedDate.month)} ${_selectedDate.day} – '
            '${_monthName(end.month)} ${end.day}, ${end.year}';
      default:
        return '${_monthName(_selectedDate.month)} ${_selectedDate.year}';
    }
  }

  String get _currentTabName {
    switch (_tabCtl.index) {
      case 0:  return 'Daily';
      case 1:  return 'Weekly';
      default: return 'Monthly';
    }
  }

  Future<void> _sendEmail() async {
    final data = _currentData;
    if (data == null) return;

    // Ask for recipient email
    final companyEmail = await db.getSetting('co_email') ?? '';
    final companyName  = await db.getSetting('co_name')  ?? 'Blue Sky Smog';
    final emailCtl = TextEditingController(text: companyEmail);

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send Report'),
        content: TextField(
          controller: emailCtl,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Send to email',
            prefixIcon: Icon(Icons.email_outlined),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (confirmed != true) return;

    final toEmail = emailCtl.text.trim();
    if (toEmail.isEmpty) return;

    // Build report body
    final buf = StringBuffer();
    buf.writeln('$companyName — $_currentTabName Sales Report');
    buf.writeln('Period: $_currentPeriodLabel');
    buf.writeln('─' * 40);
    buf.writeln();
    buf.writeln('TOTAL SALES:   \$${(data.totalCents / 100).toStringAsFixed(2)}');
    buf.writeln('INVOICE COUNT: ${data.invoiceCount}');
    buf.writeln();
    buf.writeln('BY PAYMENT METHOD:');
    if (data.cashCents    > 0) buf.writeln('  Cash:    \$${(data.cashCents    / 100).toStringAsFixed(2)}');
    if (data.cardCents    > 0) buf.writeln('  Card:    \$${(data.cardCents    / 100).toStringAsFixed(2)}');
    if (data.checkCents   > 0) buf.writeln('  Check:   \$${(data.checkCents   / 100).toStringAsFixed(2)}');
    if (data.accountCents > 0) buf.writeln('  Account: \$${(data.accountCents / 100).toStringAsFixed(2)}');
    if (data.otherCents   > 0) buf.writeln('  Other:   \$${(data.otherCents   / 100).toStringAsFixed(2)}');

    if (data.byDay.isNotEmpty && _tabCtl.index != 0) {
      buf.writeln();
      buf.writeln('DAILY BREAKDOWN:');
      for (final row in data.byDay) {
        final date  = (row['invoice_date'] ?? '').toString();
        final parts = date.split('-');
        final label = parts.length == 3
            ? '${int.tryParse(parts[1]) ?? parts[1]}/${int.tryParse(parts[2]) ?? parts[2]}/${parts[0]}'
            : date;
        final cnt   = (row['invoice_count'] as int?) ?? 0;
        final tot   = (row['total_cents']   as int?) ?? 0;
        buf.writeln('  $label  ($cnt inv)  \$${(tot / 100).toStringAsFixed(2)}');
      }
    }

    if (data.invoices.isNotEmpty) {
      buf.writeln();
      buf.writeln('INVOICES:');
      buf.writeln('  #       Date        Customer                    Method    Amount');
      buf.writeln('  ' + '-' * 70);
      for (final inv in data.invoices) {
        final num    = (inv['invoice_number'] ?? '').toString().padRight(6);
        final date   = (inv['invoice_date']   ?? '').toString();
        final parts  = date.split('-');
        final dLabel = parts.length == 3
            ? '${int.tryParse(parts[1]) ?? parts[1]}/${int.tryParse(parts[2]) ?? parts[2]}/${parts[0]}'
            : date;
        final name   = (inv['customer_name']  ?? '').toString();
        final method = (inv['payment_method'] ?? '').toString();
        final cents  = (inv['amount_cents']   as int?) ?? 0;
        buf.writeln('  #$num  ${dLabel.padRight(10)}  ${name.padRight(26)}  '
            '${method.padRight(8)}  \$${(cents / 100).toStringAsFixed(2)}');
      }
    }

    final subject = Uri.encodeComponent(
        '$_currentTabName Sales Report — $_currentPeriodLabel');
    final body = Uri.encodeComponent(buf.toString());
    final uri  = Uri.parse('mailto:$toEmail?subject=$subject&body=$body');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open email client.')));
    }
  }

  // ── Date picker ───────────────────────────────────────────────────────────

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
      _load();
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  String _money(int cents) =>
      '\$${(cents / 100).toStringAsFixed(2)}';

  String _monthName(int m) => const [
    '', 'Jan','Feb','Mar','Apr','May','Jun',
    'Jul','Aug','Sep','Oct','Nov','Dec'
  ][m];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales Reports'),
        bottom: TabBar(
          controller: _tabCtl,
          tabs: const [
            Tab(text: 'Daily'),
            Tab(text: 'Weekly'),
            Tab(text: 'Monthly'),
            Tab(text: 'Balances'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.email_outlined),
            tooltip: 'Email Report',
            onPressed: _loading ? null : _sendEmail,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_today, size: 18),
              label: Text(
                '${_selectedDate.month}/${_selectedDate.day}/${_selectedDate.year}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabCtl,
              children: [
                _buildDayTab(),
                _buildWeekTab(),
                _buildMonthTab(),
                _buildBalancesTab(),
              ],
            ),
    );
  }

  // ── Daily tab ─────────────────────────────────────────────────────────────

  Widget _buildDayTab() {
    final data = _dayData;
    if (data == null) return const Center(child: CircularProgressIndicator());
    final label =
        '${_monthName(_selectedDate.month)} ${_selectedDate.day}, ${_selectedDate.year}';
    return ListView(padding: const EdgeInsets.all(16), children: [
      _DateChip(label: label, onTap: _pickDate),
      const SizedBox(height: 12),
      _SummaryCard(data: data),
      const SizedBox(height: 16),
      if (data.invoices.isEmpty)
        _EmptyState(message: 'No sales on $label')
      else ...[
        _sectionHeader('Invoices'),
        const SizedBox(height: 6),
        ...data.invoices.map((inv) => _InvoiceTile(inv: inv)),
      ],
    ]);
  }

  // ── Weekly tab ────────────────────────────────────────────────────────────

  Widget _buildWeekTab() {
    final data = _weekData;
    if (data == null) return const Center(child: CircularProgressIndicator());
    final start = _selectedDate;
    final end   = start.add(const Duration(days: 6));
    final label =
        '${_monthName(start.month)} ${start.day} – ${_monthName(end.month)} ${end.day}, ${end.year}';
    return ListView(padding: const EdgeInsets.all(16), children: [
      _DateChip(label: label, onTap: _pickDate),
      const SizedBox(height: 12),
      _SummaryCard(data: data),
      const SizedBox(height: 16),
      if (data.byDay.isNotEmpty) ...[
        _sectionHeader('By Day'),
        const SizedBox(height: 6),
        _DayBreakdownTable(rows: data.byDay),
        const SizedBox(height: 16),
      ],
      if (data.invoices.isEmpty)
        _EmptyState(message: 'No sales in this week')
      else ...[
        _sectionHeader('Invoices'),
        const SizedBox(height: 6),
        ...data.invoices.map((inv) => _InvoiceTile(inv: inv)),
      ],
    ]);
  }

  // ── Monthly tab ───────────────────────────────────────────────────────────

  Widget _buildMonthTab() {
    final data = _monthData;
    if (data == null) return const Center(child: CircularProgressIndicator());
    final label =
        '${_monthName(_selectedDate.month)} ${_selectedDate.year}';
    return ListView(padding: const EdgeInsets.all(16), children: [
      _DateChip(label: label, onTap: _pickDate),
      const SizedBox(height: 12),
      _SummaryCard(data: data),
      const SizedBox(height: 16),
      if (data.byDay.isNotEmpty) ...[
        _sectionHeader('By Day'),
        const SizedBox(height: 6),
        _DayBreakdownTable(rows: data.byDay),
        const SizedBox(height: 16),
      ],
      if (data.invoices.isEmpty)
        _EmptyState(message: 'No sales in ${_monthName(_selectedDate.month)} ${_selectedDate.year}')
      else ...[
        _sectionHeader('Invoices'),
        const SizedBox(height: 6),
        ...data.invoices.map((inv) => _InvoiceTile(inv: inv)),
      ],
    ]);
  }

  // ── Balances tab ──────────────────────────────────────────────────────────

  Widget _buildBalancesTab() {
    if (_balances.isEmpty) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
          SizedBox(height: 12),
          Text('No outstanding account balances',
              style: TextStyle(fontSize: 16, color: Colors.grey)),
        ]),
      );
    }

    final totalCents = _balances.fold<int>(
        0, (sum, r) => sum + ((r['balance_cents'] as int?) ?? 0));

    return Column(children: [
      // Total banner
      Container(
        width: double.infinity,
        color: Colors.red.shade50,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          const Icon(Icons.account_balance_wallet_outlined, color: Colors.red),
          const SizedBox(width: 8),
          Text('${_balances.length} account${_balances.length == 1 ? '' : 's'} outstanding',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('Total: \$${(totalCents / 100).toStringAsFixed(2)}',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.red, fontSize: 15)),
        ]),
      ),
      // List
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: _balances.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final r       = _balances[i];
            final cents   = (r['balance_cents'] as int?) ?? 0;
            final name    = (r['company_name'] as String?)?.isNotEmpty == true
                ? r['company_name'] as String
                : '${r['first_name'] ?? ''} ${r['last_name'] ?? ''}'.trim().isNotEmpty == true
                    ? '${r['first_name'] ?? ''} ${r['last_name'] ?? ''}'.trim()
                    : (r['name'] as String?) ?? 'Unknown';
            final phone   = (r['phone'] as String?) ?? '';
            final email   = (r['email'] as String?) ?? '';
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: phone.isNotEmpty || email.isNotEmpty
                  ? Text([if (phone.isNotEmpty) phone, if (email.isNotEmpty) email].join(' · '))
                  : null,
              trailing: Text(
                '\$${(cents / 100).toStringAsFixed(2)}',
                style: const TextStyle(
                    color: Colors.red, fontWeight: FontWeight.bold, fontSize: 15),
              ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _sectionHeader(String text) => Text(text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
          color: Colors.grey));
}

// ── Data class ────────────────────────────────────────────────────────────────

class _ReportData {
  final int invoiceCount;
  final int totalCents;
  final int cashCents;
  final int cardCents;
  final int checkCents;
  final int accountCents;
  final int otherCents;
  final List<Map<String, dynamic>> byDay;
  final List<Map<String, dynamic>> invoices;

  const _ReportData({
    required this.invoiceCount,
    required this.totalCents,
    required this.cashCents,
    required this.cardCents,
    required this.checkCents,
    required this.accountCents,
    required this.otherCents,
    required this.byDay,
    required this.invoices,
  });
}

// ── Reusable widgets ──────────────────────────────────────────────────────────

class _DateChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _DateChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.calendar_today,
              size: 15,
              color: Theme.of(context).colorScheme.onPrimaryContainer),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onPrimaryContainer)),
          const SizedBox(width: 4),
          Icon(Icons.arrow_drop_down,
              size: 18,
              color: Theme.of(context).colorScheme.onPrimaryContainer),
        ]),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final _ReportData data;
  const _SummaryCard({required this.data});

  String _money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Total Sales',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                Text(_money(data.totalCents),
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: scheme.primary)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(children: [
                Text('${data.invoiceCount}',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: scheme.onSecondaryContainer)),
                Text('invoice${data.invoiceCount == 1 ? '' : 's'}',
                    style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSecondaryContainer)),
              ]),
            ),
          ]),
          if (data.totalCents > 0) ...[
            const Divider(height: 20),
            const Text('By Payment Method',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              if (data.cashCents    > 0) _MethodChip('Cash',    data.cashCents,    Colors.green),
              if (data.cardCents    > 0) _MethodChip('Card',    data.cardCents,    Colors.blue),
              if (data.checkCents   > 0) _MethodChip('Check',   data.checkCents,   Colors.orange),
              if (data.accountCents > 0) _MethodChip('Account', data.accountCents, Colors.purple),
              if (data.otherCents   > 0) _MethodChip('Other',   data.otherCents,   Colors.grey),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _MethodChip extends StatelessWidget {
  final String label;
  final int cents;
  final Color color;
  const _MethodChip(this.label, this.cents, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text('$label  \$${(cents / 100).toStringAsFixed(2)}',
            style: TextStyle(fontSize: 12, color: color,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _DayBreakdownTable extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const _DayBreakdownTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: const [
            Expanded(flex: 3, child: Text('Date',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: Colors.grey))),
            Expanded(flex: 2, child: Text('Invoices',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: Colors.grey))),
            Expanded(flex: 3, child: Text('Total',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: Colors.grey))),
          ]),
        ),
        const Divider(height: 1),
        ...rows.asMap().entries.map((entry) {
          final i   = entry.key;
          final row = entry.value;
          final date  = (row['invoice_date'] ?? '').toString();
          final count = (row['invoice_count'] as int?) ?? 0;
          final total = (row['total_cents']   as int?) ?? 0;
          final parts = date.split('-');
          final label = parts.length == 3
              ? '${int.tryParse(parts[1]) ?? parts[1]}/${int.tryParse(parts[2]) ?? parts[2]}/${parts[0]}'
              : date;
          return Container(
            color: i.isEven
                ? Colors.transparent
                : Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Expanded(flex: 3, child: Text(label,
                    style: const TextStyle(fontSize: 13))),
                Expanded(flex: 2, child: Text('$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13))),
                Expanded(flex: 3, child: Text(
                    '\$${(total / 100).toStringAsFixed(2)}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600))),
              ]),
            ),
          );
        }),
      ]),
    );
  }
}

class _InvoiceTile extends StatelessWidget {
  final Map<String, dynamic> inv;
  const _InvoiceTile({required this.inv});

  @override
  Widget build(BuildContext context) {
    final num    = inv['invoice_number']?.toString() ?? '—';
    final date   = (inv['invoice_date'] ?? '').toString();
    final name   = (inv['customer_name'] ?? '').toString();
    final method = (inv['payment_method'] ?? '').toString();
    final cents  = (inv['amount_cents'] as int?) ?? 0;

    // Format date M/D/YYYY
    final parts = date.split('-');
    final dateLabel = parts.length == 3
        ? '${int.tryParse(parts[1]) ?? parts[1]}/${int.tryParse(parts[2]) ?? parts[2]}'
        : date;

    Color methodColor = Colors.grey;
    if (method == 'CASH')    methodColor = Colors.green;
    if (method == 'CARD')    methodColor = Colors.blue;
    if (method == 'CHECK')   methodColor = Colors.orange;
    if (method == 'ACCOUNT') methodColor = Colors.purple;

    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          // Invoice #
          SizedBox(
            width: 52,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text('#$num',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
              Text(dateLabel,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
          ),
          const SizedBox(width: 8),
          // Customer
          Expanded(
            child: Text(name.isNotEmpty ? name : 'Unknown',
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis),
          ),
          // Method badge
          if (method.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 6),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: methodColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(method,
                  style: TextStyle(fontSize: 10,
                      color: methodColor,
                      fontWeight: FontWeight.w600)),
            ),
          // Amount
          Text('\$${(cents / 100).toStringAsFixed(2)}',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14)),
        ]),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 32),
        Icon(Icons.bar_chart, size: 56, color: Colors.grey.shade300),
        const SizedBox(height: 12),
        Text(message,
            style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
      ]),
    );
  }
}
