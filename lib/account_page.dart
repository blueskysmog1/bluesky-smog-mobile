import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'local_db.dart';

// ── Accounts List Page ─────────────────────────────────────────────────────

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});
  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  final db = LocalDb.instance;
  List<Map<String, dynamic>> _customers = [];
  String _search = '';
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final rows = await db.listAccountCustomers();
    if (!mounted) return;
    setState(() { _customers = rows; _loading = false; });
  }

  List<Map<String, dynamic>> get _filtered {
    if (_search.isEmpty) return _customers;
    final q = _search.toLowerCase();
    return _customers.where((c) =>
        (c['name'] ?? '').toString().toLowerCase().contains(q) ||
        (c['company_name'] ?? '').toString().toLowerCase().contains(q) ||
        (c['first_name'] ?? '').toString().toLowerCase().contains(q) ||
        (c['last_name'] ?? '').toString().toLowerCase().contains(q)).toList();
  }

  String _displayName(Map<String, dynamic> c) {
    final co = (c['company_name'] ?? '').toString().trim();
    if (co.isNotEmpty) return co;
    final fn = (c['first_name'] ?? '').toString().trim();
    final ln = (c['last_name'] ?? '').toString().trim();
    if (fn.isNotEmpty || ln.isNotEmpty) return '$fn $ln'.trim();
    return (c['name'] ?? 'Unknown').toString();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search accounts…',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const Center(child: Text('No accounts found.'))
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (ctx, i) {
                          final c = filtered[i];
                          final bal = (c['balance_cents'] as int? ?? 0) / 100.0;
                          return ListTile(
                            leading: const CircleAvatar(child: Icon(Icons.business_outlined)),
                            title: Text(_displayName(c)),
                            subtitle: Text((c['email'] ?? '').toString().isEmpty
                                ? 'No email on file' : (c['email'] as String)),
                            trailing: Text(
                              '\$${bal.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: bal > 0 ? Colors.red.shade700 : Colors.green.shade700,
                              ),
                            ),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => AccountDetailPage(
                                  customerId: c['customer_id'] as String,
                                  displayName: _displayName(c),
                                  email: (c['email'] ?? '').toString(),
                                ),
                              ));
                              _load();
                            },
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}

// ── Account Detail Page ────────────────────────────────────────────────────

class AccountDetailPage extends StatefulWidget {
  final String customerId;
  final String displayName;
  final String email;
  final String deviceId;
  const AccountDetailPage({
    super.key,
    required this.customerId,
    required this.displayName,
    required this.email,
    this.deviceId = '',
  });
  @override
  State<AccountDetailPage> createState() => _AccountDetailPageState();
}

