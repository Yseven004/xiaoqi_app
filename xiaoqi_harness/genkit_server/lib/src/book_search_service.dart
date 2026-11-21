import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'book_search_query.dart';
import 'store.dart';

typedef BookSearchProvider =
    Stream<BookSearchCandidate> Function(
      BookSearchQuery query,
      BookSearchCancellation cancellation,
    );
typedef BookSearchVerifier =
    Future<Uri> Function(
      BookSearchCandidate candidate,
      BookSearchCancellation cancellation,
    );

class BookSearchException implements Exception {
  const BookSearchException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

class BookSearchCancellation {
  final _signal = Completer<void>();
  bool get isCancelled => _signal.isCompleted;
  Future<void> get whenCancelled => _signal.future;

  void _cancel() {
    if (!_signal.isCompleted) _signal.complete();
  }
}

class BookSearchCandidate {
  const BookSearchCandidate({
    required this.id,
    required this.title,
    required this.author,
    required this.language,
    required this.edition,
    required this.format,
    required this.sourceName,
    required this.sourceUri,
    this.license,
    this.licenseUri,
    this.downloadUri,
    this.inlineEpub = false,
    this.availability,
    this.isbn,
    this.translator,
    this.publisher,
    this.publicationYear,
  });

  factory BookSearchCandidate._fromStored(Map<String, dynamic> row) =>
      BookSearchCandidate(
        id: row['id'] as String,
        title: row['title'] as String,
        author: row['author'] as String,
        language: row['language'] as String,
        edition: row['edition'] as String,
        format: row['format'] as String,
        sourceName: row['sourceName'] as String,
        sourceUri: Uri.parse(row['sourceUrl'] as String),
        license: row['license'] as String?,
        inlineEpub: row['inlineEpub'] == true,
        licenseUri: row['licenseUrl'] is String
            ? Uri.parse(row['licenseUrl'] as String)
            : null,
        downloadUri: row['downloadUrl'] is String
            ? Uri.parse(row['downloadUrl'] as String)
            : null,
        availability: row['availability'] as String?,
        isbn: row['isbn'] as String?,
        translator: row['translator'] as String?,
        publisher: row['publisher'] as String?,
        publicationYear: row['publicationYear'] as String?,
      );

  final String id;
  final String title;
  final String author;
  final String language;
  final String edition;
  final String format;
  final String sourceName;
  final Uri sourceUri;
  final String? license;
  final Uri? licenseUri;
  final Uri? downloadUri;
  final bool inlineEpub;
  final String? availability;
  final String? isbn;
  final String? translator;
  final String? publisher;
  final String? publicationYear;

  Map<String, dynamic> _toStored() => {
    'id': id,
    'title': title,
    'author': author,
    'language': language,
    'edition': edition,
    'format': format,
    'sourceName': sourceName,
    'sourceUrl': sourceUri.toString(),
    'importable': downloadUri != null || inlineEpub,
    if (inlineEpub) 'inlineEpub': true,
    if (downloadUri != null) 'downloadUrl': downloadUri.toString(),
    if (license != null) 'license': license,
    if (licenseUri != null) 'licenseUrl': licenseUri.toString(),
    if (availability != null) 'availability': availability,
    if (isbn != null) 'isbn': isbn,
    if (translator != null) 'translator': translator,
    if (publisher != null) 'publisher': publisher,
    if (publicationYear != null) 'publicationYear': publicationYear,
    'verifiedAt': DateTime.now().toUtc().toIso8601String(),
  };
}

/// Shared by authenticated HTTP and Genkit tool invocations. Callers enforce
/// network and plugin permissions and supply an authenticated owner.
class BookSearchService {
  BookSearchService({
    required CloudStore store,
    required BookSearchProvider find,
    required BookSearchVerifier verify,
    this.buildEpub,
    Duration searchTimeout = const Duration(seconds: 25),
  }) : _store = store,
       _find = find,
       _verify = verify,
       _searchTimeout = searchTimeout;

