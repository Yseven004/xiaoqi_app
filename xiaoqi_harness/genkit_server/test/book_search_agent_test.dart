import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/model_limits.dart';

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

  for (final consecutiveRepeats in [false, true]) {
    test(
      consecutiveRepeats
          ? 'modal reserves an answer after two consecutive repeated queries'
          : 'modal counts repeated requests against the five action budget',
      () async {
        final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => model.close(force: true));
        final toolResults = <Map>[];
        var observedTools = <String>[];
        var observedSystem = '';
        var calls = 0;
        final toolChoices = <Object?>[];
        final queries = consecutiveRepeats ? [1] : [1, 2, 1, 3, 4, 2, 5];
        final expectedSearches = consecutiveRepeats ? 1 : 4;
        final expectedAnswer = consecutiveRepeats
            ? '尝试了一轮，暂未找到指定版次。找到一份替代版入口，请你确认。'
            : '五轮仍未找到符合条件的下载入口。';
        model.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
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
          final toolChoice = body['tool_choice'];
          toolChoices.add(toolChoice);
          final shouldSearch = toolChoice != 'none';
          final delta = shouldSearch
              ? {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call-$calls',
                      'type': 'function',
                      'function': {
                        'name': 'find_book_material',
                        'arguments': jsonEncode({
                          'title': 'Hello 算法',
                          'topic':
                              'alias-${queries[(calls - 1) % queries.length]}',
                        }),
                      },
                    },
                  ],
                }
              : {'content': expectedAnswer};
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'data: ${jsonEncode({
              'id': 'book-search-fixture',
              'choices': [
                {'index': 0, 'delta': delta, 'finish_reason': shouldSearch ? 'tool_calls' : 'stop'},
              ],
            })}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        });

        final output = await runFixture(
          model.port,
          args: consecutiveRepeats ? ['alternate'] : const [],
        );
        expect(output['text'], expectedAnswer);
        expect((output['search'] as Map)['status'], 'complete');
        expect(output['starts'], expectedSearches);
        expect(output['attempts'], expectedSearches);
        expect(output['operation_count'], expectedSearches);
        expect(output['acquisitions'], 0);
        expect(calls, consecutiveRepeats ? 4 : 6);
        expect(toolChoices.where((choice) => choice == 'none'), hasLength(1));
        expect(toolChoices.last, 'none');
        expect(
          observedTools,
          containsAll([
            'find_book_material',
            'web_search',
            'web_fetch',
            'inspect_book_source',
            'use_skill',
          ]),
        );
        expect(observedSystem, contains('找书助手'));
        expect(observedSystem, contains('用 edition 描述来源标明的版本'));
        expect(observedSystem, contains('publicationYear 是来源注明的出版年份'));
        expect(observedSystem, contains('最多五轮'));
        expect(observedSystem, contains('attemptsRemaining'));
        expect(observedSystem, contains('搜索只查找电子书获取入口，不会预先下载整本'));
        expect(observedSystem, contains('仍不表示用户已下载或已入库'));
        expect(observedSystem, isNot(contains('Rendering UI with A2UI')));
        expect(toolResults, hasLength(consecutiveRepeats ? 3 : 5));
        expect(
          toolResults.map((result) => result['attemptsUsed']),
          consecutiveRepeats ? [1, 1, 1] : [1, 2, 2, 3, 4],
        );
        expect(
          toolResults.map((result) => result['requestOutcome']),
          consecutiveRepeats
              ? ['searched', 'reused', 'reused']
              : ['searched', 'searched', 'reused', 'searched', 'searched'],
        );
        expect(toolResults.first['attemptsUsed'], 1);
        expect(toolResults.first['candidates'].single['importable'], isFalse);
        expect(toolResults.last['attemptsUsed'], expectedSearches);
        expect(toolResults.last['attemptsRemaining'], 5 - expectedSearches);
        expect(
          toolResults.last['attemptedCriteria'],
          hasLength(expectedSearches),
        );
        expect(toolResults.last['candidates'].last['importable'], isFalse);
        if (consecutiveRepeats) {
          final alternative = toolResults.last['candidates'].single as Map;
          expect(alternative['verified'], isFalse);
          expect(alternative['downloadable'], isTrue);
          expect(alternative['candidateToken'], isA<String>());
          expect(alternative['confirmationReason'], contains('1.2.0'));
        }
        expect(toolResults.last['exhausted'] == true, isFalse);
        expect(toolResults.first, containsPair('id', 'test-book-search-turn'));
        expect(toolResults.first, containsPair('status', 'complete'));
      },
      // This integration fixture starts a fresh Dart VM with the full Agent runtime.
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'loads the skill and follows a tool result to the verified source entry',
    () async {
      final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => model.close(force: true));
      var calls = 0;
      final seen = <Map>[];
      model.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        seen.add(body);
        final tools = (body['messages'] as List)
            .whereType<Map>()
            .where((row) => row['role'] == 'tool')
            .toList();
        calls++;
        final previous = tools.isEmpty
            ? null
            : jsonDecode(tools.last['content'] as String);
        final candidates = previous is Map
            ? previous['candidates'] as List?
            : null;
        final candidate = candidates?.firstOrNull;
        final sourceRef = candidate is Map ? candidate['sourceRef'] : null;
        final (tool, arguments) = switch (calls) {
          1 => ('use_skill', {'skillName': 'online-book-search'}),
          2 => ('find_book_material', {'title': 'Hello 算法'}),
          3 => (
            'inspect_book_source',
            {'title': 'Hello 算法', 'source_ref': sourceRef},
          ),
          _ => ('', <String, Object?>{}),
        };
        final delta = tool.isEmpty
            ? {'content': '已找到文件入口。'}
            : {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call-$calls',
                    'type': 'function',
                    'function': {
                      'name': tool,
                      'arguments': jsonEncode(arguments),
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
            'id': 'book-correction-fixture',
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': tool.isEmpty ? 'stop' : 'tool_calls'},
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      final out = await runFixture(model.port, args: ['correction']);
      expect(calls, 4);
      expect(jsonEncode(seen[1]['messages']), contains('根据实际失败决定下一步'));
      expect(
        jsonEncode(seen[2]['messages']),
        contains('no_matching_book_file_evidence'),
      );
      expect(seen[3]['tool_choice'], 'none');
      expect(
        (out['search']['candidates'] as List).last['id'],
        'checked-release',
      );
      expect(out['acquisitions'], 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final malformedAnswer in [false, true]) {
    test(
      'exact download entry finishes without acquiring a file (fallback=$malformedAnswer)',
      () async {
        final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => model.close(force: true));
        final requests = <Map>[];
        const answer = '已找到下载入口，点击下载并导入后会获取并核验文件。';
        model.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          requests.add(body);
          final first = requests.length == 1;
          final delta = first || malformedAnswer
              ? {
                  'reasoning_content': 'fixture reasoning for tool continuity',
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call-${requests.length}',
                      'type': 'function',
                      'function': {
                        'name': 'find_book_material',
                        'arguments': jsonEncode({'title': 'Hello 算法'}),
                      },
                    },
                  ],
                }
              : {'content': answer};
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'data: ${jsonEncode({
              'id': 'book-search-fixture',
              'choices': [
                {'index': 0, 'delta': delta, 'finish_reason': first || malformedAnswer ? 'tool_calls' : 'stop'},
              ],
            })}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        });

        final output = await runFixture(model.port, args: ['downloadable']);
        expect(requests, hasLength(2));
        for (final request in requests) {
          expect(request['model'], ModelLimits.siliconFlowBookSearchModel);
          expect(request['enable_thinking'], isTrue);
          expect(request['reasoning_effort'], 'high');
          expect(request['thinking'], isNull);
          expect(request['max_tokens'], 8192);
          expect(request['max_completion_tokens'], isNull);
        }
        final priorToolRequest = (requests.last['messages'] as List)
            .whereType<Map>()
            .firstWhere((message) => message['tool_calls'] is List);
        expect(
          priorToolRequest['reasoning_content'],
          'fixture reasoning for tool continuity',
        );
        expect(requests.last['tool_choice'], 'none');
        expect(output['starts'], 1);
        expect(output['attempts'], 1);
        expect(output['operation_count'], 1);
        expect(output['acquisitions'], 0);
        final search = output['search'] as Map;
        expect(search['attemptsRemaining'], 4);
        final candidate = (search['candidates'] as List).single as Map;
        expect(candidate['downloadable'], isTrue);
        expect(candidate['verified'], isFalse);
        expect(candidate['importable'], isFalse);
        expect(candidate['confirmationReason'], isNull);
        expect(candidate['fileSha256'], isNull);
        expect(candidate['downloadUrl'], isNull);
        if (malformedAnswer) {
          expect(output['text'], contains('获取入口'));
          expect(output['text'], contains('点击「下载并导入」后'));
          expect(output['text'], isNot(contains('已核验')));
        } else {
          expect(output['text'], answer);
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'modal preserves an unverified alternate entry after malformed provider output',
    () async {
      final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => model.close(force: true));
      var calls = 0;
      final requests = <Map>[];
      model.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        requests.add(body);
        calls++;
        final isTool = calls < 4;
        final delta = isTool
            ? {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call-$calls',
                    'type': 'function',
                    'function': {
                      'name': calls == 2 ? 'author' : 'find_book_material',
                      'arguments': jsonEncode({
                        'title': calls == 1 ? 'Hello 算法' : 'Hello Algo',
                      }),
                    },
                  },
                ],
              }
            : {'content': '检索结束。<｜DSML｜calls>author'};
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'id': 'book-search-fixture',
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': isTool ? 'tool_calls' : 'stop'},
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });

      final output = await runFixture(model.port, args: ['alternate']);
      expect(calls, 4);
      expect(output['starts'], 2);
      expect(output['attempts'], 2);
      expect(output['operation_count'], 2);
      expect(output['acquisitions'], 0);
      expect(output['text'], contains('暂未找到符合条件的电子书获取入口'));
      expect(output['text'], contains('替代版的获取入口'));
      expect(output['text'], isNot(contains('已核验')));
      expect(output['text'], isNot(contains('DSML')));
      final search = output['search'] as Map;
      final alternative = (search['candidates'] as List).single as Map;
      expect(alternative['edition'], '1.3.0');
      expect(alternative['verified'], isFalse);
      expect(alternative['downloadable'], isTrue);
      expect(alternative['candidateToken'], isA<String>());
      expect(alternative['importable'], isFalse);
      expect(alternative['confirmationReason'], contains('1.2.0'));
      final retry = (requests[2]['messages'] as List).last as Map;
      expect(retry['content'], contains('author 等字段是参数名'));
      expect(
        jsonEncode(requests.last['messages']),
        isNot(contains('"name":"author"')),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'ordinary chat and reading discussion send native thinking requests',
    () async {
      final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => model.close(force: true));
      final requests = <Map>[];
      model.listen((request) async {
        requests.add(
          jsonDecode(await utf8.decoder.bind(request).join()) as Map,
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'id': 'ordinary-fixture',
            'choices': [
              {
                'index': 0,
                'delta': {'content': '普通聊天回复。'},
                'finish_reason': 'stop',
              },
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      const deepseek = 'deepseek-flash';
      const mimo = 'mimo-v2.6-flash';
      const cases = [
        (mimo, 'enabled', false, mimo, 'enabled', null),
        (mimo, 'none', false, mimo, 'disabled', null),
        (mimo, 'low', false, mimo, 'enabled', null),
        (deepseek, 'low', false, deepseek, 'enabled', 'low'),
        (deepseek, 'high', false, deepseek, 'enabled', 'high'),
        (deepseek, 'medium', false, deepseek, 'enabled', 'high'),
        (deepseek, 'max', false, deepseek, 'enabled', 'max'),
        (mimo, 'max', true, deepseek, 'enabled', 'max'),
      ];
      final output = await runFixture(
        model.port,
        args: [
          'reasoning',
          jsonEncode([
            for (final (model, level, reading, _, _, _) in cases)
              {
                'model_id': model,
                'reasoning_level': level,
                if (reading) '_reading_discussion': true,
              },
          ]),
        ],
      );
      expect(output['answers'], List.filled(cases.length, '普通聊天回复。'));
      expect(requests, hasLength(cases.length));
      for (final (index, (_, _, _, providerModel, thinking, wireEffort))
          in cases.indexed) {
        final request = requests[index];
        expect(request['model'], providerModel);
        expect(request['thinking'], {'type': thinking});
        expect(request['reasoning_effort'], wireEffort);
        expect(request['enable_thinking'], isNull);
        if (providerModel == mimo) {
          expect(request['max_completion_tokens'], 131072);
          expect(request.containsKey('max_tokens'), isFalse);
          expect(request.containsKey('reasoning_effort'), isFalse);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'reading discussion retrieves and publishes book sources only on lookup',
    () async {
      final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => model.close(force: true));
      final requests = <Map>[];
      model.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (jsonEncode(body['messages']).contains('XIAOQI_TURN_INTENT_V1')) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'id': 'reading-intent-fixture',
            'choices': [
              {
                'index': 0,
                'message': {
                  'role': 'assistant',
                  'content': jsonEncode({
                    'mode': 'answer',
                    'image_count': 0,
                    'answer_required': true,
                    'skill_ids': [],
                    'connection_ids': [],
                    'target_artifact_id': null,
                    'clarification': null,
                  }),
                },
                'finish_reason': 'stop',
              },
            ],
          }));
          await request.response.close();
          return;
        }
        requests.add(body);
        final lookup = requests.length == 2;
        final delta = lookup
            ? {
                'reasoning_content': '需要核对书中的出处。',
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'lookup-1',
                    'type': 'function',
                    'function': {
                      'name': 'read_task_material',
                      'arguments': jsonEncode({
                        'material_id': 'fixture-material',
                        'mode': 'query',
                        'query': '花园小径',
                      }),
                    },
                  },
                ],
              }
            : {'content': requests.length == 1 ? 'Garden path.' : '见第 21 页。'};
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'id': 'reading-citations-fixture',
            'choices': [
              {
                'index': 0,
                'delta': delta,
                'finish_reason': lookup ? 'tool_calls' : 'stop',
              },
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });

      final output = await runFixture(model.port, args: ['reading-citations']);
      expect(requests.length, 3, reason: jsonEncode(output));
      expect(jsonEncode(requests.first['tools']), contains('read_task_material'));
      final initialMessages = jsonEncode(requests.first['messages']);
      expect(initialMessages, contains('先回答读者当前的问题'));
      expect(initialMessages, isNot(contains('回答必须说明实际阅读范围')));
      expect(initialMessages, isNot(contains('沿着花园小径走到了门口')));

      final turns = (output['turns'] as List).cast<Map>();
      final direct = turns.first;
      expect(direct['text'], 'Garden path.');
      final directEvents = (direct['events'] as List).cast<Map>();
      expect(
        directEvents.where(
          (event) =>
              event['type'] == 'reading_evidence' ||
              event['type'] == 'reading_material' ||
              event['tool'] == 'read_task_material',
        ),
        isEmpty,
      );
      final cited = turns.last;
      expect(cited['text'], '见第 21 页。');
      final evidence = (cited['events'] as List).cast<Map>().singleWhere(
        (event) => event['type'] == 'reading_evidence',
      );
      final reference = (evidence['references'] as List).single as Map;
      expect(reference['page'], 21);
      expect(reference['quote'], '沿着花园小径走到了门口。');
      expect(reference['source_version'], 'b' * 64);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'missing SiliconFlow key never falls back to the main chat provider',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--disable-dart-dev',
          '--packages=.dart_tool/package_config.json',
          'test/support/book_search_agent_fixture.dart',
        ],
        environment: {
          'SILICONFLOW_API_KEY': '',
          'MIMO_API_KEY': 'fixture-only',
          'MIMO_BASE_URL': 'http://127.0.0.1:1/v1',
          'XIAOQI_CAPTURE_TRACES': '0',
        },
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('服务器未配置 SILICONFLOW_API_KEY'));
      expect(result.stdout.toString(), isNot(contains('RESULT:')));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<Map> runFixture(int port, {List<String> args = const []}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      '--disable-dart-dev',
      '--packages=.dart_tool/package_config.json',
      'test/support/book_search_agent_fixture.dart',
      ...args,
    ],
    environment: {
      'MIMO_API_KEY': 'fixture-only',
      'MIMO_BASE_URL': 'http://127.0.0.1:$port/v1',
      'DEEPSEEK_API_KEY': 'fixture-only',
      'DEEPSEEK_BASE_URL': 'http://127.0.0.1:$port/v1',
      'SILICONFLOW_API_KEY': 'fixture-only',
      'SILICONFLOW_BASE_URL': 'http://127.0.0.1:$port/v1',
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
  return jsonDecode(line.substring('RESULT:'.length)) as Map;
}
