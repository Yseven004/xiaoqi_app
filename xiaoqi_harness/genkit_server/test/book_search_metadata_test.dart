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
          request.response.write(switch (request.uri.path) {
            '/advancedsearch.php' => '{"response":{"docs":[]}}',
            '/graphql' => '{"data":{"books":[]}}',
            _ => '{"query":{"pages":[]}}',
          });
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

      final otherFormat = await sources
          .search('《测试作品》中文版 PDF', BookSearchCancellation())
          .single;
      expect(otherFormat.id, result.single.id);
      expect(requests, [('测试作品', 'identity')]);
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
            '/graphql' => {
              'data': {'books': []},
            },
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
        requests.where((r) => r.path != '/graphql').map((r) => r.path),
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
    'prefers a catalog title in the original script only for the exact ISBN and edition',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      const isbn = '9787508630779';
      const otherIsbn = '9787508621050';
      final requests = <Uri>[];
      var archiveRecord = (isbn: isbn, edition: 'OL71M', title: '科普实例：副标题');
      server.listen((request) async {
        requests.add(request.uri);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(switch (request.uri.path) {
            '/search.json' => {
              'docs': [
                {
                  'author_name': ['Ada Writer'],
                  'editions': {
                    'docs': [
                      {
                        'key': '/books/OL71M',
                        'title': 'Ke pu shi li',
                        'language': ['chi'],
                        'isbn': [isbn],
                        'edition_name': 'Di 2 ban',
                      },
                    ],
                  },
                },
              ],
            },
            '/advancedsearch.php' => {
              'response': {
                'docs': [
                  {
                    'identifier': 'native-edition',
                    'title-alt-script': archiveRecord.title,
                    'creator': 'Writer, Ada',
                    'language': 'chi',
                    'year': 2011,
                    'isbn': [otherIsbn, archiveRecord.isbn],
                    'openlibrary_edition': archiveRecord.edition,
                  },
                ],
              },
            },
            '/api/books' => {
              'OLID:OL71M': {
                'details': {
                  'key': '/books/OL71M',
                  'edition_name': 'Di 2 ban',
                  'isbn_13': [isbn],
                },
              },
            },
            _ => {},
          }),
        );
        await request.response.close();
      });
      BookSearchSources sources() => BookSearchSources(
        clientFactory: () => HttpClient()
          ..connectionFactory = ((_, _, _) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
          ..findProxy = (_) => 'DIRECT',
      );
      Future<BookSearchCandidate> lookup() => sources()
          .search('ISBN：978-7-5086-3077-9', BookSearchCancellation())
          .single;

      final original = await lookup();
      expect(
        requests
            .singleWhere((r) => r.path == '/advancedsearch.php')
            .queryParameters['q'],
        'mediatype:texts AND collection:internetarchivebooks AND isbn:"$isbn"',
      );
      expect(original.title, '科普实例');
      expect(original.isbn, isbn);
      expect(original.author, 'Ada Writer');
      expect(original.edition, '第2版 · 2011');
      expect(
        original.sourceUri.toString(),
        'https://archive.org/details/native-edition',
      );
      expect(original.downloadUri, isNull);

      for (final (wrongIsbn, wrongEdition, title) in [
        (otherIsbn, 'OL71M', '另一版本'),
        (isbn, 'OL73M', '不一致的版本'),
        (isbn, 'OL71M', 'Ke pu shi li: Chinese text only after colon 科普'),
      ]) {
        archiveRecord = (isbn: wrongIsbn, edition: wrongEdition, title: title);
        final fallback = await lookup();
        expect(fallback.title, 'Ke pu shi li');
        expect(fallback.isbn, isbn);
        expect(
          fallback.sourceUri.toString(),
          'https://openlibrary.org/books/OL71M',
        );
        expect(fallback.downloadUri, isNull);
      }
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
        if (request.url.host == 'api.search.tinyfish.ai') {
          expect(request.url.queryParameters['query'], '科普实例 中文 pdf');
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'url': 'https://publisher.example/books/kepu',
                  'title': '科普实例 · 图书详情',
                  'snippet': '未核实作者和版本',
                },
                {
                  'url': 'https://publisher.example/files/kepu.pdf',
                  'title': '科普实例 PDF',
                },
                {
                  'url': 'https://publisher.example/books/other',
                  'title': '其他书籍',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/tools/search');
        expect(jsonDecode(request.body), {
          'query': '"科普实例" ISBN 出版社 图书馆 不同版本 书目',
          'count': 8,
          'need_content': false,
        });
        return http.Response(
          jsonEncode({
            'results': [
              for (final (host, title, isbn) in [
                ('not-a-library.example', '科普实例', '9787508621050'),
                ('unreachable.example.edu.cn', '科普实例', '9787508621050'),
                ('opac.example.edu.cn', '科普实例习题', '9787508621050'),
                ('opac.example.edu.cn', '科普实例', '978-7-5086-3077-9'),
              ])
                {
                  'url': 'https://$host/opac/book/$isbn',
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
          deepSeekKey: 'test',
          client: webHttp,
          checkCancelled: check,
          resolveHost: (host) async {
            expect(host, isNot('not-a-library.example'));
            if (host == 'unreachable.example.edu.cn') {
              throw const SocketException('DNS lookup failed');
            }
            return [InternetAddress('8.8.8.8')];
          },
        ),
      );
      final found = await sources
          .searchByCriteria(
            const BookSearchQuery(title: '科普实例', language: '中文', format: 'pdf'),
            BookSearchCancellation(),
          )
          .toList();
      expect(webRequests, ['api.deepseek.com', 'api.search.tinyfish.ai']);
      expect(requested, ['isbn:9787508630779']);
      expect(found.map((r) => r.edition), ['第2版', '第1版', '']);
      expect(found.take(2).map((r) => r.id), ['OL2M', 'OL1M']);
      expect(found.last.sourceUri.host, 'publisher.example');
      expect(found.last.sourceUri.path, '/books/kepu');
      expect(found.last.availability, contains('来源和版本待核'));
      expect(found.last.author, isEmpty);
      expect(found.last.format, isEmpty);
      expect(
        found.every((r) => r.title == '科普实例' && r.downloadUri == null),
        isTrue,
      );
    },
  );
}
