import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final scenario in [
    'explicit',
    'explicit-partial',
    'implicit',
    'script-available',
    'text-only',
    'text-only-workspace-retry',
    'text-only-shell',
    'text-only-search',
    'text-only-network-python',
    'text-only-network-on',
    'text-only-network-script',
    'text-only-network-denied',
    'text-only-network-changed',
    'text-only-network-file-changed',
    'text-only-network-legacy',
    'text-only-unplanned-image',
    'image-format-repair',
    'missing',
    'mcp-success',
    'mcp-partial-selection',
    'mcp-partial-startup',
    'mcp-error',
    'mcp-read',
    'mcp-public-read',
    'mcp-large',
    'mcp-approved-repeat',
    'mcp-denied',
    'mcp-disabled',
    'mcp-reconfigured',
    'mcp-argument-change',
  ]) {
    test(
      '$scenario exercises real Genkit discovery, tool loop and delivery gate',
      () async {
        final requests = <Map<String, dynamic>>[];
        var providerRequests = 0;
        final searchQueries = <String>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serving = server.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          final serialized = jsonEncode(body['messages']);
          if (request.uri.path.endsWith('/tools/search')) {
            searchQueries.add(body['query'].toString());
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'summary': 'local-search-result',
                'results': [
                  {
                    'title': 'Fixture source',
                    'url': 'https://example.com/source-${searchQueries.length}',
                    'summary': 'local-search-result',
                  },
                ],
              }),
            );
            await request.response.close();
            return;
          }
          providerRequests++;
          if (serialized.contains('XIAOQI_TURN_INTENT_V1')) {
            final messages = (body['messages'] as List)
                .whereType<Map>()
                .toList();
            final content = messages.last['content'];
            final prompt =
                jsonDecode(
                      content is String
                          ? content
                          : (content as List)
                                .whereType<Map>()
                                .map((p) => p['text'] ?? '')
                                .join(),
                    )
                    as Map;
            final catalog = (prompt['skills'] as List).whereType<Map>();
            final connectors = (prompt['connections'] as List).whereType<Map>();
            final proposal = {
              'mode':
                  const {
                    'mcp-read',
                    'mcp-public-read',
                    'mcp-large',
                    'mcp-disabled',
                    'mcp-reconfigured',
                  }.contains(scenario)
                  ? 'answer'
                  : 'workflow',
              'answer_required': true,
              'image_count':
                  const {
                        'mcp-read',
                        'mcp-public-read',
                        'mcp-large',
                        'mcp-disabled',
                        'mcp-reconfigured',
                      }.contains(scenario) ||
                      scenario.startsWith('text-only')
                  ? 0
                  : scenario.startsWith('mcp-')
                  ? 1
                  : 2,
              'skill_ids': catalog.map((entry) => entry['id']).toList(),
              'connection_ids': connectors.map((entry) => entry['id']).toList(),
              'target_artifact_id': null,
              'clarification': null,
            };
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'id': 'intent-fixture',
                'choices': [
                  {
                    'index': 0,
                    'message': {
                      'role': 'assistant',
                      'content': jsonEncode(proposal),
                    },
                    'finish_reason': 'stop',
                  },
                ],
              }),
            );
            await request.response.close();
            return;
          }
          requests.add(body);
          final textOnly = scenario.startsWith('text-only');
          final tools = (body['tools'] as List? ?? const []).whereType<Map>();
          final preparing =
              body['tool_choice'] != 'none' &&
              tools.any(
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
            final large = scenario == 'mcp-large';
            final directoryName = large
                ? tools.firstWhere(
                        (tool) => tool['function']['description']
                            .toString()
                            .contains('“search_tools”'),
                      )['function']['name']
                      as String
                : null;
            final remoteName = tools
                .where(
                  (tool) =>
                      !large ||
                      tool['function']['description'].toString().contains(
                        '“call_tool”',
                      ),
                )
                .map((tool) => tool['function']?['name']?.toString())
                .whereType<String>()
                .where((name) => name.startsWith('mcp_'))
                .first;
            final remoteRefs = messages
                .expand(
                  (message) => (message['tool_calls'] as List? ?? const [])
                      .whereType<Map>(),
                )
                .where(
                  (call) => (call['function'] as Map?)?['name'] == remoteName,
                )
                .map((call) => call['id'])
                .toSet();
            final remoteResponses = messages
                .where(
                  (message) =>
                      message['role'] == 'tool' &&
                      (message['name'] == remoteName ||
                          remoteRefs.contains(message['tool_call_id'])),
                )
                .length;
            if (!called('set_task_deliverables')) {
              tool = 'set_task_deliverables';
              input = {
                'steps': ['Call MCP', 'Check image'],
                'skill_ids': [],
                'no_skill_reason': 'This task uses the selected MCP connector',
                'tools': [
                  if (directoryName != null)
                    {'name': directoryName, 'count': 1},
                  {'name': remoteName, 'count': 1},
                ],
                'artifacts': [
                  if (!const {
                    'mcp-read',
                    'mcp-public-read',
                    'mcp-large',
                    'mcp-disabled',
                    'mcp-reconfigured',
                  }.contains(scenario))
                    {'media_type': 'image/*', 'count': 1},
                ],
              };
            } else if (directoryName != null && !called(directoryName)) {
              tool = directoryName;
              input = {'query': 'fetch_card_119'};
            } else if (!called(remoteName) ||
                (const {
                      'mcp-approved-repeat',
                      'mcp-denied',
                      'mcp-argument-change',
                    }.contains(scenario) &&
                    remoteResponses < 2)) {
              tool = remoteName;
              input = large
                  ? {'tool_name': 'fetch_card_119', 'arguments': {}}
                  : scenario == 'mcp-public-read'
                  ? {'repoName': 'firebase/genkit'}
                  : scenario == 'mcp-argument-change'
                  ? {'destination': remoteResponses == 0 ? 'A' : 'B'}
                  : {};
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
                  if (scenario == 'text-only-workspace-retry')
                    {'name': 'execute_python', 'count': 1},
                  if (scenario == 'text-only-shell')
                    {'name': 'execute_shell', 'count': 1},
                  if (scenario == 'text-only-search')
                    {'name': 'web_search', 'count': 3},
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
              if (scenario.startsWith('text-only-network-')) {
                final name = scenario == 'text-only-network-script'
                    ? 'execute_skill_script'
                    : 'execute_python';
                final calls = RegExp(
                  '"name":"$name"',
                ).allMatches(serialized).length;
                if (calls < 2) {
                  tool = name;
                  input = {
                    if (name == 'execute_skill_script') ...{
                      'script_path': 'scripts/check.py',
                      'language': 'python',
                    } else
                      'code':
                          scenario == 'text-only-network-changed' && calls > 0
                          ? 'changed after first approved call'
                          : 'original approved code',
                    'skill_id': alias,
                    'domains': ['example.com'],
                    'purpose': '读取公开资料',
                  };
                } else if (scenario == 'text-only-network-denied' &&
                    !called('execute_shell')) {
                  tool = 'execute_shell';
                  input = {
                    'code': 'another entry',
                    'skill_id': alias,
                    'domains': ['example.com'],
                    'purpose': '读取公开资料',
                  };
                }
              }
              if (scenario == 'text-only-search') {
                final attempts = RegExp(
                  r'"name":"web_search"',
                ).allMatches(serialized).length;
                if (attempts < 3) {
                  tool = 'web_search';
                  input = {
                    'query': 'fixture search ${attempts + 1}',
                    'skill_id': alias,
                    'purpose': '核验当前步骤的公开来源',
                  };
                }
              }
              if (scenario == 'text-only-shell' && !called('execute_shell')) {
                tool = 'execute_shell';
                input = {
                  'code': r'printf "%s" "$1"',
                  'arguments': [r'literal; $(not-a-host-command)', ''],
                };
              }
              if (scenario == 'text-only-workspace-retry') {
                final attempts = RegExp(
                  r'"name":"execute_python"',
                ).allMatches(serialized).length;
                if (attempts < 3) {
                  tool = 'execute_python';
                  input = {
                    'code': 'print("recovery attempt ${attempts + 1}")',
                    'language': 'python',
                  };
                }
              }
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
              if (scenario == 'text-only-search') ...{
                'DEEPSEEK_API_KEY': 'local-search-fixture',
                'DEEPSEEK_BASE_URL': 'http://127.0.0.1:${server.port}/v1',
                'DEEPSEEK_SEARCH_BASE_URL':
                    'http://127.0.0.1:${server.port}/v1',
              },
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
          final budgetLine = process.stdout
              .toString()
              .split('\n')
              .singleWhere((line) => line.startsWith('MODEL_REQUESTS:'));
          expect(
            int.parse(budgetLine.substring('MODEL_REQUESTS:'.length)),
            providerRequests,
            reason:
                'Count every actual provider attempt, including intent, repair and resume',
          );
          expect(requests, isNotEmpty);
          if (!scenario.startsWith('mcp-')) {
            final firstToolNames = (requests.first['tools'] as List)
                .whereType<Map>()
                .map((tool) => tool['function']?['name'])
                .toList();
            expect(
              firstToolNames.contains('execute_skill_script'),
              scenario == 'script-available' ||
                  scenario.startsWith('text-only-network-'),
              reason:
                  'Only advertise installed script execution when real scripts exist',
            );
          }
          if (scenario == 'text-only-network-legacy') {
            expect(result['network_before_approval'], 0);
            expect(result['network_runs'], 1);
            expect(result['network_grants'], isEmpty);
            expect(result['text'], contains('纯文字'));
            return;
          }
          if (scenario.startsWith('mcp-')) {
            final blocked = const {
              'mcp-denied',
              'mcp-disabled',
              'mcp-reconfigured',
            }.contains(scenario);
            expect(
              result['before_approval'],
              const {
                    'mcp-read',
                    'mcp-large',
                    'mcp-public-read',
                  }.contains(scenario)
                  ? 1
                  : 0,
            );
            if (scenario == 'mcp-public-read') {
              expect(result['approval_events'], 0);
              expect(result['called_tools'], ['read_wiki_structure']);
              expect(result['called_arguments'], [
                {'repoName': 'firebase/genkit'},
              ]);
            }
            expect(result['mcp_calls'], blocked ? 0 : 1);
            if (scenario == 'mcp-large')
              expect(result['called_tools'], ['fetch_card_119']);
            expect(
              result['missing'],
              scenario == 'mcp-error' ||
                  blocked ||
                  scenario.startsWith('mcp-partial-'),
            );
            if (scenario.startsWith('mcp-partial-')) {
              expect(result['text'], contains('任务尚未完成'));
              expect(result['text'], contains('Unavailable component'));
              expect(jsonEncode(result['events']), contains('mcp_connection'));
              expect(
                jsonEncode(result),
                isNot(contains('private-connection-diagnostic')),
              );
            }
            expect(
              result['artifacts'],
              scenario == 'mcp-error' || blocked ? 0 : 1,
            );
            expect(
              result['mcp_status'],
              scenario == 'mcp-denied'
                  ? 'skipped'
                  : scenario == 'mcp-argument-change'
                  ? 'waiting'
                  : const {
                      'mcp-error',
                      'mcp-disabled',
                      'mcp-reconfigured',
                    }.contains(scenario)
                  ? 'failed'
                  : 'completed',
            );
            if (const {
              'mcp-approved-repeat',
              'mcp-denied',
            }.contains(scenario)) {
              expect(result['approval_events'], 1);
              expect(
                result['tool_operation_count'],
                scenario == 'mcp-denied' ? 0 : 1,
              );
              expect(
                result['maximum_mcp_success_count'],
                scenario == 'mcp-denied' ? 0 : 1,
              );
            }
            if (scenario == 'mcp-argument-change') {
              expect(result['approval_events'], 2);
              expect(result['called_arguments'], [
                {'destination': 'A'},
              ]);
              expect((result['pending_arguments'] as Map)['destination'], 'B');
              expect(result['pending_hash_changed'], true);
              expect(result['tool_operation_count'], 1);
            }
          } else if (scenario == 'missing') {
            expect(result['missing'], isTrue);
            expect(result['generated'], 0);
            expect(result['text'], contains('任务尚未完成'));
            expect(requests, hasLength(3));
          } else if (scenario.startsWith('text-only')) {
            if (scenario.startsWith('text-only-network-')) {
              expect(result['network_before_approval'], 0);
              expect(result['network_grants'], isEmpty);
              expect(
                result['network_runs'],
                const {
                      'text-only-network-denied',
                      'text-only-network-file-changed',
                    }.contains(scenario)
                    ? 0
                    : 1,
              );
              expect(
                result['network_interrupted'],
                const {
                  'text-only-network-changed',
                  'text-only-network-file-changed',
                }.contains(scenario),
              );
              if (const {
                'text-only-network-changed',
                'text-only-network-file-changed',
              }.contains(scenario)) {
                expect(
                  jsonEncode(result['events']),
                  contains('network_permission_required'),
                );
                return;
              }
              if (scenario == 'text-only-network-denied')
                expect(jsonEncode(result['events']), contains('user_denied'));
            }
            expect(result['missing'], isFalse, reason: jsonEncode(result));
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
            // The provider is configured, but this turn does not permit images.
            expect(
              jsonEncode(requests.first['tools']),
              isNot(contains('generate_image')),
            );
            if (scenario == 'text-only-unplanned-image') {
              expect(jsonEncode(requests), contains('scope_denied'));
            }
            if (scenario == 'text-only-workspace-retry') {
              final transcript = jsonEncode(requests);
              expect(transcript, contains('terminal-workspace-cause'));
              expect(transcript, contains('recovered'));
              expect(transcript, isNot(contains('连续失败两次')));
            }
            if (scenario == 'text-only-shell') {
              expect(jsonEncode(requests), contains('shell-routing-verified'));
              expect(jsonEncode(result['events']), contains('execute_shell'));
            }
            if (scenario == 'text-only-search') {
              expect(searchQueries, [
                'fixture search 1',
                'fixture search 2',
                'fixture search 3',
              ]);
              expect(
                jsonEncode(requests),
                isNot(contains('search_budget_exhausted')),
              );
              expect(result['operation_count'], 3);
            }
          } else {
            expect(result['missing'], scenario == 'explicit-partial');
            expect(result['generated'], 2);
            expect(result['artifacts'], 2);
            expect(result['active'], hasLength(1));
            if (scenario == 'explicit-partial') {
              expect(result['text'], contains('任务尚未完成'));
              expect(result['text'], contains('Unavailable plugin'));
              expect(
                jsonEncode(result),
                isNot(contains('private-package-diagnostic')),
              );
            }
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
          if (!const {
            'missing',
            'explicit-partial',
            'mcp-error',
            'mcp-partial-selection',
            'mcp-partial-startup',
            'mcp-denied',
            'mcp-disabled',
            'mcp-reconfigured',
            'mcp-argument-change',
          }.contains(scenario)) {
            final finalRequest = requests.last;
            expect(finalRequest['tool_choice'], 'none');
            expect(finalRequest['tools'], isNotEmpty);
            expect(
              jsonEncode(finalRequest['tools']),
              isNot(contains('send_a2ui')),
            );
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
