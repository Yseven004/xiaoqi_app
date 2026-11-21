import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';

void main() {
  test(
    'preserves explicit format and scopes linked print identifiers to the same book',
    () {
      const linked = {
        'title': '测试作品',
        'author': '测试作者',
        'isbn': '9787508630779',
      };
      final query = BookSearchQuery.fromTool(
        {'title': '测试作品', 'language': '简体中文', 'isbn': linked['isbn']},
        userText: '找《测试作品》中文版 PDF',
        linkedBook: linked,
      );
      expect(query.format, 'pdf');
      expect(query.language, '中文');
      expect(query.isbn, isEmpty);
      expect(query.referenceIsbn, linked['isbn']);
      expect(query.author, isEmpty);
      const jobs = {'title': '乔布斯的魔力演讲', 'author': '(美) 加洛'};
      for (final author in ['(美) 加洛', '加洛', 'Carmine Gallo']) {
        expect(
          BookSearchQuery.fromTool(
            {'title': jobs['title'], 'author': author},
            userText: '帮我找《乔布斯的魔力演讲》中文版',
            linkedBook: jobs,
          ).author,
          isEmpty,
        );
      }
      expect(
        BookSearchQuery.fromTool({
          'title': '呐喊',
          'author': '鲁迅',
        }, userText: '帮我找鲁迅的《呐喊》').author,
        '鲁迅',
      );
      expect(
        BookSearchQuery.fromTool(
          {'author': '加洛'},
          userText: '找该作者的其他作品',
          linkedBook: jobs,
        ).author,
        '加洛',
      );
      for (final other in [
        {'topic': '计算机入门'},
        {'title': '另一部作品'},
        {'title': '测试作品', 'author': '同名书的另一位作者'},
        {'author': '测试作者'},
      ]) {
        expect(
          BookSearchQuery.fromTool(
            other,
            userText: '再找一本 ${other['author'] ?? ''}',
            linkedBook: linked,
          ).referenceIsbn,
          isEmpty,
        );
      }
    },
  );

  test(
    'modal advertises only book search, deduplicates retries and reports unexecuted conditions',
    () async {
      final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => model.close(force: true));
      final toolResults = <Map>[];
      var observedTools = <String>[];
      var observedSystem = '';
      var calls = 0;
      model.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final messages = (body['messages'] as List).whereType<Map>();
        observedTools = [
          for (final tool in (body['tools'] as List).whereType<Map>())
            tool['function']['name'] as String,
        ];
        observedSystem = messages
            .where((m) => m['role'] == 'system')
            .map((m) => m['content'])
            .join('\n');
        final responses = messages.where(
          (message) => message['role'] == 'tool',
        );
        toolResults
          ..clear()
          ..addAll(
            responses.map((message) {
              final output = jsonDecode(message['content'] as String);
              return (output is String ? jsonDecode(output) : output) as Map;
            }),
          );
        calls++;
        final delta = toolResults.isNotEmpty
            ? {'content': '已完成本次查找。'}
            : {
                'tool_calls': [
                  for (final (index, edition) in [
                    '1.2.0',
                    '1.2.0',
                    '1.1.0',
                  ].indexed)
                    {
                      'index': index,
                      'id': 'call-$index',
                      'type': 'function',
                      'function': {
                        'name': 'find_book_material',
                        'arguments': jsonEncode({
                          'title': 'Hello 算法',
                          'edition': edition,
                        }),
                      },
                    },
                ],
              };
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'id': 'book-search-fixture',
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': toolResults.isEmpty ? 'tool_calls' : 'stop'},
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });

      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--disable-dart-dev',
          '--packages=.dart_tool/package_config.json',
          'test/support/book_search_agent_fixture.dart',
        ],
        environment: {
          'MIMO_API_KEY': 'fixture-only',
          'MIMO_BASE_URL': 'http://127.0.0.1:${model.port}/v1',
          'XIAOQI_CAPTURE_TRACES': '0',
        },
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final line = result.stdout
          .toString()
          .split('\n')
          .firstWhere((line) => line.startsWith('RESULT:'));
      final output = jsonDecode(line.substring('RESULT:'.length)) as Map;
      expect(output, {
        'text': '已完成本次查找。',
        'status': 'complete',
        'starts': 1,
        'operation_count': 1,
      });
      expect(calls, 2);
      expect(observedTools, ['find_book_material']);
      expect(observedSystem, contains('找书助手'));
      expect(observedSystem, contains('用 edition 描述实际取得的版本'));
      expect(observedSystem, contains('publicationYear 是来源注明的出版年份'));
      for (final hidden in [
        'web_search',
        'web_fetch',
        'use_skill',
        'Rendering UI with A2UI',
      ]) {
        expect(observedSystem, isNot(contains(hidden)));
      }
      expect(toolResults, hasLength(3));
      expect(toolResults[0], toolResults[1]);
      expect(toolResults[2]['status'], 'not_searched');
      expect(toolResults.first, containsPair('id', 'test-book-search-turn'));
      expect(toolResults.first, containsPair('status', 'complete'));
    },
    // This integration fixture starts a fresh Dart VM with the full Agent runtime.
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
