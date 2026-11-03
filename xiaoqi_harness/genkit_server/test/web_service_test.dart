import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/web_service.dart';

void main() {
  test(
    'target permission and not-found statuses cannot trigger fallback',
    () async {
      for (final status in [401, 403, 404, 410]) {
        var calls = 0;
        final web = WebService(
          tinyFishKey: 'tiny',
          deepSeekKey: 'deep',
          resolveHost: (_) async => [InternetAddress('93.184.216.34')],
          client: MockClient((_) async {
            calls++;
            return http.Response(
              jsonEncode({
                'results': [],
                'errors': [
                  {'error': 'target_http_error', 'status': status},
                ],
              }),
              200,
            );
          }),
        );
        await expectLater(
          web.fetch('https://example.com'),
          throwsFormatException,
        );
        expect(calls, 1);
      }
    },
  );
  test(
    'malformed fetch response falls back rather than masquerading as an invalid URL',
    () async {
      var calls = 0;
      final web = WebService(
        tinyFishKey: 'tiny',
        deepSeekKey: 'deep',
        resolveHost: (_) async => [InternetAddress('93.184.216.34')],
        client: MockClient((request) async {
          calls++;
          return request.url.host.contains('tinyfish')
              ? http.Response('not json', 200)
              : http.Response(
                  '{"title":"page","content":"verified text"}',
                  200,
                );
        }),
      );
      final result = await web.fetch('https://example.com');
      expect(result['provider'], 'deepseek');
      expect(result['fallback_reason'], 'invalid_response');
      expect(calls, 2);
    },
  );
  WebService service(
    Future<http.Response> Function(http.Request) handler, {
    String key = 'tiny',
    void Function()? check,
  }) => WebService(
    tinyFishKey: key,
    deepSeekKey: 'deep',
    client: MockClient(handler),
    checkCancelled: check,
    resolveHost: (_) async => [InternetAddress('93.184.216.34')],
  );
  http.Response json(Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

  test('TinyFish search sends minimal query; empty is valid', () async {
    var calls = 0;
    final web = service((request) async {
      calls++;
      expect(request.method, 'GET');
      expect(request.url.host, 'api.search.tinyfish.ai');
      expect(request.url.queryParameters, {
        'query': 'dart site:dart.dev',
        'purpose': '文档',
      });
      expect(request.headers['X-API-Key'], 'tiny');
      return json({'results': []});
    });
    final result = await web.search('dart site:dart.dev', purpose: '文档');
    expect(result['sources'], isEmpty);
    expect(result['provider'], 'tinyfish');
    expect(calls, 1);
  });

  test('search limits sources and marks snippet evidence', () async {
    final web = service(
      (_) async => json({
        'results': List.generate(
          8,
          (i) => {
            'title': '标题$i',
            'url': 'https://example.com/$i',
            'snippet': '摘要$i',
          },
        ),
      }),
    );
    final result = await web.search('查询', limit: 2);
    expect(result['sources'], hasLength(2));
    expect(
      (result['sources'] as List).first['source_id'],
      'https://example.com/0',
    );
    expect(result['evidence_type'], 'search_snippet');
  });

  for (final status in [401, 402, 429, 500]) {
    test('HTTP $status falls back once', () async {
      final hosts = <String>[];
      final web = service((request) async {
        hosts.add(request.url.host);
        if (request.url.host.contains('tinyfish'))
          return http.Response('', status);
        return json({
          'results': [
            {'url': 'https://example.com', 'title': '备用', 'summary': '证据'},
          ],
        });
      });
      final result = await web.search('测试');
      expect(hosts, ['api.search.tinyfish.ai', 'api.deepseek.com']);
      expect(result['provider'], 'deepseek');
      expect(result['fallback_reason'], 'http_$status');
    });
  }

  test('missing key uses fallback directly', () async {
    final web = service((request) async {
      expect(request.url.host, 'api.deepseek.com');
      return json({
        'results': [
          {'url': 'https://example.com', 'title': '备用'},
        ],
      });
    }, key: '');
    expect((await web.search('测试'))['fallback_reason'], 'not_configured');
  });

  test('cancellation prevents fallback', () async {
    var cancelled = false, calls = 0;
    final web = service(
      (_) async {
        calls++;
        cancelled = true;
        return http.Response('', 500);
      },
      check: () {
        if (cancelled) throw StateError('cancelled');
      },
    );
    await expectLater(web.search('测试'), throwsStateError);
    expect(calls, 1);
  });

  test(
    'fetch requests Markdown and pages Unicode without refetching',
    () async {
      var calls = 0;
      final web = service((request) async {
        calls++;
        expect(jsonDecode(request.body)['format'], 'markdown');
        return json({
          'results': [
            {'url': 'https://example.com', 'title': '正文', 'text': '甲😀乙丙'},
          ],
        });
      });
      final doc = await web.fetch('https://example.com');
      final first = WebService.page(doc, maxChars: 2);
      expect(first['content'], '甲😀');
      expect(first['next_start_char'], 2);
      expect(WebService.page(doc, start: 2)['content'], '乙丙');
      expect(calls, 1);
      expect(doc['evidence_type'], 'page_content');
    },
  );

  for (final error in [
    'login_required',
    'page_not_found',
    'invalid_redirect_url',
  ]) {
    test('$error never falls back', () async {
      var calls = 0;
      final web = service((_) async {
        calls++;
        return json({
          'results': [],
          'errors': [
            {'error': error},
          ],
        });
      });
      await expectLater(
        web.fetch('https://example.com'),
        throwsFormatException,
      );
      expect(calls, 1);
    });
  }

  test('dangerous URLs are rejected before a request', () async {
    final web = service((_) async => throw StateError('must not request'));
    for (final url in [
      'file:///etc/passwd',
      'http://localhost',
      'http://127.0.0.1',
      'http://169.254.169.254/latest',
      'http://10.0.0.1',
      'https://u:p@example.com',
      'http://[::1]',
      'http://[::ffff:127.0.0.1]',
      'https://example.com:8080',
    ]) {
      await expectLater(web.fetch(url), throwsFormatException, reason: url);
    }
  });

  test('private DNS resolution is rejected', () async {
    final web = WebService(
      tinyFishKey: 'tiny',
      deepSeekKey: '',
      resolveHost: (_) async => [InternetAddress('192.168.1.2')],
    );
    addTearDown(web.close);
    await expectLater(
      web.fetch('https://private.example.com'),
      throwsFormatException,
    );
  });

  test('both providers failing remains a failure', () async {
    var calls = 0;
    final web = service((_) async {
      calls++;
      return http.Response('', 500);
    });
    await expectLater(web.search('查询'), throwsException);
    expect(calls, 2);
  });
}