class _AccountDetailPageState extends State<AccountDetailPage> {
  final db = LocalDb.instance;
  int _balanceCents = 0;
  List<Map<String, dynamic>> _invoices = [];
  List<Map<String, dynamic>> _payments = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      db.getAccountBalance(widget.customerId),
      db.getAccountInvoices(widget.customerId),
      db.getAccountPayments(widget.customerId),
    ]);
    if (!mounted) return;
    setState(() {
      _balanceCents = results[0] as int;
      _invoices     = results[1] as List<Map<String, dynamic>>;
      _payments     = results[2] as List<Map<String, dynamic>>;
      _loading = false;
    });
  }

  /// Build merged, sorted history entries.
  /// Each entry: {date, type, ref, invoiceAmt, paymentAmt, note, isPaid}
  List<Map<String, dynamic>> get _merged {
    // Collect paid invoice UUIDs from payments
    final paidIds = <String>{};
    for (final p in _payments) {
      for (final id in (p['invoice_id'] as String? ?? '').split(',')) {
        final t = id.trim();
        if (t.isNotEmpty) paidIds.add(t);
      }
    }

    final entries = <Map<String, dynamic>>[];
    for (final inv in _invoices) {
      final isPaid = paidIds.contains(inv['invoice_id'] as String? ?? '');
      entries.add({
        'date':       inv['invoice_date'] ?? '',
        'sort':       0,
        'type':       'Invoice',
        'ref':        inv['invoice_number']?.toString() ?? '—',
        'invoiceAmt': (inv['amount_cents'] as int? ?? 0) / 100.0,
        'paymentAmt': 0.0,
        'note':       '',
        'isPaid':     isPaid,
        'invoiceId':  inv['invoice_id'] ?? '',
      });
    }
    for (final pay in _payments) {
      entries.add({
        'date':       pay['entry_date'] ?? '',
        'sort':       1,
        'type':       'Payment',
        'ref':        pay['payment_number'] ?? '—',
        'invoiceAmt': 0.0,
        'paymentAmt': (pay['amount_cents'] as int? ?? 0) / 100.0,
        'note':       pay['note'] ?? '',
        'isPaid':     false,
        'invoiceId':  '',
      });
    }
    entries.sort((a, b) {
      final d = (b['date'] as String).compareTo(a['date'] as String);
      if (d != 0) return d;
      return (a['sort'] as int).compareTo(b['sort'] as int);
    });
    return entries;
  }

  // ── Post Payment ──────────────────────────────────────────────────────────

  Future<void> _postPayment() async {
    final nextPmt = await db.getNextPaymentNumber();
    if (!mounted) return;

    final pmtCtl  = TextEditingController(text: nextPmt);
    final dateCtl = TextEditingController(
        text: DateTime.now().toIso8601String().substring(0, 10));
    final amtCtl  = TextEditingController();
    final noteCtl = TextEditingController();

    // Step 1 — collect payment details
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Post Payment'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: pmtCtl,
                decoration: const InputDecoration(labelText: 'Payment #')),
            const SizedBox(height: 8),
            TextField(controller: dateCtl,
                decoration: const InputDecoration(labelText: 'Date (YYYY-MM-DD)')),
            const SizedBox(height: 8),
            TextField(controller: amtCtl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Amount \$', prefixText: '\$ ')),
            const SizedBox(height: 8),
            TextField(controller: noteCtl,
                decoration: const InputDecoration(labelText: 'Notes')),
            const SizedBox(height: 8),
            Text('Payment is applied automatically to the oldest unpaid invoices first.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Next →')),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      pmtCtl.dispose(); dateCtl.dispose(); amtCtl.dispose(); noteCtl.dispose();
      return;
    }

    final amt = double.tryParse(amtCtl.text.trim().replaceAll(',', ''));
    if (amt == null || amt <= 0) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid amount')));
      pmtCtl.dispose(); dateCtl.dispose(); amtCtl.dispose(); noteCtl.dispose();
      return;
    }

    // Step 2 — compute auto-apply
    final unpaid = await db.getUnpaidInvoicesWithRemaining(widget.customerId);
    double left = amt;
    final fullyPaid = <Map<String, dynamic>>[];
    Map<String, dynamic>? partial;
    for (final inv in unpaid) {
      if (left < 0.005) break;
      final remaining = inv['remaining'] as double;
      if (left >= remaining - 0.005) {
        fullyPaid.add(inv);
        left = (left - remaining).clamp(0.0, double.infinity);
      } else {
        partial = {
          ...inv,
          'applied':    left,
          'shortfall':  remaining - left,
        };
        left = 0;
        break;
      }
    }

    // Step 3 — show confirmation with breakdown
    final breakdownLines = <Widget>[];
    for (final inv in fullyPaid) {
      final tag = (inv['wasPartial'] as bool? ?? false) ? ' (completes partial)' : '';
      breakdownLines.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 16),
          const SizedBox(width: 6),
          Expanded(child: Text(
              'Invoice #${inv['num']}  (\$${(inv['full'] as double).toStringAsFixed(2)}) — PAID IN FULL$tag',
              style: const TextStyle(fontSize: 13))),
        ]),
      ));
    }
    if (partial != null) {
      breakdownLines.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16),
          const SizedBox(width: 6),
          Expanded(child: Text(
              'Invoice #${partial['num']}  (\$${(partial['full'] as double).toStringAsFixed(2)}) — '
              '\$${(partial['applied'] as double).toStringAsFixed(2)} applied, '
              '\$${(partial['shortfall'] as double).toStringAsFixed(2)} still owed (stays unpaid)',
              style: const TextStyle(fontSize: 13))),
        ]),
      ));
    }
    if (fullyPaid.isEmpty && partial == null) {
      breakdownLines.add(Text(
          unpaid.isEmpty
              ? 'No open invoices — payment reduces balance only.'
              : 'Amount is less than any single invoice — no invoices marked paid.',
          style: const TextStyle(fontSize: 13, color: Colors.grey)));
    }

    // Capture controller values BEFORE disposing
    final pmtNum  = pmtCtl.text.trim().isNotEmpty ? pmtCtl.text.trim() : nextPmt;
    final dateStr = dateCtl.text.trim().isNotEmpty
        ? dateCtl.text.trim()
        : DateTime.now().toIso8601String().substring(0, 10);
    final userNote = noteCtl.text.trim();

    if (!mounted) {
      pmtCtl.dispose(); dateCtl.dispose(); amtCtl.dispose(); noteCtl.dispose();
      return;
    }
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirm  $pmtNum  —  \$${amt.toStringAsFixed(2)}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Breakdown:', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              ...breakdownLines,
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Post Payment')),
        ],
      ),
    );

    pmtCtl.dispose(); dateCtl.dispose(); amtCtl.dispose(); noteCtl.dispose();
    if (proceed != true || !mounted) return;

    // Step 4 — build fields and post
    final invoiceIds = fullyPaid.map((i) => i['uuid'] as String).toList();

    String partialJson = '{}';
    String partialNote = '';
    if (partial != null) {
      final applied   = partial['applied']   as double;
      final shortfall = partial['shortfall'] as double;
      final invNum    = partial['num'];
      partialJson = '{"${partial['uuid']}":${applied.toStringAsFixed(4)}}';
      partialNote = '[Partial \$${applied.toStringAsFixed(2)} toward '
                    'Inv #$invNum — \$${shortfall.toStringAsFixed(2)} remaining]';
    }
    final finalNote = [userNote, partialNote]
        .where((s) => s.isNotEmpty).join('  ');

    await db.postPayment(
      customerId:    widget.customerId,
      deviceId:      widget.deviceId,
      entryDate:     dateStr,
      amountCents:   (amt * 100).round(),
      note:          finalNote,
      invoiceIds:    invoiceIds,
      paymentNumber: pmtNum,
      paymentId:     const Uuid().v4(),
      partialJson:   partialJson,
    );
    await _load();
  }

  // ── Send Statement ────────────────────────────────────────────────────────

  Future<void> _sendStatement() async {
    if (widget.email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No email address on file for this customer.')));
      return;
    }

    // Dialog: choose type + start date for full history
    String type = 'outstanding';
    DateTime? startDate;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          title: const Text('Send Account Statement'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            RadioListTile<String>(
              title: const Text('Outstanding Balance Only'),
              subtitle: const Text('Unpaid invoices only'),
              value: 'outstanding',
              groupValue: type,
              onChanged: (v) => setDlg(() => type = v!),
            ),
            RadioListTile<String>(
              title: const Text('Full Account History'),
              subtitle: const Text('All invoices and payments'),
              value: 'full',
              groupValue: type,
              onChanged: (v) => setDlg(() => type = v!),
            ),
            if (type == 'full') ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.date_range),
                label: Text(startDate == null
                    ? 'Select Start Date (optional)'
                    : 'From: ${startDate!.toIso8601String().substring(0, 10)}'),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: DateTime.now().subtract(const Duration(days: 365)),
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setDlg(() => startDate = picked);
                },
              ),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
          ],
        );
      }),
    );
    if (confirmed != true) return;

    // Build statement body
    final bal = _balanceCents / 100.0;
    final buf = StringBuffer();
    buf.writeln('Account Statement — ${widget.displayName}');
    buf.writeln('Balance Owed: \$${bal.toStringAsFixed(2)}');
    buf.writeln('');

    final merged = _merged;

    if (type == 'outstanding') {
      buf.writeln('OUTSTANDING INVOICES');
      buf.writeln('--------------------');
      final unpaid = merged.where((e) =>
          e['type'] == 'Invoice' && !(e['isPaid'] as bool)).toList();
      if (unpaid.isEmpty) {
        buf.writeln('No outstanding invoices.');
      } else {
        for (final e in unpaid) {
          buf.writeln('Invoice #${e['ref']}   ${e['date']}   \$${(e['invoiceAmt'] as double).toStringAsFixed(2)}');
        }
      }
    } else {
      buf.writeln('FULL ACCOUNT HISTORY');
      if (startDate != null) {
        buf.writeln('From: ${startDate!.toIso8601String().substring(0, 10)}');
      }
      buf.writeln('--------------------');
      final cutoff = startDate?.toIso8601String().substring(0, 10) ?? '';
      final filtered2 = merged.where((e) =>
          cutoff.isEmpty || (e['date'] as String).compareTo(cutoff) >= 0).toList();
      for (final e in filtered2) {
        if (e['type'] == 'Invoice') {
          final paid = (e['isPaid'] as bool) ? ' [PAID]' : '';
          buf.writeln('Invoice #${e['ref']}   ${e['date']}   \$${(e['invoiceAmt'] as double).toStringAsFixed(2)}$paid');
        } else {
          buf.writeln('Payment  ${e['ref']}   ${e['date']}   \$${(e['paymentAmt'] as double).toStringAsFixed(2)}  ${e['note']}');
        }
      }
    }

    final subject = Uri.encodeComponent(
        'Account Statement — ${widget.displayName}');
    final body = Uri.encodeComponent(buf.toString());
    final uri = Uri.parse('mailto:${widget.email}?subject=$subject&body=$body');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open email client.')));
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bal = _balanceCents / 100.0;
    final merged = _loading ? <Map<String, dynamic>>[] : _merged;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.displayName),
        actions: [
          IconButton(
            icon: const Icon(Icons.email_outlined),
            tooltip: 'Send Statement',
            onPressed: _loading ? null : _sendStatement,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _postPayment,
        icon: const Icon(Icons.add),
        label: const Text('Post Payment'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              // Balance banner
              Container(
                width: double.infinity,
                color: bal > 0 ? Colors.red.shade50 : Colors.green.shade50,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.displayName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text(widget.email.isEmpty ? 'No email on file' : widget.email,
                          style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('Balance Owed',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                    Text(
                      '\$${bal.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: bal > 0 ? Colors.red.shade700 : Colors.green.shade700,
                      ),
                    ),
                  ]),
                ]),
              ),
              // Column headers
              Container(
                color: Colors.grey.shade100,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(children: const [
                  SizedBox(width: 82,  child: Text('Date',    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                  SizedBox(width: 60,  child: Text('Type',    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                  SizedBox(width: 56,  child: Text('Ref #',   style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                  Expanded(           child: Text('Invoice',  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600), textAlign: TextAlign.right)),
                  SizedBox(width: 8),
                  SizedBox(width: 72, child: Text('Payment',  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600), textAlign: TextAlign.right)),
                ]),
              ),
              const Divider(height: 1),
              // History list
              Expanded(
                child: merged.isEmpty
                    ? const Center(child: Text('No history yet.'))
                    : ListView.separated(
                        itemCount: merged.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final e = merged[i];
                          final isInv = e['type'] == 'Invoice';
                          final isPaid = e['isPaid'] as bool;
                          Color bg;
                          if (!isInv) {
                            bg = Colors.green.shade50;
                          } else if (isPaid) {
                            bg = Colors.lightBlue.shade50;
                          } else {
                            bg = Colors.white;
                          }
                          return Container(
                            color: bg,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            child: Row(children: [
                              SizedBox(width: 82,
                                  child: Text(e['date'] as String,
                                      style: const TextStyle(fontSize: 12))),
                              SizedBox(width: 60,
                                  child: Text(e['type'] as String,
                                      style: TextStyle(fontSize: 12,
                                          color: isInv ? Colors.blue.shade700 : Colors.green.shade700))),
                              SizedBox(width: 56,
                                  child: Text(e['ref'] as String,
                                      style: const TextStyle(fontSize: 12))),
                              Expanded(
                                child: Text(
                                  isInv ? '\$${(e['invoiceAmt'] as double).toStringAsFixed(2)}' : '',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 72,
                                child: Text(
                                  !isInv ? '\$${(e['paymentAmt'] as double).toStringAsFixed(2)}' : (isPaid ? 'PAID' : ''),
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: !isInv ? Colors.green.shade700
                                          : isPaid ? Colors.blue.shade700 : null,
                                      fontWeight: isPaid || !isInv ? FontWeight.w600 : FontWeight.normal),
                                ),
                              ),
                            ]),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}
