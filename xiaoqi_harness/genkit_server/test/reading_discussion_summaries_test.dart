import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/reading_discussion_summaries.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory directory;
  late CloudStore store;
  late ReadingDiscussionSummaries summaries;
  late Map<String, ReadingDiscussionTurn> turns;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('reading-discussions-');
    store = CloudStore(root: directory.path);
    summaries = ReadingDiscussionSummaries(store);
    turns = {};
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  void save({
    String owner = 'reader',
    String book = 'book-a',
    String workflow = 'discussion',
    String snapshot = 'first',
    String? parent,
    String user = '为什么选择女王大学？',
    String answer = '原文说他比较了两所学校。',
    List<String> versions = const ['edition-1'],
  }) {
    final turn = (
      snapshotId: snapshot,
      userText: user,
      answerText: answer,
      sourceVersions: versions,
    );
    turns[snapshot] = turn;
    summaries.select(
      owner: owner,
      bookKey: book,
      workflow: workflow,
      sessionId: 'session-$workflow',
      snapshotId: snapshot,
      turns: [turn, if (turns[parent] case final ancestor?) ancestor],
    );
  }

  List<Map<String, dynamic>> related(
    String query, {
    String owner = 'reader',
    String book = 'book-a',
    Set<String> versions = const {'edition-1'},
  }) => summaries.related(
    owner: owner,
    bookKey: book,
    query: query,
    allowedSourceVersions: versions,
  );

  test('related context is scoped to account, book and authorized version', () {
    save();
    save(owner: 'different-reader');
    save(book: 'book-b');
    save(workflow: 'other-edition', versions: ['edition-2']);
    final match = related('他为什么选择女王大学？').single;
    expect(match['workflow'], 'discussion');
    expect(match['snapshot_id'], 'first');
    expect(match['user_text'], '为什么选择女王大学？');
    expect(match['assistant_text'], '原文说他比较了两所学校。');
    expect(related('毫无关系的橙树'), isEmpty);
    expect(related('女王大学', versions: {}), isEmpty);
  });

  test('selected branch follows its exact parent, siblings stay separate', () {
    save();
    save(snapshot: 'second', parent: 'first', user: '该校第一学期有什么课程？');
    expect(related('女王大学').single['snapshot_id'], 'first');
    expect(related('女王大学').single['selected_snapshot_id'], 'second');
    save(snapshot: 'sibling', parent: 'other', user: '那座城市下雪吗？');
    expect(related('女王大学'), isEmpty);
    expect(related('城市下雪').single['snapshot_id'], 'sibling');
    save(snapshot: 'second', parent: 'first', user: '该校第一学期有什么课程？');
    expect(related('女王大学').single['selected_snapshot_id'], 'second');
    expect(related('城市下雪'), isEmpty);
  });

  test(
    'revocation removes relevant versions and deletion removes workflow',
    () {
      save();
      save(
        snapshot: 'second',
        parent: 'first',
        user: '学校旁边的广场在哪里？',
        versions: ['edition-2'],
      );
      summaries.deleteSource(
        owner: 'reader',
        bookKey: 'book-a',
        sourceVersion: 'edition-1',
      );
      expect(related('女王大学'), isEmpty);
      expect(
        related('学校旁边的广场', versions: {'edition-2'}).single['snapshot_id'],
        'second',
      );
      expect(
        summaries.delete(
          owner: 'reader',
          bookKey: 'book-a',
          workflow: 'discussion',
        ),
        isTrue,
      );
      expect(related('学校旁边的广场', versions: {'edition-2'}), isEmpty);
      save(versions: ['edition-2'], user: '学校旁边的广场在哪里？');
      expect(related('学校旁边的广场', versions: {'edition-2'}), isEmpty);
    },
  );

  test(
    'blank responses are excluded and excerpts are Unicode-safe and bounded',
    () {
      save(answer: ' ');
      expect(related('女王大学'), isEmpty);
      save(answer: '🦉' * 800);
      expect(
        (related('女王大学').single['assistant_text'] as String).runes.length,
        640,
      );
    },
  );
}
