import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:genkit/experimental.dart'
    show SessionSnapshot, SessionStore, SnapshotMutator, generateUuidV4;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

class StoredDocument {
  const StoredDocument(this.value, this.revision);

  final Map<String, dynamic> value;
  final int revision;
}

class RevisionConflict implements Exception {
  const RevisionConflict(this.key);
  final String key;
}

/// SQLite document and private file storage compatible with the existing
/// single-server `xiaoqi.sqlite3` volume.
class CloudStore {
  CloudStore({String? root})
    : root = Directory(
        root ??
            Platform.environment['XIAOQI_DATA_DIR'] ??
            p.join(Directory.current.path, '.xiaoqi-data'),
      ) {
    this.root.createSync(recursive: true);
    objects = Directory(p.join(this.root.path, 'objects'))
      ..createSync(recursive: true);
    database = File(p.join(this.root.path, 'xiaoqi.sqlite3'));
    _db = sqlite3.open(database.path);
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA synchronous=FULL');
    _db.execute('PRAGMA busy_timeout=15000');
    _db.execute('PRAGMA secure_delete=ON');
    _db.execute(
      'CREATE TABLE IF NOT EXISTS documents ('
      'key TEXT PRIMARY KEY, document TEXT NOT NULL, revision INTEGER NOT NULL)',
    );
    _db.execute(
      'CREATE TABLE IF NOT EXISTS objects ('
      'key TEXT PRIMARY KEY, updated_at INTEGER NOT NULL)',
    );
  }

  final Directory root;
  late final Directory objects;
  late final File database;
  late final Database _db;

  StoredDocument? get(String key) {
    final rows = _db.select(
      'SELECT document, revision FROM documents WHERE key=?',
      [key],
    );
    if (rows.isEmpty) return null;
    return StoredDocument(
      (jsonDecode(rows.first['document'] as String) as Map)
          .cast<String, dynamic>(),
      rows.first['revision'] as int,
    );
  }

  List<(String, StoredDocument)> list(
    String prefix, {
    int limit = 200,
    String? afterKey,
  }) {
    if (limit < 1) return const [];
    final comparison = afterKey == null ? 'key>=?' : 'key>?';
    final start = afterKey ?? prefix;
    final rows = _db.select(
      'SELECT key, document, revision FROM documents '
      'WHERE $comparison AND key<? ORDER BY key LIMIT ?',
      [start, '$prefix\uffff', limit],
    );
    return [
      for (final row in rows)
        (
          row['key'] as String,
          StoredDocument(
            (jsonDecode(row['document'] as String) as Map)
                .cast<String, dynamic>(),
            row['revision'] as int,
          ),
        ),
    ];
  }

  StoredDocument put(
    String key,
    Map<String, dynamic> value,
    int? expectedRevision,
  ) {
    final encoded = jsonEncode(value);
    try {
      _db.execute('BEGIN IMMEDIATE');
      if (expectedRevision == null) {
        _db.execute(
          'INSERT INTO documents(key, document, revision) VALUES(?, ?, 1)',
          [key, encoded],
        );
        _db.execute('COMMIT');
        return StoredDocument(value, 1);
      }
      final revision = expectedRevision + 1;
      _db.execute(
        'UPDATE documents SET document=?, revision=? WHERE key=? AND revision=?',
        [encoded, revision, key, expectedRevision],
      );
      if (_db.updatedRows != 1) {
        _db.execute('ROLLBACK');
        throw RevisionConflict(key);
      }
      _db.execute('COMMIT');
      return StoredDocument(value, revision);
    } on RevisionConflict {
      rethrow;
    } on SqliteException {
      try {
        _db.execute('ROLLBACK');
      } on Object {
        // The transaction may already have been rolled back by sqlite.
      }
      throw RevisionConflict(key);
    }
  }

  bool delete(String key, {int? expectedRevision}) {
    if (expectedRevision == null) {
      _db.execute('DELETE FROM documents WHERE key=?', [key]);
    } else {
      _db.execute('DELETE FROM documents WHERE key=? AND revision=?', [
        key,
        expectedRevision,
      ]);
    }
    return _db.updatedRows == 1;
  }

  void putImmutable(String key, Map<String, List<int>> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      _safeKey(entry.key);
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    final bytes = ZipEncoder().encode(archive);
    _writeObject(key, bytes, immutable: true);
  }

