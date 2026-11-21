import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/book_search_sources.dart';
import 'package:xiaoqi_genkit_server/src/web_service.dart';

void main() {
  test(
    'looks up the clean title and decodes compressed book metadata',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <(String?, String?)>[];
      server.listen((request) async {
        if (request.uri.path != '/search.json') {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"query":{"pages":[]}}');
          await request.response.close();
          return;
        }
        requests.add((
          request.uri.queryParameters['title'],
          request.headers.value(HttpHeaders.acceptEncodingHeader),
        ));
        request.response.headers
          ..contentType = ContentType.json
          ..set(HttpHeaders.contentEncodingHeader, 'gzip');
        request.response.add(
          gzip.encode(
            utf8.encode(
              jsonEncode({
                'docs': [
                  {
                    'editions': {
                      'docs': [
                        {
                          'key': '/books/OL27131157M',
                          'title': '测试作品',
                          'language': ['chi'],
                        },
                      ],
                    },
                  },
                ],
              }),
            ),
          ),
        );
        await request.response.close();
      });
      final sources = BookSearchSources(
        clientFactory: () => HttpClient()
          ..autoUncompress = false
          ..connectionFactory = ((_, _, _) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
          ..findProxy = (_) => 'DIRECT',
      );

      final result = await sources
          .search('《测试作品》中文版', BookSearchCancellation())
          .toList();

      expect(requests, [('测试作品', 'identity')]);
      expect(result.single.title, '测试作品');
      expect(result.single.author, isEmpty);
      expect(result.single.language, '中文');
      expect(result.single.downloadUri, isNull);
    },
  );

  test(
    'matches complete authors and ignores duplicate author spellings',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      Uri? requestUri;
      server.listen((request) async {
        requestUri = request.uri;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'docs': [
              for (final (authors, key, title) in [
                (['Carmine Gallo', 'CARMINE GALLO'], 'OL1M', 'Five Stars'),
                (['Carmine Gallo Jr.'], 'OL2M', 'Other author'),
                (
                  ['Carmine Gallo', 'Unverified Contributor'],
                  'OL3M',
                  'Unclear',
                ),
              ])
                {
                  'author_name': authors,
                  'editions': {
                    'docs': [
                      {'key': '/books/$key', 'title': title},
                    ],
                  },
                },
            ],
          }),
        );
        await request.response.close();
      });
      final sources = BookSearchSources(
        clientFactory: () => HttpClient()
          ..connectionFactory = ((_, _, _) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
          ..findProxy = (_) => 'DIRECT',
      );

      final result = await sources
          .search('作者: （美）Carmine Gallo', BookSearchCancellation())
          .toList();

      expect(requestUri?.queryParameters['author'], 'Carmine Gallo');
      expect(requestUri?.queryParameters['title'], isNull);
      expect(result.single.title, 'Five Stars');
      expect(result.single.author, 'Carmine Gallo');
      expect(result.single.downloadUri, isNull);
    },
  );
  test(
    'uses verified original-script catalog titles without offering a file',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Uri>[];
      server.listen((request) async {
        requests.add(request.uri);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(switch (request.uri.path) {
            '/search.json' => {'docs': []},
            '/api/books' => {
              'OLID:OL71M': {
                'details': {
                  'key': '/books/OL71M',
                  'edition_name': 'Di 2 ban',
                  'isbn_13': ['9787508630779'],
                },
              },
              'OLID:OL73M': {
                'details': {
                  'key': '/books/OL73M',
                  'edition_name': 'Di 99 ban',
                  'isbn_13': ['9787508621050'],
                },
              },
            },
            _ => {
              'response': {
                'docs': [
                  for (final (id, title, edition) in [
                    ('generic1', '科普实例 : 副标题', 'OL71M'),
                    ('generic2', '科普实例习题', 'OL72M'),
                    ('generic3', '科普实例', 'OL73M'),
                  ])
                    {
                      'identifier': id,
                      'title-alt-script': title,
                      'creator': 'Writer, Ada',
                      'language': 'chi',
                      'year': 2011,
                      'isbn': ['9787508630779'],
                      'openlibrary_edition': edition,
                    },
                ],
              },
            },
          }),
        );
        await request.response.close();
      });
      final sources = BookSearchSources(
        clientFactory: () => HttpClient()
          ..connectionFactory = ((_, _, _) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
          ..findProxy = (_) => 'DIRECT',
      );
      final results = await sources
          .searchByCriteria(
            const BookSearchQuery(title: '科普实例', language: '中文', format: 'pdf'),
            BookSearchCancellation(),
          )
          .toList();
      expect(
        requests.map((r) => r.path),
        unorderedEquals(['/search.json', '/advancedsearch.php', '/api/books']),
      );
      expect(
        requests
            .singleWhere((r) => r.path == '/search.json')
            .queryParameters['title'],
        '科普实例',
      );
      expect(
        requests
            .singleWhere((r) => r.path == '/advancedsearch.php')
            .queryParameters['q'],
        contains('title-alt-script:"科普实例"'),
      );
      expect(results, hasLength(2));
      expect(results.last.edition, '2011');
      final book = results.first;
      expect(book.sourceUri.toString(), 'https://archive.org/details/generic1');
      expect(book.title, '科普实例');
      expect(book.author, 'Ada Writer');
      expect(book.publicationYear, '2011');
      expect(book.edition, '第2版 · 2011');
      expect(book.downloadUri, isNull);
      expect(book.format, isEmpty);
    },
  );
  test(
    'rate-limited title catalog falls back to OPAC ISBN and verified related editions',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requested = <String>[];
      server.listen((request) async {
        final path = request.uri.path;
        request.response.headers.contentType = ContentType.json;
        if (path == '/advancedsearch.php') {
          request.response.statusCode = 429;
        } else if (path == '/search.json') {
          final q = request.uri.queryParameters['q'];
          if (q != null) requested.add(q);
          request.response.write(
            jsonEncode({
              'docs': [
                if (q == 'isbn:9787508630779')
                  {
                    'author_name': ['Verified Author'],
                    'key': '/works/OL1W',
                    'editions': {
                      'docs': [
                        {
                          'title': 'Ke pu shi li',
                          'key': '/books/OL2M',
                          'isbn': ['9787508630779'],
                          'language': ['chi'],
                          'edition_name': 'Di 2 ban',
                        },
                      ],
                    },
                  },
              ],
            }),
          );
        } else if (path == '/works/OL1W/editions.json') {
          request.response.write(
            jsonEncode({
              'entries': [
                for (final (id, name) in [
                  ('OL1M', 'Ke pu shi li'),
                  ('OL3M', 'Different book'),
                ])
                  {
                    'key': '/books/$id',
                    'title': name,
                    'edition_name': 'Di 1 ban',
                    'isbn_13': ['9787508621050'],
                    'works': [
                      {'key': '/works/OL1W'},
                    ],
                    'languages': [
                      {'key': '/languages/chi'},
                    ],
                  },
              ],
            }),
          );
        }
        await request.response.close();
      });
      final webRequests = <String>[];
      final webHttp = MockClient((request) async {
        webRequests.add(request.url.host);
        return http.Response(
          jsonEncode({
            'results': [
              for (final (host, title, isbn) in [
                ('not-a-library.example', '科普实例', '9787508621050'),
                ('opac.example.edu.cn', '科普实例习题', '9787508621050'),
                ('opac.example.edu.cn', '科普实例', '978-7-5086-3077-9'),
              ])
                {
                  'url': 'https://$host/opac/book/123',
                  'title': title,
                  'snippet': 'ISBN：$isbn',
                },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final sources = BookSearchSources(
        clientFactory: () => HttpClient()
          ..connectionFactory = ((_, _, _) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
          ..findProxy = ((_) => 'DIRECT'),
        webService: (check) => WebService(
          tinyFishKey: 'test',
          deepSeekKey: '',
          client: webHttp,
          checkCancelled: check,
          resolveHost: (_) async => [InternetAddress('8.8.8.8')],
        ),
      );
      final found = await sources
          .searchByCriteria(
            const BookSearchQuery(title: '科普实例', language: '中文', format: 'pdf'),
            BookSearchCancellation(),
          )
          .toList();
      expect(webRequests, ['api.search.tinyfish.ai']);
      expect(requested, ['isbn:9787508630779']);
      expect(found.map((r) => r.edition), ['第2版', '第1版']);
      expect(found.map((r) => r.id), ['OL2M', 'OL1M']);
      expect(
        found.every((r) => r.title == '科普实例' && r.downloadUri == null),
        isTrue,
      );
    },
  );
}