  static const _prefix = 'book-searches/';
  static final _validId = RegExp(r'^[A-Za-z0-9_-]{16,80}$');
  static const _retention = Duration(hours: 2);
  static const _ownerRecordLimit = 120;
  static const _ownerSearchLimit = 4;
  static const _candidateLimit = 24;

  final CloudStore _store;
  final BookSearchProvider _find;
  final BookSearchVerifier _verify;
  final Future<Uint8List> Function(BookSearchCandidate, BookSearchCancellation)?
  buildEpub;
  final Duration _searchTimeout;
  final _active = <String, _RunningSearch>{};
  final _resolutions =
      <
        (String, String),
        (BookSearchCancellation, Future<Map<String, dynamic>>)
      >{};
  DateTime? _lastCleanup;

  bool hasSearch({required String owner, required String id}) =>
      _get(_key(owner, id)) != null;

  Map<String, dynamic> start({
    required String owner,
    required String id,
    required String query,
    BookSearchQuery? criteria,
  }) {
    _prune();
    final key = _key(owner, id);
    final normalized = query.trim();
    final filters = criteria ?? BookSearchQuery.fromText(normalized);
    if (!filters.hasIdentity ||
        normalized.length > (criteria == null ? 240 : 640)) {
      throw const BookSearchException(400, '请提供有效的书名、作者、ISBN 或主题。');
    }

    final existing = _get(key);
    if (existing != null) {
      final previous = existing.value['query'];
      if (previous != null &&
          (previous != normalized ||
              (existing.value.containsKey('criteria') &&
                  jsonEncode(existing.value['criteria']) !=
                      jsonEncode(filters.toJson())))) {
        throw const BookSearchException(409, '查找编号已用于其他查询。');
      }
      return _snapshot(_recoverInterrupted(key, existing));
    }

    _checkOwnerCapacity(owner);
    final prefix = _ownerPrefix(owner);
    if (_active.length >= 40 ||
        _active.keys.where((key) => key.startsWith(prefix)).length >=
            _ownerSearchLimit) {
      throw const BookSearchException(429, '当前查找较多，请稍后再试。');
    }
    final entry = _create(
      key,
      id,
      'searching',
      query: normalized,
      criteria: filters,
    );
    final operation = _active[key] = _RunningSearch();
    unawaited(_run(key, filters, operation));
    return _snapshot(entry);
  }

  Map<String, dynamic> read({required String owner, required String id}) {
    final key = _key(owner, id);
    return _snapshot(_recoverInterrupted(key, _require(key)));
  }

  Future<Map<String, dynamic>> wait({
    required String owner,
    required String id,
    Future<void>? cancelled,
  }) async {
    final key = _key(owner, id);
    final active = _active[key];
    if (active != null) {
      if (cancelled == null) {
        await active.done.future;
      } else {
        await Future.any([
          active.done.future,
          cancelled.then((_) {
            if (identical(_active[key], active)) {
              _finish(key, active, 'stopped');
            }
          }),
        ]);
      }
    }
    return read(owner: owner, id: id);
  }

  Map<String, dynamic> stop({required String owner, required String id}) {
    _prune();
    final key = _key(owner, id);
    final entry = _get(key);
    if (entry == null) {
      // The close action can arrive before a delayed start request.
      _checkOwnerCapacity(owner);
      return _snapshot(_create(key, id, 'stopped'));
    }
    if (entry.value['status'] != 'searching') return _snapshot(entry);
    final active = _active[key];
    if (active != null) return _snapshot(_finish(key, active, 'stopped'));
    return _snapshot(_change(key, entry, {'status': 'stopped'}));
  }

  void stopOwner(String owner) {
    final prefix = _ownerPrefix(owner);
    for (final key in _active.keys.toList()) {
      if (key.startsWith(prefix)) _finish(key, _active[key]!, 'stopped');
    }
    for (final entry in _resolutions.entries) {
      if (entry.key.$1.startsWith(prefix)) entry.value.$1._cancel();
    }
  }

