import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:xiaoqi_app/models/reader_pagination.dart';
import 'package:xiaoqi_app/services/companion_annotation_store.dart';
import 'package:xiaoqi_app/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'saves privately, edits the same selection, and rejects a stale edit after deletion',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final databaseService = DatabaseService()..useDatabaseForTesting(db);
      addTearDown(() async {
        databaseService.useDatabaseForTesting(null);
        await db.close();
      });
      await databaseService.createForTesting(db);
      final book = await db.insert('books', {
        'canonical_key': 'fixture',
        'title': '试读',
        'created_at': '2026-11-25',
        'updated_at': '2026-11-25',
      });
      final selection = CompanionAnnotationSelection(
        bookId: book,
        sourceId: 15,
        sourceVersion: 'fixture-source-version',
        anchor: const PdfReaderAnchor(sourceId: '15', pageNumber: 2),
        endAnchor: const PdfReaderAnchor(sourceId: '15', pageNumber: 3),
        locator: '第 2–3 页',
        quote: '第一段\n第二段',
        startOffset: 14,
        endOffset: 8,
        pdfPageTextHashes: const {2: 'page-2', 3: 'page-3'},
      );
      const store = CompanionAnnotationStore();
      final scope = await store.accountScope();
      Future<CompanionAnnotation> save(
        String text, {
        CompanionAnnotation? initial,
      }) => store.save(
        scope: scope,
        selection: selection,
        text: text,
        images: const [],
        audio: const [],
        initial: initial,
      );

      final created = await save('记一条');
      final read = (await store.list(scope, book)).single;
      expect(read.selection.quote, '第一段\n第二段');
      expect(read.selection.endAnchor, selection.endAnchor);
      expect(read.selection.pdfPageTextHashes, selection.pdfPageTextHashes);
      expect(await db.query('notes'), isEmpty);

      await expectLater(store.list('different-scope', book), throwsStateError);
      final revised = await save('编辑后', initial: created);
      expect(revised.id, created.id);
      expect(revised.revision, isNot(created.revision));
      await expectLater(save('过时编辑', initial: created), throwsStateError);

      await store.remove(scope, revised);
      expect(await store.list(scope, book), isEmpty);
      await expectLater(save('迟到的保存', initial: revised), throwsStateError);
      final recreated = await save('重新写一条');
      expect(recreated.id, isNot(created.id));
      await db.update(
        'books',
        {'is_deleted': 1},
        where: 'id = ?',
        whereArgs: [book],
      );
      expect(await store.list(scope, book), isEmpty);
    },
  );
}
