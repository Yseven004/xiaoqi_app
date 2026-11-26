import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/book_source.dart';
import '../models/reader_pagination.dart';
import 'book_library_service.dart';

typedef ReadingBookIdentity = ({String book, String version});

class ReadingBookPreparation {
  ReadingBookPreparation._();

  static final instance = ReadingBookPreparation._();
  static const _prefix = 'reading-book.preparation.';
  static const _importedVersion = 'reading-book.imported-version.';
  static const _installationKey = 'reading-book.installation';
  static const _discussionDeletion = 'reading-book.delete-discussion.';
  static const _discussionSelection = 'reading-book.select-discussion.';
  static const _discussionOwners = 'reading-book.discussion-owner.';
  final _cloud = CapabilityCloudSync.instance;
  final _uploads = <(ReadingBookIdentity, String), Completer<void>>{};
  final _uploadFailures = <(ReadingBookIdentity, String)>{};
  final _revocations = <(ReadingBookIdentity, String), Future<void>>{};
  final _targets = <ReadingBookIdentity, Map<String, Object?>>{};
  final _targetAccounts = <ReadingBookIdentity, String>{};
  final _targetSequences = <ReadingBookIdentity, int>{};
  final _selectionWrites = <String, Future<void>>{};
  final _bookKeys = <int, Future<String>>{};
  Future<String>? _installation;
  int _sequence = 0;
  final _instanceId = CapabilityCloudSync.newTaskId();

  Future<String?> chosenAccount() => _cloud.signedInEmail;

  Future<String?> authorization() async {
    try {
      return (await _cloud.authenticatedHeaders())['Authorization'];
    } on Object {
      return null;
    }
  }