  Future<Map<String, dynamic>> resolve({
    required String owner,
    required String id,
    required String candidateId,
  }) {
    final key = _key(owner, id);
    final candidates = _candidates(_require(key));
    final candidate = candidates
        .where((row) => row['id'] == candidateId)
        .firstOrNull;
    if (candidate == null) {
      throw const BookSearchException(404, '该版本已失效，请重新查找。');
    }
    if (candidate['importable'] != true ||
        (candidate['downloadUrl'] == null && candidate['inlineEpub'] != true)) {
      throw const BookSearchException(409, '该来源未提供可导入的完整电子书。');
    }
    final resolutionKey = (key, candidateId);
    final existing = _resolutions[resolutionKey];
    if (existing != null) return existing.$2;
    final ownerPrefix = _ownerPrefix(owner);
    if (_resolutions.length >= 40 ||
        _resolutions.keys
                .where((key) => key.$1.startsWith(ownerPrefix))
                .length >=
            4) {
      throw const BookSearchException(429, '当前导入较多，请稍后再试。');
    }
    final cancellation = BookSearchCancellation();
    final result = _resolve(candidate, cancellation).whenComplete(() {
      _resolutions.remove(resolutionKey);
    });
    _resolutions[resolutionKey] = (cancellation, result);
    return result;
  }

  Future<Map<String, dynamic>> _resolve(
    Map<String, dynamic> stored,
    BookSearchCancellation cancellation,
  ) async {
    try {
      final candidate = BookSearchCandidate._fromStored(stored);
      final payload = await Future.any([
        _resolveFile(candidate, cancellation),
        cancellation.whenCancelled.then<Map<String, dynamic>>((_) {
          throw const BookSearchException(403, '网上找书已关闭。');
        }),
      ]).timeout(Duration(seconds: candidate.inlineEpub ? 90 : 15));
      if (cancellation.isCancelled) {
        throw const BookSearchException(403, '网上找书已关闭。');
      }
      return {
        ...stored,
        ...payload,
        'verifiedAt': DateTime.now().toUtc().toIso8601String(),
      };
    } on BookSearchException {
      rethrow;
    } on Object {
      throw const BookSearchException(502, '来源文件暂不可用，请重新查找或稍后重试。');
    } finally {
      cancellation._cancel();
    }
  }

  Future<Map<String, dynamic>> _resolveFile(
    BookSearchCandidate candidate,
    BookSearchCancellation cancellation,
  ) async {
    if (candidate.inlineEpub) {
      final build = buildEpub;
      if (build == null || candidate.format != 'epub') {
        throw const BookSearchException(409, '该来源不支持生成电子书。');
      }
      final bytes = await build(candidate, cancellation);
      if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024) {
        throw const BookSearchException(422, '整书超出在线排版的大小限制。');
      }
      // Only the authenticated resolve response contains book bytes. The
      // persisted candidate, search snapshots and model see metadata only.
      return {
        'epubBase64': base64Encode(bytes),
        'sha256': sha256.convert(bytes).toString(),
      };
    }
    final download = await _verify(candidate, cancellation);
    if (download.scheme != 'https' ||
        download.host.isEmpty ||
        download.userInfo.isNotEmpty) {
      throw const BookSearchException(502, '来源返回了无效的电子书下载链接。');
    }
    return {'downloadUrl': download.toString()};
  }

  Future<void> _run(
    String key,
    BookSearchQuery query,
    _RunningSearch search,
  ) async {
    final cancellation = search.cancellation;
    final deadline = Timer(_searchTimeout, () {
      _finish(key, search, 'unavailable', usePartialResults: true);
    });
    StreamIterator<BookSearchCandidate>? iterator;
    try {
      iterator = StreamIterator(_find(query, cancellation));
      final cancelled = cancellation.whenCancelled.then((_) => false);
      while (await Future.any([iterator.moveNext(), cancelled])) {
        if (cancellation.isCancelled) return;
        final candidate = iterator.current;
        final entry = _require(key);
        final candidates = _candidates(entry);
        if (!candidates.any((row) => row['id'] == candidate.id)) {
          candidates.add(candidate._toStored());
          _change(key, entry, {'candidates': candidates});
          if (candidates.length >= _candidateLimit) break;
        }
      }
      if (!cancellation.isCancelled) _finish(key, search, 'complete');
    } on Object {
      if (!cancellation.isCancelled) {
        _finish(key, search, 'unavailable', usePartialResults: true);
      }
    } finally {
      deadline.cancel();
      try {
        await iterator?.cancel();
      } on Object {
        // Cleanup can fail after the terminal result has already been saved.
      }
    }
  }

