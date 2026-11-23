import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'book_search_query.dart';
import 'store.dart';

typedef BookSearchProvider =
    Stream<BookSearchCandidate> Function(
      BookSearchQuery query,
      BookSearchCancellation cancellation,
    );
typedef BookSearchFileAcquirer =
    Future<File> Function(
      BookSearchCandidate candidate,
      BookSearchCancellation cancellation,
    );
typedef BookSearchSourceInspector =
    Stream<BookSearchCandidate> Function(
      Uri source,
      BookSearchQuery query,
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
  final _diagnostics = <Map<String, Object>>[];
  bool get isCancelled => _signal.isCompleted;
  Future<void> get whenCancelled => _signal.future;

  void report(Map<String, Object> evidence) {
    if (!isCancelled && _diagnostics.length < 32) _diagnostics.add(evidence);
  }

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
    this.alternateEdition = false,
    this.availability,
    this.isbn,
    this.translator,
    this.publisher,
    this.publicationYear,
  });

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
  final bool alternateEdition;
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
    'downloadable': downloadUri != null || inlineEpub,
    'preparationRequired': inlineEpub,
    'importable': false,
    'verified': false,
    if (inlineEpub) 'inlineEpub': true,
    if (downloadUri != null) 'downloadUrl': downloadUri.toString(),
    if (license != null) 'license': license,
    if (licenseUri != null) 'licenseUrl': licenseUri.toString(),
    if (availability != null) 'availability': availability,
    if (isbn != null) 'isbn': isbn,
    if (translator != null) 'translator': translator,
    if (publisher != null) 'publisher': publisher,
    if (publicationYear != null) 'publicationYear': publicationYear,
  };

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
        downloadUri: row['downloadUrl'] is String
            ? Uri.parse(row['downloadUrl'] as String)
            : null,
        inlineEpub: row['inlineEpub'] == true,
        alternateEdition: row['confirmationReason'] is String,
        license: row['license'] as String?,
        licenseUri: row['licenseUrl'] is String
            ? Uri.parse(row['licenseUrl'] as String)
            : null,
        isbn: row['isbn'] as String?,
        translator: row['translator'] as String?,
        publisher: row['publisher'] as String?,
        publicationYear: row['publicationYear'] as String?,
      );
}

/// Shared by authenticated HTTP and Genkit tool invocations. Callers enforce
/// network and plugin permissions and supply an authenticated owner.
class BookSearchService {
  BookSearchService({
    required CloudStore store,
    required BookSearchProvider find,
    required BookSearchFileAcquirer acquire,
    BookSearchSourceInspector? inspect,
    Duration searchTimeout = const Duration(minutes: 2),
    Duration preparationTimeout = const Duration(seconds: 90),
  }) : _store = store,
       _find = find,
       _acquire = acquire,
       _inspect = inspect,
       _searchTimeout = searchTimeout,
       _preparationTimeout = preparationTimeout;

  static const _prefix = 'book-searches/';
  static final _validId = RegExp(r'^[A-Za-z0-9_-]{16,80}$');
  static const _retention = Duration(hours: 2);
  static const _ownerRecordLimit = 120;
  static const _ownerSearchLimit = 4;
  static const _candidateLimit = 24;
  static const maxSearchAttempts = 5;

  final CloudStore _store;
  final BookSearchProvider _find;
  final BookSearchFileAcquirer _acquire;
  final BookSearchSourceInspector? _inspect;
  final Duration _searchTimeout;
  final Duration _preparationTimeout;
  final _active = <String, _RunningSearch>{};
  final _preparing = <String, _PreparingCandidate>{};
  DateTime? _lastCleanup;

  bool hasSearch({required String owner, required String id}) =>
      _get(_key(owner, id)) != null;

