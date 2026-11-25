import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoqi_app/models/reader_pagination.dart';
import 'package:xiaoqi_app/services/companion_annotation_store.dart';
import 'package:xiaoqi_app/services/companion_annotation_sync.dart';
import 'package:xiaoqi_app/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'offline changes queue atomically and a second library remaps local IDs',
    () async {
      final dbA = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dbB = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final service = DatabaseService();
      await service.createForTesting(dbA);
      await service.createForTesting(dbB);
      final directory = await Directory.systemTemp.createTemp(
        'companion-sync-client-',
      );
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        pathChannel,
        (_) async => directory.path,
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathChannel, null);
        service.useDatabaseForTesting(null);
        FlutterSecureStorage.setMockInitialValues({});
        await dbA.close();
        await dbB.close();
        await directory.delete(recursive: true);
      });
      FlutterSecureStorage.setMockInitialValues({
        'xiaoqi.capabilities.device_token.v1': 'fixture-only-token',
        'xiaoqi.auth.method.v1': 'email',
        'xiaoqi.auth.email.v1': 'same-account@example.com',
      });
      final hash = 'a' * 64;
      Future<void> fixture(Database db, int book, int sourceId) async {
        await db.insert('books', {
          'id': book,
          'canonical_key': 'source fixture',
          'title': '试读',
          'created_at': '2026-11-25',
          'updated_at': '2026-11-25',
        });
        await db.insert('book_sources', {
          'id': sourceId,
          'book_id': book,
          'content_hash': hash,
          'display_name': '例子.pdf',
          'file_path': 'fixture.pdf',
          'created_at': '2026-11-25',
          'updated_at': '2026-11-25',
        });
      }

      await fixture(dbA, 4, 14);
      await fixture(dbB, 8, 18);
      const store = CompanionAnnotationStore();
      final sync = CompanionAnnotationSync.instance;
      final scope = await store.accountScope();
      service.useDatabaseForTesting(dbA);
      final saved = await store.save(
        scope: scope,
        selection: CompanionAnnotationSelection(
          bookId: 4,
          sourceId: 14,
          sourceVersion: hash,
          quote: '完整引文',
          locator: '第 2 页',
          anchor: const PdfReaderAnchor(sourceId: '14', pageNumber: 2),
          startOffset: 1,
          endOffset: 5,
        ),
        text: '离线编辑',
        images: const [],
        audio: const [],
      );
      final queued = (await dbA.query('companion_sync_outbox')).single;
      final remote = jsonDecode(queued['body'] as String) as Map;
      expect(jsonDecode(remote['selection']['anchor'])['source_id'], hash);
      await dbB.insert('companion_sync_inbox', {
        'scope': scope,
        'kind': 'note',
        'entity_id': saved.id,
        'book_key': queued['book_key'],
        'body': queued['body'],
      });
      await dbB.transaction((txn) async {
        await sync.freezeBookIdentity(txn, 8);
        await txn.update('books', {
          'title': '首次绑定前修改名称',
          'canonical_key': 'renamed-before-binding',
        }, where: 'id=8');
      });
      service.useDatabaseForTesting(dbB);
      final second = (await store.list(scope, 8)).single;
      expect(second.id, saved.id);
      expect(second.selection.sourceId, 18);
      expect(second.selection.anchor.sourceId, '18');

      await dbB.update('books', {
        'title': '修改名称',
        'canonical_key': 'renamed',
      }, where: 'id=8');
      final edited = await store.save(
        scope: scope,
        selection: second.selection,
        initial: second,
        text: '改名后编辑',
        images: const [],
        audio: const [],
      );
      expect(edited.id, saved.id);
      final newerQueue = (await dbB.query('companion_sync_outbox')).single;
      expect(newerQueue['book_key'], queued['book_key']);
      expect(
        jsonDecode(newerQueue['body'] as String)['edited_at'],
        greaterThan(remote['edited_at']),
      );
      await dbB.transaction(
        (txn) => sync.enqueueBookLifecycle(txn, scope, [8], deleted: true),
      );
      expect(await store.list(scope, 8), isEmpty);
      await dbB.transaction(
        (txn) => sync.enqueueBookLifecycle(txn, scope, [8], deleted: false),
      );
      expect((await store.list(scope, 8)).single.id, saved.id);

      service.useDatabaseForTesting(dbA);
      await dbA.delete('book_sources', where: 'id = ?', whereArgs: [14]);
      final withoutSource = await store.save(
        scope: scope,
        selection: saved.selection,
        initial: saved,
        text: '移除资料后继续编辑',
        images: const [],
        audio: const [],
      );
      final editedOperation =
          jsonDecode(
                (await dbA.query('companion_sync_outbox')).single['body']
                    as String,
              )
              as Map;
      expect(editedOperation['source_hash'], hash);
      expect(editedOperation['text'], withoutSource.text);
      await store.remove(scope, withoutSource);
      final deleteOperation =
          jsonDecode(
                (await dbA.query('companion_sync_outbox')).single['body']
                    as String,
              )
              as Map;
      expect(deleteOperation['source_hash'], hash);
      expect(deleteOperation['deleted'], true);

      final invalid = await File(
        '${directory.path}/bad.png',
      ).writeAsBytes([0, 1, 2]);
      await expectLater(
        sync.stageMedia(scope, [invalid.path], const []),
        throwsFormatException,
      );
    },
  );

  test(
    'a rolled-back cursor replays newer edits and confirmed deletions',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final service = DatabaseService();
      await service.createForTesting(db);
      service.useDatabaseForTesting(db);
      final directory = await Directory.systemTemp.createTemp(
        'companion-reset-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      FlutterSecureStorage.setMockInitialValues({
        'xiaoqi.capabilities.device_token.v1': 'fixture-only-token',
        'xiaoqi.auth.method.v1': 'email',
        'xiaoqi.auth.email.v1': 'reset-account@example.com',
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        service.useDatabaseForTesting(null);
        FlutterSecureStorage.setMockInitialValues({});
        await db.close();
        await directory.delete(recursive: true);
      });

      final hash = 'b' * 64;
      await db.insert('books', {
        'id': 1,
        'canonical_key': 'reset',
        'title': '读本',
        'created_at': '2026-11-25',
        'updated_at': '2026-11-25',
      });
      await db.insert('book_sources', {
        'id': 11,
        'book_id': 1,
        'content_hash': hash,
        'display_name': 'reset.pdf',
        'file_path': 'fixture.pdf',
        'created_at': '2026-11-25',
        'updated_at': '2026-11-25',
      });
      final sync = CompanionAnnotationSync.instance;
      const store = CompanionAnnotationStore();
      final scope = await store.accountScope();
      CompanionAnnotationSelection selection(int page) =>
          CompanionAnnotationSelection(
            bookId: 1,
            sourceId: 11,
            sourceVersion: hash,
            quote: '引文 $page',
            locator: '第 $page 页',
            anchor: PdfReaderAnchor(sourceId: '11', pageNumber: page),
          );
      Future<CompanionAnnotation> save(
        int page,
        String text, [
        CompanionAnnotation? initial,
      ]) => store.save(
        scope: scope,
        selection: selection(page),
        initial: initial,
        text: text,
        images: const [],
        audio: const [],
      );
      Map<String, Object?> payload(Map<String, Object?> row) =>
          (jsonDecode(row['body'] as String) as Map<String, Object?>)
            ..remove('operation_id');
      Future<Map<String, Object?>> acknowledge(String id) async {
        final row = (await db.query(
          'companion_sync_outbox',
          where: 'entity_id=?',
          whereArgs: [id],
        )).single;
        final item = payload(row);
        await db.insert('companion_sync_inbox', {
          'scope': scope,
          'kind': item['kind'],
          'entity_id': id,
          'book_key': item['book_key'],
          'body': jsonEncode(item),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await db.delete(
          'companion_sync_outbox',
          where: 'entity_id=?',
          whereArgs: [id],
        );
        return item;
      }

      final first = await save(1, '较早的文字');
      final removed = await save(2, '随后删除的文字');
      final backupFirst = await acknowledge(first.id);
      final backupRemoved = await acknowledge(removed.id);
      final edited = await save(1, '最后保存的文字', first);
      await store.remove(scope, removed);
      final latestEdit = await acknowledge(first.id);
      final latestDelete = await acknowledge(removed.id);
      final recreated = await save(2, '重新创建的注释');

      await sync.applyCursorResetForTesting(scope, [
        backupFirst,
        backupRemoved,
      ]);
      final active = await store.list(scope, 1);
      expect(
        active.map((annotation) => annotation.id),
        unorderedEquals([first.id, recreated.id]),
      );
      expect(
        active.singleWhere((annotation) => annotation.id == first.id).revision,
        edited.revision,
      );
      final queue = await db.query(
        'companion_sync_outbox',
        orderBy: 'recovery_priority DESC, position',
      );
      final restored = {
        for (final row in queue) row['entity_id']: payload(row),
      };
      expect(restored[first.id], latestEdit);
      expect(restored[removed.id], latestDelete);
      expect(queue.last['entity_id'], recreated.id);
      expect(await db.query('companion_sync_recovery'), isEmpty);

      await db.delete('companion_sync_outbox');
      final bookKey = backupFirst['book_key'] as String;
      final deletedBook = <String, Object?>{
        'kind': 'book',
        'book_key': bookKey,
        'generation': 2,
        'deleted': true,
      };
      await db.insert('companion_sync_inbox', {
        'scope': scope,
        'kind': 'book',
        'entity_id': bookKey,
        'book_key': bookKey,
        'body': jsonEncode(deletedBook),
      });
      final oldActiveBook = {...deletedBook, 'generation': 1, 'deleted': false};
      await sync.applyCursorResetForTesting(scope, [
        backupFirst,
        backupRemoved,
        oldActiveBook,
      ]);
      expect(await store.list(scope, 1), isEmpty);
      final fence = (await db.query(
        'companion_sync_outbox',
        where: 'entity_id=?',
        whereArgs: [bookKey],
      )).single;
      expect(fence['blocked_reason'], 'cursor_recovery');
      expect(payload(fence), deletedBook);
    },
  );
}
