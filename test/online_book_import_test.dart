import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoqi_app/models/book_recognition.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/database_service.dart';
import 'package:xiaoqi_app/services/online_book_import.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final databaseService = DatabaseService();
  late Directory root;
  late Database db;
  late BookLibraryService library;
  final book = BookRecord(
    title: '中文电子书',
    authors: ['作者'],
    edition: '数字版',
    source: 'online_book_search',
    sourceId: 'sample-zh-1',
  );
  final sourcePage = Uri.parse('https://www.hello-algo.com/');

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('online-book-import-');
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    databaseService.useDatabaseForTesting(db);
    await databaseService.createForTesting(db);
    library = BookLibraryService(databaseService: databaseService);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => root.path,
    );
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
    databaseService.useDatabaseForTesting(null);
    await db.close();
    await root.delete(recursive: true);
  });

  test('concurrent confirmations share one book and one source', () async {
    // Represents the staged artifact after downloader format validation.
    final file = File('${root.path}/download.epub')
      ..writeAsStringSync('staged');
    final results = await Future.wait([
      for (var index = 0; index < 2; index++)
        library.importVerifiedOnlineBook(
          book: book,
          sourcePath: file.path,
          displayName: '中文电子书.epub',
          format: 'epub',
          sourcePage: sourcePage,
        ),
    ]);
    final first = results.first.source;
    expect(results.map((result) => result.source.bookId).toSet(), {
      first.bookId,
    });
    expect(results.map((result) => result.source.id).toSet(), {first.id});
    expect(results.where((result) => result.reusedExisting), hasLength(1));
    final record = (await library.listSourcesForBook(first.bookId)).single;
    expect(record.originUri, sourcePage.toString());
    expect(record.canonicalUri, sourcePage.toString());
    expect(DateTime.tryParse(record.capturedAt), isNotNull);
    expect(await File(record.filePath).readAsString(), 'staged');
  });

  test('failed file import rolls back the new book', () async {
    await expectLater(
      library.importVerifiedOnlineBook(
        book: book,
        sourcePath: '${root.path}/missing.epub',
        displayName: '缺少的文件.epub',
        format: 'epub',
        sourcePage: sourcePage,
      ),
      throwsStateError,
    );
    expect(await db.query('books'), isEmpty);
    expect(await db.query('book_sources'), isEmpty);
  });

  test('reimport keeps the book and its user-edited title', () async {
    final file = File('${root.path}/download.epub')
      ..writeAsStringSync('staged');
    Future<int> confirmImport() async =>
        (await library.importVerifiedOnlineBook(
          book: book,
          sourcePath: file.path,
          displayName: '中文电子书.epub',
          format: 'epub',
          sourcePage: sourcePage,
        )).source.bookId;
    final bookId = await confirmImport();
    await library.updateBookMetadata(
      (await library.getBook(bookId))!.copyWith(title: '我改过的书名'),
    );
    expect(await confirmImport(), bookId);
    expect((await library.getBook(bookId))!.title, '我改过的书名');
  });

  test(
    'rejects unapproved download addresses before opening a connection',
    () async {
      for (final url in [
        'https://github.com/unapproved/repo/releases/download/v1/book.pdf',
        'https://release-assets.githubusercontent.com/anything',
        'https://zh-v2.d2l.ai:8443/d2l-zh.pdf',
        'http://zh-v2.d2l.ai/d2l-zh.pdf',
        'https://127.0.0.1/book.pdf',
        'https://ws-export.wmcloud.org/?format=epub-3&lang=zh&page=吶喊',
      ]) {
        await expectLater(
          importOnlineBook({
            'id': 'd2l-2.0.0-pytorch-pdf',
            'title': book.title,
            'format': 'pdf',
            'importable': true,
            'sourceUrl': sourcePage.toString(),
            'downloadUrl': url,
          }),
          throwsFormatException,
        );
      }
      final wiki = Uri.https('zh.wikisource.org', '/wiki/吶喊');
      for (final invalid in [
        {'sourceUrl': 'https://example.org/wiki/吶喊'},
        {'downloadUrl': 'https://example.org/book.epub'},
        {'epubBase64': 'AQID', 'sha256': 'wrong'},
      ]) {
        await expectLater(
          importOnlineBook({
            'id': 'wikisource-zh-11-12',
            'title': '吶喊',
            'format': 'epub',
            'importable': true,
            'inlineEpub': true,
            'sourceUrl': wiki.toString(),
            ...invalid,
          }),
          throwsFormatException,
        );
      }
    },
  );
}
