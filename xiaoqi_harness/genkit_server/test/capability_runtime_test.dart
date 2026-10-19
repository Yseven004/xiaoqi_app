import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final scenario in [
    'explicit',
    'implicit',
    'script-available',
    'text-only',
    'text-only-unplanned-image',
    'image-format-repair',
    'missing',
    'mcp-success',
    'mcp-error',
  ]) {
    test(
      '$scenario exercises real Genkit discovery, tool loop and delivery gate',
      () async {
        final requests = <Map<String, dynamic>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serving = server.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          requests.add(body);
          final serialized = jsonEncode(body['messages']);
          final textOnly = scenario.startsWith('text-only');
          final tools = (body['tools'] as List? ?? const []).whereType<Map>();
          final preparing = tools.any(
            (tool) => tool['function']?['name'] == 'set_task_deliverables',
          );
          final alias = RegExp(
            r'skill-[a-f0-9]{24}',
          ).firstMatch(serialized)?.group(0);
          final messages = (body['messages'] as List).whereType<Map>().toList();
          bool ran(String name) => messages.any(
            (message) => message['role'] == 'tool' && message['name'] == name,
          );
          // OpenAI adapters do not always retain the tool name on tool responses.
          bool called(String name) => serialized.contains('"name":"$name"');
          String? tool;
          Map<String, dynamic>? input;
          if (preparing && scenario.startsWith('mcp-')) {
            final remoteName = tools
                .map((tool) => tool['function']?['name']?.toString())
                .whereType<String>()
                .where((name) => name.startsWith('mcp_'))
                .first;
            if (!called('set_task_deliverables')) {
              tool = 'set_task_deliverables';
              input = {
                'steps': ['Call MCP', 'Check image'],
                'skill_ids': [],
                'no_skill_reason': 'This task uses the selected MCP connector',
                'tools': [
                  {'name': remoteName, 'count': 1},
                ],
                'artifacts': [
                  {'media_type': 'image/*', 'count': 1},
                ],
              };
            } else if (!called(remoteName)) {
              tool = remoteName;
              input = {};
            }
          } else if (preparing && scenario != 'missing') {
            if (scenario == 'implicit' && !called('use_skill')) {
              tool = 'use_skill';
              input = {'skillName': alias};
            } else if (!called('read_skill_resource')) {
              tool = 'read_skill_resource';
              input = {'skill_id': alias, 'path': 'references/rules.md'};
            } else if ((!called('set_task_deliverables') &&
                    !ran('set_task_deliverables')) ||
                (scenario == 'image-format-repair' &&
                    RegExp(
                          r'"name":"set_task_deliverables"',
                        ).allMatches(serialized).length <
                        2)) {
              tool = 'set_task_deliverables';
              input = {
                'steps': ['Read rules', 'Generate two pages'],
                'skill_ids': [alias],
                'tools': [
                  if (!textOnly) {'name': 'generate_image', 'count': 2},
                  {'name': 'read_skill_resource', 'count': 1},
                ],
                'artifacts': [
                  if (!textOnly)
                    {
                      'media_type':
                          scenario == 'image-format-repair' &&
                              !called('set_task_deliverables')
                          ? 'image/png'
                          : 'image/*',
                      'count': 2,
                    },
                ],
              };
            } else if (textOnly) {
              if (scenario == 'text-only-unplanned-image' &&
                  !called('generate_image')) {
                tool = 'generate_image';
                input = {'prompt': 'unplanned image must not reach provider'};
              }
            } else {
              final calls = RegExp(
                r'"name":"generate_image"',
              ).allMatches(serialized).length;
              if (calls < 2) {
                tool = 'generate_image';
                input = {'prompt': 'study page ${calls + 1}'};
              }
            }
          }
          final delta = tool == null
              ? {
                  'content': preparing
                      ? '【准备完成】'
                      : textOnly
                      ? '纯文字整理已完成。'
                      : '两页图片已交付。',
                }
              : {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call-${requests.length}',
                      'type': 'function',
                      'function': {
                        'name': tool,
                        'arguments': jsonEncode(input),
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
              'id': 'fixture',
              'choices': [
                {'index': 0, 'delta': delta, 'finish_reason': null},
              ],
            })}\n\n',
          );
          request.response.write(
            'data: ${jsonEncode({
              'id': 'fixture',
              'choices': [
                {'index': 0, 'delta': {}, 'finish_reason': tool == null ? 'stop' : 'tool_calls'},
              ],
            })}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        });
        try {
          final process = await Process.run(
            Platform.resolvedExecutable,
            [
              '--disable-dart-dev',
              '--packages=.dart_tool/package_config.json',
              scenario.startsWith('mcp-')
                  ? 'test/support/mcp_runtime_fixture.dart'
                  : 'test/support/capability_runtime_fixture.dart',
              scenario,
            ],
            environment: {
              'MIMO_API_KEY': 'local-test',
              'MIMO_BASE_URL': 'http://127.0.0.1:${server.port}/v1',
              'XIAOQI_CAPTURE_TRACES': '0',
            },
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(
            process.exitCode,
            0,
            reason: '${process.stdout}\n${process.stderr}',
          );
          final line = process.stdout
              .toString()
              .split('\n')
              .firstWhere((line) => line.startsWith('RESULT:'));
          final result = jsonDecode(line.substring(7)) as Map;
          expect(requests, isNotEmpty);
          if (!scenario.startsWith('mcp-')) {
            final firstToolNames = (requests.first['tools'] as List)
                .whereType<Map>()
                .map((tool) => tool['function']?['name'])
                .toList();
            expect(
              firstToolNames.contains('execute_skill_script'),
              scenario == 'script-available',
              reason:
                  'Only advertise installed script execution when real scripts exist',
            );
          }
          if (scenario.startsWith('mcp-')) {
            expect(result['before_approval'], 0);
            expect(result['mcp_calls'], 1);
            expect(result['missing'], scenario == 'mcp-error');
            expect(result['artifacts'], scenario == 'mcp-error' ? 0 : 1);
            expect(
              result['mcp_status'],
              scenario == 'mcp-error' ? 'failed' : 'completed',
            );
          } else if (scenario == 'missing') {
            expect(result['missing'], isTrue);
            expect(result['generated'], 0);
            expect(result['text'], contains('任务尚未完成'));
            expect(requests, hasLength(3));
          } else if (scenario.startsWith('text-only')) {
            expect(result['missing'], isFalse);
            expect(result['generated'], 0);
            expect(result['artifacts'], 0);
            expect(result['active'], hasLength(1));
            expect(result['text'], contains('纯文字'));
            expect(
              jsonEncode(result['events']),
              contains('read_skill_resource'),
            );
            expect(
              jsonEncode(requests.first['messages']),
              contains('TEXT_ONLY'),
            );
            // Image generation is available; zero calls are caused by this
            // task's delivery requirements, not a disabled image provider.
            expect(
              jsonEncode(requests.first['tools']),
              contains('generate_image'),
            );
            if (scenario == 'text-only-unplanned-image') {
              expect(jsonEncode(requests), contains('budget_exhausted'));
            }
          } else {
            expect(result['missing'], isFalse);
            expect(result['generated'], 2);
            expect(result['artifacts'], 2);
            expect(result['active'], hasLength(1));
            expect(
              jsonEncode(result['events']),
              contains('read_skill_resource'),
            );
            if (scenario == 'explicit')
              expect(
                jsonEncode(requests.first['messages']),
                contains('REQUIRED_GRAPHIC'),
              );
            if (scenario == 'implicit')
              expect(
                jsonEncode(requests.first['tools']),
                contains('use_skill'),
              );
            if (scenario == 'image-format-repair')
              expect(jsonEncode(requests), contains('图片编码格式尚无可执行保障'));
          }
        } finally {
          await server.close(force: true);
          await serving.cancel();
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
