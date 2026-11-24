import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoqi_app/models/book_recognition.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/book_download_storage.dart';
import 'package:xiaoqi_app/services/book_source_metadata.dart';
import 'package:xiaoqi_app/services/database_service.dart';
import 'package:xiaoqi_app/services/online_book_import.dart';

List<int> _minimalEpub() {
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes('mimetype', utf8.encode('application/epub+zip'))
        ..compression = CompressionType.none,
    )
    ..addFile(
      ArchiveFile.bytes(
        'META-INF/container.xml',
        utf8.encode(
          '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        ),
      ),
    )
    ..addFile(
      ArchiveFile.bytes(
        'OEBPS/content.opf',
        utf8.encode(
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Hello 算法</dc:title><dc:creator>靳宇栋</dc:creator><dc:publisher>测试出版社</dc:publisher><dc:date>2024-04-03</dc:date><dc:language>zh-CN</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>',
        ),
      ),
    )
    ..addFile(
      ArchiveFile.bytes(
        'OEBPS/chapter.xhtml',
        utf8.encode(
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head><body><h1>第一章</h1><p>测试正文。</p></body></html>',
        ),
      ),
    );
  return ZipEncoder().encode(archive);
}

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

  test(
    'local prefill reads the EPUB and failed import commits no book',
    () async {
      const fallback = BookRecord(title: 'download', source: 'local_epub');
      final file = File('${root.path}/download.epub')
        ..writeAsBytesSync(_minimalEpub());
      final preview = await BookSourceMetadataPreview.read(file.path, fallback);
      addTearDown(preview.dispose);
      expect(preview.book.title, 'Hello 算法');
      expect(preview.book.authors, ['靳宇栋']);
      expect(preview.book.publisher, '测试出版社');
      expect(preview.book.editionLabel, startsWith('2024'));
      await expectLater(
        library.importLocalBookWithSource(
          book: preview.book,
          sourcePath: '${root.path}/missing.epub',
          displayName: 'download.epub',
          format: 'epub',
        ),
        throwsStateError,
      );
      expect(await library.listBooks(), isEmpty);
      final imported = await library.importLocalBookWithSource(
        book: preview.book,
        sourcePath: file.path,
        displayName: 'download.epub',
        format: 'epub',
      );
      expect(
        (await library.getBook(imported.source.bookId))?.publisher,
        '测试出版社',
      );
    },
  );

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
    'imports only the staged file whose full length and hash were verified',
    () async {
      final bytes = _minimalEpub();
      final staged = File('${root.path}/verified.epub')
        ..writeAsBytesSync(bytes);
      final candidate = {
        'id': 'hello-algo-1.3.0-epub',
        'title': 'Hello 算法',
        'author': '靳宇栋',
        'language': '简体中文',
        'edition': '1.3.0',
        'format': 'epub',
        'sourceName': '作者官方仓库',
        'sourceUrl': 'https://github.com/krahets/hello-algo/releases/tag/1.3.0',
        'importable': true,
        'verified': true,
        'fileSha256': sha256.convert(bytes).toString(),
        'fileLength': bytes.length,
        'stagedFilePath': staged.path,
      };

      File? downloaded;
      final result = await importOnlineBook(
        candidate,
        library: library,
        saveDownload:
            ({
              required file,
              required displayName,
              required format,
              required sha256,
            }) async {
              downloaded = await saveVerifiedBookToDownloadDirectory(
                directory: Directory('${root.path}/Downloads'),
                file: file,
                displayName: displayName,
                format: format,
                expectedSha256: sha256,
              );
            },
      );
      expect(result.source.bookId, greaterThan(0));
      expect(await File(result.source.filePath).readAsBytes(), bytes);
      await staged.delete();
      expect(await downloaded!.readAsBytes(), bytes);
      expect(downloaded!.path, contains('Downloads'));
      expect(await File(result.source.filePath).readAsBytes(), bytes);
    },
  );

  test(
    'public save failure preserves library and retry reuses the same source',
    () async {
      final bytes = _minimalEpub();
      final staged = File('${root.path}/verified.epub')
        ..writeAsBytesSync(bytes);
      final candidate = {
        'id': 'hello-algo-1.3.0-epub',
        'title': 'Hello 算法',
        'author': '靳宇栋',
        'edition': '1.3.0',
        'format': 'epub',
        'sourceName': '作者官方仓库',
        'sourceUrl': 'https://github.com/krahets/hello-algo/releases/tag/1.3.0',
        'importable': true,
        'verified': true,
        'fileSha256': sha256.convert(bytes).toString(),
        'fileLength': bytes.length,
        'stagedFilePath': staged.path,
      };
      OnlineBookDownloadSaveException? failure;
      try {
        await importOnlineBook(
          candidate,
          library: library,
          saveDownload:
              ({
                required file,
                required displayName,
                required format,
                required sha256,
              }) async {
                throw const FileSystemException('disk full');
              },
        );
        fail('public save must not report success');
      } on OnlineBookDownloadSaveException catch (error) {
        failure = error;
      }
      expect(failure.message, contains('已导入书库'));
      expect(await File(failure.result.source.filePath).readAsBytes(), bytes);
      final retried = await importOnlineBook(
        candidate,
        library: library,
        saveDownload:
            ({
              required file,
              required displayName,
              required format,
              required sha256,
            }) async {
              await saveVerifiedBookToDownloadDirectory(
                directory: Directory('${root.path}/Downloads'),
                file: file,
                displayName: displayName,
                format: format,
                expectedSha256: sha256,
              );
            },
      );
      expect(retried.reusedExisting, isTrue);
      expect(retried.source.id, failure.result.source.id);
      expect(await db.query('books'), hasLength(1));
      expect(await db.query('book_sources'), hasLength(1));
    },
  );

  test(
    'download storage reuses bytes and never overwrites a modified public file',
    () async {
      final bytes = _minimalEpub();
      final source = File('${root.path}/verified.epub')
        ..writeAsBytesSync(bytes);
      final downloads = Directory('${root.path}/Downloads');
      Future<File> save() => saveVerifiedBookToDownloadDirectory(
        directory: downloads,
        file: source,
        displayName: '../标题/安全.epub',
        format: 'epub',
        expectedSha256: sha256.convert(bytes).toString(),
      );
      final first = await save();
      expect((await save()).path, first.path);
      expect(
        await FileSystemEntity.identical(
          first.parent.path,
          Directory('${downloads.path}/小栖').path,
        ),
        isTrue,
      );
      await first.writeAsString('用户改动');
      final replacement = await save();
      expect(replacement.path, isNot(first.path));
      expect(await first.readAsString(), '用户改动');
      expect(await replacement.readAsBytes(), bytes);
      expect((await save()).path, replacement.path);
    },
  );

  test('rejects a staged file changed after server verification', () async {
    final staged = File('${root.path}/modified.pdf')
      ..writeAsBytesSync('%PDF- altered'.codeUnits);
    await expectLater(
      importOnlineBook({
        'id': 'hello-algo-1.3.0-pdf',
        'title': 'Hello 算法',
        'format': 'pdf',
        'sourceUrl': 'https://github.com/krahets/hello-algo/releases/tag/1.3.0',
        'importable': true,
        'verified': true,
        'fileSha256': List.filled(64, '0').join(),
        'fileLength': 256,
        'stagedFilePath': staged.path,
      }, library: library),
      throwsFormatException,
    );
    expect(await db.query('books'), isEmpty);
    expect(await db.query('book_sources'), isEmpty);
  });

  test('long Chinese download names fit filesystem byte limits', () async {
    final bytes = _minimalEpub();
    final source = File('${root.path}/verified.epub')..writeAsBytesSync(bytes);
    final saved = await saveVerifiedBookToDownloadDirectory(
      directory: Directory('${root.path}/Downloads'),
      file: source,
      displayName: '${List.filled(100, '中文📖').join()}.epub',
      format: 'epub',
      expectedSha256: sha256.convert(bytes).toString(),
    );
    expect(utf8.encode(saved.uri.pathSegments.last).length, lessThan(255));
    expect(saved.uri.pathSegments.last, isNot(contains('\uFFFD')));
    expect(await saved.readAsBytes(), bytes);
  });

  test(
    'failed download copy validation leaves no published or staging file',
    () async {
      final source = File('${root.path}/verified.epub')
        ..writeAsBytesSync(_minimalEpub());
      final downloads = Directory('${root.path}/Downloads');
      await expectLater(
        saveVerifiedBookToDownloadDirectory(
          directory: downloads,
          file: source,
          displayName: '书.epub',
          format: 'epub',
          expectedSha256: List.filled(64, '0').join(),
        ),
        throwsFormatException,
      );
      expect(await Directory('${downloads.path}/小栖').list().toList(), isEmpty);
      expect(await source.exists(), isTrue);
    },
  );

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