  Map<String, List<int>> getImmutable(String key) {
    final archive = ZipDecoder().decodeBytes(getObject(key));
    return {
      for (final file in archive.files.where((file) => file.isFile))
        _safeKey(file.name): List<int>.from(file.content as List<int>),
    };
  }

  void putTaskBlob(String key, List<int> bytes) =>
      _writeObject(key, bytes, immutable: false);

  List<int> getObject(String key) => _objectFile(key).readAsBytesSync();

  void deleteImmutable(String key) {
    _objectFile(key).deleteSyncSafe();
    _db.execute('DELETE FROM objects WHERE key=?', [key]);
  }

  void deleteObjectsPrefix(String prefix) {
    final rows = _db.select('SELECT key FROM objects WHERE key>=? AND key<?', [
      prefix,
      '$prefix\uffff',
    ]);
    for (final row in rows) _objectFile(row['key'] as String).deleteSyncSafe();
    _db.execute('DELETE FROM objects WHERE key>=? AND key<?', [
      prefix,
      '$prefix\uffff',
    ]);
  }

  Map<String, int> summary() => {
    'documents':
        _db.select('SELECT COUNT(*) AS count FROM documents').first['count']
            as int,
    'objects':
        _db.select('SELECT COUNT(*) AS count FROM objects').first['count']
            as int,
    'object_files': objects
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => !p.basename(file.path).startsWith('.tmp-'))
        .length,
  };

  bool checkpointWal() {
    final result = _db.select('PRAGMA wal_checkpoint(TRUNCATE)').first;
    return (result['busy'] as int? ?? 0) == 0;
  }

  void removeOrphanedTempFiles() {
    for (final entity in objects.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && p.basename(entity.path).startsWith('.tmp-')) {
        entity.deleteSyncSafe();
      }
    }
  }

  void close() => _db.close();

  void _writeObject(String key, List<int> bytes, {required bool immutable}) {
    final destination = _objectFile(key);
    destination.parent.createSync(recursive: true);
    _db.execute(
      'INSERT INTO objects(key, updated_at) VALUES(?, unixepoch()) '
      'ON CONFLICT(key) DO UPDATE SET updated_at=excluded.updated_at',
      [key],
    );
    if (immutable && destination.existsSync()) return;
    final temporary = File(
      p.join(
        destination.parent.path,
        '.tmp-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      temporary.writeAsBytesSync(bytes, flush: true);
      if (immutable && destination.existsSync()) return;
      if (destination.existsSync()) destination.deleteSync();
      temporary.renameSync(destination.path);
    } finally {
      temporary.deleteSyncSafe();
    }
  }

  File _objectFile(String key) =>
      File(p.joinAll([objects.path, ..._safeKey(key).split('/')]));

  static String _safeKey(String key) {
    final parts = key.split('/');
    if (key.isEmpty ||
        key.startsWith('/') ||
        key.contains('\\') ||
        parts.any(
          (part) =>
              part.isEmpty || part == '.' || part == '..' || part.contains(':'),
        )) {
      throw const FormatException('存储路径无效');
    }
    return key;
  }
}

/// Persists Genkit agent snapshots in the existing tenant-scoped SQLite store.
///
/// Every lookup requires the authenticated tenant in [context]. Snapshot ids
/// are indexed within that tenant, so a snapshot id from another account is
/// indistinguishable from a missing snapshot.
class CloudSessionStore implements SessionStore {
  CloudSessionStore(this._store);

  final CloudStore _store;

  @override
  Future<SessionSnapshot?> getSnapshot({
    String? snapshotId,
    String? sessionId,
    Map<String, dynamic>? context,
  }) async {
    final tenant = _tenant(context);
    final hasSnapshot = snapshotId != null && snapshotId.isNotEmpty;
    final hasSession = sessionId != null && sessionId.isNotEmpty;
    if (hasSnapshot == hasSession) {
      throw ArgumentError('Provide exactly one of snapshotId or sessionId.');
    }
    if (hasSnapshot) return _readSnapshot(tenant, snapshotId);

    final snapshots = _readSessionSnapshots(tenant, sessionId!);
    if (snapshots.isEmpty) return null;
    final parentIds = snapshots.map((snapshot) => snapshot.parentId).toSet();
    final leaves = snapshots
        .where((snapshot) => !parentIds.contains(snapshot.snapshotId))
        .toList();
    if (leaves.isEmpty) {
      throw StateError('Agent session contains a cyclic snapshot history.');
    }
    leaves.sort((left, right) {
      final leftTime = DateTime.tryParse(left.createdAt);
      final rightTime = DateTime.tryParse(right.createdAt);
      if (leftTime != null && rightTime != null) {
        return leftTime.compareTo(rightTime);
      }
      return left.createdAt.compareTo(right.createdAt);
    });
    return leaves.last;
  }

