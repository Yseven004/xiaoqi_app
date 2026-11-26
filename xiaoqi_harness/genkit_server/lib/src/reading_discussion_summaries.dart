import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'store.dart';

typedef ReadingDiscussionTurn = ({
  String snapshotId,
  String userText,
  String answerText,
  List<String> sourceVersions,
});

/// A derived excerpt from the selected branch of a saved reading discussion.
/// Genkit snapshots remain the authority for the discussion and its branches.
class ReadingDiscussionSummaries {
  const ReadingDiscussionSummaries(this._store);

  final CloudStore _store;

  static const maxTurns = 4;
  static const _maxExcerpt = 640;
  static const _pageSize = 100;
  static final _word = RegExp(r'[a-z0-9]+|[\u3400-\u9fff]+');
  static final _space = RegExp(r'\s+');

  /// Replace the entire derived summary with the selected Genkit branch.
  void select({
    required String owner,
    required String bookKey,
    required String workflow,
    required String? sessionId,
    required String? snapshotId,
    required Iterable<ReadingDiscussionTurn> turns,
  }) {
    final key = _key(owner, bookKey, workflow);
    final previous = _store.get(key);
    if (previous?.value['deleted'] == true) return;
    final excerpts = <Map<String, dynamic>>[];
    for (final turn in turns.take(maxTurns)) {
      final user = _excerpt(turn.userText);
      final answer = _excerpt(turn.answerText);
      if (user.isEmpty || answer.isEmpty || turn.sourceVersions.isEmpty) {
        continue;
      }
      excerpts.add({
        'snapshot_id': turn.snapshotId,
        'user_text': user,
        'assistant_text': answer,
        'source_versions': turn.sourceVersions.toSet().toList()..sort(),
      });
    }
    if (snapshotId == null && previous == null) return;
    _store.put(key, {
      'workflow': workflow,
      'session_id': sessionId,
      'snapshot_id': snapshotId,
      'turns': excerpts,
    }, previous?.revision);
  }

  /// Return excerpts relevant to the query from this account's same book.
  /// Any excerpt that cites a source version needs a currently allowed scope.
  List<Map<String, dynamic>> related({
    required String owner,
    required String bookKey,
    required String query,
    Set<String> allowedSourceVersions = const {},
    String? excludeWorkflow,
    int limit = 3,
  }) {
    final queryTerms = _terms(_excerpt(query));
    if (queryTerms.isEmpty || limit < 1) return const [];
    final matches = <({int score, Map<String, dynamic> value})>[];
    final prefix = _prefix(owner, bookKey);
    String? cursor;
    while (true) {
      final page = _store.list(prefix, limit: _pageSize, afterKey: cursor);
      if (page.isEmpty) break;
      for (final (_, record) in page) {
        final workflow = record.value['workflow'];
        if (workflow == excludeWorkflow) continue;
        final relevant = <({int score, Map<String, dynamic> turn})>[];
        for (final turn in _turns(record.value)) {
          final versions = (turn['source_versions'] as List).cast<String>();
          if (versions.isEmpty ||
              !versions.every(allowedSourceVersions.contains)) {
            continue;
          }
          final text = '${turn['user_text']} ${turn['assistant_text']}';
          final terms = _terms(text);
          final score = queryTerms
              .where(terms.contains)
              .fold<int>(0, (count, term) => count + term.length);
          if (score > 0) relevant.add((score: score, turn: turn));
        }
        relevant.sort((left, right) => right.score.compareTo(left.score));
        if (relevant.isEmpty) continue;
        final best = relevant.first;
        matches.add((
          score: best.score,
          value: {
            'workflow': workflow,
            'session_id': record.value['session_id'],
            'selected_snapshot_id': record.value['snapshot_id'],
            ...best.turn,
          },
        ));
      }
      if (page.length < _pageSize) break;
      cursor = page.last.$1;
    }
    matches.sort((left, right) {
      final score = right.score.compareTo(left.score);
      if (score != 0) return score;
      return (left.value['workflow'] as String).compareTo(
        right.value['workflow'] as String,
      );
    });
    return matches.take(limit.clamp(1, 5)).map((match) => match.value).toList();
  }

  bool delete({
    required String owner,
    required String bookKey,
    required String workflow,
  }) {
    final key = _key(owner, bookKey, workflow);
    final previous = _store.get(key);
    if (previous?.value['deleted'] == true) return false;
    _store.put(key, {'deleted': true, 'turns': <Object>[]}, previous?.revision);
    return previous != null;
  }

  /// Revocation removes excerpts that retained this source version. The
  /// authoritative discussion history is managed by the conversation store.
  void deleteSource({
    required String owner,
    required String bookKey,
    required String sourceVersion,
  }) {
    final prefix = _prefix(owner, bookKey);
    String? cursor;
    while (true) {
      final page = _store.list(prefix, limit: _pageSize, afterKey: cursor);
      if (page.isEmpty) return;
      for (final (key, record) in page) {
        if (record.value['deleted'] == true) continue;
        final turns = _turns(record.value);
        final remaining = turns
            .where(
              (turn) =>
                  !(turn['source_versions'] as List).contains(sourceVersion),
            )
            .toList();
        if (remaining.isEmpty) {
          _store.delete(key, expectedRevision: record.revision);
        } else if (remaining.length != turns.length) {
          _store.put(key, {
            ...record.value,
            'turns': remaining,
          }, record.revision);
        }
      }
      if (page.length < _pageSize) return;
      cursor = page.last.$1;
    }
  }

  static List<Map<String, dynamic>> _turns(Map<String, dynamic> record) =>
      (record['turns'] as List).cast<Map<String, dynamic>>();

  static String _excerpt(String text) {
    final normalized = String.fromCharCodes(
      text.runes.take(_maxExcerpt * 2),
    ).replaceAll(_space, ' ').trim();
    return String.fromCharCodes(normalized.runes.take(_maxExcerpt));
  }

  static Set<String> _terms(String text) {
    final terms = <String>{};
    for (final match in _word.allMatches(text.toLowerCase())) {
      final value = match.group(0)!;
      if (value.codeUnitAt(0) >= 0x3400) {
        for (var i = 0; i + 1 < value.length; i++) {
          terms.add(value.substring(i, i + 2));
          if (i + 2 < value.length) terms.add(value.substring(i, i + 3));
        }
      } else if (value.length >= 2) {
        terms.add(value);
      }
    }
    return terms;
  }

  static String _prefix(String owner, String bookKey) =>
      'reading_discussion_summary/${_digest(owner)}/${_digest(bookKey)}/';

  static String _key(String owner, String bookKey, String workflow) =>
      '${_prefix(owner, bookKey)}${_digest(workflow)}';

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}
