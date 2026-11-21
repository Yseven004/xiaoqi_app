import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/book_search_sources.dart';

void main() {
  test(
    'looks up the clean title and decodes compressed book metadata',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <(String?, String?)>[];
      server.listen((request) async {
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
                    'author_name': ['作者'],
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
}
