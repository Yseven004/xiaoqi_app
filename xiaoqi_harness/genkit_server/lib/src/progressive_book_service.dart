import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'store.dart';

/// Stores authorized book originals and publishes independently searchable units.
class ProgressiveBookService {
  ProgressiveBookService(
    this._store,
    this._db, {
    Future<BookWorker> Function(File, String)? workerFactory,
  }) : _workerFactory = workerFactory ?? BookWorker.start {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS reading_book_sources (
        id TEXT PRIMARY KEY,
        tenant TEXT NOT NULL,
        book_key TEXT NOT NULL,
        version TEXT NOT NULL,
        format TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        original_key TEXT NOT NULL,
        generation TEXT NOT NULL,
        status TEXT NOT NULL,
        error TEXT,
        catalog TEXT,
        lease TEXT,
        lease_until INTEGER,
        updated INTEGER NOT NULL,
        UNIQUE(tenant, book_key, version)
      );
      CREATE INDEX IF NOT EXISTS reading_book_queue
        ON reading_book_sources(status, updated);
      CREATE TABLE IF NOT EXISTS reading_book_bindings (
        tenant TEXT NOT NULL,
        book_key TEXT NOT NULL,
        version TEXT NOT NULL,
        binding TEXT NOT NULL,
        generation TEXT NOT NULL,
        active INTEGER NOT NULL CHECK(active IN (0, 1)),
        PRIMARY KEY(tenant, book_key, version, binding)
      );
      CREATE TABLE IF NOT EXISTS reading_book_units (
        source TEXT NOT NULL,
        unit INTEGER NOT NULL,
        state TEXT NOT NULL,
        bytes INTEGER NOT NULL,
        PRIMARY KEY(source, unit)
      );
      CREATE TABLE IF NOT EXISTS reading_book_passages (
        id INTEGER PRIMARY KEY,
        source TEXT NOT NULL,
        unit INTEGER NOT NULL,
        part INTEGER NOT NULL,
        locator TEXT,
        quote TEXT NOT NULL,
        searchable TEXT NOT NULL,
        UNIQUE(source, unit, part)
      );
      CREATE TABLE IF NOT EXISTS reading_book_targets (
        source TEXT NOT NULL,
        instance TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        chapter_id TEXT,
        page INTEGER,
        expires INTEGER NOT NULL,
        PRIMARY KEY(source, instance)
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS reading_book_fts USING fts5(
        searchable, content='reading_book_passages',
        content_rowid='id', tokenize='trigram'
      );
      CREATE TRIGGER IF NOT EXISTS reading_book_fts_insert
        AFTER INSERT ON reading_book_passages BEGIN
        INSERT INTO reading_book_fts(rowid, searchable)
          VALUES (new.id, new.searchable);
      END;
      CREATE TRIGGER IF NOT EXISTS reading_book_fts_delete
        AFTER DELETE ON reading_book_passages BEGIN
        INSERT INTO reading_book_fts(reading_book_fts, rowid, searchable)
          VALUES ('delete', old.id, old.searchable);
      END;
    ''');
    _schedule();
  }

  static const maxBookBytes = 256 << 20;
  static const _maxTextBytes = 50 << 20;
  static const _maxPassages = 48000;
  static const _leaseSeconds = 150;
  static const _targetSeconds = 180;
  static const _scanLimit = 384;
  static const _uuid = Uuid();

  final CloudStore _store;
  final Database _db;
  final Future<BookWorker> Function(File, String) _workerFactory;
  final _uploads = <String, Future<Map<String, dynamic>>>{};
  BookWorker? _worker;
  String? _workerSource;
  Future<void>? _drain;
  Timer? _wake;
  bool _closed = false;

  /// A version cannot be replaced by a different original. The server computes
  /// content identity before publishing the queued source.
  Future<Map<String, dynamic>> ingest({
    required String tenant,
    required String bookKey,
    required String version,
    required String format,
    required File original,
    String? verifiedSha256,
    bool Function()? isAllowed,
  }) async {
    _validKey(tenant);
    _validKey(bookKey);
    _validKey(version);
    if (format != 'epub' && format != 'pdf') {
      throw const FormatException('仅可索引 EPUB 或 PDF');
    }
    final size = await original.length();
    if (size == 0 || size > maxBookBytes) {
      throw const FormatException('资料为空或超过大小限制');
    }
    if (verifiedSha256 != null &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(verifiedSha256)) {
      throw const FormatException('原件校验失败');
    }
    final digest =
        verifiedSha256 ??
        (await sha256.bind(original.openRead()).first).toString();
    final id = _id(tenant, bookKey, version);
    var pending = _uploads[id];
    while (pending != null) {
      try {
        await pending;
      } on Object {
        // The previous uploader receives its own failure.
      }
      pending = _uploads[id];
    }
    _requireAllowed(isAllowed);
    if (_closed) throw StateError('书籍索引服务正在停止');
    final future = _ingest(
      tenant,
      bookKey,
      version,
      format,
      original,
      id,
      digest,
      isAllowed,
    );
    _uploads[id] = future;
    try {
      return await future;
    } finally {
      if (identical(_uploads[id], future)) _uploads.remove(id);
    }
  }

  Future<Map<String, dynamic>> _ingest(
    String tenant,
    String bookKey,
    String version,
    String format,
    File original,
    String id,
    String digest,
    bool Function()? isAllowed,
  ) async {
    _requireAllowed(isAllowed);
    final old = _source(tenant, id);
    if (old != null && (old['sha256'] != digest || old['format'] != format)) {
      throw const FormatException('该资料版本已绑定其他原件');
    }
    if (old != null && old['status'] != 'uploading') {
      if (old['status'] == 'failed' ||
          old['status'] == 'complete_with_errors') {
        _db.execute(
          '''
          DELETE FROM reading_book_units WHERE source=? AND state='failed'
        ''',
          [id],
        );
        _db.execute(
          '''
          UPDATE reading_book_sources SET status='queued', error=NULL,
            lease=NULL, lease_until=NULL WHERE id=?
        ''',
          [id],
        );
        _schedule();
      }
      return status(tenant, id)!;
    }

    final generation = _uuid.v4();
    final blob = 'reading_book_original/$id/$generation';
    final prior =
        _db.select('SELECT original_key FROM reading_book_sources WHERE id=?', [
              id,
            ]).firstOrNull?['original_key']
            as String?;
    _db.execute(
      '''
      INSERT INTO reading_book_sources
        (id, tenant, book_key, version, format, sha256, original_key,
         generation, status, updated)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'uploading', ?)
      ON CONFLICT(id) DO UPDATE SET format=excluded.format,
        sha256=excluded.sha256, original_key=excluded.original_key,
        generation=excluded.generation, status='uploading',
        error=NULL, catalog=NULL, lease=NULL, lease_until=NULL,
        updated=excluded.updated
    ''',
      [id, tenant, bookKey, version, format, digest, blob, generation, _now],
    );
    try {
      if (prior != null) _store.deleteTaskBlob(prior);
      await _store.putTaskBlobFile(blob, original);
      _requireAllowed(isAllowed);
      _db.execute(
        '''
        UPDATE reading_book_sources SET status='queued', updated=?
        WHERE id=? AND generation=? AND status='uploading'
      ''',
        [_now, id, generation],
      );
      if (_db.updatedRows != 1) throw StateError('书籍资料授权已变更');
    } catch (_) {
      _db.execute(
        '''
        UPDATE reading_book_sources SET status=?, error='upload_failed'
        WHERE id=? AND generation=? AND status='uploading'
      ''',
        [isAllowed?.call() == false ? 'revoked' : 'uploading', id, generation],
      );
      _deleteOriginal({'original_key': blob});
      rethrow;
    }
    _schedule();
    return status(tenant, id)!;
  }

  Map<String, dynamic>? lookup(String tenant, String bookKey, String version) =>
      status(tenant, _id(tenant, bookKey, version));

  bool hasSourceVersion(String tenant, String bookKey, String version) =>
      _source(tenant, _id(tenant, bookKey, version)) != null;

  ({String generation, bool active}) sourceBinding(
    String tenant,
    String book,
    String version,
    String binding,
  ) {
    final row = _db
        .select(
          '''
      SELECT generation, active FROM reading_book_bindings
      WHERE tenant=? AND book_key=? AND version=? AND binding=?
      ''',
          [tenant, book, version, binding],
        )
        .firstOrNull;
    return (
      generation: row?['generation'] as String? ?? '0',
      active: row?['active'] == 1,
    );
  }

  void grantSourceBinding(
    String tenant,
    String book,
    String version,
    String binding,
    String generation,
  ) {
    _db.execute(
      '''
      INSERT INTO reading_book_bindings
        (tenant, book_key, version, binding, generation, active)
      VALUES (?, ?, ?, ?, ?, 1)
      ON CONFLICT(tenant, book_key, version, binding) DO UPDATE SET active=1
      WHERE reading_book_bindings.generation=excluded.generation
      ''',
      [tenant, book, version, binding, generation],
    );
    if (_db.updatedRows != 1) throw StateError('资料授权已变更');
  }

  bool hasActiveBindings(String tenant, String book, String version) => _db
      .select(
        '''
        SELECT 1 FROM reading_book_bindings
        WHERE tenant=? AND book_key=? AND version=? AND active=1
        LIMIT 1
        ''',
        [tenant, book, version],
      )
      .isNotEmpty;

  /// Rotate one grant and atomically remove searchable data on the last grant.
  bool revokeSourceBinding(
    String tenant,
    String book,
    String version,
    String binding,
  ) {
    Map<String, dynamic>? revokedSource;
    final last = _transaction(() {
      _db.execute(
        '''
        INSERT INTO reading_book_bindings
          (tenant, book_key, version, binding, generation, active)
        VALUES (?, ?, ?, ?, ?, 0)
        ON CONFLICT(tenant, book_key, version, binding) DO UPDATE SET
          generation=excluded.generation, active=0
        ''',
        [tenant, book, version, binding, _uuid.v4()],
      );
      _db.execute(
        'DELETE FROM reading_book_targets WHERE source=? AND instance LIKE ?',
        [_id(tenant, book, version), '${_bindingTargetPrefix(binding)}%'],
      );
      if (hasActiveBindings(tenant, book, version)) return false;
      final source = _source(tenant, _id(tenant, book, version));
      if (source != null) {
        _markRevoked(source);
        revokedSource = source;
      }
      return true;
    });
    if (revokedSource case final source?) _disposeRevoked(source);
    return last;
  }

  List<String> readyVersions(String tenant, String bookKey) => [
    for (final row in _db.select(
      '''
      SELECT version FROM reading_book_sources AS s
      WHERE s.tenant=? AND s.book_key=? AND s.status<>'revoked'
        AND EXISTS (
          SELECT 1 FROM reading_book_units AS u
          WHERE u.source=s.id AND u.state='ready'
        )
      ORDER BY s.version
    ''',
      [tenant, bookKey],
    ))
      row['version'] as String,
  ];

  Map<String, dynamic>? status(String tenant, String id) {
    final source = _source(tenant, id);
    return source == null ? null : _describe(source);
  }

  bool prioritize(
    String tenant,
    String id, {
    required String instance,
    required int sequence,
    String? binding,
    String? chapterId,
    int? page,
    bool release = false,
  }) {
    _validKey(instance);
    final scope = binding == null
        ? instance
        : '${_bindingTargetPrefix(binding)}$instance';
    final source = _source(tenant, id);
    if (source == null) return false;
    if (sequence < 0 || (page != null && page < 1)) {
      throw const FormatException('阅读位置无效');
    }
    if (chapterId != null) _validKey(chapterId, max: 2048);
    if (!release && chapterId == null && page == null) {
      throw const FormatException('缺少阅读位置');
    }
    _db.execute(
      '''
      INSERT INTO reading_book_targets
        (source, instance, sequence, chapter_id, page, expires)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(source, instance) DO UPDATE SET sequence=excluded.sequence,
        chapter_id=excluded.chapter_id, page=excluded.page,
        expires=excluded.expires
      WHERE excluded.sequence > reading_book_targets.sequence
    ''',
      [
        id,
        scope,
        sequence,
        release ? null : chapterId,
        release ? null : page,
        DateTime.now().millisecondsSinceEpoch + _targetSeconds * 1000,
      ],
    );
    return true;
  }

  static String _bindingTargetPrefix(String binding) =>
      '${sha256.convert(utf8.encode(binding))}:';

  Future<bool> revoke(String tenant, String id) async {
    final source = _source(tenant, id);
    if (source == null) return false;
    _transaction(() => _markRevoked(source));
    _disposeRevoked(source);
    return true;
  }

  void _markRevoked(Map<String, dynamic> source) {
    final id = source['id'] as String;
    _db.execute(
      '''
      UPDATE reading_book_sources SET status='revoked', lease=NULL,
        lease_until=NULL, catalog=NULL
      WHERE id=? AND generation=?
      ''',
      [id, source['generation']],
    );
    _db.execute('DELETE FROM reading_book_passages WHERE source=?', [id]);
    _db.execute('DELETE FROM reading_book_units WHERE source=?', [id]);
    _db.execute('DELETE FROM reading_book_targets WHERE source=?', [id]);
  }

  void _disposeRevoked(Map<String, dynamic> source) {
    if (_workerSource == source['id']) _worker?.stop();
    _deleteOriginal(source);
  }

  Future<void> revokeBook(String tenant, String bookKey) async {
    final sources = _db.select(
      '''
      SELECT id FROM reading_book_sources
      WHERE tenant=? AND book_key=? AND status<>'revoked'
    ''',
      [tenant, bookKey],
    );
    for (final source in sources) {
      await revoke(tenant, source['id'] as String);
    }
  }

  void _deleteOriginal(Map<String, dynamic> source) {
    final key = source['original_key'] as String;
    try {
      _store.deleteTaskBlob(key);
    } on FileSystemException {
      // The worker may still own an OS file handle. The next sweep retries.
    }
  }

  Map<String, dynamic>? _source(String tenant, String id) => _db
      .select(
        '''
    SELECT * FROM reading_book_sources
    WHERE tenant=? AND id=? AND status<>'revoked'
  ''',
        [tenant, id],
      )
      .firstOrNull;

  Map<String, dynamic> _describe(Map<String, dynamic> source) {
    final catalog = _catalog(source);
    final completed = _db.select(
      '''
      SELECT unit, state FROM reading_book_units
      WHERE source=? ORDER BY unit
    ''',
      [source['id']],
    );
    final ready = [
      for (final row in completed)
        if (row['state'] == 'ready') row['unit'],
    ];
    final skipped = [
      for (final row in completed)
        if (row['state'] == 'no_text') row['unit'],
    ];
    final failed = [
      for (final row in completed)
        if (row['state'] == 'failed') row['unit'],
    ];
    return {
      'id': source['id'],
      'book_key': source['book_key'],
      'version': source['version'],
      'source_version': source['version'],
      'source_format': source['format'],
      'status': source['status'],
      'coverage': source['status'] == 'complete' ? 'full' : 'partial',
      'ready': ready.isNotEmpty,
      'completed_units': ready,
      'completed_pages': ready,
      'skipped_units': skipped,
      'failed_units': failed,
      'total_units': catalog.length,
      'total_pages': catalog.length,
      if (source['error'] != null) 'error_code': source['error'],
    };
  }

  static List<Map<String, dynamic>> _maps(Object? value) =>
      value is List ? value.cast<Map<String, dynamic>>() : const [];

  static Map<String, dynamic> _catalogData(Map<String, dynamic> source) =>
      source['catalog'] == null
      ? const {}
      : jsonDecode(source['catalog'] as String) as Map<String, dynamic>;

  static List<Map<String, dynamic>> _catalog(Map<String, dynamic> source) =>
      _maps(_catalogData(source)['units']);

  Map<String, dynamic>? readUnitBatch(
    String tenant,
    String id, {
    List<int> units = const [],
    bool overview = false,
    int offset = 0,
    int maxChars = 160000,
  }) {
    if (units.length > 8 || units.any((unit) => unit < 1) || offset < 0) {
      throw const FormatException('资料范围无效，每次最多读取 8 个单元');
    }
    final source = _source(tenant, id);
    if (source == null) return null;
    final description = _describe(source);
    final catalog = _catalog(source);
    final byId = {for (final unit in catalog) unit['id'] as int: unit};
    final ready = (description['completed_units'] as List).cast<int>();
    final requested = units.toSet().toList()..sort();
    if (requested.isEmpty && overview && ready.isNotEmpty) {
      requested.addAll({ready.first, ready[ready.length ~/ 2], ready.last});
    } else if (requested.isEmpty) {
      requested.addAll(byId.keys.take(8));
    }
    if (catalog.isNotEmpty &&
        requested.any((unit) => !byId.containsKey(unit))) {
      throw const FormatException('找不到所请求的资料单元');
    }
    final processed = requested.toSet().intersection({
      ...ready,
      ...(description['skipped_units'] as List).cast<int>(),
    });
    final text = StringBuffer();
    final locations = <int, Map<String, dynamic>>{};
    var nextOffset = offset;
    var hasMore = false;
    final capacity = maxChars.clamp(3000, 160000);
    if (requested.isNotEmpty) {
      final placeholders = List.filled(requested.length, '?').join(',');
      final cursorUnit = offset ~/ (_maxPassages + 1);
      final cursorPart = offset % (_maxPassages + 1);
      final result = _db.select(
        'SELECT unit, part, locator, quote FROM reading_book_passages '
        'WHERE source=? AND unit IN ($placeholders) '
        'AND (unit>? OR (unit=? AND part>=?)) ORDER BY unit, part LIMIT 513',
        [id, ...requested, cursorUnit, cursorUnit, cursorPart],
      );
      for (final row in result.take(512)) {
        final unit = row['unit'] as int;
        final location = byId[unit]!;
        final locator = row['locator'] ?? location['locator'];
        final newUnit = !locations.containsKey(unit);
        final item = '${newUnit ? '## $locator\n\n' : ''}${row['quote']}\n\n';
        if (text.length + item.length > capacity && text.isNotEmpty) {
          hasMore = true;
          break;
        }
        if (newUnit) {
          locations[unit] = {
            'unit': unit,
            'locator': locator,
            'page': location['page'],
            'chapter_id': location['item_id'],
            'href': location['href'],
            'source_version': source['version'],
          };
        }
        text.write(item);
        nextOffset = unit * (_maxPassages + 1) + (row['part'] as int) + 1;
      }
      hasMore = hasMore || result.length > 512;
    }
    final searchIncomplete =
        description['coverage'] != 'full' ||
        processed.length < requested.length;
    final nextUnits = requested.isEmpty || overview || hasMore
        ? const <int>[]
        : byId.keys.where((unit) => unit > requested.last).take(8).toList();
    return {
      ...description,
      'kind': 'document',
      'text': text.toString(),
      'segments': locations.values.toList(),
      'read_pages': [...locations.keys],
      'requested_units': requested,
      'offset': offset,
      'next_offset': hasMore ? nextOffset : null,
      'next_pages': nextUnits,
      'is_last_chunk': !hasMore && !searchIncomplete,
      'search_incomplete': searchIncomplete,
      'text_truncated': hasMore || searchIncomplete,
      'source_text_truncated': processed.length < requested.length,
    };
  }

  Map<String, dynamic>? search(
    String tenant,
    String id, {
    String query = '',
    String? chapterId,
    int? page,
    String? selection,
    List<int> pages = const [],
    int limit = 3,
  }) {
    final source = _source(tenant, id);
    if (source == null) return null;
    final description = _describe(source);
    final units = _catalog(source);
    final byId = {for (final unit in units) unit['id'] as int: unit};
    final focus = _targetUnits(units, const [], chapterId, page).firstOrNull;
    final nearSelection = focus == null
        ? const <Row>[]
        : _nearSelection(id, focus, selection);
    final neighboringIds = nearSelection.map((row) => row['id']).toSet();
    final requestedPages = pages.where((p) => p > 0).toSet().take(8).toList();
    final terms = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(_normalize(String.fromCharCodes(query.runes.take(512))))
        .map((match) => match.group(0)!)
        .toSet()
        .take(8)
        .toList();
    final phrases = terms.where((term) => term.runes.length >= 3).toList();
    final short = terms.where((term) => term.runes.length < 3).toList();
    final found = <int, Map<String, dynamic>>{};
    var limited = false;

    if (requestedPages.isNotEmpty) {
      for (final row in _db.select(
        '''
        SELECT * FROM reading_book_passages WHERE source=?
          AND unit IN (${requestedPages.map((_) => '?').join(',')})
        ORDER BY unit, part LIMIT ?
      ''',
        [id, ...requestedPages, limit.clamp(1, 8)],
      )) {
        found[row['id'] as int] = row;
      }
    } else {
      if (phrases.isNotEmpty) {
        final filter = phrases.map((term) => '"$term"').join(' OR ');
        final candidates = _db.select(
          '''
          SELECT p.* FROM reading_book_fts AS f
          JOIN reading_book_passages AS p ON p.id=f.rowid
          WHERE reading_book_fts MATCH ? AND p.source=?
          ORDER BY abs(p.unit - ?), p.unit, p.part LIMIT ?
        ''',
          [filter, id, focus ?? 1, _scanLimit + 1],
        );
        limited = candidates.length > _scanLimit;
        for (final row in candidates.take(_scanLimit)) {
          found[row['id'] as int] = row;
        }
      }
      if (short.isNotEmpty || (terms.isEmpty && focus != null)) {
        final candidates = _db.select(
          '''
          SELECT * FROM reading_book_passages WHERE source=?
            AND (? IS NULL OR unit BETWEEN ? AND ?)
          ORDER BY abs(unit - ?), unit, part LIMIT ?
        ''',
          [
            id,
            focus,
            (focus ?? 1) - (terms.isEmpty ? 0 : 1),
            (focus ?? 1) + (terms.isEmpty ? 0 : 1),
            focus ?? 1,
            _scanLimit + 1,
          ],
        );
        if (candidates.length > _scanLimit ||
            (focus != null && units.length > 3)) {
          limited = true;
        }
        for (final row in candidates.take(_scanLimit)) {
          final searchable = row['searchable'] as String;
          if (short.any(searchable.contains) || terms.isEmpty) {
            found[row['id'] as int] = row;
          }
        }
      }
    }
    int score(Map<String, dynamic> row) {
      final searchable = row['searchable'] as String;
      return terms
          .where(searchable.contains)
          .fold(0, (value, term) => value + term.runes.length.clamp(1, 64));
    }

    final ranked = found.values.toList()
      ..sort((a, b) {
        final evidence = score(b).compareTo(score(a));
        if (evidence != 0) return evidence;
        final adjacent = (neighboringIds.contains(b['id']) ? 1 : 0).compareTo(
          neighboringIds.contains(a['id']) ? 1 : 0,
        );
        if (adjacent != 0) return adjacent;
        final nearest = ((a['unit'] as int) - (focus ?? 1)).abs().compareTo(
          ((b['unit'] as int) - (focus ?? 1)).abs(),
        );
        if (nearest != 0) return nearest;
        final unit = (a['unit'] as int).compareTo(b['unit'] as int);
        return unit != 0
            ? unit
            : (a['part'] as int).compareTo(b['part'] as int);
      });
    Map<String, dynamic> evidence(Map<String, dynamic> row) => {
      'text': row['quote'],
      'quote': row['quote'],
      'locator': row['locator'] ?? byId[row['unit']]?['locator'],
      'page': byId[row['unit']]?['page'],
      'chapter_id': byId[row['unit']]?['item_id'],
      'href': byId[row['unit']]?['href'],
      'unit': row['unit'],
      'part': row['part'],
      'source_version': source['version'],
    };
    final matches = ranked.take(limit.clamp(1, 8)).map(evidence).toList();
    final ready = (description['completed_units'] as List).toSet();
    final skipped = (description['skipped_units'] as List).toSet();
    final failed = (description['failed_units'] as List).toSet();
    final scope = requestedPages.isNotEmpty
        ? requestedPages
        : focus == null
        ? const <int>[]
        : [focus];
    final targetReady = scope.every(ready.contains);
    final targetProcessed = scope.every(
      (id) => ready.contains(id) || skipped.contains(id),
    );
    final noText =
        scope.isNotEmpty && scope.every(skipped.contains) ||
        scope.isEmpty && ready.isEmpty && description['coverage'] == 'full';
    return {
      ...description,
      'search_status': matches.isNotEmpty
          ? 'matched'
          : scope.any(failed.contains)
          ? 'parse_failed'
          : noText
          ? 'no_text'
          : !targetProcessed ||
                (ready.isEmpty && description['coverage'] != 'full')
          ? 'not_ready'
          : limited
          ? 'search_limit'
          : 'no_match',
      'target_ready': targetReady,
      'search_incomplete': limited || description['coverage'] != 'full',
      'segments': matches,
      'matches': matches,
      if (nearSelection.isNotEmpty)
        'nearby_context': nearSelection.map(evidence).toList(),
    };
  }

  List<Row> _nearSelection(String source, int unit, String? selection) {
    if (selection == null || selection.isEmpty) return const [];
    final sample = _normalize(String.fromCharCodes(selection.runes.take(80)));
    if (sample.runes.length < 2) return const [];
    final anchors = _db.select(
      '''
      SELECT part FROM reading_book_passages WHERE source=? AND unit=?
        AND instr(searchable, ?) > 0 LIMIT 2
    ''',
      [source, unit, sample],
    );
    if (anchors.length != 1) return const [];
    final anchor = anchors.single['part'] as int;
    return _db.select(
      '''
      SELECT * FROM reading_book_passages WHERE source=? AND unit=?
        AND part BETWEEN ? AND ? AND part<>? ORDER BY part
    ''',
      [source, unit, anchor - 1, anchor + 1, anchor],
    );
  }

  static String _normalize(String text) {
    final characters = String.fromCharCodes(
      text.runes.map((code) {
        if (code == 0x3000) return 32;
        return code >= 0xff01 && code <= 0xff5e ? code - 0xfee0 : code;
      }),
    );
    return characters
        .replaceAllMapped(
          RegExp(r'([\u3400-\u9fff])[ \t]*\n[ \t]*(?=[\u3400-\u9fff])'),
          (m) => m[1]!,
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase()
        .trim();
  }

  static Iterable<String> _passages(String markdown) sync* {
    for (final paragraph in markdown.split(RegExp(r'\r?\n[ \t]*\r?\n'))) {
      final text = paragraph.trim();
      if (text.isEmpty) continue;
      var offset = 0;
      while (offset < text.length) {
        var end = (offset + 1800).clamp(0, text.length);
        if (end < text.length && (text.codeUnitAt(end) & 0xfc00) == 0xdc00)
          end--;
        yield text.substring(offset, end);
        offset = end;
      }
    }
  }

  void _schedule() {
    if (_closed || _drain != null) return;
    _wake?.cancel();
    _wake = null;
    _drain = Future<void>(_drainQueue).whenComplete(() {
      _drain = null;
    });
  }

  Future<void> _drainQueue() async {
    for (final row in _db.select('''
      SELECT * FROM reading_book_sources WHERE status='revoked'
        AND original_key IN (SELECT key FROM objects)
    ''')) {
      _deleteOriginal(row);
    }
    while (!_closed) {
      final lease = _uuid.v4();
      final claimed = _transaction(() {
        final row = _db
            .select(
              '''
          SELECT * FROM reading_book_sources WHERE status='queued'
            OR (status='processing' AND lease_until <= ?)
          ORDER BY updated, id LIMIT 1
        ''',
              [_now],
            )
            .firstOrNull;
        if (row == null) return null;
        _db.execute(
          '''
          UPDATE reading_book_sources SET status='processing',
            lease=?, lease_until=? WHERE id=?
        ''',
          [lease, _now + _leaseSeconds, row['id']],
        );
        return row;
      });
      if (claimed == null) {
        if (_db.select('''
          SELECT 1 FROM reading_book_sources WHERE status='processing' LIMIT 1
        ''').isNotEmpty) {
          _wake = Timer(const Duration(seconds: 2), _schedule);
        }
        return;
      }
      try {
        await _process(claimed, lease);
      } on Object {
        _db.execute(
          '''
          UPDATE reading_book_sources SET status=?, error=?,
            lease=NULL, lease_until=NULL
          WHERE id=? AND generation=? AND lease=?
        ''',
          [
            _closed ? 'queued' : 'failed',
            _closed ? null : 'parse_failed',
            claimed['id'],
            claimed['generation'],
            lease,
          ],
        );
      } finally {
        final worker = _worker;
        _worker = null;
        _workerSource = null;
        await worker?.close();
        final current = _source(
          claimed['tenant'] as String,
          claimed['id'] as String,
        );
        if (current?['generation'] != claimed['generation']) {
          _deleteOriginal(claimed);
        }
      }
    }
  }

  Future<void> _process(Map<String, dynamic> source, String lease) async {
    final id = source['id'] as String;
    final original = _store.taskBlobFile(source['original_key'] as String);
    final worker = await _workerFactory(original, source['format'] as String);
    _worker = worker;
    _workerSource = id;
    _requireLease(source, lease);
    final catalog = await worker.catalog();
    final units = _maps(catalog['units']);
    final sections = _maps(catalog['sections']);
    final byId = {for (final unit in units) unit['id'] as int: unit};
    if (units.length != byId.length || catalog['type'] != 'catalog') {
      throw const FormatException('书籍目录格式无效');
    }
    final encoded = jsonEncode({'units': units, 'sections': sections});
    if (source['catalog'] != null && source['catalog'] != encoded) {
      throw const FormatException('书籍目录发生变化');
    }
    _requireLease(source, lease);
    _db.execute('UPDATE reading_book_sources SET catalog=? WHERE id=?', [
      encoded,
      id,
    ]);
    final completed = _db.select(
      'SELECT unit, bytes FROM reading_book_units WHERE source=?',
      [id],
    );
    final pending = byId.keys.toSet()
      ..removeAll(completed.map((row) => row['unit']));
    var bytes = completed.fold<int>(
      0,
      (sum, row) => sum + (row['bytes'] as int),
    );
    var passages =
        _db
                .select(
                  '''
      SELECT count(*) AS count FROM reading_book_passages WHERE source=?
    ''',
                  [id],
                )
                .single['count']
            as int;
    while (pending.isNotEmpty) {
      _requireLease(source, lease);
      final target = _db
          .select(
            '''
        SELECT chapter_id, page FROM reading_book_targets
        WHERE source=? AND expires>? AND (chapter_id IS NOT NULL OR page IS NOT NULL)
        ORDER BY expires DESC, rowid DESC LIMIT 1
      ''',
            [id, DateTime.now().millisecondsSinceEpoch],
          )
          .firstOrNull;
      final priorities = _targetUnits(
        units,
        sections,
        target?['chapter_id'] as String?,
        target?['page'] as int?,
      ).where(pending.contains);
      final batch = {...priorities.take(3), ...pending.take(3)}
          .take(completed.isEmpty && pending.length == byId.length ? 1 : 3)
          .toList();
      _db.execute(
        '''
        UPDATE reading_book_sources SET lease_until=? WHERE id=? AND lease=?
      ''',
        [_now + _leaseSeconds, id, lease],
      );
      await worker.batch(batch, (result) {
        _requireLease(source, lease);
        final unit = result['id'] as int;
        final state = result['status'];
        final markdown = result['markdown'] as String?;
        if (!batch.contains(unit) ||
            !pending.contains(unit) ||
            !const {'ready', 'no_text', 'failed'}.contains(state) ||
            (state == 'ready'
                ? markdown == null || markdown.trim().isEmpty
                : markdown != null && markdown.isNotEmpty)) {
          throw const FormatException('书籍单元结果无效');
        }
        final length = markdown == null ? 0 : utf8.encode(markdown).length;
        final parts = markdown == null
            ? const <String>[]
            : _passages(markdown).toList();
        if (bytes + length > _maxTextBytes ||
            passages + parts.length > _maxPassages) {
          throw const FormatException('书籍文本超过限制');
        }
        _transaction(() {
          _requireLease(source, lease);
          for (final (index, quote) in parts.indexed) {
            _db.execute(
              '''
              INSERT INTO reading_book_passages
                (source, unit, part, locator, quote, searchable)
                VALUES (?, ?, ?, ?, ?, ?)
            ''',
              [
                id,
                unit,
                index,
                result['locator'] ?? byId[unit]?['locator'],
                quote,
                _normalize(quote),
              ],
            );
          }
          _db.execute(
            '''
            INSERT INTO reading_book_units (source, unit, state, bytes)
              VALUES (?, ?, ?, ?)
          ''',
            [id, unit, state, length],
          );
        });
        bytes += length;
        passages += parts.length;
        pending.remove(unit);
      });
      if (batch.any(pending.contains)) {
        throw const FormatException('书籍解析批次不完整');
      }
    }
    _requireLease(source, lease);
    final errors = _db
        .select(
          '''
      SELECT 1 FROM reading_book_units WHERE source=? AND state='failed' LIMIT 1
    ''',
          [id],
        )
        .isNotEmpty;
    _db.execute(
      '''
      UPDATE reading_book_sources SET status=?, error=?, lease=NULL, lease_until=NULL
      WHERE id=? AND lease=?
    ''',
      [
        errors ? 'complete_with_errors' : 'complete',
        errors
            ? 'unit_failed'
            : passages == 0
            ? 'no_readable_text'
            : null,
        id,
        lease,
      ],
    );
  }

  static Iterable<int> _targetUnits(
    List<Map<String, dynamic>> units,
    List<Map<String, dynamic>> sections,
    String? chapter,
    int? page,
  ) sync* {
    if (chapter != null) {
      final clean = chapter.startsWith('epub:')
          ? chapter.substring(5)
          : chapter;
      for (final unit in units) {
        if (unit['item_id'] == clean || unit['href'] == clean)
          yield unit['id'] as int;
      }
    }
    if (page == null || !units.any((unit) => unit['page'] == page)) return;
    yield page;
    final section = sections.where((section) {
      final start = section['start'];
      final end = section['end'];
      return start is int && end is int && start <= page && page <= end;
    }).lastOrNull;
    if (section != null) {
      final start = section['start'] as int;
      final end = section['end'] as int;
      for (var current = start; current <= end; current++) {
        if (current != page) yield current;
      }
    } else {
      if (page > 1) yield page - 1;
      yield page + 1;
    }
  }

  void _requireLease(Map<String, dynamic> source, String lease) {
    if (_closed ||
        _db
            .select(
              '''
      SELECT 1 FROM reading_book_sources WHERE id=? AND generation=?
        AND lease=? AND status='processing' AND lease_until>?
    ''',
              [source['id'], source['generation'], lease, _now],
            )
            .isEmpty) {
      throw StateError('书籍解析任务已停止');
    }
  }

  T _transaction<T>(T Function() run) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = run();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static void _validKey(String value, {int max = 256}) {
    if (value.trim().isEmpty ||
        value.length > max ||
        value.contains('\u0000')) {
      throw const FormatException('书籍索引标识无效');
    }
  }

  static void _requireAllowed(bool Function()? isAllowed) {
    if (isAllowed?.call() == false) {
      throw StateError('书籍资料授权已变更');
    }
  }

  static String _id(String tenant, String bookKey, String version) => sha256
      .convert(utf8.encode(jsonEncode([tenant, bookKey, version])))
      .toString();

  static int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<void> close() async {
    _closed = true;
    _wake?.cancel();
    _worker?.stop();
    await _drain;
    await Future.wait(
      _uploads.values.map((future) async {
        try {
          await future;
        } on Object {
          // Upload errors are reported to the caller.
        }
      }),
    );
  }
}

/// The existing MarkItDown worker, left open while the scheduler chooses units.
abstract class BookWorker {
  static Future<BookWorker> start(File original, String format) async {
    final env = Platform.environment;
    final executable =
        env['XIAOQI_BOOK_MARKITDOWN_PYTHON'] ??
        (Platform.isWindows ? 'python' : 'python3');
    final script = p.absolute(
      env['XIAOQI_BOOK_MARKITDOWN_PATH'] ?? p.join('bin', 'book_markitdown.py'),
    );
    final process = await Process.start(
      executable,
      [script, p.absolute(original.path), format, '--interactive'],
      workingDirectory: original.parent.path,
      includeParentEnvironment: false,
      environment: {
        'PATH': env['PATH'] ?? '/usr/bin:/bin',
        if (Platform.isWindows)
          'SystemRoot': env['SystemRoot'] ?? r'C:\Windows',
        'PYTHONUTF8': '1',
        'PYTHONIOENCODING': 'utf-8',
        'PYTHONDONTWRITEBYTECODE': '1',
        'PYTHONNOUSERSITE': '1',
        'LC_ALL': 'C.UTF-8',
        'OMP_THREAD_LIMIT': '1',
        'OMP_NUM_THREADS': '1',
        'HOME': original.parent.path,
        'TMPDIR': original.parent.path,
        'TMP': original.parent.path,
        'TEMP': original.parent.path,
      },
    );
    return _ProcessBookWorker(process);
  }

  Future<Map<String, dynamic>> catalog();
  Future<void> batch(
    List<int> units,
    void Function(Map<String, dynamic>) onUnit,
  );
  void stop();
  Future<void> close();
}

class _ProcessBookWorker implements BookWorker {
  _ProcessBookWorker(this._process)
    : _lines = StreamIterator(
        _process.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      ),
      _stderr = _process.stderr.drain<void>() {
    _process.stdin.done.ignore();
  }

  final Process _process;
  final StreamIterator<String> _lines;
  final Future<void> _stderr;

  Future<Map<String, dynamic>> _read() async {
    if (!await _lines.moveNext().timeout(const Duration(seconds: 45))) {
      throw const FormatException('书籍解析进程提前退出');
    }
    return jsonDecode(_lines.current) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> catalog() => _read();

  @override
  Future<void> batch(
    List<int> units,
    void Function(Map<String, dynamic>) onUnit,
  ) async {
    _process.stdin.writeln(jsonEncode({'ids': units}));
    await _process.stdin.flush();
    for (var i = 0; i < units.length; i++) {
      final record = await _read();
      if (record['type'] != 'unit' || record['id'] != units[i]) {
        throw const FormatException('书籍解析单元顺序不符');
      }
      onUnit(record);
    }
    if ((await _read())['type'] != 'batch_done') {
      throw const FormatException('书籍解析批次缺少完成标记');
    }
  }

  @override
  void stop() => _process.kill();

  @override
  Future<void> close() async {
    stop();
    await _lines.cancel();
    try {
      await _process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
    await _stderr.timeout(const Duration(seconds: 3), onTimeout: () {});
  }
}
