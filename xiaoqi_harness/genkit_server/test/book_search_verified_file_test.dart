import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/book_search_sources.dart';

BookSearchCandidate _helloPdf() => BookSearchCandidate(
  id: 'hello-1.3.0-zh-python-pdf',
  title: 'Hello 算法 · Python 版',
  author: '靳宇栋（krahets）',
  language: '简体中文',
  edition: '1.3.0',
  format: 'pdf',
  sourceName: '作者官方仓库',
  sourceUri: Uri.https('github.com', '/krahets/hello-algo/releases/tag/1.3.0'),
  downloadUri: Uri.https(
    'github.com',
    '/krahets/hello-algo/releases/download/1.3.0/hello-algo_1.3.0_zh_python.pdf',
  ),
);

Future<HttpServer> _fileServer(
  List<int> bytes, {
  bool truncated = false,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response
      ..headers.contentType = ContentType('application', 'pdf')
      ..contentLength = truncated ? bytes.length - 40 : bytes.length;
    request.response.add(
      truncated ? bytes.sublist(0, bytes.length - 40) : bytes,
    );
    await request.response.close();
  });
  return server;
}

HttpClient _localClient(HttpServer server) => HttpClient()
  ..autoUncompress = false
  ..connectionFactory = ((_, _, _) =>
      Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
  ..findProxy = (_) => 'DIRECT';

void main() {
  final live = Platform.environment['XIAOQI_BOOK_SEARCH_LIVE'] == '1';
  final proxy = Platform.environment['XIAOQI_BOOK_SEARCH_TEST_PROXY'];
  for (final (query, title, author, edition, source) in [
    (
      const BookSearchQuery(
        title: 'Eloquent JavaScript',
        author: 'Marijn Haverbeke',
        edition: '第4版',
        language: 'English',
        format: 'epub',
      ),
      'Eloquent JavaScript',
      'Marijn Haverbeke',
      '4th edition',
      'https://eloquentjavascript.net/',
    ),
    (
      const BookSearchQuery(
        title: 'Think Python',
        author: 'Allen Downey',
        edition: '2nd edition',
        format: 'pdf',
      ),
      'Think Python',
      'Allen B. Downey',
      '2nd edition',
      'https://greenteapress.com/wp/think-python-2e/',
    ),
  ]) {
    test(
      'acquires the official whole file for $title',
      () async {
        final sources = BookSearchSources(
          clientFactory: proxy == null
              ? null
              : () => HttpClient()..findProxy = (_) => 'PROXY $proxy',
        );
        final cancellation = BookSearchCancellation();
        final candidate = await sources
            .searchByCriteria(query, cancellation)
            .firstWhere((row) => row.downloadUri != null);
        expect(candidate.title, title);
        expect(candidate.author, author);
        expect(candidate.edition, edition);
        expect(candidate.language, '英文');
        expect(candidate.format, query.format);
        expect(candidate.sourceUri.toString(), source);
        expect(candidate.license, 'CC BY-NC 3.0');
        final file = await sources.acquire(candidate, cancellation);
        addTearDown(() => file.parent.delete(recursive: true));
        expect(await file.length(), greaterThan(500000));
      },
      skip: !live,
      timeout: const Timeout(Duration(seconds: 110)),
    );
  }

  test(
    'downloads and retains the complete trusted PDF before returning it',
    () async {
      final bytes = Uint8List(320)
        ..setRange(0, 5, '%PDF-'.codeUnits)
        ..setRange(314, 320, '%%EOF\n'.codeUnits);
      final server = await _fileServer(bytes);
      addTearDown(() => server.close(force: true));
      final sources = BookSearchSources(
        clientFactory: () => _localClient(server),
      );

      final file = await sources.acquire(_helloPdf(), BookSearchCancellation());
      addTearDown(() => file.parent.delete(recursive: true));

      expect(await file.length(), bytes.length);
      expect(await file.readAsBytes(), bytes);
    },
  );

  test(
    'rejects a truncated file before it can become an importable result',
    () async {
      final bytes = Uint8List(320)
        ..setRange(0, 5, '%PDF-'.codeUnits)
        ..setRange(314, 320, '%%EOF\n'.codeUnits);
      final server = await _fileServer(bytes, truncated: true);
      addTearDown(() => server.close(force: true));
      final sources = BookSearchSources(
        clientFactory: () => _localClient(server),
      );

      await expectLater(
        sources.acquire(_helloPdf(), BookSearchCancellation()),
        throwsA(isA<Object>()),
      );
    },
  );

  test('rejects an EPUB whose reading order references a missing file', () async {
    final book = BookSearchCandidate(
      id: 'eloquent-javascript-4-en-epub',
      title: 'Eloquent JavaScript',
      author: 'Marijn Haverbeke',
      language: '英文',
      edition: '4th edition',
      format: 'epub',
      sourceName: 'Eloquent JavaScript 作者官网',
      sourceUri: Uri.https('eloquentjavascript.net', '/'),
      downloadUri: Uri.https(
        'eloquentjavascript.net',
        '/Eloquent_JavaScript.epub',
      ),
    );
    final archive = Archive()
      ..add(
        ArchiveFile.string('mimetype', 'application/epub+zip')
          ..compression = CompressionType.none,
      )
      ..add(
        ArchiveFile.string(
          'META-INF/container.xml',
          '<container><rootfiles><rootfile full-path="EPUB/book.opf"/></rootfiles></container>',
        ),
      )
      ..add(
        ArchiveFile.string(
          'EPUB/book.opf',
          '<package><manifest><item id="chapter" href="missing.xhtml"/>'
              '</manifest><spine><itemref idref="chapter"/></spine></package>',
        ),
      );
    final server = await _fileServer(ZipEncoder().encode(archive));
    addTearDown(() => server.close(force: true));
    final sources = BookSearchSources(
      clientFactory: () => _localClient(server),
    );
    await expectLater(
      sources.acquire(book, BookSearchCancellation()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'EPUB 正文章节缺失。',
        ),
      ),
    );
  });
}
