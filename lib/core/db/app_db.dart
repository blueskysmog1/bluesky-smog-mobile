import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'tables.dart';

class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();

  Database? _db;

  Future<Database> get db async {
    final existing = _db;
    if (existing != null) return existing;

    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'blue_sky.db');

    final database = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(createInvoicesTable);
        await db.execute(createOutboxTable);
        await db.execute(createMetaTable);
      },
    );

    _db = database;
    return database;
  }

  Future<String> getOrCreateDeviceId() async {
    final dbx = await db;
    final rows = await dbx.query('meta', where: 'key = ?', whereArgs: ['device_id']);
    if (rows.isNotEmpty) return rows.first['value'] as String;

    // Simple stable ID. Later we can switch to real device info if you want.
    final newId = 'PHONE-01';
    await dbx.insert('meta', {'key': 'device_id', 'value': newId});
    return newId;
  }

  Future<int> nextSeq() async {
    final dbx = await db;
    await dbx.transaction((txn) async {
      final rows = await txn.query('meta', where: 'key = ?', whereArgs: ['seq']);
      final current = rows.isNotEmpty ? int.tryParse(rows.first['value'] as String) ?? 0 : 0;
      final next = current + 1;
      if (rows.isEmpty) {
        await txn.insert('meta', {'key': 'seq', 'value': next.toString()});
      } else {
        await txn.update('meta', {'value': next.toString()}, where: 'key = ?', whereArgs: ['seq']);
      }
    });

    final rows2 = await dbx.query('meta', where: 'key = ?', whereArgs: ['seq']);
    return int.parse(rows2.first['value'] as String);
  }

  Future<void> enqueueOutboxEvent({
    required String eventId,
    required int seq,
    required String entity,
    required String entityId,
    required String action,
    required Map<String, dynamic> payload,
  }) async {
    final dbx = await db;
    final now = DateTime.now().millisecondsSinceEpoch;

    await dbx.insert('outbox', {
      'event_id': eventId,
      'seq': seq,
      'entity': entity,
      'entity_id': entityId,
      'action': action,
      'payload_json': jsonEncode(payload),
      'created_at': now,
      'sent_at': null,
    });
  }
}