import 'package:sqflite/sqflite.dart';

Future<void> createCompanionAnnotationSyncTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS companion_sync_clock (
      scope TEXT PRIMARY KEY, device TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0,
      offset_ms INTEGER, last_edit INTEGER NOT NULL DEFAULT 0,
      trusted_edit_floor INTEGER NOT NULL DEFAULT 0,
      reconciling INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS companion_sync_outbox (
      position INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL,
      operation_id TEXT NOT NULL UNIQUE, book_key TEXT NOT NULL,
      entity_id TEXT NOT NULL, selector TEXT, generation INTEGER NOT NULL,
      body TEXT NOT NULL,
      blocked_reason TEXT, recovery_priority INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS companion_sync_queue ON companion_sync_outbox(scope, position)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS companion_sync_inbox (
      scope TEXT NOT NULL, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
      book_key TEXT NOT NULL, body TEXT NOT NULL,
      PRIMARY KEY(scope, kind, entity_id)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS companion_sync_inbox_book ON companion_sync_inbox(scope, book_key)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS companion_sync_recovery (
      scope TEXT NOT NULL, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
      book_key TEXT NOT NULL, body TEXT NOT NULL,
      replayed INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(scope, kind, entity_id)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS companion_sync_book_identity (
      book_id INTEGER PRIMARY KEY, identity TEXT NOT NULL,
      needs_source_hash INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS companion_sync_book_binding (
      scope TEXT NOT NULL, book_id INTEGER NOT NULL, book_key TEXT NOT NULL,
      PRIMARY KEY(scope, book_key)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS companion_sync_note_binding (
      scope TEXT NOT NULL, id TEXT NOT NULL, book_key TEXT NOT NULL,
      selector TEXT NOT NULL, source_hash TEXT NOT NULL, PRIMARY KEY(scope, id)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS companion_sync_source_binding (
      scope TEXT NOT NULL, book_id INTEGER NOT NULL, source_hash TEXT NOT NULL,
      book_key TEXT NOT NULL, PRIMARY KEY(scope, book_id, source_hash)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS companion_sync_media (
      scope TEXT NOT NULL, path TEXT NOT NULL, digest TEXT NOT NULL,
      mime TEXT NOT NULL, size INTEGER NOT NULL,
      PRIMARY KEY(scope, path)
    )
  ''');
}
