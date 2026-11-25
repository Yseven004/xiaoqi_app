import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

class CompanionAnnotationRepository {
  CompanionAnnotationRepository(this._db) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS companion_annotation_state (
        account TEXT NOT NULL, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
        sequence INTEGER NOT NULL, body TEXT NOT NULL,
        PRIMARY KEY (account, kind, entity_id)
      );
      CREATE UNIQUE INDEX IF NOT EXISTS companion_annotation_sequence
        ON companion_annotation_state(account, sequence);
      CREATE TABLE IF NOT EXISTS companion_annotation_cursor (
        account TEXT PRIMARY KEY, sequence INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS companion_annotation_receipts (
        account TEXT NOT NULL, operation_id TEXT NOT NULL,
        fingerprint TEXT NOT NULL, result TEXT NOT NULL,
        PRIMARY KEY (account, operation_id)
      );
      CREATE TABLE IF NOT EXISTS companion_annotation_selectors (
        account TEXT NOT NULL, book_key TEXT NOT NULL,
        selector TEXT NOT NULL, annotation_id TEXT NOT NULL,
        PRIMARY KEY (account, book_key, selector)
      );
      CREATE TABLE IF NOT EXISTS companion_annotation_aliases (
        account TEXT NOT NULL, alias TEXT NOT NULL, canonical TEXT NOT NULL,
        PRIMARY KEY (account, alias)
      );
      CREATE TABLE IF NOT EXISTS companion_annotation_media (
        account TEXT NOT NULL, digest TEXT NOT NULL, mime TEXT NOT NULL,
        byte_count INTEGER NOT NULL, recorded_at INTEGER NOT NULL,
        PRIMARY KEY (account, digest)
      );
    ''');
  }

  final Database _db;

  ({int size, String mime})? media(String account, String digest) {
    final rows = _db.select(
      'SELECT byte_count, mime FROM companion_annotation_media WHERE account=? AND digest=?',
      [account, digest],
    );
    if (rows.isEmpty) return null;
    return (
      size: rows.single['byte_count'] as int,
      mime: rows.single['mime'] as String,
    );
  }

  void recordMedia(String account, String digest, String mime, int length) {
    _db.execute(
      '''
      INSERT INTO companion_annotation_media(account,digest,mime,byte_count,recorded_at)
      VALUES(?,?,?,?,unixepoch())
      ON CONFLICT(account,digest) DO UPDATE SET mime=excluded.mime,
        byte_count=excluded.byte_count, recorded_at=excluded.recorded_at
    ''',
      [account, digest, mime, length],
    );
  }

  List<String> pruneMedia(String account) {
    final rows = _db.select(
      r'''
      SELECT digest FROM companion_annotation_media m WHERE account=?
      AND recorded_at < unixepoch() - 86400 * 7
      AND NOT EXISTS (
        SELECT 1 FROM companion_annotation_state s, json_each(s.body, '$.media') items
        WHERE s.account = m.account AND s.kind = 'note'
        AND json_extract(items.value, '$.digest') = m.digest
      ) LIMIT 100
    ''',
      [account],
    );
    return rows.map((row) => row['digest'] as String).toList(growable: false);
  }

  void forgetMedia(String account, String digest) {
    _db.execute(
      'DELETE FROM companion_annotation_media WHERE account=? AND digest=?',
      [account, digest],
    );
  }

  int _cursor(String account) =>
      _db.select(
            'SELECT sequence FROM companion_annotation_cursor WHERE account=?',
            [account],
          ).firstOrNull?['sequence']
          as int? ??
      0;

  Map<String, Object?> pull(String account, int after, int? through) {
    final latest = _cursor(account);
    if (after > latest ||
        (through != null && (through < after || through > latest))) {
      return {
        'reset': true,
        'server_time_ms': DateTime.now().millisecondsSinceEpoch,
      };
    }
    final bound = through ?? latest;
    final rows = _db.select(
      '''
      SELECT kind, sequence, body FROM companion_annotation_state
      WHERE account=? AND sequence>? AND sequence<=?
      ORDER BY sequence LIMIT 101
    ''',
      [account, after, bound],
    );
    // Limit by both rows and serialized bytes. A page remains bounded even
    // when a reader selection has a long quote or many media descriptors.
    final entries = <Map<String, Object?>>[];
    var bytes = 0;
    var last = after;
    for (final row in rows.take(100)) {
      final encoded = row['body'] as String;
      final size = utf8.encode(encoded).length;
      if (entries.isNotEmpty && bytes + size > 2 * 1024 * 1024) break;
      bytes += size;
      entries.add(_map(encoded));
      last = row['sequence'] as int;
    }
    final more = entries.length < rows.length;
    return {
      'items': entries,
      'cursor': more ? last : bound,
      'through': bound,
      'more': more,
      'server_time_ms': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, Object?> apply(
    String account,
    String operationId,
    String fingerprint,
    Map<String, Object?> operation,
  ) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final prior = _db
          .select(
            '''
        SELECT fingerprint, result FROM companion_annotation_receipts
        WHERE account=? AND operation_id=?
      ''',
            [account, operationId],
          )
          .firstOrNull;
      if (prior != null) {
        if (prior['fingerprint'] != fingerprint) {
          throw const FormatException('同步操作编号对应的内容已变化');
        }
        final result = _map(prior['result'] as String);
        final item = result['item'];
        if (item is Map) {
          final kind = item['kind'] as String;
          final id = (item['id'] ?? item['book_key']) as String;
          result['item'] = _state(account, kind, id);
        }
        _db.execute('COMMIT');
        return result;
      }
      final value = operation['kind'] == 'book'
          ? _applyBook(account, operation)
          : _applyNote(account, operation);
      final item = value['item'];
      final receipt = <String, Object?>{
        if (value.containsKey('rejected')) 'rejected': value['rejected'],
        if (item is Map)
          'item': {
            'kind': item['kind'],
            'id': item['id'],
            'book_key': item['book_key'],
          },
      };
      _db.execute(
        '''
        INSERT INTO companion_annotation_receipts(account,operation_id,fingerprint,result)
        VALUES(?,?,?,?)
      ''',
        [account, operationId, fingerprint, jsonEncode(receipt)],
      );
      _db.execute('COMMIT');
      return value;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  Map<String, Object?> _applyBook(
    String account,
    Map<String, Object?> operation,
  ) {
    final key = operation['book_key'] as String;
    final state = _state(account, 'book', key);
    final generation = state?['generation'] as int? ?? 0;
    final deleted = state?['deleted'] == true;
    final requested = operation['deleted'] == true;
    final purged = requested && operation['purged'] == true;
    if (operation['generation'] != generation ||
        (deleted == requested && !purged) ||
        state?['purged'] == true) {
      return {'item': state};
    }
    final next = <String, Object?>{
      'kind': 'book',
      'book_key': key,
      'deleted': requested,
      'generation': requested ? generation : generation + 1,
      if (purged) 'purged': true,
    };
    _setState(account, 'book', key, next);
    if (purged) {
      // No active body or media remains after an explicit permanent deletion.
      final rows = _db.select(
        r'''
        SELECT entity_id FROM companion_annotation_state WHERE account=?
          AND kind='note' AND json_extract(body,'$.book_key')=?
      ''',
        [account, key],
      );
      for (final row in rows) {
        final id = row['entity_id'] as String;
        final current = _state(account, 'note', id)!;
        _setState(account, 'note', id, _tombstone(current));
      }
      _db.execute(
        'DELETE FROM companion_annotation_selectors WHERE account=? AND book_key=?',
        [account, key],
      );
    }
    return {'item': next};
  }

  Map<String, Object?> _applyNote(
    String account,
    Map<String, Object?> operation,
  ) {
    final book = operation['book_key'] as String;
    final state = _state(account, 'book', book);
    if (state?['deleted'] == true ||
        operation['generation'] != (state?['generation'] ?? 0)) {
      return {'item': state, 'rejected': 'book_generation'};
    }
    final originalId = operation['id'] as String;
    final alias =
        _db.select(
              'SELECT canonical FROM companion_annotation_aliases WHERE account=? AND alias=?',
              [account, originalId],
            ).firstOrNull?['canonical']
            as String?;
    var id = alias ?? originalId;
    var current = _state(account, 'note', id);
    if (current?['deleted'] == true ||
        (current != null &&
            (current['book_key'] != book ||
                current['selector'] != operation['selector']))) {
      return {'item': current};
    }
    final selector = operation['selector'] as String;
    if (current == null && operation['deleted'] != true) {
      final selected =
          _db
                  .select(
                    '''
        SELECT annotation_id FROM companion_annotation_selectors
        WHERE account=? AND book_key=? AND selector=?
      ''',
                    [account, book, selector],
                  )
                  .firstOrNull?['annotation_id']
              as String?;
      if (selected != null) {
        id = selected;
        current = _state(account, 'note', id);
        _db.execute(
          'INSERT OR IGNORE INTO companion_annotation_aliases VALUES(?,?,?)',
          [account, originalId, id],
        );
      }
    }
    if (operation['deleted'] == true) {
      final next = _tombstone({...?current, ...operation, 'id': id});
      _setState(account, 'note', id, next);
      _db.execute(
        '''
        DELETE FROM companion_annotation_selectors
        WHERE account=? AND book_key=? AND selector=? AND annotation_id=?
      ''',
        [account, book, selector, id],
      );
      return {'item': next};
    }
    if (current != null && _compareEdits(operation, current) <= 0) {
      return {'item': current};
    }
    for (final item in (operation['media'] as List).whereType<Map>()) {
      final resource = media(account, item['digest'] as String);
      if (resource == null ||
          resource.mime != item['mime'] ||
          resource.size != item['size']) {
        throw const FormatException('注释附件尚未上传完成');
      }
    }
    final next = {...operation, 'id': id};
    _setState(account, 'note', id, next);
    _db.execute(
      '''
      INSERT INTO companion_annotation_selectors VALUES(?,?,?,?)
      ON CONFLICT(account,book_key,selector) DO UPDATE SET annotation_id=excluded.annotation_id
    ''',
      [account, book, selector, id],
    );
    return {'item': next};
  }

  Map<String, Object?> _tombstone(Map<String, Object?> note) => {
    for (final key in [
      'kind',
      'id',
      'book_key',
      'source_hash',
      'selector',
      'generation',
      'revision',
      'edited_at',
      'device',
    ])
      if (note.containsKey(key)) key: note[key],
    'deleted': true,
  };

  int _compareEdits(
    Map<String, Object?> incoming,
    Map<String, Object?> current,
  ) {
    final time = (incoming['edited_at'] as int).compareTo(
      current['edited_at'] as int,
    );
    if (time != 0) return time;
    final device = (incoming['device'] as String).compareTo(
      current['device'] as String,
    );
    return device == 0
        ? (incoming['revision'] as String).compareTo(
            current['revision'] as String,
          )
        : device;
  }

  Map<String, Object?>? _state(String account, String kind, String id) {
    final row = _db
        .select(
          '''
      SELECT body FROM companion_annotation_state WHERE account=? AND kind=? AND entity_id=?
    ''',
          [account, kind, id],
        )
        .firstOrNull;
    return row == null ? null : _map(row['body'] as String);
  }

  void _setState(
    String account,
    String kind,
    String id,
    Map<String, Object?> body,
  ) {
    final sequence = _cursor(account) + 1;
    _db.execute(
      '''
      INSERT INTO companion_annotation_cursor VALUES(?,?)
      ON CONFLICT(account) DO UPDATE SET sequence=excluded.sequence
    ''',
      [account, sequence],
    );
    _db.execute(
      '''
      INSERT INTO companion_annotation_state VALUES(?,?,?,?,?)
      ON CONFLICT(account, kind, entity_id)
      DO UPDATE SET sequence=excluded.sequence, body=excluded.body
    ''',
      [account, kind, id, sequence, jsonEncode(body)],
    );
  }

  static Map<String, Object?> _map(String raw) =>
      (jsonDecode(raw) as Map).cast<String, Object?>();
}