  Map<String, dynamic> start({
    required String owner,
    required String id,
    required String query,
    BookSearchQuery? criteria,
    BookSearchQuery? requiredMatch,
    Uri? source,
  }) {
    if (source != null && _inspect == null) {
      throw const BookSearchException(503, '当前无法检查来源页。');
    }
    _prune();
    final key = _key(owner, id);
    final normalized = query.trim();
    final existing = _get(key);
    final storedMatch = existing?.value['requiredMatch'];
    final requested = criteria ?? BookSearchQuery.fromText(normalized);
    // A search task owns its original constraints across model retries. Direct
    // requests use the explicit filters parsed from the user's typed query.
    final priorConstraints = storedMatch is Map
        ? BookSearchQuery.fromStoredConstraints(storedMatch)
        : requiredMatch ??
              (criteria == null ? requested : const BookSearchQuery());
    final original = priorConstraints.withRequiredMatch(
      BookSearchQuery(
        author: priorConstraints.author.isEmpty ? requested.author : '',
        translator: priorConstraints.translator.isEmpty
            ? requested.translator
            : '',
      ),
    );
    final filters = requested.withRequiredMatch(original);
    final attempt = {
      ...filters.toJson(),
      if (source != null) 'source': source.toString(),
    };
    final hash = _criteriaHash(attempt);
    if (!filters.hasIdentity ||
        normalized.length > (criteria == null ? 240 : 640)) {
      throw const BookSearchException(400, '请提供有效的书名、作者、ISBN 或主题。');
    }

    if (existing != null) {
      if (existing.value['status'] == 'stopped' ||
          _candidates(existing).any(_exactDownloadable)) {
        return _snapshot(existing);
      }
      final attempts = List<String>.from(
        existing.value['attemptHashes'] as List? ?? const [],
      );
      final attemptCriteria = List<Map<String, dynamic>>.from(
        (existing.value['attemptCriteria'] as List? ?? const [])
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row)),
      );
      final previousHash = attempts.isEmpty ? null : attempts.last;
      if (previousHash == hash) {
        return _snapshot(_recoverInterrupted(key, existing));
      }
      if (existing.value['status'] == 'searching') {
        throw const BookSearchException(409, '上一轮查找仍在执行，请等待结果后再调整条件。');
      }
      if (attempts.contains(hash)) {
        return _snapshot(existing);
      }
      if (attempts.length >= maxSearchAttempts) {
        return _snapshot(_change(key, existing, {'exhausted': true}));
      }
      final prefix = _ownerPrefix(owner);
      if (_active.length >= 40 ||
          _active.keys.where((key) => key.startsWith(prefix)).length >=
              _ownerSearchLimit) {
        throw const BookSearchException(429, '当前查找较多，请稍后再试。');
      }
      final next = _change(key, existing, {
        'query': normalized,
        'criteria': filters.toJson(),
        if (storedMatch == null ||
            priorConstraints.author != original.author ||
            priorConstraints.translator != original.translator)
          'requiredMatch': original.toJson(),
        'status': 'searching',
        'partial': false,
        'exhausted': false,
        'attemptHashes': [...attempts, hash],
        'attemptCriteria': [...attemptCriteria, attempt],
      });
      final operation = _active[key] = _RunningSearch();
      unawaited(_run(key, filters, original, operation, source: source));
      return _snapshot(next);
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
      requiredMatch: original,
      attemptHashes: [hash],
      attemptCriteria: [attempt],
    );
    final operation = _active[key] = _RunningSearch();
    unawaited(_run(key, filters, original, operation, source: source));
    return _snapshot(entry);
  }

  Map<String, dynamic> read({required String owner, required String id}) {
    final key = _key(owner, id);
    return _snapshot(_recoverInterrupted(key, _require(key)));
  }

  Map<String, dynamic> readForAgent({
    required String owner,
    required String id,
  }) {
    final key = _key(owner, id);
    final entry = _recoverInterrupted(key, _require(key));
    return {
      ..._snapshot(entry),
      'attemptedCriteria': entry.value['attemptCriteria'] ?? const [],
      'effectiveCriteria': entry.value['criteria'] ?? const {},
      'diagnostics': entry.value['diagnostics'] ?? const [],
      'requiredMatch': entry.value['requiredMatch'] ?? const {},
    };
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
    _cancelPreparations(key);
    final entry = _get(key);
    if (entry == null) {
      // The close action can arrive before a delayed start request.
      _checkOwnerCapacity(owner);
      return _snapshot(_create(key, id, 'stopped'));
    }
    final active = _active[key];
    if (active != null) return _snapshot(_finish(key, active, 'stopped'));
    return _snapshot(_change(key, entry, {'status': 'stopped'}));
  }

  void stopOwner(String owner) {
    final prefix = _ownerPrefix(owner);
    for (final key in _active.keys.toList()) {
      if (key.startsWith(prefix)) _finish(key, _active[key]!, 'stopped');
    }
    for (final operation in _preparing.values.toList()) {
      if (operation.searchKey.startsWith(prefix)) {
        operation.cancellation._cancel();
        final entry = _get(operation.searchKey);
        if (entry != null && entry.value['status'] != 'stopped') {
          _change(operation.searchKey, entry, {'status': 'stopped'});
        }
      }
    }
  }

  Future<Map<String, dynamic>> resolve({
    required String owner,
    required String id,
    required String candidateId,
    String? acceptedCandidateToken,
  }) async {
    final key = _key(owner, id);
    final entry = _require(key);
    if (entry.value['status'] == 'stopped') {
      throw const BookSearchException(409, '找书已停止，请重新查找。');
    }
    if (entry.value['status'] == 'searching') {
      throw const BookSearchException(409, '查找仍在执行，请等待结果后再下载。');
    }
    final candidates = _candidates(entry);
    final candidate = candidates
        .where((row) => row['id'] == candidateId)
        .firstOrNull;
    if (candidate == null) {
      throw const BookSearchException(404, '该版本已失效，请重新查找。');
    }
    if (candidate['confirmationReason'] is String) {
      if (!_canOfferAlternative(entry, candidates) ||
          candidate['downloadable'] != true ||
          candidate['candidateToken'] is! String) {
        throw const BookSearchException(409, '这份替代版已不可用，请重新查找。');
      }
      final token = candidate['candidateToken'];
      if (acceptedCandidateToken != null && acceptedCandidateToken != token) {
        throw const BookSearchException(409, '候选版本已变化，请重新确认。');
      }
      if (acceptedCandidateToken != token &&
          candidate['acceptedCandidateToken'] != token) {
        throw const BookSearchException(409, '请先确认下载并导入这份替代版。');
      }
    }
    if (candidate['downloadable'] != true) {
      throw const BookSearchException(409, '该版本只有书目信息，没有文件入口。');
    }
    if (acceptedCandidateToken != null &&
        acceptedCandidateToken != candidate['candidateToken']) {
      throw const BookSearchException(409, '候选版本已变化，请重新确认。');
    }
    if (candidate['verified'] == true && candidate['fileKey'] is String) {
      _stagedFile(candidate);
      return {..._publicCandidate(candidate), 'importable': true};
    }
    final preparationKey = _blobKey(key, candidateId);
    final existing = _preparing[preparationKey];
    if (existing != null) return existing.result;
    final ownerPrefix = _ownerPrefix(owner);
    if (_preparing.length >= 40 ||
        _preparing.values
                .where((item) => item.searchKey.startsWith(ownerPrefix))
                .length >=
            _ownerSearchLimit) {
      throw const BookSearchException(429, '当前下载较多，请稍后再试。');
    }
    final operation = _PreparingCandidate(key);
    _preparing[preparationKey] = operation;
    operation.result = _prepareForImport(key, candidate, operation)
        .whenComplete(() {
          operation.cancellation._cancel();
          if (identical(_preparing[preparationKey], operation)) {
            _preparing.remove(preparationKey);
          }
        });
    return operation.result;
  }

  void _cancelPreparations(String searchKey) {
    for (final operation in _preparing.values) {
      if (operation.searchKey == searchKey) operation.cancellation._cancel();
    }
  }

  Future<Map<String, dynamic>> _prepareForImport(
    String key,
    Map<String, dynamic> row,
    _PreparingCandidate operation,
  ) async {
    final started = Stopwatch()..start();
    final selected = BookSearchCandidate._fromStored(row);
    final canReplace =
        !selected.alternateEdition &&
        selected.title.trim().isNotEmpty &&
        selected.author.trim().isNotEmpty &&
        selected.language.trim().isNotEmpty &&
        selected.edition.trim().isNotEmpty;
    final primary = BookSearchCancellation();
    final discovery = BookSearchCancellation();
    unawaited(
      operation.cancellation.whenCancelled.then((_) {
        primary._cancel();
        discovery._cancel();
      }),
    );
    Future<BookSearchCandidate?>? replacementLookup;
    Future<BookSearchCandidate?> findReplacement() {
      final budget = (_preparationTimeout - started.elapsed) ~/ 3;
      const cap = Duration(seconds: 8);
      return replacementLookup ??= _findReplacement(
        key,
        selected,
        discovery,
        budget < cap ? budget : cap,
      );
    }

    // Start looking for a substitute when the selected source stalls. The
    // original download keeps its full budget if no safe substitute exists.
    var stalled = false;
    final lookAhead = canReplace
        ? Timer(_preparationTimeout * 0.7, () {
            unawaited(
              findReplacement().then((replacement) {
                if (replacement != null && !primary.isCancelled) {
                  stalled = true;
                  primary._cancel();
                }
              }),
            );
          })
        : null;
    final Map<String, dynamic> primaryResult;
    try {
      primaryResult = await _prepareCandidate(
        key,
        selected,
        selected.id,
        primary,
        _preparationTimeout,
      );
    } finally {
      lookAhead?.cancel();
      primary._cancel();
    }
    var prepared = stalled && primaryResult['verified'] != true
        ? {
            ...primaryResult,
            'preparationStatus': 'timed_out',
            'availability': '获取整本文件超时，未通过核验',
          }
        : primaryResult;
    var replacedSource = false;
    try {
      if (canReplace &&
          prepared['verified'] != true &&
          !operation.cancellation.isCancelled) {
        final replacement = await findReplacement();
        final remaining = _preparationTimeout - started.elapsed;
        if (replacement != null &&
            remaining > Duration.zero &&
            !operation.cancellation.isCancelled) {
          final alternate = await _prepareCandidate(
            key,
            replacement,
            selected.id,
            operation.cancellation,
            remaining,
          );
          if (alternate['verified'] == true) {
            prepared = alternate;
            replacedSource = true;
          }
        }
      }
    } finally {
      discovery._cancel();
    }
    if (operation.cancellation.isCancelled) {
      if (prepared['verified'] == true) {
        _store.deleteTaskBlob(_blobKey(key, selected.id));
      }
      throw const BookSearchException(409, '下载已停止。');
    }
    final entry = _get(key);
    if (entry == null) {
      _store.deleteTaskBlob(_blobKey(key, row['id'] as String));
      throw const BookSearchException(404, '找书记录已失效，请重新查找。');
    }
    final candidates = _candidates(entry);
    final index = candidates.indexWhere((item) => item['id'] == row['id']);
    if (entry.value['status'] == 'stopped' ||
        index < 0 ||
        candidates[index]['candidateToken'] != row['candidateToken'] ||
        (row['confirmationReason'] is String &&
            !_canOfferAlternative(entry, candidates))) {
      _store.deleteTaskBlob(_blobKey(key, row['id'] as String));
      throw const BookSearchException(409, '候选版本已变化，请重新查找。');
    }
    // Use the same selection and file endpoint, with the actual source's metadata.
    final result = {
      if (!replacedSource) ...row,
      ...prepared,
      'id': selected.id,
      'candidateToken': row['candidateToken'],
    };
    if (row['confirmationReason'] is String && prepared['verified'] == true) {
      result['importable'] = false;
      result['acceptedCandidateToken'] = row['candidateToken'];
      result['acceptedSha256'] = prepared['fileSha256'];
    }
    candidates[index] = result;
    _change(key, entry, {'candidates': candidates});
    if (prepared['verified'] != true) {
      throw BookSearchException(
        prepared['preparationStatus'] == 'timed_out' ? 408 : 422,
        result['availability'] as String? ?? '文件未通过完整性核验。',
      );
    }
    return {..._publicCandidate(result), 'importable': true};
  }

  Future<BookSearchCandidate?> _findReplacement(
    String key,
    BookSearchCandidate selected,
    BookSearchCancellation cancellation,
    Duration timeout,
  ) async {
    final entry = _get(key);
    if (entry == null || cancellation.isCancelled || timeout <= Duration.zero) {
      return null;
    }
    final filters = entry.value['criteria'];
    final required = entry.value['requiredMatch'];
    if (filters is! Map || required is! Map) return null;
    final constraints = BookSearchQuery.fromStoredConstraints(required);
    final query = BookSearchQuery(
      title: filters['title'] as String? ?? selected.title,
      author: filters['author'] as String? ?? '',
      translator: constraints.translator,
      // A catalog format may have its own ISBN. Reuse only the user's ISBN filter.
      isbn: filters['isbn'] as String? ?? '',
      language: selected.language,
      edition: filters['edition'] as String? ?? '',
      format: selected.format,
    );
    bool matches(BookSearchCandidate candidate) =>
        _sameEdition(selected, candidate) &&
        constraints.matchesAuthor(candidate.author) &&
        constraints.acceptsFile(
          title: candidate.title,
          edition: candidate.edition,
          format: candidate.format,
          language: candidate.language,
          isbn: candidate.isbn,
          translator: candidate.translator,
        );
    for (final row in _candidates(entry)) {
      final candidate = BookSearchCandidate._fromStored(row);
      if (matches(candidate)) return candidate;
    }

    final deadline = Timer(timeout, cancellation._cancel);
    StreamIterator<BookSearchCandidate>? iterator;
    try {
      iterator = StreamIterator(_find(query, cancellation));
      final cancelled = cancellation.whenCancelled.then((_) => false);
      while (await Future.any([iterator.moveNext(), cancelled])) {
        if (cancellation.isCancelled) return null;
        if (matches(iterator.current)) return iterator.current;
      }
    } on Exception {
      // Preserve the selected source's error when no replacement can be found.
    } finally {
      deadline.cancel();
      cancellation._cancel();
      unawaited(iterator?.cancel().catchError((_) {}));
    }
    return null;
  }

  bool _sameEdition(
    BookSearchCandidate selected,
    BookSearchCandidate candidate,
  ) {
    String normalized(String? text) =>
        (text ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    bool same(String? a, String? b) => normalized(a) == normalized(b);
    bool present(String? text) => normalized(text).isNotEmpty;
    if (candidate.id == selected.id ||
        candidate.alternateEdition ||
        (candidate.downloadUri == null && !candidate.inlineEpub) ||
        (candidate.downloadUri != null &&
            candidate.downloadUri == selected.downloadUri) ||
        !same(selected.title, candidate.title) ||
        !same(selected.author, candidate.author) ||
        !same(selected.translator, candidate.translator) ||
        !same(selected.edition, candidate.edition) ||
        !same(selected.format, candidate.format) ||
        !same(selected.language, candidate.language)) {
      return false;
    }
    final selectedIsbn = normalized(
      selected.isbn,
    ).replaceAll(RegExp(r'[- ]'), '');
    final candidateIsbn = normalized(
      candidate.isbn,
    ).replaceAll(RegExp(r'[- ]'), '');
    if (selectedIsbn.isNotEmpty || candidateIsbn.isNotEmpty) {
      return RegExp(r'^(?:97[89]\d{10}|\d{9}[\dx])$').hasMatch(selectedIsbn) &&
          selectedIsbn == candidateIsbn &&
          (!present(selected.publisher) ||
              !present(candidate.publisher) ||
              same(selected.publisher, candidate.publisher));
    }
    if (selected.sourceUri == candidate.sourceUri &&
        !selected.inlineEpub &&
        !candidate.inlineEpub) {
      return true;
    }
    return present(selected.publisher) &&
        present(selected.publicationYear) &&
        same(selected.publisher, candidate.publisher) &&
        same(selected.publicationYear, candidate.publicationYear);
  }

  File verifiedFile({
    required String owner,
    required String id,
    required String candidateId,
  }) {
    final key = _key(owner, id);
    final entry = _require(key);
    if (entry.value['status'] == 'stopped') {
      throw const BookSearchException(409, '下载已停止。');
    }
    final candidates = _candidates(entry);
    final candidate = candidates
        .where((row) => row['id'] == candidateId)
        .firstOrNull;
    if (candidate == null || candidate['fileKey'] is! String) {
      throw const BookSearchException(404, '已核验的电子书文件不存在或已过期。');
    }
    if (candidate['confirmationReason'] is String) {
      if (!_canOfferAlternative(entry, candidates) ||
          candidate['verified'] != true ||
          candidate['fileSha256'] is! String ||
          candidate['acceptedSha256'] != candidate['fileSha256']) {
        throw const BookSearchException(409, '请先确认导入这份替代版。');
      }
    } else if (candidate['importable'] != true) {
      throw const BookSearchException(404, '已核验的电子书文件不存在或已过期。');
    }
    return _stagedFile(candidate);
  }

  File _stagedFile(Map<String, dynamic> candidate) {
    final file = _store.taskBlobFile(candidate['fileKey'] as String);
    if (!file.existsSync()) {
      throw const BookSearchException(404, '已核验的电子书文件已过期，请重新查找。');
    }
    return file;
  }

  Future<void> _run(
    String key,
    BookSearchQuery query,
    BookSearchQuery requiredMatch,
    _RunningSearch search, {
    Uri? source,
  }) async {
    final cancellation = search.cancellation;
    final deadline = Timer(_searchTimeout, () {
      cancellation.report({
        'stage': 'search',
        'outcome': 'failed',
        'reason': 'timeout',
      });
      _finish(key, search, 'unavailable', usePartialResults: true);
    });
    StreamIterator<BookSearchCandidate>? iterator;
    try {
      iterator = StreamIterator(
        source == null
            ? _find(query, cancellation)
            : _inspect!(source, query, cancellation),
      );
      final cancelled = cancellation.whenCancelled.then((_) => false);
      while (await Future.any([iterator.moveNext(), cancelled])) {
        if (cancellation.isCancelled) return;
        final candidate = iterator.current;
        final entry = _require(key);
        final candidates = _candidates(entry);
        final alternative = candidate.alternateEdition;
        if (candidate.downloadUri != null || candidate.inlineEpub) {
          bool matches({required bool checkEdition}) =>
              requiredMatch.matchesAuthor(candidate.author) &&
              requiredMatch.acceptsFile(
                title: candidate.title,
                edition: candidate.edition,
                format: candidate.format,
                language: candidate.language,
                isbn: candidate.isbn,
                translator: candidate.translator,
                checkEdition: checkEdition,
              );
          if (alternative) {
            if (requiredMatch.edition.isEmpty ||
                requiredMatch.isbn.isNotEmpty ||
                !matches(checkEdition: false) ||
                matches(checkEdition: true) ||
                candidates.any((row) => row['confirmationReason'] is String)) {
              continue;
            }
          } else if (!matches(checkEdition: true)) {
            cancellation.report({
              'source': candidate.sourceUri.host,
              'stage': 'match',
              'outcome': 'rejected',
              'reason': 'constraint_mismatch',
            });
            continue;
          }
        } else if (alternative) {
          continue;
        }
        if (!candidates.any((row) => row['id'] == candidate.id)) {
          final discovered = candidate._toStored();
          discovered['candidateToken'] = sha256
              .convert(
                utf8.encode(
                  jsonEncode({'search': key, 'candidate': discovered}),
                ),
              )
              .toString();
          if (discovered['downloadable'] == true) {
            discovered['availability'] = candidate.inlineEpub
                ? '可生成电子书，下载后校验'
                : '已找到文件入口，下载后校验';
          }
          if (alternative) {
            discovered['confirmationReason'] =
                '这是替代版。你指定的是「${requiredMatch.edition}」。';
          }
          candidates.add(discovered);
          _change(key, entry, {'candidates': candidates});
          if (_exactDownloadable(discovered)) break;
          if (candidates.length >= _candidateLimit) break;
        }
      }
      if (!cancellation.isCancelled) _finish(key, search, 'complete');
    } on Object {
      if (!cancellation.isCancelled) {
        cancellation.report({
          'stage': 'search',
          'outcome': 'failed',
          'reason': 'source_pipeline_failed',
        });
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

  Future<Map<String, dynamic>> _prepareCandidate(
    String searchKey,
    BookSearchCandidate candidate,
    String selectionId,
    BookSearchCancellation operation,
    Duration timeout,
  ) async {
    final row = candidate._toStored();
    if (candidate.downloadUri == null && !candidate.inlineEpub) return row;
    final cancellation = BookSearchCancellation();
    unawaited(operation.whenCancelled.then((_) => cancellation._cancel()));
    final started = Stopwatch()..start();
    void checkTime() {
      if (started.elapsed >= timeout) {
        throw TimeoutException('整本文件准备超时');
      }
    }

    File? file;
    try {
      final acquisition = _acquire(candidate, cancellation).then((
        received,
      ) async {
        if (cancellation.isCancelled) {
          await _deleteTemporary(received);
          throw const BookSearchException(409, '下载已停止。');
        }
        return received;
      });
      file =
          await Future.any<File>([
            acquisition,
            cancellation.whenCancelled.then<File>(
              (_) => throw const BookSearchException(409, '下载已停止。'),
            ),
          ]).timeout(
            timeout,
            onTimeout: () {
              cancellation._cancel();
              throw TimeoutException('整本文件准备超时');
            },
          );
      final length = await file.length();
      if (length <= 128 || length > 256 * 1024 * 1024) {
        throw const BookSearchException(422, '整本文件大小无效。');
      }
      final digest = await sha256.bind(file.openRead()).first;
      if (cancellation.isCancelled) {
        throw const BookSearchException(409, '下载已停止。');
      }
      checkTime();
      final blobKey = _blobKey(searchKey, selectionId);
      await _store.putTaskBlobFile(blobKey, file);
      if (cancellation.isCancelled || started.elapsed >= timeout) {
        _store.deleteTaskBlob(blobKey);
        checkTime();
        throw const BookSearchException(409, '下载已停止。');
      }
      row.addAll({
        'importable': true,
        'verified': true,
        'fileKey': blobKey,
        'fileLength': length,
        'fileSha256': digest.toString(),
        'verifiedAt': DateTime.now().toUtc().toIso8601String(),
        'availability': '完整文件已核验',
        'preparationStatus': 'ready',
      });
      return row;
    } on BookSearchException catch (error) {
      return {
        ...row,
        'importable': false,
        'verified': false,
        'preparationStatus': 'failed',
        'availability': error.message,
      };
    } on TimeoutException {
      return {
        ...row,
        'importable': false,
        'verified': false,
        'preparationStatus': 'timed_out',
        'availability': '获取整本文件超时，未通过核验',
      };
    } on Object {
      return {
        ...row,
        'importable': false,
        'verified': false,
        'preparationStatus': 'failed',
        'availability': '整本文件未能通过下载与完整性核验',
      };
    } finally {
      cancellation._cancel();
      if (file != null) {
        await _deleteTemporary(file);
      }
    }
  }

  Future<void> _deleteTemporary(File file) async {
    try {
      await file.parent.delete(recursive: true);
    } on FileSystemException {
      // Temporary source files are not part of the durable search record.
    }
  }

  static bool isExactDownloadable(Map<dynamic, dynamic> row) =>
      row['downloadable'] == true &&
      row['confirmationReason'] is! String &&
      !const {'failed', 'timed_out'}.contains(row['preparationStatus']);

  bool _exactDownloadable(Map<String, dynamic> row) => isExactDownloadable(row);

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
      final attempts =
          (entry.value['attemptHashes'] as List? ?? const []).length;
      final hasImportable = _candidates(entry).any(_exactDownloadable);
      return _change(key, entry, {
        'status': isPartial ? 'complete' : status,
        if (isPartial) 'partial': true,
        'exhausted': attempts >= maxSearchAttempts && !hasImportable,
        'diagnostics': search.cancellation._diagnostics,
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
    BookSearchQuery? requiredMatch,
    List<String> attemptHashes = const [],
    List<Map<String, String>> attemptCriteria = const [],
  }) => _store.put(key, {
    'id': id,
    if (query != null) 'query': query,
    if (criteria != null) 'criteria': criteria.toJson(),
    if (requiredMatch != null) 'requiredMatch': requiredMatch.toJson(),
    'status': status,
    'createdMs': DateTime.now().millisecondsSinceEpoch,
    'attemptHashes': attemptHashes,
    'attemptCriteria': attemptCriteria,
    'candidates': [],
  }, null);

  StoredDocument _change(
    String key,
    StoredDocument entry,
    Map<String, dynamic> changes,
  ) => _store.put(key, {...entry.value, ...changes}, entry.revision);

  List<Map<String, dynamic>> _candidates(StoredDocument entry) =>
      List<Map<String, dynamic>>.from(entry.value['candidates'] as List);

  bool _canOfferAlternative(
    StoredDocument entry,
    List<Map<String, dynamic>> candidates,
  ) =>
      (entry.value['status'] == 'complete' ||
          entry.value['status'] == 'unavailable') &&
      !candidates.any(_exactDownloadable);

  Map<String, dynamic> _publicCandidate(Map<String, dynamic> row) => {...row}
    ..remove('fileKey')
    ..remove('acceptedSha256')
    ..remove('acceptedCandidateToken')
    ..remove('downloadUrl')
    ..remove('inlineEpub');

  Map<String, dynamic> _snapshot(StoredDocument entry) => {
    'id': entry.value['id'],
    'query': entry.value['query'] ?? '',
    'status': entry.value['status'],
    'revision': entry.revision,
    'attemptsUsed': (entry.value['attemptHashes'] as List? ?? const []).length,
    'attemptsRemaining':
        maxSearchAttempts -
        (entry.value['attemptHashes'] as List? ?? const []).length,
    if (entry.value['exhausted'] == true) 'exhausted': true,
    if (entry.value['partial'] == true) 'partial': true,
    'candidates': _visibleCandidates(entry),
  };

  List<Map<String, dynamic>> _visibleCandidates(StoredDocument entry) {
    final rows = _candidates(entry);
    final canOfferAlternative = _canOfferAlternative(entry, rows);
    return [
      for (final row in rows)
        if (row['confirmationReason'] is! String || canOfferAlternative)
          _publicCandidate(row),
    ];
  }

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
        if (_expired(entry)) {
          _store.delete(key, expectedRevision: entry.revision);
          final ownerPrefix = key.substring(
            _prefix.length,
            key.lastIndexOf('/'),
          );
          final id = key.substring(key.lastIndexOf('/') + 1);
          _store.deleteObjectsPrefix('book-search-files/$ownerPrefix/$id/');
        }
      }
      if (rows.length < pageSize) return;
      after = rows.last.$1;
    }
  }

  String _criteriaHash(Map<String, String> criteria) =>
      sha256.convert(utf8.encode(jsonEncode(criteria))).toString();

  String _blobKey(String searchKey, String candidateId) {
    final ownerPrefix = searchKey.substring(
      _prefix.length,
      searchKey.lastIndexOf('/'),
    );
    final id = searchKey.substring(searchKey.lastIndexOf('/') + 1);
    final hash = sha256.convert(utf8.encode(candidateId));
    return 'book-search-files/$ownerPrefix/$id/$hash';
  }
}

class _RunningSearch {
  final cancellation = BookSearchCancellation();
  final done = Completer<void>();
}

class _PreparingCandidate {
  _PreparingCandidate(this.searchKey);

  final String searchKey;
  final cancellation = BookSearchCancellation();
  late final Future<Map<String, dynamic>> result;
}
