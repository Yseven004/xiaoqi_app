import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:xiaoqi_app/models/book_recognition.dart';
import 'package:xiaoqi_app/services/book_cover_storage.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/database_service.dart';

class _RecordingCoverStorage extends BookCoverStorage {
  _RecordingCoverStorage({
    required super.httpClient,
    required super.directoryFactory,
  });

  final storedPaths = <String>[];

  @override
  Future<BookRecord> persistCatalogueCover(BookRecord book) async {
    final stored = await super.persistCatalogueCover(book);
    storedPaths.add(stored.coverPath);
    return stored;
  }
}

Future<void> _waitUntil(Future<bool> Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Cover persistence did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final databaseService = DatabaseService();
  late BookLibraryService library;
  late Database db;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('book-metadata-update-');
    db = await databaseFactoryFfi.openDatabase('${root.path}/books.db');
    databaseService.useDatabaseForTesting(db);
    await databaseService.createForTesting(db);
    library = BookLibraryService(databaseService: databaseService);
  });

  tearDown(() async {
    databaseService.useDatabaseForTesting(null);
    await db.close();
    await root.delete(recursive: true);
  });

  test(
    'overlapping catalogue downloads retain the referenced cover only',
    () async {
      final requests = <Completer<http.Response>>[];
      final client = MockClient((_) {
        final request = Completer<http.Response>();
        requests.add(request);
        return request.future;
      });
      addTearDown(client.close);
      final storage = _RecordingCoverStorage(
        httpClient: client,
        directoryFactory: () async => root,
      );
      library = BookLibraryService(
        databaseService: databaseService,
        coverStorage: storage,
      );
      final bookId = await library.saveBook(
        const BookRecord(
          title: '封面并发测试',
          isbn13: '9787508614007',
          coverUrl: 'https://example.test/cover.jpg',
        ),
      );
      await _waitUntil(() async => requests.length == 1);
      await library.updateBookMetadata(
        (await library.getBook(bookId))!.copyWith(title: '更新书名'),
      );
      await _waitUntil(() async => requests.length == 2);

      requests[0].complete(
        http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'image/jpeg'},
        ),
      );
      await _waitUntil(
        () async => (await library.getBook(bookId))!.coverPath.isNotEmpty,
      );
      final referencedPath = (await library.getBook(bookId))!.coverPath;
      requests[1].complete(
        http.Response.bytes(
          [4, 5, 6],
          200,
          headers: {'content-type': 'image/jpeg'},
        ),
      );
      await _waitUntil(() async => storage.storedPaths.length == 2);
      expect(storage.storedPaths[0], isNot(storage.storedPaths[1]));
      await _waitUntil(
        () async => !await File(storage.storedPaths[1]).exists(),
      );

      expect((await library.getBook(bookId))!.coverPath, referencedPath);
      expect(await File(referencedPath).readAsBytes(), [1, 2, 3]);
    },
  );

  test('saves metadata and categories together', () async {
    final bookId = await library.saveBook(const BookRecord(title: '旧书名'));
    final categories = await library.listCategories();
    final originalCategoryId = categories.first.id!;
    final nextCategoryId = categories[1].id!;
    await library.setBookCategories(bookId, [originalCategoryId]);

    final updatedBook = (await library.getBook(bookId))!.copyWith(title: '新书名');
    await library.updateBookMetadataAndCategories(updatedBook, [
      nextCategoryId,
    ]);

    expect((await library.getBook(bookId))!.title, '新书名');
    final savedLinks = await db.query(
      'book_category_links',
      columns: ['category_id'],
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
    expect(savedLinks.single['category_id'], nextCategoryId);
  });

  test(
    'metadata and categories roll back together when category writes fail',
    () async {
      final bookId = await library.saveBook(const BookRecord(title: '初始书名'));
      final categories = await library.listCategories();
      final originalCategoryId = categories.first.id!;
      final nextCategoryId = categories[1].id!;
      await library.setBookCategories(bookId, [originalCategoryId]);

      await db.execute('''
      CREATE TRIGGER fail_book_category_link
      BEFORE INSERT ON book_category_links
      WHEN NEW.category_id = $nextCategoryId
      BEGIN
        SELECT RAISE(ABORT, 'injected category link failure');
      END
    ''');

      final updatedBook = (await library.getBook(
        bookId,
      ))!.copyWith(title: '不应保存的新书名');
      await expectLater(
        library.updateBookMetadataAndCategories(updatedBook, [nextCategoryId]),
        throwsA(isA<Exception>()),
      );

      final savedBook = (await library.getBook(bookId))!;
      final savedLinks = await db.query(
        'book_category_links',
        columns: ['category_id'],
        where: 'book_id = ?',
        whereArgs: [bookId],
      );
      expect(savedBook.title, '初始书名');
      expect(savedLinks, [
        {'category_id': originalCategoryId},
      ]);
    },
  );

  test(
    'duplicate metadata is rejected without changing the original category',
    () async {
      final firstId = await library.saveBook(const BookRecord(title: '第一本书'));
      final secondId = await library.saveBook(const BookRecord(title: '第二本书'));
      final categories = await library.listCategories();
      final originalCategoryId = categories.first.id!;
      final nextCategoryId = categories[1].id!;
      await library.setBookCategories(firstId, [originalCategoryId]);

      final firstBook = (await library.getBook(firstId))!;
      final secondBook = (await library.getBook(secondId))!;
      await expectLater(
        library.updateBookMetadataAndCategories(
          firstBook.copyWith(
            title: secondBook.title,
            authors: secondBook.authors,
            publisher: secondBook.publisher,
            edition: secondBook.edition,
          ),
          [nextCategoryId],
        ),
        throwsA(isA<StateError>()),
      );

      expect((await library.getBook(firstId))!.title, '第一本书');
      final savedLinks = await db.query(
        'book_category_links',
        columns: ['category_id'],
        where: 'book_id = ?',
        whereArgs: [firstId],
      );
      expect(savedLinks.single['category_id'], originalCategoryId);
    },
  );
}
