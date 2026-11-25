import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoqi_app/models/reader_pagination.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/companion_annotation_library.dart';
import 'package:xiaoqi_app/services/companion_annotation_store.dart';
import 'package:xiaoqi_app/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'snapshot is idempotent, owns its media and survives book removal privately',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'xiaoqi_annotation_copy_',
      );
      final handle =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      handle.setMockMethodCallHandler(channel, (_) async => root.path);
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final database = DatabaseService()..useDatabaseForTesting(db);
      addTearDown(() async {
        handle.setMockMethodCallHandler(channel, null);
        database.useDatabaseForTesting(null);
        FlutterSecureStorage.setMockInitialValues({});
        await db.close();
        await root.delete(recursive: true);
      });
      await database.createForTesting(db);
      void signIn(String email) => FlutterSecureStorage.setMockInitialValues({
        'xiaoqi.auth.method.v1': 'email',
        'xiaoqi.auth.email.v1': email,
        'xiaoqi.capabilities.device_token.v1': 'synthetic',
      });
      signIn('alice@example.test');
      final scope = (await DatabaseService.currentPrivateNoteScope())!;
      final bookId = await db.insert('books', {
        'canonical_key': 'copy-fixture',
        'title': '试读',
        'created_at': '2026-11-25',
        'updated_at': '2026-11-25',
      });
      final image = await File(
        p.join(root.path, 'origin.png'),
      ).writeAsBytes([1, 2, 3]);
      final audio = await File(
        p.join(root.path, 'origin.m4a'),
      ).writeAsBytes([4, 5]);
      final selection = CompanionAnnotationSelection(
        bookId: bookId,
        sourceId: 42,
        sourceVersion: 'local-fixture',
        anchor: const PdfReaderAnchor(sourceId: '42', pageNumber: 3),
        locator: '第 3 页',
        quote: '完整引文第一行\n第二行',
        startOffset: 4,
        endOffset: 11,
      );
      CompanionAnnotation annotation(String revision, String body) =>
          CompanionAnnotation(
            id: 'local-annotation',
            revision: revision,
            selection: selection,
            text: body,
            images: [image.path],
            audio: [audio.path],
          );
      const library = CompanionAnnotationLibrary();
      final records = await Future.wait([
        library.copyToLibrary(annotation('v1', '初次摘录'), scope: scope),
        library.copyToLibrary(annotation('v1', '初次摘录'), scope: scope),
      ]);
      expect(records[0], records[1]);
      final id = records.first;
      final original = (await database.getNoteById(id))!;
      expect(original.content, contains(selection.quote));
      final delta = jsonDecode(original.contentDelta) as List;
      expect(quill.Document.fromJson(delta).toPlainText(), contains('初次摘录'));
      final attachments = await database.queryNoteAttachments(id);
      expect(attachments.map((value) => value.kind), ['audio', 'image']);
      final next = await library.copyToLibrary(
        annotation('v2', '第二版'),
        scope: scope,
      );
      expect(next, isNot(id));
      expect((await database.getNoteById(id))?.content, contains('初次摘录'));

      await image.delete();
      await audio.delete();
      expect(
        await library.copyToLibrary(annotation('v1', '初次摘录'), scope: scope),
        id,
      );
      await BookLibraryService().deleteBooks([bookId]);
      final detached = (await database.getNoteById(id))!;
      expect(detached.bookId, isNull);
      expect(detached.isDeleted, 0);
      expect(
        (await database.queryCompanionAnnotationSnapshot(id))?['source_id'],
        42,
      );
      expect(
        await File(
          p.join(root.path, attachments.first.relativePath),
        ).readAsBytes(),
        [4, 5],
      );
      expect(
        await File(
          p.join(root.path, attachments.last.relativePath),
        ).readAsBytes(),
        [1, 2, 3],
      );

      signIn('bob@example.test');
      expect(await database.getNoteById(id), isNull);
      expect(await database.queryAllNotes(), isEmpty);
      expect(await database.queryRecentNotes(), isEmpty);
      expect(await database.queryNoteAttachments(id), isEmpty);
      expect(await database.queryCompanionAnnotationSnapshot(id), isNull);
      await database.permanentlyDeleteNotes([id]);
      signIn('alice@example.test');
      expect(await database.getNoteById(id), isNotNull);
    },
  );
}
