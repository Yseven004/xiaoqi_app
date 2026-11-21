import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'one modal turn reuses the first search for additional tool calls',
    () async {
      final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => model.close(force: true));
      final toolResults = <Map>[];
      var calls = 0;
      model.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final messages = (body['messages'] as List).whereType<Map>();
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
                  for (final (index, query) in [
                    'Hello 算法 1.2.0',
                    'Hello 算法 1.1.0',
                  ].indexed)
                    {
                      'index': index,
                      'id': 'call-$index',
                      'type': 'function',
                      'function': {
                        'name': 'find_book_material',
                        'arguments': jsonEncode({'query': query}),
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
      expect(toolResults, hasLength(2));
      expect(toolResults.first, toolResults.last);
      expect(toolResults.first, containsPair('id', 'test-book-search-turn'));
      expect(toolResults.first, containsPair('status', 'complete'));
    },
  );
}