  @override
  Future<String?> saveSnapshot(
    String? snapshotId,
    SnapshotMutator mutator, {
    Map<String, dynamic>? context,
  }) async {
    final tenant = _tenant(context);
    final requestedId = snapshotId?.trim();
    for (var attempt = 0; attempt < 10; attempt++) {
      final currentDocument = requestedId == null || requestedId.isEmpty
          ? null
          : _snapshotDocument(tenant, requestedId);
      final current = currentDocument == null
          ? null
          : SessionSnapshot.fromJson(currentDocument.value);
      final next = mutator(current);
      if (next == null) return null;

      final id = requestedId?.isNotEmpty == true
          ? requestedId!
          : (next.snapshotId.isNotEmpty ? next.snapshotId : _newSnapshotId());
      final ownerSessionId = next.sessionId ?? next.state?.sessionId;
      if (ownerSessionId == null || ownerSessionId.trim().isEmpty) {
        throw StateError('Genkit snapshot is missing its session id.');
      }
      next
        ..snapshotId = id
        ..sessionId = ownerSessionId;

      final key = _sessionSnapshotKey(tenant, ownerSessionId, id);
      try {
        _writeSnapshotIndex(tenant, id, ownerSessionId);
        final stored = currentDocument ?? _store.get(key);
        _store.put(key, next.toJson(), stored?.revision);
        return id;
      } on RevisionConflict {
        if (attempt == 9) rethrow;
      }
    }
    throw StateError('Genkit snapshot update conflicted too many times.');
  }

  StoredDocument? _snapshotDocument(String tenant, String snapshotId) {
    if (!_safeAgentId.hasMatch(snapshotId)) return null;
    final index = _store.get(_snapshotIndexKey(tenant, snapshotId));
    final sessionId = index?.value['session_id']?.toString();
    if (sessionId == null || !_safeAgentId.hasMatch(sessionId)) return null;
    return _store.get(_sessionSnapshotKey(tenant, sessionId, snapshotId));
  }

  SessionSnapshot? _readSnapshot(String tenant, String snapshotId) {
    final document = _snapshotDocument(tenant, snapshotId);
    return document == null ? null : SessionSnapshot.fromJson(document.value);
  }

  List<SessionSnapshot> _readSessionSnapshots(String tenant, String sessionId) {
    if (!_safeAgentId.hasMatch(sessionId)) return const [];
    final prefix = 'genkit/session/$tenant/$sessionId/';
    final snapshots = <SessionSnapshot>[];
    String? afterKey;
    while (true) {
      final page = _store.list(prefix, limit: 200, afterKey: afterKey);
      snapshots.addAll(
        page.map((entry) => SessionSnapshot.fromJson(entry.$2.value)),
      );
      if (page.length < 200) break;
      afterKey = page.last.$1;
    }
    return snapshots;
  }

  void _writeSnapshotIndex(String tenant, String snapshotId, String sessionId) {
    final key = _snapshotIndexKey(tenant, snapshotId);
    for (var attempt = 0; attempt < 10; attempt++) {
      final current = _store.get(key);
      if (current != null) {
        if (current.value['session_id'] == sessionId) return;
        throw StateError('Genkit snapshot id collision.');
      }
      try {
        _store.put(key, {'session_id': sessionId}, null);
        return;
      } on RevisionConflict {
        if (attempt == 9) rethrow;
      }
    }
  }

  static final _safeAgentId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  static String _tenant(Map<String, dynamic>? context) {
    final tenant = context?['tenant_id']?.toString().trim() ?? '';
    if (!_safeAgentId.hasMatch(tenant)) {
      throw StateError('Authenticated tenant is required for agent storage.');
    }
    return tenant;
  }

  static String _snapshotIndexKey(String tenant, String snapshotId) =>
      'genkit/snapshot/$tenant/$snapshotId';

  static String _sessionSnapshotKey(
    String tenant,
    String sessionId,
    String snapshotId,
  ) => 'genkit/session/$tenant/$sessionId/$snapshotId';

  static String _newSnapshotId() => generateUuidV4();
}

extension on File {
  void deleteSyncSafe() {
    if (existsSync()) deleteSync();
  }
}