  Future<String> _installationId() => _installation ??= () async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_installationKey);
    if (existing != null) return existing;
    final id = CapabilityCloudSync.newTaskId();
    if (!await prefs.setString(_installationKey, id)) {
      throw StateError('资料绑定保存失败');
    }
    return id;
  }();

  Future<ReadingBookIdentity?> identity(BookSourceRecord source) async {
    final version = source.contentHash.toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) return null;
    return (book: await bookKey(source.bookId), version: version);
  }

  Future<String> bookKey(int bookId) => _bookKeys.putIfAbsent(bookId, () async {
    try {
      final edition = await BookLibraryService().readingEditionIdentity(bookId);
      final identity = edition == null
          ? ['reading-book-local-v1', await _installationId(), bookId]
          : ['reading-book-edition-v1', edition];
      return sha256.convert(utf8.encode(jsonEncode(identity))).toString();
    } on Object {
      _bookKeys.remove(bookId);
      rethrow;
    }
  });

  String _key(ReadingBookIdentity id) => '$_prefix${id.book}.${id.version}';

  Future<void> recordImport(
    BookSourceRecord source, {
    required bool cloudEnabled,
    required String? accountEmail,
  }) async {
    final id = await identity(source);
    if (id == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_key(id), true)) {
      throw StateError('云端资料选项保存失败');
    }
    if (!await prefs.setBool('$_importedVersion${id.version}', true)) {
      throw StateError('云端资料选项保存失败');
    }
    if (accountEmail == null) return;
    final account = sha256
        .convert(utf8.encode(accountEmail.trim().toLowerCase()))
        .toString();
    final key = '${_key(id)}.$account';
    if (!cloudEnabled) _stopUpload(id, account);
    final saved = await prefs.setString(
      key,
      jsonEncode({
        'book_id': source.bookId,
        'source_id': source.id,
        'allowed': cloudEnabled,
      }),
    );
    if (!saved) throw StateError('云端资料选项保存失败');
    unawaited(resume(BookLibraryService()));
  }

  Future<bool?> cloudChoice(
    BookSourceRecord source, {
    String? expectedAccount,
  }) async {
    final id = await identity(source);
    if (id == null) return null;
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_key(id))) {
      return prefs.containsKey('$_importedVersion${id.version}') ? false : null;
    }
    final email = (await chosenAccount())?.trim().toLowerCase();
    if (email == null || email.isEmpty) return false;
    if (expectedAccount != null && email != expectedAccount) return false;
    final account = sha256.convert(utf8.encode(email)).toString();
    final record = prefs.getString('${_key(id)}.$account');
    return record != null && (jsonDecode(record) as Map)['allowed'] == true;
  }

  Future<void> resume(
    BookLibraryService library, {
    Set<int> removedBookIds = const {},
    Set<int> removedSourceIds = const {},
  }) async {
    try {
      final removal = removedBookIds.isNotEmpty || removedSourceIds.isNotEmpty;
      final prefs = await SharedPreferences.getInstance();
      if (removal) {
        for (final key in prefs.getKeys().where(
          (key) => key.startsWith(_prefix),
        )) {
          final identifiers = key.substring(_prefix.length).split('.');
          final raw = prefs.getString(key);
          if (identifiers.length != 3 || raw == null) continue;
          final data = jsonDecode(raw);
          if (data is Map &&
              (removedBookIds.contains(data['book_id']) ||
                  removedSourceIds.contains(data['source_id']))) {
            _stopUpload((
              book: identifiers[0],
              version: identifiers[1],
            ), identifiers[2]);
          }
        }
      }
      final token = await authorization();
      if (token == null) return;
      final email = await _cloud.emailForAuthorization(token);
      final account = sha256.convert(utf8.encode(email)).toString();
      final uploads = <(BookSourceRecord, ReadingBookIdentity)>[];
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(_prefix) || !key.endsWith('.$account')) continue;
        try {
          final raw = prefs.getString(key);
          if (raw == null) continue;
          final data = jsonDecode(raw) as Map;
          final book = data['book_id'] as int;
          if (removal &&
              !removedBookIds.contains(book) &&
              !removedSourceIds.contains(data['source_id'])) {
            continue;
          }
          final activeBook = await library.getBook(book);
          final files = await library.listSourcesForBook(book);
          final source = files
              .where((file) => file.id == data['source_id'])
              .firstOrNull;
          if (prefs.getString(key) != raw) continue;
          final identifiers = key.substring(_prefix.length).split('.');
          final id = (book: identifiers[0], version: identifiers[1]);
          if (data['allowed'] == true &&
              activeBook != null &&
              source != null &&
              source.contentHash.toLowerCase() == id.version) {
            if (!removal) uploads.add((source, id));
          } else {
            _stopUpload(id, account);
            await _revoke(id, account, token);
            if (source == null && prefs.getString(key) == raw) {
              await prefs.remove(key);
            }
          }
        } on Object {
          // One unavailable source should not prevent checking the other rows.
        }
      }
      if (removal) return;
      unawaited(_syncDiscussionSelections(prefs, account, token));
      for (final key in prefs.getKeys()) {
        if (!key.startsWith('$_discussionDeletion$account.')) continue;
        try {
          final value = jsonDecode(prefs.getString(key)!) as List;
          await _cloud.deleteReadingDiscussion(
            value[0] as String,
            value[1] as String,
            authorization: token,
          );
          await prefs.remove(key);
        } on Object {
          // The pending removal is scoped to this account for later retry.
        }
      }
      for (final (source, id) in uploads) {
        await _schedule(library, source, id, account, email, token);
      }
    } on Object {
      // Persisted imports are retried on the next signed-in foreground entry.
    }
  }

  Future<void> deleteDiscussion(int bookId, String workflow) async {
    final prefs = await SharedPreferences.getInstance();
    final account =
        prefs.getString('$_discussionOwners$workflow') ??
        await _currentAccountHash();
    if (account == null) return;
    final key = '$_discussionDeletion$account.$workflow';
    final saved = await prefs.setString(
      key,
      jsonEncode([await bookKey(bookId), workflow]),
    );
    if (saved) {
      await prefs.remove('$_discussionSelection$account.$workflow');
      unawaited(resume(BookLibraryService()));
    }
  }

  Future<void> rememberDiscussionOwner(
    String workflow, {
    String? expectedAuthorization,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_discussionOwners$workflow';
    if (prefs.getString(key) != null) return;
    final email = expectedAuthorization == null
        ? (await chosenAccount())?.trim().toLowerCase()
        : await _cloud.emailForAuthorization(expectedAuthorization);
    if (email == null || email.isEmpty || prefs.getString(key) != null) return;
    final account = sha256.convert(utf8.encode(email)).toString();
    await prefs.setString(key, account);
  }

  Future<void> queueDiscussionSelection(
    int bookId,
    String workflow,
    String? snapshotId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final account = prefs.getString('$_discussionOwners$workflow');
    if (account == null) return;
    final book = await bookKey(bookId);
    if (prefs.containsKey('$_discussionDeletion$account.$workflow')) return;
    final key = '$_discussionSelection$account.$workflow';
    if (!await prefs.setString(key, jsonEncode([book, workflow, snapshotId]))) {
      throw StateError('伴读摘要同步状态保存失败');
    }
    unawaited(_resumeDiscussionSelections(prefs, account));
  }

  Future<void> _resumeDiscussionSelections(
    SharedPreferences prefs,
    String account,
  ) async {
    try {
      final token = await authorization();
      if (token == null) return;
      final email = await _cloud.emailForAuthorization(token);
      if (sha256.convert(utf8.encode(email)).toString() == account) {
        await _syncDiscussionSelections(prefs, account, token);
      }
    } on Object {
      // The saved selection will retry during the next foreground entry.
    }
  }

  Future<void> _syncDiscussionSelections(
    SharedPreferences prefs,
    String account,
    String token,
  ) async {
    final prefix = '$_discussionSelection$account.';
    for (final key in prefs.getKeys().where((key) => key.startsWith(prefix))) {
      final write = _selectionWrites.putIfAbsent(key, () async {
        var raw = prefs.getString(key);
        while (raw != null) {
          try {
            final value = jsonDecode(raw) as List;
            await _cloud.selectReadingDiscussion(
              value[0] as String,
              value[1] as String,
              value[2] as String?,
              authorization: token,
            );
            if (prefs.getString(key) == raw) await prefs.remove(key);
          } on Object {
            if (prefs.getString(key) == raw) break;
          }
          raw = prefs.getString(key);
        }
      });
      try {
        await write;
      } finally {
        if (identical(_selectionWrites[key], write)) {
          _selectionWrites.remove(key);
        }
      }
    }
  }

  Future<String?> _currentAccountHash() async {
    final email = (await chosenAccount())?.trim().toLowerCase();
    if (email == null || email.isEmpty) return null;
    return sha256.convert(utf8.encode(email)).toString();
  }

  void _stopUpload(ReadingBookIdentity id, String account) {
    final key = (id, account);
    _uploadFailures.remove(key);
    final abort = _uploads[key];
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  Future<void> _revoke(
    ReadingBookIdentity id,
    String account,
    String token,
  ) async {
    final binding = await _installationId();
    final key = (id, account);
    final pending = _revocations.putIfAbsent(
      key,
      () => _cloud.revokeReadingBook(
        id.book,
        id.version,
        authorization: token,
        binding: binding,
      ),
    );
    try {
      await pending;
    } finally {
      if (identical(_revocations[key], pending)) _revocations.remove(key);
    }
  }

  Future<void> _schedule(
    BookLibraryService library,
    BookSourceRecord source,
    ReadingBookIdentity id,
    String account,
    String email,
    String token,
  ) async {
    final key = (id, account);
    if (_uploads.containsKey(key)) return;
    final abort = _uploads[key] = Completer<void>();
    _uploadFailures.remove(key);
    try {
      await _revocations[key];
      if (abort.isCompleted) return;
      final binding = await _installationId();
      final (:status, :generation, :bound) = await _cloud.readingBookStatus(
        id.book,
        id.version,
        authorization: token,
        binding: binding,
      );
      final needsUpload =
          status == null ||
          const {
            'uploading',
            'failed',
            'complete_with_errors',
          }.contains(status['status']);
      if (needsUpload || !bound) {
        if (await File(source.filePath).length() == 0) {
          throw StateError('本机原文件为空');
        }
        final format = normalizeBookSourceFormat(source.format);
        if (format != 'pdf' && format != 'epub') return;
        final files = await library.listSourcesForBook(source.bookId);
        if (generation == null ||
            !files.any(
              (file) =>
                  file.id == source.id &&
                  file.contentHash == source.contentHash,
            ) ||
            await library.getBook(source.bookId) == null ||
            await cloudChoice(source, expectedAccount: email) != true ||
            abort.isCompleted) {
          return;
        }
        if (needsUpload) {
          await _cloud.createAttachment(
            path: source.filePath,
            name: 'book.$format',
            mimeType: format == 'pdf'
                ? 'application/pdf'
                : 'application/epub+zip',
            contentHash: id.version,
            abortTrigger: abort.future,
            expectedAuthorization: token,
            attachmentProfile: readingBookMarkItDownAttachmentProfile,
            readingBook: id,
            readingAuthorization: generation,
            readingBinding: binding,
          );
        } else {
          await _cloud.bindReadingBook(
            id.book,
            id.version,
            authorization: token,
            binding: binding,
            generation: generation,
          );
        }
      }
      if (abort.isCompleted) return;
      if (_targets[id] case final target?) await _sendTarget(id, target, token);
    } on Object catch (error) {
      if (!abort.isCompleted &&
          !(error is AttachmentCloudException &&
              error.code == 'account_changed')) {
        _uploadFailures.add(key);
      }
      // Keep the local book and the pending authorization for a later retry.
    } finally {
      _uploads.remove(key);
    }
  }

  Future<void> readingTarget(
    BookSourceRecord source,
    ReaderAnchor? anchor,
  ) async {
    final sequence = ++_sequence;
    final id = await identity(source);
    if (id == null || (_targetSequences[id] ?? 0) > sequence) return;
    _targetSequences[id] = sequence;
    final account = (await chosenAccount())?.trim().toLowerCase();
    if (account == null || _targetSequences[id] != sequence) {
      return;
    }
    if (anchor != null &&
        await cloudChoice(source, expectedAccount: account) != true) {
      return;
    }
    if (_targetSequences[id] != sequence) return;
    if (anchor == null && !_targets.containsKey(id)) return;
    final target = <String, Object?>{
      'instance': _instanceId,
      'sequence': sequence,
      if (anchor == null) 'release': true,
      if (anchor is FlowReaderAnchor) 'chapter_id': anchor.chapterId,
      if (anchor is PdfReaderAnchor) 'page': anchor.pageNumber,
    };
    _targets[id] = target;
    _targetAccounts[id] = account;
    final token = await authorization();
    if (token != null) await _sendTarget(id, target, token);
  }

  Future<void> _sendTarget(
    ReadingBookIdentity id,
    Map<String, Object?> target,
    String token,
  ) async {
    final account = (await chosenAccount())?.trim().toLowerCase();
    if (_targetSequences[id] != target['sequence'] ||
        !identical(_targets[id], target) ||
        _targetAccounts[id] != account) {
      return;
    }
    try {
      await _cloud.setReadingBookTarget(
        id.book,
        id.version,
        target,
        authorization: token,
        binding: await _installationId(),
      );
      if (target['release'] == true && identical(_targets[id], target)) {
        _targets.remove(id);
        _targetAccounts.remove(id);
      }
    } on Object {
      // A pending target may precede upload registration or a reconnect.
    }
  }

  Future<Map<String, dynamic>?> cloudStatus(BookSourceRecord source) async {
    final id = await identity(source);
    if (id == null) return null;
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_key(id))) {
      return prefs.containsKey('$_importedVersion${id.version}')
          ? {'status': 'local_only'}
          : null;
    }
    final email = (await chosenAccount())?.trim().toLowerCase();
    if (email == null || email.isEmpty) {
      final hadConsent = prefs.getKeys().any((key) {
        if (!key.startsWith('${_key(id)}.')) return false;
        final raw = prefs.getString(key);
        return raw != null && (jsonDecode(raw) as Map)['allowed'] == true;
      });
      return {'status': hadConsent ? 'waiting_for_login' : 'local_only'};
    }
    if (await cloudChoice(source, expectedAccount: email) != true) {
      return {'status': 'local_only'};
    }
    final token = await authorization();
    if (token == null) return {'status': 'pending'};
    try {
      if (await _cloud.emailForAuthorization(token) != email) return null;
      final result = await _cloud.readingBookStatus(
        id.book,
        id.version,
        authorization: token,
        binding: await _installationId(),
      );
      final account = sha256.convert(utf8.encode(email)).toString();
      if (await cloudChoice(source, expectedAccount: email) != true) return null;
      final key = (id, account);
      return (result.bound ? result.status : null) ??
          {
            'status': _uploads.containsKey(key)
                ? 'uploading'
                : _uploadFailures.contains(key)
                ? 'failed'
                : 'pending',
          };
    } on Object {
      return {'status': 'pending'};
    }
  }

  Future<Map<String, Object?>?> material(
    BookSourceRecord source,
    String token,
  ) async {
    final id = await identity(source);
    if (id == null) return null;
    final result = await _cloud.readingBookStatus(
      id.book,
      id.version,
      authorization: token,
      binding: await _installationId(),
    );
    if (!result.bound) return null;
    if (result.status?['id'] case final String remote) {
      return {
        'id': 'reading-book-$remote',
        'name': source.displayName,
        'reading_book_id': remote,
        'kind': 'document',
      };
    }
    return null;
  }
}