  StoredDocument _finish(
    String key,
    _RunningSearch search,
    String status, {
    bool usePartialResults = false,
  }) {
    final entry = _require(key);
    if (!identical(_active[key], search)) return entry;
    _active.remove(key);
    try {
      final isPartial = usePartialResults && _candidates(entry).isNotEmpty;
      return _change(key, entry, {
        'status': isPartial ? 'complete' : status,
        if (isPartial) 'partial': true,
      });
    } finally {
      search.cancellation._cancel();
      search.done.complete();
    }
  }

  StoredDocument _recoverInterrupted(String key, StoredDocument document) {
    if (document.value['status'] != 'searching' || _active.containsKey(key)) {
      return document;
    }
    final hasCandidates = _candidates(document).isNotEmpty;
    return _change(key, document, {
      'status': hasCandidates ? 'complete' : 'unavailable',
      if (hasCandidates) 'partial': true,
    });
  }

  String _ownerPrefix(String owner) =>
      '$_prefix${sha256.convert(utf8.encode(owner))}/';

  String _key(String owner, String id) {
    if (!_validId.hasMatch(id)) {
      throw const BookSearchException(400, '查找编号无效。');
    }
    return '${_ownerPrefix(owner)}$id';
  }

  void _checkOwnerCapacity(String owner) {
    if (_store.list(_ownerPrefix(owner), limit: _ownerRecordLimit).length >=
        _ownerRecordLimit) {
      throw const BookSearchException(429, '查找次数过多，请稍后再试。');
    }
  }

  StoredDocument? _get(String key) {
    final entry = _store.get(key);
    if (entry == null || !_expired(entry)) return entry;
    _store.delete(key, expectedRevision: entry.revision);
    return null;
  }

  StoredDocument _require(String key) =>
      _get(key) ?? (throw const BookSearchException(404, '找书记录已失效，请重新查找。'));

  bool _expired(StoredDocument entry) =>
      DateTime.now().millisecondsSinceEpoch -
          (entry.value['createdMs'] as int) >=
      _retention.inMilliseconds;

  StoredDocument _create(
    String key,
    String id,
    String status, {
    String? query,
    BookSearchQuery? criteria,
  }) => _store.put(key, {
    'id': id,
    if (query != null) 'query': query,
    if (criteria != null) 'criteria': criteria.toJson(),
    'status': status,
    'createdMs': DateTime.now().millisecondsSinceEpoch,
    'candidates': [],
  }, null);

  StoredDocument _change(
    String key,
    StoredDocument entry,
    Map<String, dynamic> changes,
  ) => _store.put(key, {...entry.value, ...changes}, entry.revision);

  List<Map<String, dynamic>> _candidates(StoredDocument entry) =>
      List<Map<String, dynamic>>.from(entry.value['candidates'] as List);

  Map<String, dynamic> _snapshot(StoredDocument entry) => {
    'id': entry.value['id'],
    'query': entry.value['query'] ?? '',
    'status': entry.value['status'],
    'revision': entry.revision,
    if (entry.value['partial'] == true) 'partial': true,
    'candidates': [
      for (final row in _candidates(entry)) {...row}..remove('downloadUrl'),
    ],
  };

  void _prune() {
    final now = DateTime.now();
    final lastCleanup = _lastCleanup;
    if (lastCleanup != null && now.difference(lastCleanup).inMinutes < 10)
      return;
    _lastCleanup = now;
    String? after;
    const pageSize = 200;
    while (true) {
      final rows = _store.list(_prefix, afterKey: after, limit: pageSize);
      for (final (key, entry) in rows) {
        if (_expired(entry))
          _store.delete(key, expectedRevision: entry.revision);
      }
      if (rows.length < pageSize) return;
      after = rows.last.$1;
    }
  }
}

class _RunningSearch {
  final cancellation = BookSearchCancellation();
  final done = Completer<void>();
}
