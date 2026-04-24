const createInvoicesTable = '''
CREATE TABLE IF NOT EXISTS invoices (
  id TEXT PRIMARY KEY,
  number TEXT,
  customer_name TEXT,
  total_cents INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'draft',
  updated_at INTEGER NOT NULL
);
''';

const createOutboxTable = '''
CREATE TABLE IF NOT EXISTS outbox (
  event_id TEXT PRIMARY KEY,
  seq INTEGER NOT NULL,
  entity TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  action TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  sent_at INTEGER
);
''';

const createMetaTable = '''
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';