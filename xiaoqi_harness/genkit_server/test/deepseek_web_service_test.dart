import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/deepseek_web_service.dart';

void main() {
  test('uses DeepSeek Search contract and returns URL sources', () async {
    Map<String, dynamic>? captured;
    final client = MockClient((request) async {
      captured = jsonDecode(request.body) as Map<String, dynamic>;
      expect(request.url.path, '/v1/tools/search');
      expect(request.headers['authorization'], 'Bearer test-key');
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'results': [
              {
                'title': '官方来源',
                'url': 'https://example.com/current',
                'summary': '用于核验的公开页面',
                'snippet': '页面摘要',
                'site_name': 'Example',
                'site_icon': 'https://example.com/favicon.ico',
                'date': '2026-10-18T00:00:00Z',
                'authority': 4,
              },
              {
                'title': '忽略不安全来源',
                'url': 'javascript:alert(1)',
                'summary': '不应保留',
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = DeepSeekWebSearchService(
      apiKey: 'test-key',
      client: client,
    );

    final result = await service.search('2026 年 Genkit Dart A2UI 文档');

    expect(captured, {
      'query': '2026 年 Genkit Dart A2UI 文档',
      'count': 3,
      'need_content': false,
    });
    expect(result.sources, hasLength(1));
    expect(result.sources.single.url, 'https://example.com/current');
    expect(result.sources.single.siteName, 'Example');
    expect(result.sources.single.siteIcon, 'https://example.com/favicon.ico');
    expect(result.sources.single.authority, 4);
    expect(result.summary, contains('用于核验的公开页面'));
    client.close();
  });

  test('uses DeepSeek Fetch contract and returns markdown content', () async {
    Map<String, dynamic>? captured;
    final service = DeepSeekWebFetchService(
      apiKey: 'test-key',
      client: MockClient((request) async {
        captured = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.url.path, '/v1/tools/fetch');
        return http.Response.bytes(
          utf8.encode(jsonEncode({'title': '文章标题', 'content': '# 正文'})),
          200,
        );
      }),
    );

    final result = await service.fetch('https://example.com/article');

    expect(captured, {'url': 'https://example.com/article'});
    expect(result.title, '文章标题');
    expect(result.content, '# 正文');
  });

  test('does not claim success without valid URL sources', () async {
    final service = DeepSeekWebSearchService(
      apiKey: 'test-key',
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'results': [
                {'title': '无效来源', 'url': 'javascript:alert(1)'},
              ],
            }),
          ),
          200,
        ),
      ),
    );
    await expectLater(
      service.search('查询词'),
      throwsA(isA<DeepSeekWebException>()),
    );
  });
}
