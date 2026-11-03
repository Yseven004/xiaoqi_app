import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../lib/services/database_service.dart';

Map<String, dynamic> update(String receipt, {String conversation = 'chat-1'}) =>
    {
      'receipt_id': receipt,
      'topic_id': 'topic-recall',
      'title': '主动回忆',
      'summary': '合上资料尝试提取，再核对。',
      'sections': [
        {
          'heading': '怎么练习',
          'items': ['先回忆，再核对'],
        },
      ],
      'conversation_id': conversation,
      'message_id': 'message-$receipt',
      'source_text': '我应该怎么复习？',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final service = DatabaseService();
  late Database db;
  late Directory root;
  late String path;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('learning-notes-');
    path = '${root.path}/notes.db';
    db = await databaseFactoryFfi.openDatabase(path);
    service.useDatabaseForTesting(db);
    await service.createForTesting(db);
  });
  tearDown(() async {
    service.useDatabaseForTesting(null);
    await db.close();
    root.deleteSync(recursive: true);
  });

  test(
    'cross-chat append survives restart and duplicate delivery preserves manual rich text',
    () async {
      await service.enqueueLearningNotes('alice', [update('first')]);
      final first = await service.applyLearningNotes('alice', {});
      final id = first.single.noteId;
      final manual = [
        {
          'insert': '我手动改过的内容',
          'attributes': {'bold': true, 'color': '#123456'},
        },
        {
          'insert': {'image': 'private/photo.png'},
        },
        {
          'insert': '\n',
          'attributes': {'align': 'center'},
        },
      ];
      await db.update(
        'notes',
        {
          'title': '我改过的标题',
          'content': '我手动改过的内容\n',
          'content_delta': jsonEncode(manual),
        },
        where: 'id=?',
        whereArgs: [id],
      );
      final addition = update('second', conversation: 'chat-2');
      await service.enqueueLearningNotes('alice', [addition, addition]);
      expect(await service.applyLearningNotes('alice', {id}), isEmpty);
      await db.close();
      db = await databaseFactoryFfi.openDatabase(path);
      service.useDatabaseForTesting(db);
      final next = await service.applyLearningNotes('alice', {});
      expect(next.single.noteId, id);
      final note = (await service.getNoteById(id))!;
      expect(note.title, '我改过的标题');
      expect(note.content, startsWith('我手动改过的内容\n'));
      final delta = jsonDecode(note.contentDelta) as List;
      expect(delta.take(manual.length).toList(), manual);
      expect(await service.applyLearningNotes('alice', {}), isEmpty);
      expect(await db.query('notes'), hasLength(1));
      expect(await db.query('note_chat_sources'), hasLength(2));
      expect(await service.learningNoteTopics('bob'), isEmpty);
    },
  );

  test(
    'pause and disabled chat retain pending data, deleted notes never resurrect',
    () async {
      await service.enqueueLearningNotes('alice', [update('one')]);
      expect(
        await service.applyLearningNotes(
          'alice',
          {},
          shouldContinue: () => false,
        ),
        isEmpty,
      );
      expect(
        await service.applyLearningNotes('alice', {}, enabledConversations: {}),
        isEmpty,
      );
      final saved = await service.applyLearningNotes(
        'alice',
        {},
        enabledConversations: {'chat-1'},
      );
      final id = saved.single.noteId;
      await db.update(
        'notes',
        {'is_deleted': 1},
        where: 'id=?',
        whereArgs: [id],
      );
      await service.enqueueLearningNotes('alice', [update('two')]);
      expect(await service.applyLearningNotes('alice', {}), isEmpty);
      expect(await db.query('notes'), hasLength(1));
      expect(
        (await db.query(
          'learning_note_queue',
          where: 'receipt_id=?',
          whereArgs: ['two'],
        )).single['status'],
        'deleted',
      );
    },
  );

  test(
    'migration adds only queue and topic tables without changing existing notes',
    () async {
      await service.enqueueLearningNotes('alice', [update('migrate')]);
      final id = (await service.applyLearningNotes('alice', {})).single.noteId;
      final before = (await service.getNoteById(id))!.toMap();
      await db.execute('DROP TABLE learning_note_queue');
      await db.execute('DROP TABLE learning_note_topics');
      await service.migrateForTesting(db, 34, 35);
      expect((await service.getNoteById(id))!.toMap(), before);
      await service.enqueueLearningNotes('alice', [update('after')]);
      expect(await db.query('learning_note_queue'), hasLength(1));
    },
  );

  test(
    'stale editor snapshot cannot erase an automatic append made just before opening',
    () async {
      await service.enqueueLearningNotes('alice', [update('baseline')]);
      final id = (await service.applyLearningNotes('alice', {})).single.noteId;
      final old = (await service.getNoteById(id))!;
      final extra = update('late')..['summary'] = '打开编辑器前刚刚追加的知识';
      await service.enqueueLearningNotes('alice', [extra]);
      await service.applyLearningNotes('alice', {});
      final operations = jsonDecode(old.contentDelta) as List;
      operations.add({
        'insert': '我的手工补充\n',
        'attributes': {'bold': true},
      });
      final edited = old.copyWith(
        content: '${old.content}我的手工补充\n',
        contentDelta: jsonEncode(operations),
        updatedAt: DateTime.now().toIso8601String(),
      );
      final saved = await service.saveNoteEditorSnapshot(
        edited,
        learningNotesBaseline: old.updatedAt,
      );
      expect(saved.$1.content, contains('我的手工补充'));
      expect(saved.$1.content.split('打开编辑器前刚刚追加的知识'), hasLength(2));
      final again = await service.saveNoteEditorSnapshot(
        saved.$1,
        learningNotesBaseline: saved.$1.updatedAt,
      );
      expect(again.$1.content, saved.$1.content);
    },
  );
}
