import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/book_search_sources.dart';
import 'package:xiaoqi_genkit_server/src/gutenberg_books.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xml/xml.dart';

const _rdf = '''
<r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    xmlns:d="http://purl.org/dc/terms/"
    xmlns:g="http://www.gutenberg.org/2009/pgterms/">
  <g:ebook r:about="ebooks/23864">
    <d:title>孫子兵法</d:title>
    <d:language><r:Description><r:value>zh</r:value></r:Description></d:language>
    <d:type><r:Description><r:value>Text</r:value></r:Description></d:type>
    <d:issued>2007-12-15</d:issued>
    <d:rights>Public domain in the USA.</d:rights>
    <d:creator><g:agent>
      <g:name>Sunzi, active 6th century B.C.</g:name>
      <g:webpage r:resource="https://zh.wikipedia.org/wiki/%E5%AD%99%E6%AD%A6"/>
    </g:agent></d:creator>
    <d:hasFormat>
      <g:file r:about="https://www.gutenberg.org/ebooks/23864.epub3.images" />
    </d:hasFormat>
  </g:ebook>
</r:RDF>
''';

void main() {
  test('finds only exact indexed EPUB titles in either Chinese script', () {
    expect(GutenbergBooks.matchingIds(const BookSearchQuery(title: '西游记')), [
      23962,
    ]);
    expect(GutenbergBooks.matchingIds(const BookSearchQuery(title: '西遊記')), [
      23962,
    ]);
    for (final query in const [
      BookSearchQuery(title: '小西遊記'),
      BookSearchQuery(title: '西游记', format: 'pdf'),
      BookSearchQuery(title: '西游记', isbn: '9787508621050'),
      BookSearchQuery(title: '西游记', language: '简体中文'),
    ]) {
      expect(GutenbergBooks.matchingIds(query), isEmpty);
    }
  });

  test(
    'accepts a probed public-domain EPUB while Wikisource is pending',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <String>[];
      final pendingWiki = Completer<void>();
      final wikiDisconnected = Completer<void>();
      var metadata = _rdf;
      server.listen((request) async {
        seen.add(request.uri.path);
        final response = request.response;
        switch (request.uri.path) {
          case '/w/api.php':
            if (!pendingWiki.isCompleted) {
              final socket = await response.detachSocket(writeHeaders: false);
              pendingWiki.complete();
              socket.listen(
                (_) {},
                onDone: () {
                  wikiDisconnected.complete();
                  socket.destroy();
                },
              );
              return;
            }
            response.write('{"query":{"pages":[]}}');
          case '/search.json':
            response.write('{"docs":[]}');
          case '/advancedsearch.php':
            response.write('{"response":{"docs":[]}}');
          case '/graphql':
            response.write('{"data":{"books":[]}}');
          case '/cache/epub/23864/pg23864.rdf':
            await pendingWiki.future;
            response.write(metadata);
          case '/cache/epub/23864/pg23864-images-3.epub':
            final prefix = List<int>.filled(256, 0);
            prefix.setRange(0, 4, [0x50, 0x4b, 0x03, 0x04]);
            prefix[26] = 8;
            prefix.setRange(30, 58, 'mimetypeapplication/epub+zip'.codeUnits);
            response
              ..contentLength = prefix.length
              ..add(prefix);
          default:
            response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      final events = <Map<String, Object>>[];
      final sources = BookSearchSources(
        onDiagnostic: events.add,
        clientFactory: () => HttpClient()
          ..connectionFactory = ((_, _, _) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
          ..findProxy = (_) => 'DIRECT',
      );
      const query = BookSearchQuery(
        title: '孙子兵法',
        author: '孙武',
        format: 'epub',
      );
      Future<List<BookSearchCandidate>> search() => sources
          .searchByCriteria(query, BookSearchCancellation())
          .where((row) => row.sourceName == GutenbergBooks.sourceName)
          .toList();

      final directory = await Directory.systemTemp.createTemp(
        'book-source-race-',
      );
      final store = CloudStore(root: directory.path);
      addTearDown(() async {
        store.close();
        await directory.delete(recursive: true);
      });
      BookSearchCandidate? published;
      final service = BookSearchService(
        store: store,
        find: (criteria, cancellation) =>
            sources.searchByCriteria(criteria, cancellation).map((book) {
              if (book.downloadUri != null) published = book;
              return book;
            }),
        acquire: (_, _) =>
            throw StateError('Search must not download a full file'),
      );
      const owner = 'test-reader';
      const id = 'source-race-0001';
      service.start(owner: owner, id: id, query: query.title, criteria: query);
      final finished = await service
          .wait(owner: owner, id: id)
          .timeout(const Duration(seconds: 3));
      expect(finished['status'], 'complete');
      final result = published!;
      expect(
        (finished['candidates'] as List)
            .where((row) => row['downloadable'] == true)
            .single['id'],
        result.id,
      );
      await wikiDisconnected.future.timeout(const Duration(seconds: 1));
      expect(
        result.sourceUri.toString(),
        'https://www.gutenberg.org/ebooks/23864',
      );
      expect(result.title, '孫子兵法');
      expect(result.author, '孙武');
      expect(result.edition, '古登堡电子版 · 2007');
      expect(result.license, 'Public domain in the USA.');
      expect(result.downloadUri?.host, 'gutenberg.pglaf.org');
      expect(GutenbergBooks.permitsDownload(result), isTrue);
      expect(
        GutenbergBooks.matchesPublication(
          result,
          XmlDocument.parse('''
          <package xmlns:d="http://purl.org/dc/elements/1.1/"><metadata>
            <d:identifier>https://www.gutenberg.org/23962</d:identifier>
            <d:title>孫子兵法</d:title><d:language>zh</d:language>
          </metadata></package>'''),
        ),
        isFalse,
      );
      expect(
        events,
        contains(
          allOf(
            containsPair('source', 'gutenberg'),
            containsPair('outcome', 'release_match'),
          ),
        ),
      );

      seen.clear();
      final direct = Uri.parse(
        'https://www.gutenberg.org/ebooks/23864.epub3.images',
      );
      final fromLink = await sources
          .inspect(direct, query, BookSearchCancellation())
          .toList();
      expect(fromLink.single.id, result.id);
      expect(fromLink.single.downloadUri, result.downloadUri);
      expect(seen, [
        '/cache/epub/23864/pg23864.rdf',
        '/cache/epub/23864/pg23864-images-3.epub',
      ]);
      expect(
        await sources
            .inspect(
              direct,
              const BookSearchQuery(title: '呐喊'),
              BookSearchCancellation(),
            )
            .toList(),
        isEmpty,
      );

      seen.clear();
      metadata = _rdf.replaceFirst('Public domain in the USA.', 'Copyrighted.');
      expect(await search(), isEmpty);
      expect(seen, isNot(contains('/cache/epub/23864/pg23864-images-3.epub')));
    },
  );
}
