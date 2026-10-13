import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/mimo_web_search_service.dart';

void main() {
  test(
    'uses MiMo documented force_search contract and returns citations',
    () async {
      Map<String, dynamic>? captured;
      final client = MockClient((request) async {
        captured = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.url.path, '/v1/chat/completions');
        expect(request.headers['authorization'], 'Bearer test-key');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': '最新公开信息摘要',
                  'annotations': [
                    {
                      'type': 'url_citation',
                      'title': '官方来源',
                      'url': 'https://example.com/current',
                      'summary': '用于核验的公开页面',
                    },
                    {
                      'type': 'url_citation',
                      'title': '忽略不安全来源',
                      'url': 'javascript:alert(1)',
                      'summary': '不应保留',
                    },
                  ],
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = MimoWebSearchService(
        apiKey: 'test-key',
        model: 'mimo-v2.6-flash',
        client: client,
      );

      final result = await service.search('2026 年 Genkit Dart A2UI 文档');

      expect(captured?['model'], 'mimo-v2.6-flash');
      expect(captured?['tools'], [
        {
          'type': 'web_search',
          'max_keyword': 1,
          'force_search': true,
          'limit': 3,
        },
      ]);
      expect(captured?['thinking'], {'type': 'disabled'});
      expect(captured?['max_completion_tokens'], 500);
      expect(captured?['messages'], hasLength(2));
      expect(jsonEncode(captured), contains('2026 年 Genkit Dart A2UI 文档'));
      expect(jsonEncode(captured), isNot(contains('legacy_history')));
      expect(result.summary, '最新公开信息摘要');
      expect(result.sources, hasLength(1));
      expect(result.sources.single.url, 'https://example.com/current');
      client.close();
    },
  );

  test('does not claim search success without real URL citations', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '没有可验证来源'},
            },
          ],
        }),
        200,
      ),
    );
    final service = MimoWebSearchService(
      apiKey: 'test-key',
      model: 'mimo-v2.6-flash',
      client: client,
    );
    await expectLater(
      service.search('查询词'),
      throwsA(isA<MimoWebSearchException>()),
    );
    client.close();
  });

  test(
    'reports how to enable the account plugin when no key is configured',
    () async {
      final service = MimoWebSearchService(
        apiKey: '',
        model: 'mimo-v2.6-flash',
        client: MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(
        service.search('查询词'),
        throwsA(
          isA<MimoWebSearchException>().having(
            (error) => error.message,
            'message',
            contains('插件管理'),
          ),
        ),
      );
    },
  );
}
