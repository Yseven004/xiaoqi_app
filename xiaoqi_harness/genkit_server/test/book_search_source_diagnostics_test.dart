import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/book_search_sources.dart';

Future<BookSearchSources> _sources(
  List<Map<String, Object>> diagnostics,
  void Function(HttpRequest) respond,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    respond(request);
    await request.response.close();
  });
  return BookSearchSources(
    clientFactory: () => HttpClient()
      ..connectionFactory = ((_, _, _) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
      ..findProxy = (_) => 'DIRECT',
    onDiagnostic: diagnostics.add,
  );
}

void main() {
  test('extracts only the EPUB declared by a licensed publisher', () async {
    final epub = ZipEncoder().encode(
      Archive()
        ..addFile(
          ArchiveFile.string('mimetype', 'application/epub+zip')
            ..compression = CompressionType.none,
        )
        ..addFile(
          ArchiveFile.string(
            'META-INF/container.xml',
            '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'book.opf',
            '''<package xmlns:dc="http://purl.org/dc/elements/1.1/">
              <metadata><dc:title>測試書</dc:title><dc:creator>寫書人</dc:creator>
              <dc:language>zh</dc:language></metadata>
              <manifest><item id="chapter" href="chapter.xhtml"/></manifest>
              <spine><itemref idref="chapter"/></spine>
             </package>''',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'chapter.xhtml',
            '<html><body>${'測試正文' * 450}</body></html>',
          ),
        ),
    );
    List<int> wrap({bool twoBooks = false}) {
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('book.epub', epub))
        ..addFile(ArchiveFile.string('__MACOSX/._book.epub', 'resource fork'));
      if (twoBooks) archive.addFile(ArchiveFile.bytes('other.epub', epub));
      return ZipEncoder().encode(archive);
    }

    var bytes = wrap();
    final diagnostics = <Map<String, Object>>[];
    final sources = await _sources(diagnostics, (request) {
      final response = request.response;
      switch (request.uri.path) {
        case '/':
          response.headers.contentType = ContentType.html;
          response.write('<nav><a href="/book/">圖書下載</a></nav>');
        case '/book/':
          response.headers.contentType = ContentType.html;
          response.write('''
            <html lang="zh-HK"><body><p>本平台所有圖書均採用
            <a href="https://creativecommons.org/licenses/by/4.0/">CC</a>。</p>
            <article><h2>測試書</h2><p>寫書人 著</p><p>測試出版社 2024</p>
            <a href="/book.epub_.zip">下載EPUB</a></article>
            </body></html>
          ''');
        default:
          response.headers.contentType = ContentType('application', 'zip');
          response.contentLength = bytes.length;
          response.add(bytes);
      }
    });
    const query = BookSearchQuery(
      title: '測試書',
      language: '繁體中文',
      format: 'epub',
    );
    final uri = Uri.https('press.example', '/book.epub_.zip');
    final candidate =
        (await sources.inspect(uri, query, BookSearchCancellation()).toList())
            .single;
    expect(candidate.sourceUri, uri.resolve('/book/'));
    expect(candidate.author, '寫書人');
    expect(candidate.publicationYear, '2024');
    final file = await sources.acquire(candidate, BookSearchCancellation());
    addTearDown(() async => file.parent.delete(recursive: true));
    expect(file.path, endsWith('.epub'));
    expect(await file.readAsBytes(), epub);

    bytes = wrap(twoBooks: true);
    await expectLater(
      sources.acquire(candidate, BookSearchCancellation()),
      throwsA(isA<FormatException>()),
    );
    expect(diagnostics.last, containsPair('reason', 'invalid_wrapped_epub'));
  });

  test('probes a PDF only if its exact URL matches the publication', () async {
    final diagnostics = <Map<String, Object>>[];
    final visited = <String>[];
    final sources = await _sources(diagnostics, (request) {
      visited.add(request.uri.path);
      final response = request.response;
      switch (request.uri.path) {
        case '/':
          response.headers.contentType = ContentType.html;
          response.write('<nav><a href="/publications">圖書下載</a></nav>');
        case '/publications':
          response.headers.contentType = ContentType.html;
          response.write('''
            <script type="application/ld+json">
              {"@type":"Book","name":"The River","author":{"name":"A. Writer"},
               "bookEdition":"2024","inLanguage":"en","datePublished":"2024",
               "license":"https://creativecommons.org/licenses/by/4.0/",
               "encoding":{"@type":"MediaObject","encodingFormat":"application/pdf",
                           "contentUrl":"/download?v=2024"}}
            </script>
          ''');
        default:
          final bytes = [...'%PDF-'.codeUnits, ...List<int>.filled(256, 32)];
          response.headers.contentType = ContentType('application', 'pdf');
          response.contentLength = bytes.length;
          response.add(bytes);
      }
    });
    const query = BookSearchQuery(
      title: 'The River',
      author: 'A. Writer',
      edition: '2024',
      format: 'pdf',
      language: '英文',
    );
    final file = Uri.https('press.example', '/download', {'v': '2024'});
    final results = await sources
        .inspect(file, query, BookSearchCancellation())
        .toList();
    final candidate = results.single;
    expect(candidate.downloadUri, file);
    expect(candidate.sourceUri, Uri.https(file.host, '/publications'));
    expect(candidate.author, 'A. Writer');
    expect(candidate.edition, '2024');
    expect(candidate.license, 'CC BY 4.0');
    expect(visited, ['/download', '/', '/publications', '/download']);

    visited.clear();
    expect(
      await sources
          .inspect(
            file.replace(query: 'v=2023'),
            query,
            BookSearchCancellation(),
          )
          .toList(),
      isEmpty,
    );
    // Matching metadata and file type cannot approve a different file URL.
    expect(visited, ['/download', '/', '/publications']);
    expect(
      diagnostics.last,
      containsPair('reason', 'direct_file_needs_publication_page'),
    );
  });

  test(
    'separates catalog no-match, upstream outage, and missing wiki title',
    () async {
      final diagnostics = <Map<String, Object>>[];
      final sources = await _sources(diagnostics, (r) {
        switch (r.uri.path) {
          case '/search.json':
            r.response.write('{"docs":[]}');
          case '/advancedsearch.php':
            r.response
              ..statusCode = HttpStatus.serviceUnavailable
              ..write('upstream-secret-body');
          case '/w/api.php':
            r.response.write('{"query":{"pages":[]}}');
        }
      });

      await expectLater(
        sources.search('仅用于测试的书名', BookSearchCancellation()).toList(),
        throwsA(isA<BookSearchException>()),
      );

      expect(
        diagnostics,
        contains(
          allOf(
            containsPair('source', 'open_library'),
            containsPair('outcome', 'no_match'),
          ),
        ),
      );
      expect(
        diagnostics,
        contains(
          allOf(
            containsPair('source', 'internet_archive'),
            containsPair('outcome', 'failed'),
            containsPair('upstream_status', 503),
          ),
        ),
      );
      expect(
        diagnostics,
        contains(
          allOf(
            containsPair('source', 'wikisource_zh'),
            containsPair('outcome', 'no_match'),
            containsPair('reason', 'title_not_found'),
          ),
        ),
      );
      expect(
        diagnostics.map((event) => event['attempt']).toSet(),
        hasLength(1),
      );
      final log = jsonEncode(diagnostics);
      expect(log, isNot(contains('仅用于测试的书名')));
      expect(log, isNot(contains('upstream-secret-body')));
      expect(log, isNot(contains('https:')));
    },
  );

  test(
    'separates unsupported wiki directory from a transport failure',
    () async {
      final diagnostics = <Map<String, Object>>[];
      final sources = await _sources(diagnostics, (r) {
        switch (r.uri.path) {
          case '/search.json':
            r.response.write('{"docs":[]}');
          case '/advancedsearch.php':
            r.response.write('{"response":{"docs":[]}}');
          case '/w/api.php':
            r.response.write(
              jsonEncode({
                'query': {
                  'pages': [
                    {
                      'ns': 0,
                      'title': '測試集',
                      'pageid': 10,
                      'categories': [
                        {'title': 'Category:PD-old'},
                      ],
                      'revisions': [
                        {
                          'revid': 20,
                          'slots': {
                            'main': {
                              'content': '{{header| author = 某作者}}\n[[第一章]]',
                            },
                          },
                        },
                      ],
                    },
                  ],
                },
              }),
            );
        }
      });

      expect(
        await sources.search('測試集', BookSearchCancellation()).toList(),
        isEmpty,
      );
      expect(
        diagnostics,
        contains(
          allOf(
            containsPair('source', 'wikisource_zh'),
            containsPair('outcome', 'rejected'),
            containsPair('reason', 'unsupported_directory_layout'),
          ),
        ),
      );
    },
  );

  test(
    'separates an official HTTP probe failure from an incomplete file',
    () async {
      final diagnostics = <Map<String, Object>>[];
      final visited = <String>[];
      var status = HttpStatus.notFound;
      final sources = await _sources(diagnostics, (r) {
        visited.add(r.uri.path);
        if (r.uri.path == '/search.json') {
          r.response.write('{"docs":[]}');
          return;
        }
        if (r.uri.path == '/advancedsearch.php') {
          r.response.write('{"response":{"docs":[]}}');
          return;
        }
        final bytes = [...'%PDF-'.codeUnits, ...List<int>.filled(250, 32)];
        r.response.statusCode = status;
        if (status == HttpStatus.ok) {
          r.response.contentLength = bytes.length;
          r.response.add(bytes);
        }
      });
      final cancellation = BookSearchCancellation();

      await expectLater(
        sources.search('《Hello 算法》 Python PDF', cancellation).toList(),
        throwsA(isA<BookSearchException>()),
      );
      expect(
        diagnostics,
        contains(
          allOf(
            containsPair('source', 'hello_algo'),
            containsPair('stage', 'probe'),
            containsPair('upstream_status', 404),
          ),
        ),
      );
      expect(visited, containsAll(['/search.json', '/advancedsearch.php']));

      status = HttpStatus.ok;
      visited.clear();
      final books = StreamIterator(
        sources.search('《Hello 算法》 Java PDF', cancellation),
      );
      addTearDown(books.cancel);
      expect(await books.moveNext(), isTrue);
      expect(visited, isNot(contains('/search.json')));
      await expectLater(
        sources.acquire(books.current, cancellation),
        throwsFormatException,
      );
      expect(
        diagnostics,
        contains(
          allOf(
            containsPair('source', 'hello_algo'),
            containsPair('stage', 'download'),
            containsPair('reason', 'incomplete_file'),
          ),
        ),
      );
      expect(await books.moveNext(), isFalse);
      expect(visited, containsAll(['/search.json', '/advancedsearch.php']));
    },
  );

  test(
    'keeps matching edition metadata and separately offers one official alternate',
    () async {
      final paths = <String>[];
      final sources = await _sources([], (r) {
        paths.add(r.uri.path);
        if (r.uri.path == '/search.json') {
          r.response.write(
            jsonEncode({
              'docs': [
                {
                  'author_name': ['靳宇栋'],
                  'editions': {
                    'docs': [
                      {
                        'key': '/books/OL41M',
                        'title': 'Hello 算法',
                        'edition_name': '1.2.0',
                      },
                      {
                        'key': '/books/OL42M',
                        'title': 'Hello 算法',
                        'edition_name': '1.3.0',
                      },
                    ],
                  },
                },
              ],
            }),
          );
        } else if (r.uri.path == '/advancedsearch.php') {
          r.response.write('{"response":{"docs":[]}}');
        } else if (r.uri.path == '/graphql') {
          r.response.write('{"data":{"books":[]}}');
        } else {
          final bytes = [...'%PDF-'.codeUnits, ...List<int>.filled(250, 32)];
          r.response.contentLength = bytes.length;
          r.response.add(bytes);
        }
      });
      final matches = await sources
          .search('Hello 算法 1.2.0', BookSearchCancellation())
          .toList();

      expect(
        paths.take(3),
        unorderedEquals(['/search.json', '/advancedsearch.php', '/graphql']),
      );
      expect(paths.length, 4);
      expect(matches.map((entry) => entry.edition), ['1.2.0', '1.3.0']);
      expect(matches.first.downloadUri, isNull);
      expect(matches.first.alternateEdition, isFalse);
      expect(matches.last.downloadUri?.path, endsWith('_zh_python.pdf'));
      expect(matches.last.alternateEdition, isTrue);
    },
  );

  for (final query in [
    '动手学深度学习 第一版 EPUB',
    'Hello 算法 纸质书',
    '《Hello 算法题解》1.2.0 PDF',
  ]) {
    test('does not substitute a different edition for $query', () async {
      final sources = await _sources([], (r) {
        if (r.uri.path == '/search.json') {
          r.response.write('{"docs":[]}');
        } else {
          r.response.write('{"response":{"docs":[]}}');
        }
      });
      expect(
        await sources.search(query, BookSearchCancellation()).toList(),
        isEmpty,
      );
    });
  }
}
