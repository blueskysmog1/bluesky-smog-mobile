import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// ---------------------------------------------------------------------------
/// LocalDb — single-file SQLite helper  (DB version 10)
/// ---------------------------------------------------------------------------
/// Tables: customers · vehicles · services · settings · outbox · invoices ·
///         invoice_items · accounts
/// ---------------------------------------------------------------------------

class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();

  static Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  // ── Schema ────────────────────────────────────────────────────────────────

  static const int _version = 10;

  Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'local.db');
    return openDatabase(
      path,
      version: _version,
      onCreate: _create,
      onUpgrade: _migrate,
      onOpen: _ensureColumns,
    );
  }

  Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE customers (
        customer_id   TEXT PRIMARY KEY,
        device_id     TEXT NOT NULL,
        name          TEXT,
        company_name  TEXT,
        phone         TEXT,
        email         TEXT,
        address       TEXT,
        referral_code TEXT,
        deleted       INTEGER NOT NULL DEFAULT 0,
        seq           INTEGER NOT NULL DEFAULT 0,
        event_id      TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE vehicles (
        vehicle_id    TEXT PRIMARY KEY,
        customer_id   TEXT NOT NULL,
        device_id     TEXT NOT NULL,
        vin           TEXT,
        plate         TEXT,
        make          TEXT,
        model         TEXT,
        year          TEXT,
        odometer      TEXT,
        service_type  TEXT,
        deleted       INTEGER NOT NULL DEFAULT 0,
        seq           INTEGER NOT NULL DEFAULT 0,
        event_id      TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE services (
        service_id          TEXT PRIMARY KEY,
        name                TEXT NOT NULL,
        service_type        TEXT,
        default_price_cents INTEGER NOT NULL DEFAULT 0,
        sort_order          INTEGER NOT NULL DEFAULT 0,
        deleted             INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE outbox (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id    TEXT NOT NULL,
        event_id     TEXT NOT NULL,
        seq          INTEGER NOT NULL,
        entity       TEXT NOT NULL,
        action       TEXT NOT NULL,
        payload_json TEXT NOT NULL DEFAULT '{}',
        sent         INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE invoices (
        invoice_id      TEXT PRIMARY KEY,
        customer_id     TEXT NOT NULL,
        device_id       TEXT NOT NULL,
        customer_name   TEXT,
        payment_method  TEXT,
        notes           TEXT,
        invoice_number  INTEGER,
        invoice_date    TEXT,
        status          TEXT NOT NULL DEFAULT 'ESTIMATE',
        amount_cents    INTEGER NOT NULL DEFAULT 0,
        finalized       INTEGER NOT NULL DEFAULT 0,
        pdf_uploaded    INTEGER NOT NULL DEFAULT 0,
        deleted         INTEGER NOT NULL DEFAULT 0,
        seq             INTEGER NOT NULL DEFAULT 0,
        event_id        TEXT,
        vin             TEXT,
        plate           TEXT,
        year            TEXT,
        make            TEXT,
        model           TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE invoice_items (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id          TEXT NOT NULL UNIQUE,
        invoice_id       TEXT NOT NULL,
        vehicle_id       TEXT,
        service_id       TEXT,
        name             TEXT,
        qty              REAL NOT NULL DEFAULT 1,
        unit_price_cents INTEGER NOT NULL DEFAULT 0,
        discount_cents   INTEGER NOT NULL DEFAULT 0,
        result           TEXT NOT NULL DEFAULT '',
        cert             TEXT NOT NULL DEFAULT '',
        odometer         TEXT,
        vin              TEXT,
        plate            TEXT,
        year             TEXT,
        make             TEXT,
        model            TEXT,
        deleted          INTEGER NOT NULL DEFAULT 0,
        seq              INTEGER NOT NULL DEFAULT 0,
        event_id         TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE accounts (
        customer_id   TEXT PRIMARY KEY,
        balance_cents INTEGER NOT NULL DEFAULT 0,
        updated_at    TEXT
      )
    ''');
  }

  Future<void> _migrate(Database db, int oldVersion, int newVersion) async {
    await _ensureColumns(db);
  }

  /// Always-safe column check — runs on upgrade AND after onCreate.
  /// ALTER TABLE IF NOT EXISTS column is not supported in older SQLite,
  /// so we check PRAGMA table_info first.
  Future<void> _ensureColumns(Database db) async {
    final invoiceCols = (await db.rawQuery("PRAGMA table_info(invoices)"))
        .map((r) => r['name'] as String).toSet();
    for (final col in ['vin', 'plate', 'year', 'make', 'model', 'signature_path',
                        'account_id', 'po_number', 'owner_first', 'owner_last']) {
      if (!invoiceCols.contains(col)) {
        await db.execute("ALTER TABLE invoices ADD COLUMN $col TEXT");
      }
    }
    final customerCols = (await db.rawQuery("PRAGMA table_info(customers)"))
        .map((r) => r['name'] as String).toSet();
    for (final col in ['city', 'state', 'zip', 'first_name', 'last_name']) {
      if (!customerCols.contains(col)) {
        await db.execute("ALTER TABLE customers ADD COLUMN $col TEXT");
      }
    }
    if (!customerCols.contains('discount_percent')) {
      await db.execute(
          "ALTER TABLE customers ADD COLUMN discount_percent REAL NOT NULL DEFAULT 0.0");
    }
    if (!customerCols.contains('discount_type')) {
      await db.execute(
          "ALTER TABLE customers ADD COLUMN discount_type TEXT NOT NULL DEFAULT 'PERCENT'");
    }
    final vehicleCols = (await db.rawQuery("PRAGMA table_info(vehicles)"))
        .map((r) => r['name'] as String).toSet();
    for (final col in ['test_interval_days', 'next_test_due']) {
      if (!vehicleCols.contains(col)) {
        await db.execute("ALTER TABLE vehicles ADD COLUMN $col ${col == 'test_interval_days' ? 'INTEGER' : 'TEXT'}");
      }
    }
    final itemCols = (await db.rawQuery("PRAGMA table_info(invoice_items)"))
        .map((r) => r['name'] as String).toSet();
    if (!itemCols.contains('discount_cents')) {
      await db.execute(
          "ALTER TABLE invoice_items ADD COLUMN discount_cents INTEGER NOT NULL DEFAULT 0");
    }
    if (!itemCols.contains('result')) {
      await db.execute(
          "ALTER TABLE invoice_items ADD COLUMN result TEXT NOT NULL DEFAULT ''");
    }
    if (!itemCols.contains('cert')) {
      await db.execute(
          "ALTER TABLE invoice_items ADD COLUMN cert TEXT NOT NULL DEFAULT ''");
    }
    // Create accounts table if it doesn't exist (existing installs)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS accounts (
        customer_id   TEXT PRIMARY KEY,
        balance_cents INTEGER NOT NULL DEFAULT 0,
        updated_at    TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS account_history (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        customer_id    TEXT NOT NULL,
        entry_date     TEXT NOT NULL,
        type           TEXT NOT NULL DEFAULT 'payment',
        amount_cents   INTEGER NOT NULL DEFAULT 0,
        note           TEXT NOT NULL DEFAULT '',
        invoice_id     TEXT NOT NULL DEFAULT '',
        payment_number TEXT NOT NULL DEFAULT '',
        payment_id     TEXT NOT NULL DEFAULT ''
      )
    ''');
    // Add payment_id column to existing installs
    final ahCols = (await db.rawQuery("PRAGMA table_info(account_history)"))
        .map((r) => r['name'] as String).toSet();
    if (!ahCols.contains('payment_id')) {
      await db.execute(
          "ALTER TABLE account_history ADD COLUMN payment_id TEXT NOT NULL DEFAULT ''");
    }
    await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_ah_payment_id "
        "ON account_history(payment_id) WHERE payment_id != ''");
    if (!ahCols.contains('partial_json')) {
      await db.execute(
          "ALTER TABLE account_history ADD COLUMN partial_json TEXT NOT NULL DEFAULT '{}'");
    }
    // Ensure accounts row exists for every customer
    await db.execute('''
      INSERT OR IGNORE INTO accounts (customer_id, balance_cents, updated_at)
      SELECT customer_id, 0, datetime('now') FROM customers WHERE deleted=0
    ''');
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<void> _addOutboxEntry(
    DatabaseExecutor db, {
    required String deviceId,
    required String eventId,
    required int seq,
    required String entity,
    required String action,
    required Map<String, dynamic> payload,
  }) async {
    await db.insert('outbox', {
      'device_id':    deviceId,
      'event_id':     eventId,
      'seq':          seq,
      'entity':       entity,
      'action':       action,
      'payload_json': jsonEncode(payload),
      'sent':         0,
    });
  }

  // ── clearAllLocalData ─────────────────────────────────────────────────────
  /// Wipe every user-data table.  Called by main.dart, login_page.dart,
  /// and settings_page.dart when switching accounts / logging out.
  Future<void> clearAllLocalData(String deviceId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('customers');
      await txn.delete('vehicles');
      await txn.delete('invoices');
      await txn.delete('invoice_items');
      await txn.delete('outbox');
      // keep settings (logo, company info) — intentional
    });
  }

  // ── Customers ─────────────────────────────────────────────────────────────

  /// Return all non-deleted customers ordered by name.
  Future<List<Map<String, dynamic>>> listCustomers() async {
    final db = await database;
    return db.query(
      'customers',
      where: 'deleted = 0',
      orderBy: 'COALESCE(NULLIF(first_name,""), NULLIF(company_name,""), name) ASC',
    );
  }

  /// Fetch a single customer by [customerId]. Returns null if not found.
  Future<Map<String, dynamic>?> getCustomer(String customerId) async {
    final db   = await database;
    final rows = await db.query(
      'customers',
      where: 'customer_id = ? AND deleted = 0',
      whereArgs: [customerId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Full-text search across name and company_name.
  /// Optionally excludes [excludeId] (used when editing to avoid self-match).
  Future<List<Map<String, dynamic>>> searchCustomers(
    String query, {
    String? excludeId,
  }) async {
    final db  = await database;
    final q   = '%${query.toLowerCase()}%';
    final sql = StringBuffer(
      'SELECT * FROM customers WHERE deleted = 0 '
      'AND (LOWER(name) LIKE ? OR LOWER(company_name) LIKE ?)',
    );
    final args = <dynamic>[q, q];
    if (excludeId != null) {
      sql.write(' AND customer_id != ?');
      args.add(excludeId);
    }
    sql.write(' ORDER BY COALESCE(NULLIF(first_name,""), NULLIF(company_name,""), name) ASC LIMIT 10');
    return db.rawQuery(sql.toString(), args);
  }

  /// Insert or update a customer record and write an outbox event.
  Future<void> upsertCustomer({
    required String customerId,
    required String deviceId,
    required String firstName,
    required String lastName,
    String?  companyName,
    String?  phone,
    String?  email,
    String?  address,
    String?  city,
    String?  state,
    String?  zip,
    double   discountPercent = 0.0,
    String   discountType   = 'PERCENT',
    required String eventId,
    required int    seq,
  }) async {
    final db = await database;
    final fullName = [firstName, lastName].where((s) => s.isNotEmpty).join(' ');
    await db.transaction((txn) async {
      await txn.insert(
        'customers',
        {
          'customer_id':     customerId,
          'device_id':       deviceId,
          'name':            fullName,
          'first_name':      firstName,
          'last_name':       lastName,
          'company_name':    companyName,
          'phone':           phone,
          'email':           email,
          'address':         address,
          'city':            city,
          'state':           state,
          'zip':             zip,
          'discount_percent': discountPercent,
          'discount_type':    discountType,
          'deleted':         0,
          'seq':             seq,
          'event_id':        eventId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: eventId, seq: seq,
        entity: 'customer', action: 'upsert',
        payload: {
          'customer_id':     customerId,
          'first_name':      firstName,
          'last_name':       lastName,
          'name':            fullName,
          'company_name':    companyName,
          'phone':           phone,
          'email':           email,
          'address':         address,
          'city':            city,
          'state':           state,
          'zip':             zip,
          'discount_percent': discountPercent,
          'discount_type':    discountType,
        },
      );
    });
  }

  /// Soft-delete a customer (and cascade-delete their vehicles / invoices
  /// locally).  Writes an outbox event so the server mirrors the deletion.
  Future<void> deleteCustomer({
    required String customerId,
    required String deviceId,
    required int    seq,
  }) async {
    final db      = await database;
    final eventId = _uuid();
    await db.transaction((txn) async {
      await txn.update(
        'customers',
        {'deleted': 1, 'seq': seq, 'event_id': eventId},
        where: 'customer_id = ?', whereArgs: [customerId],
      );
      // Cascade soft-delete vehicles
      await txn.update(
        'vehicles',
        {'deleted': 1, 'seq': seq},
        where: 'customer_id = ?', whereArgs: [customerId],
      );
      // Cascade soft-delete invoices
      await txn.update(
        'invoices',
        {'deleted': 1, 'seq': seq},
        where: 'customer_id = ?', whereArgs: [customerId],
      );
      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: eventId, seq: seq,
        entity: 'customer', action: 'delete',
        payload: {'customer_id': customerId},
      );
    });
  }

  // ── Vehicles ──────────────────────────────────────────────────────────────

  /// All non-deleted vehicles for a customer.
  Future<List<Map<String, dynamic>>> getVehicles(String customerId) async {
    final db = await database;
    return db.query(
      'vehicles',
      where: 'customer_id = ? AND deleted = 0',
      whereArgs: [customerId],
      orderBy: 'seq ASC',
    );
  }

  /// Fetch a single vehicle by [vehicleId]. Returns null if not found.
  Future<Map<String, dynamic>?> getVehicle(String vehicleId) async {
    final db   = await database;
    final rows = await db.query(
      'vehicles',
      where: 'vehicle_id = ? AND deleted = 0',
      whereArgs: [vehicleId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Insert or update a vehicle record and write an outbox event.
  Future<void> upsertVehicle({
    required String vehicleId,
    required String customerId,
    required String deviceId,
    String?  vin,
    String?  plate,
    String?  make,
    String?  model,
    String?  year,
    String?  odometer,
    String?  serviceType,
    int?     testIntervalDays,
    String?  nextTestDue,
    required String eventId,
    required int    seq,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      // Preserve existing next_test_due if not explicitly provided
      final existingRows = await txn.query('vehicles',
          columns: ['next_test_due'], where: 'vehicle_id = ?',
          whereArgs: [vehicleId], limit: 1);
      final existingNextTestDue = existingRows.isEmpty ? null
          : existingRows.first['next_test_due'] as String?;

      await txn.insert(
        'vehicles',
        {
          'vehicle_id':        vehicleId,
          'customer_id':       customerId,
          'device_id':         deviceId,
          'vin':               vin,
          'plate':             plate,
          'make':              make,
          'model':             model,
          'year':              year,
          'odometer':          odometer,
          'service_type':      serviceType,
          'test_interval_days': testIntervalDays,
          'next_test_due':     nextTestDue ?? existingNextTestDue,
          'deleted':           0,
          'seq':               seq,
          'event_id':          eventId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: eventId, seq: seq,
        entity: 'vehicle', action: 'upsert',
        payload: {
          'vehicle_id':        vehicleId,
          'customer_id':       customerId,
          'vin':               vin,
          'plate':             plate,
          'make':              make,
          'model':             model,
          'year':              year,
          'odometer':          odometer,
          'service_type':      serviceType,
          'test_interval_days': testIntervalDays,
          'next_test_due':     nextTestDue ?? existingNextTestDue,
        },
      );
    });
  }

  /// Soft-delete a vehicle and write an outbox event.
  Future<void> deleteVehicle({
    required String vehicleId,
    required String deviceId,
    required String eventId,
    required int    seq,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        'vehicles',
        {'deleted': 1, 'seq': seq, 'event_id': eventId},
        where: 'vehicle_id = ?', whereArgs: [vehicleId],
      );
      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: eventId, seq: seq,
        entity: 'vehicle', action: 'delete',
        payload: {'vehicle_id': vehicleId},
      );
    });
  }

  // ── Services ──────────────────────────────────────────────────────────────

  /// All non-deleted services ordered by sort_order.
  Future<List<Map<String, dynamic>>> listServices() async {
    final db = await database;
    return db.query(
      'services',
      where: 'deleted = 0',
      orderBy: 'sort_order ASC, name ASC',
    );
  }

  /// Insert or update a service in the catalogue.
  Future<void> upsertService({
    required String serviceId,
    required String name,
    String?  serviceType,
    required int    defaultPriceCents,
    required int    sortOrder,
  }) async {
    final db = await database;
    await db.insert(
      'services',
      {
        'service_id':           serviceId,
        'name':                 name,
        'service_type':         serviceType,
        'default_price_cents':  defaultPriceCents,
        'sort_order':           sortOrder,
        'deleted':              0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Hard-delete a service from the local catalogue (services are not synced
  /// as events; they are company-level config pulled on login).
  Future<void> deleteService(String serviceId) async {
    final db = await database;
    await db.delete(
      'services',
      where: 'service_id = ?',
      whereArgs: [serviceId],
    );
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Future<String?> getSetting(String key) async {
    final db   = await database;
    final rows = await db.query(
      'settings',
      where: 'key = ?', whereArgs: [key], limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── Accounts ──────────────────────────────────────────────────────────────

  /// All customers that have at least one account-charged invoice, with balance.
  /// Account invoices are those with payment_method IN ('CHARGE','ACCOUNT').
  Future<List<Map<String, dynamic>>> listAccountCustomers() async {
    final db = await database;
    return db.rawQuery('''
      SELECT c.customer_id, c.name, c.first_name, c.last_name, c.company_name,
             c.email, c.phone,
             MAX(0,
               COALESCE((SELECT SUM(amount_cents) FROM invoices
                         WHERE customer_id = c.customer_id AND deleted = 0
                           AND payment_method IN ('CHARGE','ACCOUNT')), 0)
               - COALESCE((SELECT SUM(amount_cents) FROM account_history
                           WHERE customer_id = c.customer_id AND type = 'payment'), 0)
             ) AS balance_cents
      FROM customers c
      WHERE c.deleted = 0
        AND EXISTS (
          SELECT 1 FROM invoices
          WHERE customer_id = c.customer_id AND deleted = 0
            AND payment_method IN ('CHARGE','ACCOUNT')
        )
      ORDER BY COALESCE(NULLIF(c.company_name,''), NULLIF(c.first_name,''), c.name) ASC
    ''');
  }

  /// Account balance for one customer — charge invoices minus payments.
  Future<int> getAccountBalance(String customerId) async {
    final db = await database;
    final inv = await db.rawQuery(
        "SELECT COALESCE(SUM(amount_cents),0) AS t FROM invoices "
        "WHERE customer_id=? AND deleted=0 AND payment_method IN ('CHARGE','ACCOUNT')",
        [customerId]);
    final pay = await db.rawQuery(
        "SELECT COALESCE(SUM(amount_cents),0) AS t FROM account_history "
        "WHERE customer_id=? AND type='payment'",
        [customerId]);
    final invTotal = (inv.first['t'] as num?)?.toInt() ?? 0;
    final payTotal = (pay.first['t'] as num?)?.toInt() ?? 0;
    return (invTotal - payTotal).clamp(0, invTotal);
  }

  /// Account-charged invoices only (payment_method CHARGE or ACCOUNT), not deleted.
  Future<List<Map<String, dynamic>>> getAccountInvoices(String customerId) async {
    final db = await database;
    return db.rawQuery(
        "SELECT * FROM invoices WHERE customer_id=? AND deleted=0 "
        "AND payment_method IN ('CHARGE','ACCOUNT') "
        "ORDER BY invoice_date DESC, invoice_number DESC",
        [customerId]);
  }

  /// Payment records from account_history for this customer (type='payment' only).
  Future<List<Map<String, dynamic>>> getAccountPayments(String customerId) async {
    final db = await database;
    return db.query('account_history',
        where: "customer_id = ? AND type = 'payment'",
        whereArgs: [customerId],
        orderBy: 'entry_date DESC, id DESC');
  }

  /// Auto-generate next PMT-XXXX number.
  Future<String> getNextPaymentNumber() async {
    final db = await database;
    final rows = await db.rawQuery(
        "SELECT MAX(CAST(REPLACE(payment_number,'PMT-','') AS INTEGER)) AS mx "
        "FROM account_history WHERE payment_number LIKE 'PMT-%'");
    final mx = rows.isEmpty ? 0 : (rows.first['mx'] as int? ?? 0);
    return 'PMT-${(mx + 1).toString().padLeft(4, '0')}';
  }

  /// Compute unpaid invoices for [customerId] with effective remaining balance,
  /// accounting for prior partial payments. Returns list oldest-first.
  Future<List<Map<String, dynamic>>> getUnpaidInvoicesWithRemaining(
      String customerId) async {
    final db = await database;

    // Collect fully-paid invoice UUIDs
    final paidRows = await db.rawQuery(
        "SELECT invoice_id FROM account_history "
        "WHERE customer_id=? AND type='payment'",
        [customerId]);
    final paidIds = <String>{};
    for (final r in paidRows) {
      for (final uid in (r['invoice_id'] as String? ?? '').split(',')) {
        final u = uid.trim();
        if (u.isNotEmpty) paidIds.add(u);
      }
    }

    // Accumulate prior partial amounts per invoice UUID
    final partialApplied = <String, double>{};
    final partialRows = await db.rawQuery(
        "SELECT partial_json FROM account_history "
        "WHERE customer_id=? AND type='payment'",
        [customerId]);
    for (final r in partialRows) {
      try {
        final pj = (r['partial_json'] as String? ?? '{}');
        if (pj.isEmpty || pj == '{}') continue;
        // parse simple JSON map manually to avoid extra dependencies
        // format: {"uuid": amount, ...}
        final stripped = pj.replaceAll('{', '').replaceAll('}', '').trim();
        for (final pair in stripped.split(',')) {
          final parts = pair.split(':');
          if (parts.length != 2) continue;
          final key = parts[0].trim().replaceAll('"', '');
          final val = double.tryParse(parts[1].trim()) ?? 0.0;
          if (key.isNotEmpty) {
            partialApplied[key] = (partialApplied[key] ?? 0.0) + val;
          }
        }
      } catch (_) {}
    }

    // Build unpaid list with effective remaining
    final invRows = await db.rawQuery(
        "SELECT invoice_id, invoice_number, amount_cents, invoice_date "
        "FROM invoices WHERE customer_id=? AND deleted=0 "
        "AND payment_method IN ('CHARGE','ACCOUNT') "
        "ORDER BY invoice_date ASC, invoice_number ASC",
        [customerId]);

    final result = <Map<String, dynamic>>[];
    for (final r in invRows) {
      final uuid = (r['invoice_id'] as String? ?? '');
      if (paidIds.contains(uuid)) continue;
      final fullAmt  = ((r['amount_cents'] as int? ?? 0)) / 100.0;
      final already  = partialApplied[uuid] ?? 0.0;
      final remaining = (fullAmt - already).clamp(0.0, fullAmt);
      if (remaining < 0.005) continue;
      result.add({
        'uuid':       uuid,
        'num':        r['invoice_number'],
        'full':       fullAmt,
        'remaining':  remaining,
        'wasPartial': already > 0.005,
      });
    }
    return result;
  }

  /// Post a payment with auto-apply to oldest invoices. Returns a breakdown
  /// map with keys: fullyPaid (List), partial (Map?), partialJsonStr (String).
  Future<void> postPayment({
    required String customerId,
    required String deviceId,
    required String entryDate,
    required int amountCents,
    required String note,
    required List<String> invoiceIds,  // fully-covered invoice UUIDs
    required String paymentNumber,
    required String paymentId,         // UUID for cross-device dedup
    String partialJson = '{}',         // partial tracking JSON
  }) async {
    final db  = await database;
    final seq = DateTime.now().millisecondsSinceEpoch;
    final custRows = await db.query('customers', columns: ['company_name'],
        where: 'customer_id = ?', whereArgs: [customerId], limit: 1);
    final companyName = custRows.isEmpty
        ? '' : (custRows.first['company_name'] as String? ?? '');
    final invoiceIdStr = invoiceIds.join(',');

    await db.transaction((txn) async {
      await txn.insert('account_history', {
        'customer_id':    customerId,
        'entry_date':     entryDate,
        'type':           'payment',
        'amount_cents':   amountCents,
        'note':           note,
        'invoice_id':     invoiceIdStr,
        'payment_number': paymentNumber,
        'payment_id':     paymentId,
        'partial_json':   partialJson,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await _addOutboxEntry(txn,
        deviceId: deviceId,
        eventId:  paymentId,
        seq:      seq,
        entity:   'account_payment',
        action:   'upsert',
        payload: {
          'payment_id':     paymentId,
          'customer_id':    customerId,
          'company_name':   companyName,
          'entry_date':     entryDate,
          'amount_cents':   amountCents,
          'note':           note,
          'invoice_id':     invoiceIdStr,
          'payment_number': paymentNumber,
          'partial_json':   partialJson,
        },
      );
    });
  }

  /// Add [deltaCents] to a customer's account balance (creates row if absent).
  Future<void> addToAccountBalance(String customerId, int deltaCents) async {
    final db      = await database;
    final current = await getAccountBalance(customerId);
    final newBal  = current + deltaCents;
    final now     = DateTime.now().toIso8601String();
    await db.insert(
      'accounts',
      {
        'customer_id':   customerId,
        'balance_cents': newBal,
        'updated_at':    now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── Invoices ──────────────────────────────────────────────────────────────

  /// Latest [limit] non-deleted invoices for a customer, newest first.
  Future<List<Map<String, dynamic>>> latestInvoices({
    required String customerId,
    int limit = 50,
  }) async {
    final db = await database;
    return db.query(
      'invoices',
      where: 'customer_id = ? AND deleted = 0',
      whereArgs: [customerId],
      orderBy: 'seq DESC',
      limit: limit,
    );
  }

  /// All items for an invoice.
  Future<List<Map<String, dynamic>>> getInvoiceItems(String invoiceId) async {
    final db = await database;
    return db.query(
      'invoice_items',
      where: 'invoice_id = ? AND deleted = 0',
      whereArgs: [invoiceId],
      orderBy: 'seq ASC',
    );
  }

  // ── Outbox / Sync ─────────────────────────────────────────────────────────

  /// Unsent outbox rows for this device, ordered by seq.
  Future<List<Map<String, dynamic>>> getPendingOutbox(String deviceId) async {
    final db = await database;
    return db.query(
      'outbox',
      where: 'device_id = ? AND sent = 0',
      whereArgs: [deviceId],
      orderBy: 'seq ASC',
    );
  }

  /// Mark all outbox rows with seq ≤ [maxSeq] as sent.
  Future<void> markOutboxSent(String deviceId, int maxSeq) async {
    final db = await database;
    await db.update(
      'outbox',
      {'sent': 1},
      where: 'device_id = ? AND seq <= ?',
      whereArgs: [deviceId, maxSeq],
    );
  }

  /// Apply a list of events pulled from the server.
  /// Returns the highest seq seen (or [current] if events is empty).
  Future<int> applyRemoteEvents({
    required String deviceId,
    required List<dynamic> events,
  }) async {
    final db = await database;
    int maxSeq = 0;

    await db.transaction((txn) async {
      for (final raw in events) {
        final e       = raw as Map<String, dynamic>;
        final entity  = (e['entity']  ?? '').toString();
        final action  = (e['action']  ?? '').toString();
        final seq     = (e['seq']     as num).toInt();
        final eventId = (e['event_id'] ?? '').toString();
        final payload = (e['payload'] as Map<String, dynamic>?) ?? {};

        if (seq > maxSeq) maxSeq = seq;

        switch (entity) {
          case 'customer':
            if (action == 'upsert') {
              await txn.insert('customers', {
                'customer_id':     payload['customer_id'],
                'device_id':       deviceId,
                'name':            payload['name'] ?? '',
                'first_name':      payload['first_name'] ?? '',
                'last_name':       payload['last_name'] ?? '',
                'company_name':    payload['company_name'],
                'phone':           payload['phone'],
                'email':           payload['email'],
                'address':         payload['address'],
                'city':            payload['city'],
                'state':           payload['state'],
                'zip':             payload['zip'],
                'discount_percent': (payload['discount_percent'] as num?)?.toDouble() ?? 0.0,
                'discount_type':    (payload['discount_type'] ?? 'PERCENT').toString(),
                'deleted':         0,
                'seq':             seq,
                'event_id':        eventId,
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            } else if (action == 'delete') {
              await txn.update('customers',
                {'deleted': 1, 'seq': seq},
                where: 'customer_id = ?',
                whereArgs: [payload['customer_id']]);
            }
            break;

          case 'vehicle':
            if (action == 'upsert') {
              // Preserve existing test due fields if server payload doesn't include them
              final existingVRows = await txn.query('vehicles',
                  columns: ['test_interval_days', 'next_test_due'],
                  where: 'vehicle_id = ?',
                  whereArgs: [payload['vehicle_id']], limit: 1);
              final existingInterval = existingVRows.isEmpty ? null
                  : existingVRows.first['test_interval_days'] as int?;
              final existingNextDue = existingVRows.isEmpty ? null
                  : existingVRows.first['next_test_due'] as String?;

              await txn.insert('vehicles', {
                'vehicle_id':        payload['vehicle_id'],
                'customer_id':       payload['customer_id'],
                'device_id':         deviceId,
                'vin':               payload['vin'],
                'plate':             payload['plate'],
                'make':              payload['make'],
                'model':             payload['model'],
                'year':              payload['year'],
                'odometer':          payload['odometer'],
                'service_type':      payload['service_type'],
                'test_interval_days': payload['test_interval_days'] ?? existingInterval,
                'next_test_due':     payload['next_test_due'] ?? existingNextDue,
                'deleted':           0,
                'seq':               seq,
                'event_id':          eventId,
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            } else if (action == 'delete') {
              await txn.update('vehicles',
                {'deleted': 1, 'seq': seq},
                where: 'vehicle_id = ?',
                whereArgs: [payload['vehicle_id']]);
            }
            break;

          case 'invoice':
            if (action == 'upsert') {
              // Preserve local-only fields that the server doesn't store
              final existingRows = await txn.query(
                'invoices',
                columns: ['signature_path'],
                where: 'invoice_id = ?',
                whereArgs: [payload['invoice_id']],
                limit: 1,
              );
              final existingSigPath = existingRows.isEmpty
                  ? null
                  : existingRows.first['signature_path'] as String?;

              await txn.insert('invoices', {
                'invoice_id':     payload['invoice_id'],
                'customer_id':    payload['customer_id'],
                'device_id':      deviceId,
                'customer_name':  payload['customer_name'],
                'payment_method': payload['payment_method'],
                'notes':          payload['notes'],
                'invoice_number': payload['invoice_number'],
                'invoice_date':   payload['invoice_date'],
                'status':         payload['status'] ?? 'ESTIMATE',
                'amount_cents':   payload['amount_cents'] ?? 0,
                'finalized':      payload['finalized'] ?? 0,
                'pdf_uploaded':   payload['pdf_uploaded'] ?? 0,
                'vin':            payload['vin'] ?? '',
                'plate':          payload['plate'] ?? '',
                'year':           payload['year'] ?? '',
                'make':           payload['make'] ?? '',
                'model':          payload['model'] ?? '',
                'account_id':     (payload['account_id'] ?? '').toString(),
                'po_number':      (payload['po_number']   ?? '').toString(),
                'owner_first':    (payload['owner_first'] ?? '').toString(),
                'owner_last':     (payload['owner_last']  ?? '').toString(),
                'deleted':        0,
                'seq':            seq,
                'event_id':       eventId,
                // Preserve local signature path — server never sends this field
                if (existingSigPath != null && existingSigPath.isNotEmpty)
                  'signature_path': existingSigPath,
              }, conflictAlgorithm: ConflictAlgorithm.replace);

              // Auto-create vehicle from invoice header if VIN/plate present
              // (handles desktop-created invoices where vehicle event may not arrive)
              final invVin    = (payload['vin']   ?? '').toString().trim();
              final invPlate  = (payload['plate'] ?? '').toString().trim();
              final invCustId = (payload['customer_id'] ?? '').toString().trim();
              if ((invVin.isNotEmpty || invPlate.isNotEmpty) && invCustId.isNotEmpty) {
                List<Map<String, dynamic>> existingV = [];
                if (invVin.isNotEmpty) {
                  existingV = await txn.query('vehicles',
                    where: 'vin = ? AND customer_id = ? AND deleted = 0',
                    whereArgs: [invVin, invCustId], limit: 1);
                }
                if (existingV.isEmpty && invPlate.isNotEmpty) {
                  existingV = await txn.query('vehicles',
                    where: 'plate = ? AND customer_id = ? AND deleted = 0',
                    whereArgs: [invPlate, invCustId], limit: 1);
                }
                if (existingV.isEmpty) {
                  await txn.insert('vehicles', {
                    'vehicle_id':   const Uuid().v4(),
                    'customer_id':  invCustId,
                    'device_id':    deviceId,
                    'vin':          invVin,
                    'plate':        invPlate,
                    'year':         (payload['year']  ?? '').toString(),
                    'make':         (payload['make']  ?? '').toString(),
                    'model':        (payload['model'] ?? '').toString(),
                    'odometer':     '',
                    'service_type': '',
                    'deleted':      0,
                    'seq':          seq,
                    'event_id':     eventId,
                  }, conflictAlgorithm: ConflictAlgorithm.ignore);
                }
              }
            } else if (action == 'delete') {
              await txn.update('invoices',
                {'deleted': 1, 'seq': seq},
                where: 'invoice_id = ?',
                whereArgs: [payload['invoice_id']]);
            }
            break;

          case 'service':
            if (action == 'upsert') {
              await txn.insert('services', {
                'service_id':          payload['service_id'],
                'name':                (payload['name'] ?? '').toString(),
                'service_type':        (payload['service_type'] ?? '').toString(),
                'default_price_cents': (payload['default_price_cents'] as int?)
                    ?? (payload['price_cents'] as int?) ?? 0,
                'sort_order':          (payload['sort_order'] as int?) ?? 0,
                'deleted':             0,
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            } else if (action == 'delete') {
              await txn.update('services',
                {'deleted': 1},
                where: 'service_id = ?',
                whereArgs: [payload['service_id']]);
            }
            break;

          case 'setting':
            if (action == 'upsert') {
              final k = (payload['key'] ?? '').toString();
              final v = (payload['value'] ?? '').toString();
              if (k.isNotEmpty) {
                await txn.insert('settings',
                  {'key': k, 'value': v},
                  conflictAlgorithm: ConflictAlgorithm.replace);
              }
            }
            break;

          case 'invoice_item':
            if (action == 'upsert') {
              // Resolve unit_price_cents: prefer explicit field, fall back to
              // legacy 'price' field. Old events stored 'price' as amount_cents
              // (the full invoice total in cents); new events always have unit_price_cents.
              final rawUnitPrice = payload['unit_price_cents'] ?? payload['price'] ?? 0;
              final resolvedUnitPriceCents = (rawUnitPrice is double)
                  ? rawUnitPrice.round()
                  : (rawUnitPrice as num).toInt();
              await txn.insert('invoice_items', {
                'item_id':          payload['item_id'],
                'invoice_id':       payload['invoice_id'],
                'vehicle_id':       payload['vehicle_id'] ?? '',
                'name':             payload['name'] ?? payload['service'] ?? '',
                'vin':              payload['vin'] ?? '',
                'plate':            payload['plate'] ?? '',
                'year':             payload['year'] ?? '',
                'make':             payload['make'] ?? '',
                'model':            payload['model'] ?? '',
                'qty':              payload['qty'] ?? 1,
                'unit_price_cents': resolvedUnitPriceCents,
                'discount_cents':   (payload['discount_cents'] as int?) ?? 0,
                'result':           (payload['result'] ?? '').toString(),
                'cert':             (payload['cert'] ?? '').toString(),
                'odometer':         payload['odometer'] ?? '',
                'deleted':          0,
                'seq':              seq,
                'event_id':         eventId,
              }, conflictAlgorithm: ConflictAlgorithm.replace);
              // Recalc invoice total after every item insert/update
              final iid = payload['invoice_id']?.toString() ?? '';
              if (iid.isNotEmpty) {
                await _recalcInvoiceTotal(txn, iid, seq);
                // Also patch vehicle fields on the invoice header so the list view shows them
                await _patchInvoiceVehicle(txn, iid, payload);
              }
              // Auto-create/update vehicle record from item data if VIN or plate present
              final itemVin   = payload['vin']?.toString()   ?? '';
              final itemPlate = payload['plate']?.toString() ?? '';
              if (itemVin.isNotEmpty || itemPlate.isNotEmpty) {
                // Look up the customer_id from the parent invoice
                final invRows = await txn.query('invoices',
                  columns: ['customer_id'],
                  where: 'invoice_id = ? AND deleted = 0',
                  whereArgs: [iid], limit: 1);
                if (invRows.isNotEmpty) {
                  final custId = invRows.first['customer_id']?.toString() ?? '';
                  if (custId.isNotEmpty) {
                    // Find existing vehicle by VIN first, then plate
                    List<Map<String, dynamic>> existing = [];
                    if (itemVin.isNotEmpty) {
                      existing = await txn.query('vehicles',
                        where: 'vin = ? AND deleted = 0',
                        whereArgs: [itemVin], limit: 1);
                    }
                    if (existing.isEmpty && itemPlate.isNotEmpty) {
                      existing = await txn.query('vehicles',
                        where: 'plate = ? AND deleted = 0',
                        whereArgs: [itemPlate], limit: 1);
                    }
                    final vid = existing.isNotEmpty
                        ? existing.first['vehicle_id'].toString()
                        : (payload['vehicle_id']?.toString().isNotEmpty == true
                            ? payload['vehicle_id'].toString()
                            : const Uuid().v4());
                    await txn.insert('vehicles', {
                      'vehicle_id':   vid,
                      'customer_id':  custId,
                      'device_id':    deviceId,
                      'vin':          itemVin,
                      'plate':        itemPlate,
                      'make':         payload['make']?.toString()     ?? '',
                      'model':        payload['model']?.toString()    ?? '',
                      'year':         payload['year']?.toString()     ?? '',
                      'odometer':     payload['odometer']?.toString() ?? '',
                      'service_type': '',
                      'deleted':      0,
                      'seq':          seq,
                      'event_id':     eventId,
                    }, conflictAlgorithm: ConflictAlgorithm.replace);
                  }
                }
              }
            } else if (action == 'delete') {
              await txn.update('invoice_items',
                {'deleted': 1, 'seq': seq},
                where: 'item_id = ?',
                whereArgs: [payload['item_id']]);
              // Recalc after delete too
              final iid = payload['invoice_id']?.toString() ?? '';
              if (iid.isNotEmpty) {
                await _recalcInvoiceTotal(txn, iid, seq);
              }
            }
            break;

          case 'account_payment':
            if (action == 'upsert') {
              final paymentId = (payload['payment_id'] ?? '').toString();
              if (paymentId.isEmpty) break;
              // Dedup — skip if already have this payment
              final existing = await txn.query('account_history',
                  where: 'payment_id = ?', whereArgs: [paymentId], limit: 1);
              if (existing.isNotEmpty) break;

              // Resolve customer_id
              var customerId = (payload['customer_id'] ?? '').toString();
              if (customerId.isEmpty) {
                // Try company_name lookup
                final companyName = (payload['company_name'] ?? '').toString();
                if (companyName.isNotEmpty) {
                  final rows = await txn.query('customers', columns: ['customer_id'],
                      where: 'UPPER(company_name) = UPPER(?)',
                      whereArgs: [companyName], limit: 1);
                  if (rows.isNotEmpty) customerId = rows.first['customer_id']?.toString() ?? '';
                }
              }
              if (customerId.isEmpty) {
                // Try resolving from referenced invoice UUIDs
                for (final iid in (payload['invoice_id'] ?? '').toString().split(',')) {
                  final trimmed = iid.trim();
                  if (trimmed.isEmpty) continue;
                  final rows = await txn.query('invoices', columns: ['customer_id'],
                      where: 'invoice_id = ?', whereArgs: [trimmed], limit: 1);
                  if (rows.isNotEmpty) {
                    customerId = rows.first['customer_id']?.toString() ?? '';
                    if (customerId.isNotEmpty) break;
                  }
                }
              }
              if (customerId.isEmpty) break;

              final amountCents = (payload['amount_cents'] as num?)?.toInt() ?? 0;
              await txn.insert('account_history', {
                'customer_id':    customerId,
                'entry_date':     (payload['entry_date'] ?? '').toString(),
                'type':           'payment',
                'amount_cents':   amountCents,
                'note':           (payload['note'] ?? '').toString(),
                'invoice_id':     (payload['invoice_id'] ?? '').toString(),
                'payment_number': (payload['payment_number'] ?? '').toString(),
                'payment_id':     paymentId,
                'partial_json':   (payload['partial_json'] ?? '{}').toString(),
              }, conflictAlgorithm: ConflictAlgorithm.ignore);

            } else if (action == 'delete') {
              final paymentId = (payload['payment_id'] ?? '').toString();
              if (paymentId.isNotEmpty) {
                await txn.delete('account_history',
                    where: 'payment_id = ?', whereArgs: [paymentId]);
              }
            }
            break;

          case 'company_settings':
            if (action == 'upsert') {
              // Map desktop field names → mobile setting keys
              final fieldMap = {
                'co_name':              payload['co_name'],
                'co_addr':              payload['co_addr'],
                'co_city':              payload['co_city'],
                'co_phone':             payload['co_phone'],
                'co_email':             payload['co_email'],
                'co_ard':               payload['co_ard'],
                'invoice_notice':       payload['invoice_notice'],
                'card_surcharge_value': payload['card_surcharge_value'],
                'card_surcharge_type':  payload['card_surcharge_type'],
              };
              for (final entry in fieldMap.entries) {
                if (entry.value != null) {
                  await txn.insert(
                    'settings',
                    {'key': entry.key, 'value': entry.value.toString()},
                    conflictAlgorithm: ConflictAlgorithm.replace,
                  );
                }
              }
            }
            break;
        }
      }
    });

    return maxSeq;
  }

  // ── Invoices (extended) ───────────────────────────────────────────────────

  /// Fetch a single invoice by [invoiceId]. Returns null if not found.
  Future<Map<String, dynamic>?> getInvoice(String invoiceId) async {
    final db   = await database;
    final rows = await db.query(
      'invoices',
      where: 'invoice_id = ? AND deleted = 0',
      whereArgs: [invoiceId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Return all open (non-finalized, non-deleted) estimates ordered by date.
  Future<List<Map<String, dynamic>>> getOpenEstimates() async {
    final db = await database;
    return db.rawQuery('''
      SELECT invoice_id, invoice_number, invoice_date, customer_name,
             amount_cents, status, payment_method
      FROM invoices
      WHERE deleted = 0 AND finalized = 0
      ORDER BY invoice_date DESC, invoice_number DESC
    ''');
  }

  /// Return by-service revenue summary for a date range (finalized invoices only).
  Future<List<Map<String, dynamic>>> getByServiceReport(
      String startDate, String endDate) async {
    final db = await database;
    return db.rawQuery('''
      SELECT
        ii.name AS service_name,
        COUNT(*)                                               AS count,
        COALESCE(SUM(ii.unit_price_cents - ii.discount_cents), 0) AS total_cents
      FROM invoice_items ii
      JOIN invoices inv ON ii.invoice_id = inv.invoice_id
      WHERE inv.deleted = 0
        AND inv.finalized = 1
        AND inv.status != 'ESTIMATE'
        AND inv.invoice_date >= ?
        AND inv.invoice_date <= ?
        AND ii.deleted = 0
      GROUP BY ii.name
      ORDER BY total_cents DESC
    ''', [startDate, endDate]);
  }

  /// Return by-payment-type revenue summary for a date range.
  Future<List<Map<String, dynamic>>> getByPaymentReport(
      String startDate, String endDate) async {
    final db = await database;
    return db.rawQuery('''
      SELECT
        COALESCE(NULLIF(payment_method,''), 'OTHER') AS method,
        COUNT(*)                                     AS count,
        COALESCE(SUM(amount_cents), 0)               AS total_cents
      FROM invoices
      WHERE deleted = 0
        AND finalized = 1
        AND status != 'ESTIMATE'
        AND invoice_date >= ?
        AND invoice_date <= ?
      GROUP BY method
      ORDER BY total_cents DESC
    ''', [startDate, endDate]);
  }

  /// Create a brand-new invoice row and enqueue an outbox event.
  Future<void> createInvoiceAndEnqueueUpsert({
    required String invoiceId,
    required String deviceId,
    required String customerId,
    required String customerName,
    required String paymentMethod,
    required String status,
    String?  notes,
    required String invoiceDate,
    required String eventId,
    required int    seq,
    String? vin,
    String? plate,
    String? year,
    String? make,
    String? model,
    String? poNumber,
    String? ownerFirst,
    String? ownerLast,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'invoices',
        {
          'invoice_id':     invoiceId,
          'customer_id':    customerId,
          'device_id':      deviceId,
          'customer_name':  customerName,
          'payment_method': paymentMethod,
          'invoice_date':   invoiceDate,
          'status':         status,
          'notes':          notes,
          'amount_cents':   0,
          'finalized':      0,
          'pdf_uploaded':   0,
          'deleted':        0,
          'seq':            seq,
          'event_id':       eventId,
          if (vin        != null) 'vin':         vin,
          if (plate      != null) 'plate':       plate,
          if (year       != null) 'year':        year,
          if (make       != null) 'make':        make,
          if (model      != null) 'model':       model,
          if (poNumber   != null) 'po_number':   poNumber,
          if (ownerFirst != null) 'owner_first': ownerFirst,
          if (ownerLast  != null) 'owner_last':  ownerLast,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: eventId, seq: seq,
        entity: 'invoice', action: 'upsert',
        payload: {
          'invoice_id':     invoiceId,
          'customer_id':    customerId,
          'customer_name':  customerName,
          'payment_method': paymentMethod,
          'invoice_date':   invoiceDate,
          'status':         status,
          'notes':          notes,
          'amount_cents':   0,
          'finalized':      0,
          'vin':            vin,
          'plate':          plate,
          'year':           year,
          'make':           make,
          'model':          model,
          'po_number':      poNumber,
          'owner_first':    ownerFirst,
          'owner_last':     ownerLast,
        },
      );
    });
  }

  /// Update an existing invoice and enqueue an outbox upsert event.
  Future<void> updateInvoiceAndEnqueueUpsert({
    required String invoiceId,
    required String deviceId,
    required String customerId,
    required String customerName,
    required String paymentMethod,
    required String status,
    String?  notes,
    required String invoiceDate,
    required String eventId,
    required int    seq,
    String? poNumber,
    String? ownerFirst,
    String? ownerLast,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        'invoices',
        {
          'customer_id':    customerId,
          'customer_name':  customerName,
          'payment_method': paymentMethod,
          'invoice_date':   invoiceDate,
          'status':         status,
          'notes':          notes,
          'seq':            seq,
          'event_id':       eventId,
          'po_number':      poNumber,
          'owner_first':    ownerFirst,
          'owner_last':     ownerLast,
        },
        where: 'invoice_id = ?',
        whereArgs: [invoiceId],
      );
      // Fetch current amount to include in outbox payload
      final rows = await txn.query('invoices',
          columns: ['amount_cents'],
          where: 'invoice_id = ?', whereArgs: [invoiceId], limit: 1);
      final cents = rows.isEmpty ? 0 : (rows.first['amount_cents'] as int? ?? 0);
      // Fetch vehicle/extra fields from the invoice row so they sync correctly
      final invRow2 = await txn.query('invoices',
          where: 'invoice_id = ?', whereArgs: [invoiceId], limit: 1);
      final iv2 = invRow2.isEmpty ? <String,Object?>{} : invRow2.first;
      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: eventId, seq: seq,
        entity: 'invoice', action: 'upsert',
        payload: {
          'invoice_id':     invoiceId,
          'customer_id':    customerId,
          'customer_name':  customerName,
          'payment_method': paymentMethod,
          'invoice_date':   invoiceDate,
          'status':         status,
          'notes':          notes,
          'amount_cents':   cents,
          'finalized':      0,
          'vin':         iv2['vin']         ?? '',
          'plate':       iv2['plate']       ?? '',
          'year':        iv2['year']        ?? '',
          'make':        iv2['make']        ?? '',
          'model':       iv2['model']       ?? '',
          'po_number':   poNumber   ?? iv2['po_number']   ?? '',
          'owner_first': ownerFirst ?? iv2['owner_first'] ?? '',
          'owner_last':  ownerLast  ?? iv2['owner_last']  ?? '',
        },
      );
    });
  }

  /// Add a service line item to an invoice and recalculate the total.
  Future<void> addItem({
    required String invoiceId,
    required String itemId,
    required String deviceId,
    required int    seq,
    required String eventId,
    required String name,
    required double qty,
    required int    unitPriceCents,
    int     discountCents = 0,
    String  result = '',
    String  cert   = '',
    String? vehicleId,
    String? odometer,
    String? vin,
    String? plate,
    String? year,
    String? make,
    String? model,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'invoice_items',
        {
          'item_id':          itemId,
          'invoice_id':       invoiceId,
          'vehicle_id':       vehicleId,
          'name':             name,
          'qty':              qty,
          'unit_price_cents': unitPriceCents,
          'discount_cents':   discountCents,
          'result':           result,
          'cert':             cert,
          'odometer':         odometer,
          'vin':              vin,
          'plate':            plate,
          'year':             year,
          'make':             make,
          'model':            model,
          'deleted':          0,
          'seq':              seq,
          'event_id':         eventId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      // Recalculate invoice total and patch invoice header vehicle fields
      await _recalcInvoiceTotal(txn, invoiceId, seq);
      final itemPayloadForPatch = {
        'vin': vin, 'plate': plate, 'year': year, 'make': make, 'model': model,
      };
      await _patchInvoiceVehicle(txn, invoiceId, itemPayloadForPatch);

      // Re-read invoice to get updated amount_cents + vehicle fields for the outbox
      final invRows = await txn.query('invoices',
          where: 'invoice_id = ?', whereArgs: [invoiceId], limit: 1);
      final invRow = invRows.isNotEmpty ? invRows.first : <String, dynamic>{};
      final updatedCents = (invRow['amount_cents'] as int?) ?? 0;

      // Push updated invoice upsert so desktop list view gets vehicle info.
      // Prefer the item's vehicle fields over the invoice header — the item
      // always has fresh vehicle data even when the header is blank.
      final effVin   = (vin   ?? (invRow['vin']   as String?));
      final effPlate = (plate ?? (invRow['plate'] as String?));
      final effYear  = (year  ?? (invRow['year']  as String?));
      final effMake  = (make  ?? (invRow['make']  as String?));
      final effModel = (model ?? (invRow['model'] as String?));
      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: const Uuid().v4(), seq: seq + 1,
        entity: 'invoice', action: 'upsert',
        payload: {
          'invoice_id':     invoiceId,
          'customer_id':    invRow['customer_id'],
          'customer_name':  invRow['customer_name'],
          'payment_method': invRow['payment_method'],
          'invoice_date':   invRow['invoice_date'],
          'invoice_number': invRow['invoice_number'],
          'status':         invRow['status'],
          'notes':          invRow['notes'],
          'amount_cents':   updatedCents,
          'finalized':      invRow['finalized'] ?? 0,
          'vin':            effVin,
          'plate':          effPlate,
          'year':           effYear,
          'make':           effMake,
          'model':          effModel,
        },
      );

      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: eventId, seq: seq,
        entity: 'invoice_item', action: 'upsert',
        payload: {
          'item_id':          itemId,
          'invoice_id':       invoiceId,
          'vehicle_id':       vehicleId,
          'name':             name,
          'service':          name,          // desktop reads 'service' first
          'qty':              qty,
          'unit_price_cents': unitPriceCents,
          'discount_cents':   discountCents,
          'discount':         discountCents / 100.0, // desktop reads 'discount' in dollars
          'result':           result,
          'cert':             cert,
          'odometer':         odometer,
          'vin':              vin,
          'plate':            plate,
          'year':             year,
          'make':             make,
          'model':            model,
        },
      );
    });
  }

  /// Soft-delete a line item and recalculate the invoice total.
  /// [localId] is the SQLite rowid; [itemId] is the UUID used in events.
  Future<void> deleteItem(
    int    localId,
    String itemId,
    String invoiceId,
    String deviceId,
    int    seq,
    String eventId,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        'invoice_items',
        {'deleted': 1, 'seq': seq, 'event_id': eventId},
        where: 'id = ?',
        whereArgs: [localId],
      );
      await _recalcInvoiceTotal(txn, invoiceId, seq);
      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: eventId, seq: seq,
        entity: 'invoice_item', action: 'delete',
        payload: {'item_id': itemId, 'invoice_id': invoiceId},
      );
    });
  }

  /// Lock an invoice: set status=PAID, finalized=1, record payment method,
  /// and queue an outbox event so the server mirrors the change.
  /// If paymentMethod is CHARGE, the invoice amount is added to the customer's
  /// account balance (accounts receivable).
  Future<void> finalizeInvoice({
    required String invoiceId,
    required String deviceId,
    required String eventId,
    required int    seq,
    required String paymentMethod,
  }) async {
    final db = await database;
    // Read invoice data before the transaction for use after
    final preRows = await db.query('invoices',
        columns: ['amount_cents', 'customer_id', 'customer_name', 'invoice_date'],
        where: 'invoice_id = ?', whereArgs: [invoiceId], limit: 1);
    final preRow   = preRows.isEmpty ? <String, Object?>{} : preRows.first;
    final cents    = (preRow['amount_cents'] as int?) ?? 0;
    final custId   = (preRow['customer_id']?.toString() ?? '');

    await db.transaction((txn) async {
      await txn.update(
        'invoices',
        {
          'status':         'PAID',
          'finalized':      1,
          'payment_method': paymentMethod,
          'seq':            seq,
          'event_id':       eventId,
        },
        where: 'invoice_id = ?',
        whereArgs: [invoiceId],
      );
      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: eventId, seq: seq,
        entity: 'invoice', action: 'upsert',
        payload: {
          'invoice_id':     invoiceId,
          'customer_id':    preRow['customer_id'],
          'customer_name':  preRow['customer_name'],
          'payment_method': paymentMethod,
          'invoice_date':   preRow['invoice_date'],
          'status':         'PAID',
          'finalized':      1,
          'amount_cents':   cents,
        },
      );
    });

    // If CHARGE payment, add invoice amount to customer's AR balance
    if (paymentMethod.toUpperCase() == 'CHARGE' && cents > 0 && custId.isNotEmpty) {
      await addToAccountBalance(custId, cents);
    }
  }

  /// Mark an invoice's PDF as successfully uploaded to the server.
  Future<void> markPdfUploaded(String invoiceId) async {
    final db = await database;
    await db.update(
      'invoices',
      {'pdf_uploaded': 1},
      where: 'invoice_id = ?',
      whereArgs: [invoiceId],
    );
  }

  Future<void> saveSignaturePath(String invoiceId, String path) async {
    final db = await database;
    await db.update(
      'invoices',
      {'signature_path': path},
      where: 'invoice_id = ?',
      whereArgs: [invoiceId],
    );
  }

  /// Update the next_test_due date for a vehicle based on invoice date + interval.
  Future<void> updateVehicleTestDue(String vehicleId, String nextTestDue) async {
    final db = await database;
    await db.update('vehicles', {'next_test_due': nextTestDue},
        where: 'vehicle_id = ? AND deleted = 0', whereArgs: [vehicleId]);
  }

  /// Returns the most recent finalized invoice_date for a vehicle, or null if none.
  Future<String?> getLastFinalizedInvoiceDateForVehicle(String vehicleId) async {
    final db = await database;
    // invoices store the vehicle VIN/plate/etc but not vehicle_id directly;
    // look up via invoice_items which do store vehicle_id
    final rows = await db.rawQuery('''
      SELECT i.invoice_date
      FROM invoices i
      JOIN invoice_items ii ON ii.invoice_id = i.invoice_id
      WHERE ii.vehicle_id = ?
        AND i.finalized = 1
        AND i.deleted = 0
      ORDER BY i.invoice_date DESC
      LIMIT 1
    ''', [vehicleId]);
    if (rows.isEmpty) return null;
    return rows.first['invoice_date'] as String?;
  }

  /// Get all vehicles with a next_test_due within the next [days] days (default 90).
  Future<List<Map<String, dynamic>>> getVehiclesDueSoon({int days = 90}) async {
    final db = await database;
    final now    = DateTime.now();
    final cutoff = now.add(Duration(days: days));
    final nowStr    = now.toIso8601String().substring(0, 10);
    final cutoffStr = cutoff.toIso8601String().substring(0, 10);
    return db.rawQuery('''
      SELECT v.*, c.company_name, c.first_name, c.last_name, c.phone
      FROM vehicles v
      LEFT JOIN customers c ON c.customer_id = v.customer_id
      WHERE v.deleted = 0
        AND v.next_test_due IS NOT NULL
        AND v.next_test_due != ''
        AND v.next_test_due >= ?
        AND v.next_test_due <= ?
      ORDER BY v.next_test_due ASC
    ''', [nowStr, cutoffStr]);
  }

  /// Soft-delete an invoice (and its items) and queue a delete event.
  /// Soft-delete invoice on this device only — no outbox event, no server sync.
  /// Used for finalized invoices where the server record should be preserved.
  Future<void> deleteInvoiceLocal({required String invoiceId}) async {
    final db = await database;
    final seq = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update('invoices', {'deleted': 1, 'seq': seq},
          where: 'invoice_id = ?', whereArgs: [invoiceId]);
      await txn.update('invoice_items', {'deleted': 1, 'seq': seq},
          where: 'invoice_id = ?', whereArgs: [invoiceId]);
    });
  }

  Future<void> deleteInvoice({
    required String invoiceId,
    required String deviceId,
    required String eventId,
    required int    seq,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        'invoices',
        {'deleted': 1, 'seq': seq, 'event_id': eventId},
        where: 'invoice_id = ?', whereArgs: [invoiceId],
      );
      await txn.update(
        'invoice_items',
        {'deleted': 1, 'seq': seq},
        where: 'invoice_id = ?', whereArgs: [invoiceId],
      );
      await _addOutboxEntry(txn,
        deviceId: deviceId, eventId: eventId, seq: seq,
        entity: 'invoice', action: 'delete',
        payload: {'invoice_id': invoiceId},
      );
    });
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  /// Recompute and write amount_cents for [invoiceId] from its live items.
  Future<void> _recalcInvoiceTotal(
      DatabaseExecutor db, String invoiceId, int seq) async {
    final rows = await db.query(
      'invoice_items',
      columns: ['qty', 'unit_price_cents', 'discount_cents'],
      where: 'invoice_id = ? AND deleted = 0',
      whereArgs: [invoiceId],
    );
    int total = 0;
    for (final r in rows) {
      final qty      = (r['qty'] as num?)?.toDouble() ?? 1.0;
      final cents    = (r['unit_price_cents'] as int?) ?? 0;
      final discount = (r['discount_cents'] as int?) ?? 0;
      total += ((qty * cents).round() - discount).clamp(0, 999999999);
    }
    await db.update(
      'invoices',
      {'amount_cents': total},
      where: 'invoice_id = ?',
      whereArgs: [invoiceId],
    );
  }

  /// Patch the invoice header's vehicle fields from a line-item payload,
  /// but only if the header fields are currently empty.
  Future<void> _patchInvoiceVehicle(
      DatabaseExecutor db, String invoiceId, Map<String, dynamic> payload) async {
    final rows = await db.query('invoices',
        where: 'invoice_id = ?', whereArgs: [invoiceId], limit: 1);
    if (rows.isEmpty) return;
    final row    = rows.first;
    final hVin   = (row['vin']   as String? ?? '').trim();
    final hPlate = (row['plate'] as String? ?? '').trim();
    final hYear  = (row['year']  as String? ?? '').trim();
    final hMake  = (row['make']  as String? ?? '').trim();
    final hModel = (row['model'] as String? ?? '').trim();
    final pVin   = (payload['vin']   as String? ?? '').trim();
    final pPlate = (payload['plate'] as String? ?? '').trim();
    final pYear  = (payload['year']  as String? ?? '').trim();
    final pMake  = (payload['make']  as String? ?? '').trim();
    final pModel = (payload['model'] as String? ?? '').trim();
    final updates = <String, dynamic>{};
    if (hVin.isEmpty   && pVin.isNotEmpty)   updates['vin']   = pVin;
    if (hPlate.isEmpty && pPlate.isNotEmpty) updates['plate'] = pPlate;
    if (hYear.isEmpty  && pYear.isNotEmpty)  updates['year']  = pYear;
    if (hMake.isEmpty  && pMake.isNotEmpty)  updates['make']  = pMake;
    if (hModel.isEmpty && pModel.isNotEmpty) updates['model'] = pModel;
    if (updates.isNotEmpty) {
      await db.update('invoices', updates,
          where: 'invoice_id = ?', whereArgs: [invoiceId]);
    }
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  /// Lightweight UUID v4 generator (no package dependency required here).
  String _uuid() {
    // Delegates to the uuid package used elsewhere in the app; if you prefer
    // to avoid the import simply inline a basic implementation.
    // ignore: depend_on_referenced_packages
    return DateTime.now().microsecondsSinceEpoch.toRadixString(16) +
        '-xxxx-4xxx-yxxx'.replaceAllMapped(RegExp(r'[xy]'), (m) {
          final r = (DateTime.now().microsecondsSinceEpoch & 0xf);
          final v = m[0] == 'x' ? r : (r & 0x3 | 0x8);
          return v.toRadixString(16);
        });
  }
}
