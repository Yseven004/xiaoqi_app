import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../features/capabilities/data/capability_cloud_sync.dart';
import 'companion_annotation_store.dart';
import 'database_service.dart';

class CompanionAnnotationSync with WidgetsBindingObserver {
  CompanionAnnotationSync._();

  static final instance = CompanionAnnotationSync._();
  static const guestScope = 'local';
  static const _store = CompanionAnnotationStore();
  static final _random = Random.secure();
  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');
  static const _timeout = Duration(seconds: 20);
  static const _maxMediaBytes = 50 * 1024 * 1024;
  final _cloud = CapabilityCloudSync.instance;
  final _client = http.Client();
  final _mediaDownloads = <String, Future<void>>{};
  final _recentClock = <String, ({int serverTime, Stopwatch elapsed})>{};
  final changes = ValueNotifier<int>(0);
  final syncFailure = ValueNotifier<String?>(null);
  Timer? _timer;
  Timer? _scheduled;
  Future<void>? _running;
  bool _runAgain = false;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _cloud.emailSessionRevision.addListener(_sessionChanged);
    _resume();
  }

  void _sessionChanged() {
    _recentClock.clear();
    syncFailure.value = null;
    schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _timer?.cancel();
      _timer = null;
      _scheduled?.cancel();
      _scheduled = null;
    }
  }

  void _resume() {
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => schedule());
    schedule();
  }

  void schedule() {
    if (!_started) return;
    _scheduled ??= Timer(const Duration(milliseconds: 400), () {
      _scheduled = null;
      unawaited(syncNow());
    });
  }

  Future<void> syncNow() {
    final active = _running;
    if (active != null) {
      _runAgain = true;
      return active;
    }
    return _running = _run().whenComplete(() {
      _running = null;
      if (_runAgain) {
        _runAgain = false;
        schedule();
      }
    });
  }

  Future<String> currentScope() => _store.accountScope();

  static String _hash(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static String _newId() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  static Map<String, Object?> _decode(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map<String, Object?>) {
      throw const FormatException('私密注释同步响应格式无效');
    }
    return value;
  }

  static Map<String, Object?>? _decodeOptional(Object? raw) =>
      raw is String ? _decode(raw) : null;

  Future<List<Map<String, Object?>>> stageMedia(
    String scope,
    List<String> images,
    List<String> audio,
  ) async {
    if (scope == guestScope) return const [];
    final db = await DatabaseService().database;
    return [
      for (final path in [...images, ...audio])
        await _mediaForPath(db, scope, path),
    ];
  }

  Future<Map<String, Object?>> _mediaForPath(
    DatabaseExecutor db,
    String scope,
    String path,
  ) async {
    final known = await db.query(
      'companion_sync_media',
      where: 'scope=? AND path=?',
      whereArgs: [scope, path],
      limit: 1,
    );
    if (known.isNotEmpty) return known.single;
    final type = switch (p.extension(path).toLowerCase()) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.gif' => 'image/gif',
      '.heic' || '.heif' => 'image/heic',
      '.m4a' => 'audio/mp4',
      _ => throw const FormatException('注释附件格式尚未支持同步'),
    };
    final file = File(path);
    final size = await file.length();
    if (size <= 0 || size > _maxMediaBytes) {
      throw const FormatException('注释附件为空或超过 50 MB');
    }
    final handle = await file.open();
    late final List<int> header;
    try {
      header = await handle.read(32);
    } finally {
      await handle.close();
    }
    if (!_mediaMatches(header, type)) {
      throw const FormatException('注释附件内容与格式不符');
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    return {
      'scope': scope,
      'path': path,
      'digest': digest,
      'mime': type,
      'size': size,
    };
  }

  static bool _mediaMatches(List<int> header, String type) {
    bool starts(List<int> bytes, [int offset = 0]) =>
        header.length >= offset + bytes.length &&
        bytes.indexed.every((pair) => header[offset + pair.$1] == pair.$2);
    bool brand(Set<String> brands) {
      if (!starts(ascii.encode('ftyp'), 4)) return false;
      for (var i = 8; i + 4 <= header.length; i += 4) {
        if (i != 12 &&
            brands.contains(String.fromCharCodes(header.getRange(i, i + 4)))) {
          return true;
        }
      }
      return false;
    }

    return switch (type) {
      'image/jpeg' => starts([255, 216, 255]),
      'image/png' => starts([137, 80, 78, 71, 13, 10, 26, 10]),
      'image/gif' =>
        starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a')),
      'image/webp' =>
        starts(ascii.encode('RIFF')) && starts(ascii.encode('WEBP'), 8),
      'image/heic' => brand({'mif1', 'msf1', 'heic', 'heix', 'hevc', 'hevx'}),
      'audio/mp4' => brand({'M4A ', 'mp42', 'isom', 'mp41', 'mp4a'}),
      _ => false,
    };
  }

  Future<int?> enqueueAnnotation(
    Transaction txn,
    String scope,
    CompanionAnnotation entry, {
    required bool deleted,
    required List<Map<String, Object?>> media,
    required int lastEdit,
  }) async {
    if (scope == guestScope) return null;
    final location = entry.selection;
    final source = (await txn.query(
      'book_sources',
      columns: ['content_hash'],
      where: 'id=? AND book_id=?',
      whereArgs: [location.sourceId, location.bookId],
    )).firstOrNull;
    final existing = (await txn.query(
      'companion_sync_note_binding',
      where: 'scope=? AND id=?',
      whereArgs: [scope, entry.id],
    )).firstOrNull;
    final remote = (await txn.query(
      'companion_sync_inbox',
      where: 'scope=? AND kind=? AND entity_id=?',
      whereArgs: [scope, 'note', entry.id],
    )).firstOrNull;
    final sourceHash =
        existing?['source_hash'] as String? ??
        source?['content_hash'] as String? ??
        (remote == null
            ? null
            : _decode(remote['body'] as String)['source_hash'] as String?);
    // A book without a stable file digest remains local until it can be bound.
    if (sourceHash == null || !_digestPattern.hasMatch(sourceHash)) return null;
    final bookKey =
        existing?['book_key'] as String? ??
        await _bindBook(txn, scope, location.bookId, sourceHash);
    if (bookKey == null) return null;
    final projection = _rewireSelection(location.toJson(), sourceHash);
    final selector =
        existing?['selector'] as String? ??
        _hash([
          sourceHash,
          projection['source_version'],
          projection['canonical_range'] ??
              [
                projection['anchor'],
                projection['end_anchor'],
                projection['start_offset'],
                projection['end_offset'],
                projection['translation_version'],
                projection['view'],
                projection['quote'],
              ],
        ]);
    final lifecycle = await _bookState(txn, scope, bookKey);
    if (lifecycle.deleted) throw StateError('书籍注释已删除');
    final stamp = await _editClock(txn, scope, lastEdit);
    for (final item in media) {
      await txn.insert(
        'companion_sync_media',
        item,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    final operation = <String, Object?>{
      'operation_id': _newId(),
      'kind': 'note',
      'id': entry.id,
      'selector': selector,
      'book_key': bookKey,
      'source_hash': sourceHash,
      'generation': lifecycle.generation,
      'deleted': deleted,
      'revision': entry.revision,
      'device': stamp.device,
      'edited_at': stamp.time,
      if (!deleted) ...{
        'selection': projection,
        'text': entry.text,
        'media': [
          for (final item in media) {...item}..remove('scope'),
        ],
      },
    };
    // A subsequent local revision supersedes earlier pending edits of this
    // same note within the same book generation. An in-flight operation
    // still has its independent receipt, and newer work remains queued.
    await txn.delete(
      'companion_sync_outbox',
      where:
          "scope=? AND entity_id=? AND selector IS NOT NULL "
          "AND (generation=? OR blocked_reason='cursor_recovery')",
      whereArgs: [scope, entry.id, lifecycle.generation],
    );
    await _outbox(txn, scope, operation);
    await txn.insert('companion_sync_note_binding', {
      'scope': scope,
      'id': entry.id,
      'book_key': bookKey,
      'selector': selector,
      'source_hash': sourceHash,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return stamp.time;
  }

  Future<void> enqueueBookLifecycle(
    Transaction txn,
    String scope,
    Iterable<int> bookIds, {
    required bool deleted,
  }) async {
    if (scope == guestScope) return;
    for (final id in bookIds) {
      await _prepareBindings(txn, scope, id);
      final bindings = await txn.query(
        'companion_sync_book_binding',
        where: 'scope=? AND book_id=?',
        whereArgs: [scope, id],
      );
      for (final binding in bindings) {
        final key = binding['book_key'] as String;
        final state = await _bookState(txn, scope, key);
        if (state.deleted == deleted) continue;
        await _outbox(txn, scope, {
          'operation_id': _newId(),
          'kind': 'book',
          'book_key': key,
          'generation': state.generation,
          'deleted': deleted,
        });
      }
    }
  }

  Future<void> _outbox(
    Transaction txn,
    String scope,
    Map<String, Object?> operation, {
    String? blockedReason,
    bool recovery = false,
  }) => txn.insert('companion_sync_outbox', {
    'scope': scope,
    'operation_id': operation['operation_id'],
    'book_key': operation['book_key'],
    'entity_id': operation['id'] ?? operation['book_key'],
    'selector': operation['selector'],
    'generation': operation['generation'],
    'body': jsonEncode(operation),
    'blocked_reason': ?blockedReason,
    if (recovery) 'recovery_priority': 1,
  });

  Future<({String device, int time})> _editClock(
    Transaction txn,
    String scope,
    int observed,
  ) async {
    final state = await _getClock(txn, scope);
    final sample = _recentClock[scope];
    final wall = sample == null
        ? DateTime.now().millisecondsSinceEpoch +
              (state['offset_ms'] as int? ?? 0)
        : sample.serverTime + sample.elapsed.elapsedMilliseconds;
    final time = max(
      max(wall * 1000, state['trusted_edit_floor'] as int),
      max(observed, state['last_edit'] as int) + 1,
    );
    await txn.update(
      'companion_sync_clock',
      {'last_edit': time},
      where: 'scope=?',
      whereArgs: [scope],
    );
    return (device: state['device'] as String, time: time);
  }

  Future<Map<String, Object?>> _getClock(Transaction txn, String scope) async {
    final rows = await txn.query(
      'companion_sync_clock',
      where: 'scope=?',
      whereArgs: [scope],
    );
    if (rows.isNotEmpty) return rows.single;
    final device = _newId();
    await txn.insert('companion_sync_clock', {
      'scope': scope,
      'device': device,
    });
    return {
      'scope': scope,
      'device': device,
      'cursor': 0,
      'last_edit': 0,
      'offset_ms': null,
      'trusted_edit_floor': 0,
      'reconciling': 0,
    };
  }

  Future<({int generation, bool deleted})> _bookState(
    DatabaseExecutor db,
    String scope,
    String bookKey,
  ) async {
    final recovery = await _recovering(db, scope)
        ? (await db.query(
            'companion_sync_recovery',
            columns: ['body'],
            where: 'scope=? AND kind=? AND entity_id=?',
            whereArgs: [scope, 'book', bookKey],
          )).firstOrNull
        : null;
    final remote =
        recovery ??
        (await db.query(
          'companion_sync_inbox',
          where: 'scope=? AND kind=? AND entity_id=?',
          whereArgs: [scope, 'book', bookKey],
        )).firstOrNull;
    final body = remote == null
        ? const <String, Object?>{}
        : _decode(remote['body'] as String);
    var generation = body['generation'] as int? ?? 0;
    var deleted = body['deleted'] == true;
    if (body['purged'] == true) return (generation: generation, deleted: true);
    final pending = await db.query(
      'companion_sync_outbox',
      columns: ['body'],
      where:
          'scope=? AND entity_id=? AND selector IS NULL AND blocked_reason IS NULL',
      whereArgs: [scope, bookKey],
      orderBy: 'position',
    );
    for (final row in pending) {
      final operation = _decode(row['body'] as String);
      if (operation['generation'] != generation) continue;
      final desired = operation['deleted'] == true;
      if (desired == deleted) continue;
      if (!desired) generation++;
      deleted = desired;
    }
    if (!deleted) {
      final fence = (await db.query(
        'companion_sync_outbox',
        columns: ['generation'],
        where:
            "scope=? AND entity_id=? AND selector IS NULL "
            "AND blocked_reason='cursor_recovery' AND generation>=?",
        whereArgs: [scope, bookKey, generation],
        limit: 1,
      )).firstOrNull;
      if (fence != null) deleted = true;
    }
    return (generation: generation, deleted: deleted);
  }

  Future<void> _prepareBindings(
    Transaction txn,
    String scope,
    int bookId,
  ) async {
    final rows = await txn.query(
      'book_sources',
      columns: ['content_hash'],
      where: 'book_id=?',
      whereArgs: [bookId],
    );
    if (rows.isEmpty) await _bindBook(txn, scope, bookId, null);
    for (final row in rows) {
      final hash = row['content_hash'] as String;
      if (_digestPattern.hasMatch(hash)) {
        await _bindBook(txn, scope, bookId, hash);
      }
    }
  }

  Future<String?> _bindBook(
    Transaction txn,
    String scope,
    int bookId,
    String? sourceHash,
  ) async {
    if (sourceHash != null) {
      final mapped = (await txn.query(
        'companion_sync_source_binding',
        where: 'scope=? AND book_id=? AND source_hash=?',
        whereArgs: [scope, bookId, sourceHash],
      )).firstOrNull;
      if (mapped != null) return mapped['book_key'] as String;
    }
    final identity = await freezeBookIdentity(txn, bookId);
    if (identity == null || (identity.needsHash && sourceHash == null)) {
      return null;
    }
    final key = _hash([
      'book-v1',
      identity.key,
      if (identity.needsHash) sourceHash,
    ]);
    final bound = (await txn.query(
      'companion_sync_book_binding',
      where: 'scope=? AND book_key=?',
      whereArgs: [scope, key],
    )).firstOrNull;
    if (bound != null && bound['book_id'] != bookId) return null;
    if (bound == null) {
      await txn.insert('companion_sync_book_binding', {
        'scope': scope,
        'book_id': bookId,
        'book_key': key,
      });
    }
    if (sourceHash != null) {
      await txn.insert('companion_sync_source_binding', {
        'scope': scope,
        'book_id': bookId,
        'source_hash': sourceHash,
        'book_key': key,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    return key;
  }

  Future<({String key, bool needsHash})?> freezeBookIdentity(
    DatabaseExecutor txn,
    int bookId,
  ) async {
    final existing = (await txn.query(
      'companion_sync_book_identity',
      where: 'book_id=?',
      whereArgs: [bookId],
    )).firstOrNull;
    if (existing != null) {
      return (
        key: existing['identity'] as String,
        needsHash: existing['needs_source_hash'] == 1,
      );
    }
    final book = (await txn.query(
      'books',
      where: 'id=?',
      whereArgs: [bookId],
    )).firstOrNull;
    if (book == null) return null;
    final isbn = (book['isbn_13'] as String?)?.trim() ?? '';
    final isbn10 = (book['isbn_10'] as String?)?.trim() ?? '';
    final catalog = (book['source_id'] as String?)?.trim() ?? '';
    final source = (book['source'] as String?)?.trim() ?? '';
    final strong = isbn.isNotEmpty
        ? 'isbn:$isbn'
        : isbn10.isNotEmpty
        ? 'isbn:$isbn10'
        : catalog.isNotEmpty && source.isNotEmpty
        ? 'catalog:$source:$catalog'
        : null;
    final identity = strong ?? book['canonical_key'] as String;
    await txn.insert('companion_sync_book_identity', {
      'book_id': bookId,
      'identity': identity,
      'needs_source_hash': strong == null ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return (key: identity, needsHash: strong == null);
  }

  static Map<String, Object?> _rewireSelection(
    Map<String, Object?> selection,
    Object sourceId,
  ) {
    return {
      ...selection,
      for (final field in ['anchor', 'end_anchor'])
        if (selection[field] case final String encoded)
          field: jsonEncode({..._decode(encoded), 'source_id': '$sourceId'}),
    };
  }

  Future<void> prepareBook(String scope, int bookId) async {
    if (scope == guestScope) return;
    final db = await DatabaseService().database;
    final folder = await _cacheDirectory(scope);
    await db.transaction((txn) async {
      await _prepareBindings(txn, scope, bookId);
      await _applyBookInbox(txn, scope, bookId, folder);
    });
  }

  Future<bool> hidesBook(
    DatabaseExecutor db,
    String scope,
    String annotationId,
  ) async {
    if (scope == guestScope) return false;
    final binding = (await db.query(
      'companion_sync_note_binding',
      columns: ['book_key'],
      where: 'scope=? AND id=?',
      whereArgs: [scope, annotationId],
    )).firstOrNull;
    if (binding == null) return false;
    return (await _bookState(db, scope, binding['book_key'] as String)).deleted;
  }

  Future<void> _applyBookInbox(
    Transaction txn,
    String scope,
    int bookId,
    Directory mediaFolder,
  ) async {
    if (await _recovering(txn, scope)) return;
    final rows = await txn.rawQuery(
      '''
      SELECT i.body FROM companion_sync_inbox i JOIN companion_sync_book_binding b
      ON b.scope=i.scope AND b.book_key=i.book_key
      WHERE b.scope=? AND b.book_id=? AND i.kind='note'
    ''',
      [scope, bookId],
    );
    final notes = rows.map((row) => _decode(row['body'] as String)).toList();
    notes.sort(
      (a, b) => (b['deleted'] == true ? 1 : 0).compareTo(
        a['deleted'] == true ? 1 : 0,
      ),
    );
    for (final note in notes) {
      await _applyNote(txn, scope, bookId, note, mediaFolder);
    }
  }

  Future<void> _applyNote(
    Transaction txn,
    String scope,
    int bookId,
    Map<String, Object?> note,
    Directory mediaFolder,
  ) async {
    final id = note['id'] as String;
    final bookKey = note['book_key'] as String;
    final selector = note['selector'] as String;
    final pending = await txn.query(
      'companion_sync_outbox',
      columns: ['entity_id'],
      where:
          "scope=? AND COALESCE(blocked_reason,'')!='book_generation' "
          'AND (entity_id=? OR (book_key=? AND selector=?))',
      whereArgs: [scope, id, bookKey, selector],
      limit: 1,
    );
    if (pending.isNotEmpty) return;
    if (note['deleted'] == true) {
      await txn.update(
        'companion_annotations',
        {'is_deleted': 1},
        where: 'scope=? AND id=?',
        whereArgs: [scope, id],
      );
      return;
    }
    final row = (await txn.query(
      'companion_annotations',
      columns: ['scope', 'revision', 'source_id', 'is_deleted'],
      where: 'id=?',
      whereArgs: [id],
    )).firstOrNull;
    if (row != null && row['scope'] != scope) return;
    final sourceRows = await txn.query(
      'book_sources',
      columns: ['id'],
      where: 'book_id=? AND content_hash=?',
      whereArgs: [bookId, note['source_hash']],
    );
    final sourceId = sourceRows.singleOrNull?['id'] as int? ?? 0;
    if (row?['revision'] == note['revision'] &&
        row?['source_id'] == sourceId &&
        row?['is_deleted'] == 0) {
      return;
    }
    final body = _rewireSelection(
      (note['selection'] as Map).cast<String, Object?>(),
      sourceId,
    );
    final images = <String>[];
    final audio = <String>[];
    for (final item in (note['media'] as List).whereType<Map>()) {
      final digest = item['digest'] as String;
      final mime = item['mime'] as String;
      final known = (await txn.query(
        'companion_sync_media',
        columns: ['path'],
        where: 'scope=? AND digest=?',
        whereArgs: [scope, digest],
        orderBy: 'path',
        limit: 1,
      )).firstOrNull;
      final path =
          known?['path'] as String? ??
          p.join(mediaFolder.path, '$digest.${_extension(mime)}');
      (mime.startsWith('audio/') ? audio : images).add(path);
      await txn.insert('companion_sync_media', {
        'scope': scope,
        'path': path,
        'digest': digest,
        'mime': mime,
        'size': item['size'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final selection = CompanionAnnotationSelection.fromJson(
      body.cast<String, dynamic>(),
      bookId: bookId,
      sourceId: sourceId,
    );
    final duplicate =
        (await txn.query(
              'companion_annotations',
              columns: ['id'],
              where:
                  'scope=? AND book_id=? AND source_id=? AND selection_key=? AND is_deleted=0',
              whereArgs: [scope, bookId, sourceId, selection.key],
            )).firstOrNull?['id']
            as String?;
    if (duplicate != null && duplicate != id) {
      final clock =
          (await txn.query(
                'companion_annotations',
                columns: ['updated_at'],
                where: 'scope=? AND id=?',
                whereArgs: [scope, duplicate],
              )).single['updated_at']
              as int;
      if (clock > (note['edited_at'] as int) && row == null) return;
      await txn.delete(
        'companion_annotations',
        where: 'scope=? AND id=?',
        whereArgs: [scope, duplicate],
      );
    }
    final values = <String, Object?>{
      'id': id,
      'scope': scope,
      'book_id': bookId,
      'source_id': sourceId,
      'selection_key': selection.key,
      'updated_at': note['edited_at'],
      'revision': note['revision'],
      'is_deleted': 0,
      'body': jsonEncode({
        ...body,
        'text': note['text'],
        'images': images,
        'audio': audio,
      }),
    };
    if (row == null) {
      await txn.insert('companion_annotations', values);
    } else {
      await txn.update(
        'companion_annotations',
        values,
        where: 'scope=? AND id=?',
        whereArgs: [scope, id],
      );
    }
    await txn.insert('companion_sync_note_binding', {
      'scope': scope,
      'id': id,
      'book_key': bookKey,
      'selector': selector,
      'source_hash': note['source_hash'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static String _extension(String mime) => switch (mime) {
    'audio/mp4' => 'm4a',
    'image/jpeg' => 'jpg',
    _ => mime.substring(mime.indexOf('/') + 1),
  };

  Future<Directory> _cacheDirectory(String scope) async {
    final root = await getApplicationSupportDirectory();
    return Directory(
      p.join(
        root.path,
        'companion_annotations',
        sha256.convert(utf8.encode(scope)).toString(),
      ),
    );
  }

  Future<void> _backfill(Database db, String scope) async {
    final rows = await db.rawQuery(
      '''
      SELECT a.* FROM companion_annotations a
      JOIN books b ON a.book_id=b.id
      JOIN book_sources s ON a.source_id=s.id AND a.book_id=s.book_id
      LEFT JOIN companion_sync_note_binding n ON a.scope=n.scope AND a.id=n.id
      WHERE a.scope=? AND a.is_deleted=0 AND b.is_deleted=0 AND n.id IS NULL
      ORDER BY a.updated_at LIMIT 100
    ''',
      [scope],
    );
    for (final row in rows) {
      try {
        final item = CompanionAnnotation.fromRow(row);
        final media = await stageMedia(scope, item.images, item.audio);
        await db.transaction((txn) async {
          final latest = (await txn.query(
            'companion_annotations',
            columns: ['revision'],
            where: 'scope=? AND id=? AND is_deleted=0',
            whereArgs: [scope, item.id],
          )).firstOrNull;
          if (latest?['revision'] != item.revision) return;
          await enqueueAnnotation(
            txn,
            scope,
            item,
            deleted: false,
            media: media,
            lastEdit: row['updated_at'] as int,
          );
        });
      } on FileSystemException {
        // Leave the existing local record available until its media returns.
      } on StateError {
        // A book lifecycle conflict keeps the original record available for a restore.
      } on FormatException {
        // Older local attachments can have formats the sync endpoint cannot store.
      }
    }
  }

  Future<Map<String, String>> _headers(String scope) async => {
    ...await _cloud.authenticatedHeaders(),
    'x-xiaoqi-annotation-scope': scope,
  };

  Uri _endpoint([String tail = '']) =>
      _cloud.capabilityEndpoint('companion-annotations$tail');

  static Map<String, Object?> _checked(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String? message;
      try {
        message = _decode(utf8.decode(response.bodyBytes))['error']?.toString();
      } on FormatException {
        // A reverse proxy can return its own error body.
      }
      throw _CompanionSyncHttpFailure(
        response.statusCode,
        message ?? '私密注释同步暂时不可用',
      );
    }
    return _decode(utf8.decode(response.bodyBytes));
  }

  Future<void> _run() async {
    final generation = _cloud.emailSessionRevision.value;
    bool current() => generation == _cloud.emailSessionRevision.value;
    try {
      final scope = await currentScope();
      if (scope == guestScope || !current()) return;
      final headers = await _headers(scope);
      if (!current()) return;
      final db = await DatabaseService().database;
      final folder = await _cacheDirectory(scope);
      await _backfill(db, scope);
      if (!current()) return;
      await _pull(db, scope, headers, folder, current);
      if (!current() || await _recovering(db, scope)) return;
      await _push(db, scope, headers, folder, current);
      if (!current()) return;
      if (await _downloadPending(db, scope, headers, current)) _notify();
      if (current()) await _clearUnreferencedMedia(db, scope, folder);
      final blocked = await db.query(
        'companion_sync_outbox',
        columns: ['blocked_reason'],
        where: 'scope=? AND blocked_reason IS NOT NULL',
        whereArgs: [scope],
      );
      if (current()) {
        syncFailure.value =
            blocked.any((row) => row['blocked_reason'] == 'invalid')
            ? '有注释未同步，请检查附件后重新保存'
            : blocked.any((row) => row['blocked_reason'] == 'cursor_recovery')
            ? '部分私密注释保留在本机，云端书籍版本有冲突'
            : blocked.isNotEmpty
            ? '部分旧注释未同步，原书已删除或恢复'
            : null;
      }
    } on Object catch (error) {
      if (current()) {
        final detail = switch (error) {
          _CompanionSyncHttpFailure(:final message) => message,
          StateError(:final message) => message.toString(),
          _ => '',
        };
        syncFailure.value = detail.startsWith('客户端 ') && detail.contains('不匹配')
            ? detail
            : '同步暂时不可用，点击重试';
      }
    }
  }

  void _notify() {
    changes.value++;
  }

  Future<void> _pull(
    Database db,
    String scope,
    Map<String, String> headers,
    Directory folder,
    bool Function() current,
  ) async {
    var after =
        (await db.transaction((txn) => _getClock(txn, scope)))['cursor'] as int;
    int? bound;
    var reset = false;
    for (var page = 0; current() && page < 100; page++) {
      final requestTime = Stopwatch()..start();
      final response = await _client
          .get(
            _endpoint().replace(
              queryParameters: {
                'cursor': '$after',
                if (bound != null) 'through': '$bound',
              },
            ),
            headers: headers,
          )
          .timeout(_timeout);
      if (!current()) return;
      final body = _checked(response);
      if (body['reset'] == true) {
        if (reset) throw StateError('私密注释同步游标无法恢复');
        reset = true;
        after = 0;
        bound = null;
        await db.transaction((txn) => _beginCursorRecovery(txn, scope));
        continue;
      }
      final serverTime =
          (body['server_time_ms'] as int) +
          requestTime.elapsedMilliseconds ~/ 2;
      final offset = serverTime - DateTime.now().millisecondsSinceEpoch;
      _recentClock[scope] = (
        serverTime: serverTime,
        elapsed: Stopwatch()..start(),
      );
      bound = body['through'] as int;
      after = body['cursor'] as int;
      final items = (body['items'] as List).cast<Map>();
      await db.transaction((txn) async {
        final affected = <int>{};
        for (final item in items) {
          final book = await _saveInbox(
            txn,
            scope,
            item.cast<String, Object?>(),
          );
          if (book != null) affected.add(book);
        }
        for (final book in affected) {
          await _applyBookInbox(txn, scope, book, folder);
        }
        await txn.update(
          'companion_sync_clock',
          {
            'cursor': after,
            'offset_ms': offset,
            'trusted_edit_floor': max(
              serverTime * 1000,
              (await _getClock(txn, scope))['trusted_edit_floor'] as int,
            ),
          },
          where: 'scope=?',
          whereArgs: [scope],
        );
      });
      if (items.isNotEmpty && current()) _notify();
      if (body['more'] != true) {
        await _recoverProjections(db, scope, folder, current);
        return;
      }
    }
  }

  Future<void> _beginCursorRecovery(Transaction txn, String scope) async {
    await _getClock(txn, scope);
    await txn.execute(
      '''
      INSERT OR IGNORE INTO companion_sync_recovery(scope,kind,entity_id,book_key,body)
      SELECT scope,kind,entity_id,book_key,body FROM companion_sync_inbox
      WHERE scope=?
    ''',
      [scope],
    );
    await txn.delete(
      'companion_sync_inbox',
      where: 'scope=?',
      whereArgs: [scope],
    );
    await txn.update(
      'companion_sync_clock',
      {'cursor': 0, 'reconciling': 1},
      where: 'scope=?',
      whereArgs: [scope],
    );
  }

  @visibleForTesting
  Future<void> applyCursorResetForTesting(
    String scope,
    List<Map<String, Object?>> serverItems,
  ) async {
    final db = await DatabaseService().database;
    final folder = await _cacheDirectory(scope);
    await db.transaction((txn) => _beginCursorRecovery(txn, scope));
    await db.transaction((txn) async {
      for (final item in serverItems) {
        final book = await _saveInbox(txn, scope, item);
        if (book != null) await _applyBookInbox(txn, scope, book, folder);
      }
    });
    await _recoverProjections(db, scope, folder, () => true);
  }

  Future<bool> _recovering(DatabaseExecutor db, String scope) async {
    final row = (await db.query(
      'companion_sync_clock',
      columns: ['reconciling'],
      where: 'scope=?',
      whereArgs: [scope],
    )).firstOrNull;
    return row?['reconciling'] == 1;
  }

  static bool _noteWasRolledBack(
    Map<String, Object?> previous,
    Map<String, Object?>? current,
  ) {
    if (current == null) return true;
    if (current['deleted'] == true) return false;
    if (previous['deleted'] == true) return true;
    final time = (previous['edited_at'] as int).compareTo(
      current['edited_at'] as int,
    );
    if (time != 0) return time > 0;
    final device = (previous['device'] as String).compareTo(
      current['device'] as String,
    );
    if (device != 0) return device > 0;
    return (previous['revision'] as String).compareTo(
          current['revision'] as String,
        ) >
        0;
  }

  Future<void> _recoverProjections(
    Database db,
    String scope,
    Directory folder,
    bool Function() current,
  ) async {
    if (!current() || !await _recovering(db, scope)) return;
    await db.transaction((txn) async {
      if (!current()) return;
      final rows = await txn.rawQuery(
        '''
        SELECT r.rowid recovery_row, r.body previous_body, n.body current_body,
          previous_book.body previous_book, current_book.body current_book,
          EXISTS(SELECT 1 FROM companion_sync_outbox o
            WHERE o.scope=r.scope AND o.entity_id=r.entity_id) pending_entity,
          EXISTS(SELECT 1 FROM companion_sync_outbox o
            WHERE o.scope=r.scope AND o.entity_id=r.book_key) pending_book
        FROM companion_sync_recovery r
        LEFT JOIN companion_sync_inbox n
          ON n.scope=r.scope AND n.kind=r.kind AND n.entity_id=r.entity_id
        LEFT JOIN companion_sync_recovery previous_book
          ON previous_book.scope=r.scope AND previous_book.kind='book'
          AND previous_book.entity_id=r.book_key
        LEFT JOIN companion_sync_inbox current_book
          ON current_book.scope=r.scope AND current_book.kind='book'
          AND current_book.entity_id=r.book_key
        WHERE r.scope=? AND r.replayed=0
        ORDER BY r.kind, r.entity_id LIMIT 100
      ''',
        [scope],
      );
      final deletingBooks = <String>{};
      for (final row in rows) {
        final previous = _decode(row['previous_body'] as String);
        final replacement = _decodeOptional(row['current_body']);
        final bookKey = previous['book_key'] as String;
        final previousBook = _decodeOptional(row['previous_book']);
        final currentBook = _decodeOptional(row['current_book']);
        final generation = currentBook?['generation'] as int? ?? 0;
        final previousGeneration = previousBook?['generation'] as int? ?? 0;
        final sameGeneration = generation == previousGeneration;
        if (previous['kind'] == 'book') {
          final restoringDeletion =
              previous['deleted'] == true &&
              currentBook?['purged'] != true &&
              (generation < previousGeneration ||
                  currentBook?['deleted'] != true ||
                  previous['purged'] == true);
          if (restoringDeletion &&
              generation <= previousGeneration &&
              row['pending_book'] != 1) {
            await _outbox(
              txn,
              scope,
              {...previous, 'operation_id': _newId()},
              blockedReason: sameGeneration ? null : 'cursor_recovery',
              recovery: true,
            );
            deletingBooks.add(bookKey);
          }
          continue;
        }
        if (row['pending_entity'] == 1 ||
            !_noteWasRolledBack(previous, replacement)) {
          continue;
        }
        final media = <Map<String, Object?>>[];
        for (final resource
            in (previous['media'] as List? ?? const []).whereType<Map>()) {
          final digest = resource['digest'] as String;
          final mime = resource['mime'] as String;
          final known = (await txn.query(
            'companion_sync_media',
            columns: ['path'],
            where: 'scope=? AND digest=?',
            whereArgs: [scope, digest],
            limit: 1,
          )).firstOrNull;
          media.add({
            ...resource.cast<String, Object?>(),
            'path':
                known?['path'] ??
                p.join(folder.path, '$digest.${_extension(mime)}'),
          });
        }
        final canReplay =
            sameGeneration &&
            currentBook?['deleted'] != true &&
            !deletingBooks.contains(bookKey) &&
            row['pending_book'] != 1;
        await _outbox(
          txn,
          scope,
          {
            ...previous,
            'operation_id': _newId(),
            'generation': generation,
            if (previous.containsKey('media')) 'media': media,
          },
          blockedReason: canReplay ? null : 'cursor_recovery',
          recovery: true,
        );
      }
      if (rows.length == 100) {
        await txn.update(
          'companion_sync_recovery',
          {'replayed': 1},
          where: 'rowid IN (${List.filled(rows.length, '?').join(',')})',
          whereArgs: rows.map((row) => row['recovery_row']).toList(),
        );
        return;
      }
      await txn.delete(
        'companion_sync_recovery',
        where: 'scope=?',
        whereArgs: [scope],
      );
      await txn.update(
        'companion_sync_clock',
        {'reconciling': 0},
        where: 'scope=?',
        whereArgs: [scope],
      );
      final bindings = await txn.query(
        'companion_sync_book_binding',
        distinct: true,
        columns: ['book_id'],
        where: 'scope=?',
        whereArgs: [scope],
      );
      for (final binding in bindings) {
        await _applyBookInbox(txn, scope, binding['book_id'] as int, folder);
      }
    });
    if (current()) _notify();
  }

  Future<void> _clearUnreferencedMedia(
    Database db,
    String scope,
    Directory folder,
  ) async {
    await db.transaction((txn) async {
      final referenced = await _activeMediaPaths(txn, scope);
      final operations = await txn.query(
        'companion_sync_outbox',
        columns: ['body'],
        where: 'scope=?',
        whereArgs: [scope],
      );
      for (final operation in operations) {
        final media =
            _decode(operation['body'] as String)['media'] as List? ?? const [];
        referenced.addAll(
          media
              .whereType<Map>()
              .map((item) => item['path'])
              .whereType<String>(),
        );
      }
      final rows = await txn.query(
        'companion_sync_media',
        columns: ['path'],
        where: 'scope=?',
        whereArgs: [scope],
      );
      var cleaned = 0;
      for (final row in rows) {
        final path = row['path'] as String;
        if (cleaned >= 16) break;
        if (referenced.contains(path) ||
            !p.isWithin(folder.path, path) ||
            _mediaDownloads.containsKey(path)) {
          continue;
        }
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
          await txn.delete(
            'companion_sync_media',
            where: 'scope=? AND path=?',
            whereArgs: [scope, path],
          );
          cleaned++;
        } on FileSystemException {
          // The entry can be collected on the next successful sync.
        }
      }
    });
  }

  Future<Set<String>> _activeMediaPaths(
    DatabaseExecutor db,
    String scope,
  ) async {
    final annotations = await db.query(
      'companion_annotations',
      columns: ['body'],
      where: 'scope=? AND is_deleted=0',
      whereArgs: [scope],
    );
    final result = <String>{};
    for (final annotation in annotations) {
      final body = _decode(annotation['body'] as String);
      for (final field in ['images', 'audio']) {
        result.addAll((body[field] as List? ?? const []).whereType<String>());
      }
    }
    return result;
  }

  Future<int?> _saveInbox(
    Transaction txn,
    String scope,
    Map<String, Object?> item,
  ) async {
    final book = item['book_key'] as String;
    await txn.insert('companion_sync_inbox', {
      'scope': scope,
      'kind': item['kind'],
      'book_key': book,
      'entity_id': item['id'] ?? book,
      'body': jsonEncode(item),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (item['kind'] == 'book') {
      await txn.delete(
        'companion_sync_outbox',
        where:
            "scope=? AND entity_id=? AND selector IS NULL "
            "AND blocked_reason='cursor_recovery' AND generation<?",
        whereArgs: [scope, book, item['generation'] as int],
      );
    }
    final binding = (await txn.query(
      'companion_sync_book_binding',
      columns: ['book_id'],
      where: 'scope=? AND book_key=?',
      whereArgs: [scope, book],
    )).firstOrNull;
    return binding?['book_id'] as int?;
  }

  Future<void> _push(
    Database db,
    String scope,
    Map<String, String> headers,
    Directory folder,
    bool Function() current,
  ) async {
    for (var count = 0; current() && count < 100; count++) {
      final row = (await db.query(
        'companion_sync_outbox',
        where: 'scope=? AND blocked_reason IS NULL',
        whereArgs: [scope],
        orderBy: 'recovery_priority DESC, position',
        limit: 1,
      )).firstOrNull;
      if (row == null) return;
      final operation = _decode(row['body'] as String);
      final Map<String, Object?>? result;
      try {
        result = await _sendOperation(operation, headers, current);
      } on _CompanionSyncHttpFailure catch (error) {
        if (!const {400, 413, 422}.contains(error.status)) rethrow;
        if (!current()) return;
        await db.update(
          'companion_sync_outbox',
          {'blocked_reason': 'invalid'},
          where: 'scope=? AND operation_id=?',
          whereArgs: [scope, row['operation_id']],
        );
        continue;
      }
      final response = result;
      if (!current() || response == null) return;
      await db.transaction((txn) async {
        final rejected = response['rejected'] == 'book_generation';
        if (rejected) {
          await txn.update(
            'companion_sync_outbox',
            {'blocked_reason': 'book_generation'},
            where: 'scope=? AND operation_id=?',
            whereArgs: [scope, row['operation_id']],
          );
          if (operation['id'] case final String id) {
            await txn.update(
              'companion_annotations',
              {'is_deleted': 1},
              where: 'scope=? AND id=? AND revision=?',
              whereArgs: [scope, id, operation['revision'] as String],
            );
          }
        } else {
          await txn.delete(
            'companion_sync_outbox',
            where: 'scope=? AND operation_id=?',
            whereArgs: [scope, row['operation_id']],
          );
        }
        if (response['item'] case final Map item) {
          final bookId = await _saveInbox(
            txn,
            scope,
            item.cast<String, Object?>(),
          );
          if (bookId != null) await _applyBookInbox(txn, scope, bookId, folder);
        }
        // Acknowledged cross-device creations may use the server's winning ID.
        if (response['item'] case {
          'kind': 'note',
          'id': final String winningId,
        } when operation['id'] != winningId && operation['id'] != null) {
          final noteId = operation['id'];
          final pending = await txn.query(
            'companion_sync_outbox',
            columns: ['entity_id'],
            where: 'scope=? AND entity_id=?',
            whereArgs: [scope, noteId],
            limit: 1,
          );
          if (pending.isEmpty) {
            await txn.delete(
              'companion_annotations',
              where: 'scope=? AND id=?',
              whereArgs: [scope, noteId],
            );
          }
        }
      });
      _notify();
    }
  }

  Future<Map<String, Object?>?> _sendOperation(
    Map<String, Object?> operation,
    Map<String, String> headers,
    bool Function() current,
  ) async {
    final media = (operation['media'] as List? ?? const []).cast<Map>();
    final uploaded = <Map<String, Object?>>[];
    for (final resource in media) {
      if (!current()) return null;
      final digest = resource['digest'] as String;
      final mime = resource['mime'] as String;
      final size = resource['size'] as int;
      final file = File(resource['path'] as String);
      if (!await file.exists()) {
        // Keep the verified remote ID while its local copy downloads.
        uploaded.add({'digest': digest, 'mime': mime, 'size': size});
        continue;
      }
      if (await file.length() != size || size <= 0 || size > _maxMediaBytes) {
        throw const _CompanionSyncHttpFailure(400, '注释附件大小不受支持');
      }
      final request = http.StreamedRequest('PUT', _endpoint('/media/$digest'))
        ..headers.addAll({...headers, 'Content-Type': mime})
        ..contentLength = size;
      final completions = await Future.wait<Object?>([
        _client.send(request).timeout(_timeout),
        request.sink
            .addStream(file.openRead())
            .whenComplete(request.sink.close)
            .timeout(_timeout),
      ]);
      uploaded.add(
        _checked(
          await http.Response.fromStream(
            completions.first as http.StreamedResponse,
          ).timeout(_timeout),
        ),
      );
    }
    if (!current()) return null;
    final payload = {
      ...operation,
      if (operation.containsKey('media')) 'media': uploaded,
    };
    return _checked(
      await _client
          .post(_endpoint(), headers: headers, body: jsonEncode(payload))
          .timeout(_timeout),
    );
  }

  Future<void> ensureMedia(String scope, CompanionAnnotation annotation) async {
    if (scope != await currentScope()) throw StateError('账号已切换');
    final needed = <String>[];
    for (final path in [...annotation.images, ...annotation.audio]) {
      if (!await File(path).exists()) needed.add(path);
    }
    if (needed.isEmpty) return;
    if (scope == guestScope) throw StateError('注释附件缺失');
    final headers = await _headers(scope);
    final db = await DatabaseService().database;
    for (final path in needed) {
      if (scope != await currentScope()) throw StateError('账号已切换');
      final item = await _mediaForPath(db, scope, path);
      await _download(headers, item);
    }
    if (scope != await currentScope()) throw StateError('账号已切换');
    _notify();
  }

  Future<void> fetchMedia(String path) async {
    final revision = _cloud.emailSessionRevision.value;
    final scope = await currentScope();
    if (scope == guestScope || revision != _cloud.emailSessionRevision.value) {
      throw StateError('注释附件缺失');
    }
    final headers = await _headers(scope);
    final db = await DatabaseService().database;
    final item = await _mediaForPath(db, scope, path);
    if (revision != _cloud.emailSessionRevision.value) {
      throw StateError('账号已切换');
    }
    await _download(headers, item);
    if (revision == _cloud.emailSessionRevision.value) _notify();
  }

  Future<bool> _downloadPending(
    Database db,
    String scope,
    Map<String, String> headers,
    bool Function() current,
  ) async {
    final paths = await _activeMediaPaths(db, scope);
    if (paths.isEmpty) return false;
    final items = await db.query(
      'companion_sync_media',
      where: 'scope=?',
      whereArgs: [scope],
    );
    var downloaded = 0;
    for (final item in items) {
      if (!current() || downloaded >= 3) break;
      final path = item['path'] as String;
      if (paths.contains(path) && !await File(path).exists()) {
        await _download(headers, item);
        downloaded++;
      }
    }
    return downloaded > 0;
  }

  Future<void> _download(
    Map<String, String> headers,
    Map<String, Object?> item,
  ) {
    final path = item['path'] as String;
    return _mediaDownloads.putIfAbsent(path, () async {
      final digest = item['digest'] as String;
      final size = item['size'] as int;
      final destination = File(path);
      final temp = File('$path.${_newId()}.partial');
      try {
        final response = await _client
            .send(
              http.Request('GET', _endpoint('/media/$digest'))
                ..headers.addAll(headers),
            )
            .timeout(_timeout);
        if (response.statusCode != 200 || response.contentLength != size) {
          await response.stream.drain<void>().timeout(_timeout);
          throw StateError('注释附件暂未下载');
        }
        await destination.parent.create(recursive: true);
        var received = 0;
        await response.stream
            .map((chunk) {
              received += chunk.length;
              if (received > size) throw StateError('注释附件长度不一致');
              return chunk;
            })
            .timeout(_timeout)
            .pipe(temp.openWrite());
        if (received != size ||
            (await sha256.bind(temp.openRead()).first).toString() != digest) {
          throw StateError('注释附件校验失败');
        }
        if (!await destination.exists()) await temp.rename(path);
      } finally {
        if (await temp.exists()) await temp.delete();
        _mediaDownloads.remove(path);
      }
    });
  }
}

class _CompanionSyncHttpFailure implements Exception {
  const _CompanionSyncHttpFailure(this.status, this.message);

  final int status;
  final String message;
}
