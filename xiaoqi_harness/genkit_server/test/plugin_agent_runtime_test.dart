import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  for (final scenario in [
    'write',
    'ignored-plugin-fields',
    'ignored-plugin-fields-approval',
    'preload',
    'preload-script-network',
    'nested',
    'plan',
    'approval',
    'denied',
    'dontask',
    'disabled',
    'readonly',
    'script-network',
    'root-hook-rewrite',
    'root-hook-deny',
    'root-hook-invalid',
    'root-hook-approval',
  ]) {
    test(
      'real runtime agent $scenario preserves task tools, budget and completion evidence',
      () async {
        var providerCalls = 0;
        final scriptNetwork = scenario.endsWith('script-network');
        final rootHooks = scenario.startsWith('root-hook-');
        final childToolSets = <Set<String>>[];
        final mcp = const {
          'approval',
          'ignored-plugin-fields-approval',
          'denied',
          'dontask',
          'disabled',
          'readonly',
          'root-hook-approval',
        }.contains(scenario);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serving = server.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          providerCalls++;
          final serialized = jsonEncode(body);
          request.response.headers.contentType = ContentType.json;
          if (serialized.contains('XIAOQI_TURN_INTENT_V1')) {
            request.response.write(
              jsonEncode({
                'id': 'intent',
                'choices': [
                  {
                    'index': 0,
                    'message': {
                      'role': 'assistant',
                      'content': jsonEncode({
                        'mode': 'workflow',
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
              }),
            );
            await request.response.close();
            return;
          }
          final messages = (body['messages'] as List).whereType<Map>().toList();
          final system = messages
              .where((m) => m['role'] == 'system')
              .map((m) => m['content'])
              .join();
          final child =
              system.contains('AGENT_RUNTIME_WRITER') ||
              system.contains('AGENT_RUNTIME_HELPER');
          final tools = (body['tools'] as List? ?? [])
              .whereType<Map>()
              .map((t) => t['function']['name'].toString())
              .toSet();
          bool called(String name) => messages.any(
            (m) =>
                m['role'] == 'assistant' &&
                (m['tool_calls'] as List? ?? []).whereType<Map>().any(
                  (t) => t['function']['name'] == name,
                ),
          );
          String? tool;
          Map<String, dynamic> input = {};
          if (child) {
            childToolSets.add(tools);
            if (scenario.startsWith('ignored-plugin-fields')) {
              expect(system, contains('按插件源协议忽略 Agent 的 mcpServers'));
              expect(system, contains('按插件源协议忽略 Agent 的 hooks'));
            }
            if (scenario == 'preload' && !called('read_skill_resource')) {
              expect(system, contains('FULL_PRELOADED_SKILL'));
              expect(system, contains('references/note.md'));
              tool = 'read_skill_resource';
              input = {
                'skill_id': RegExp(
                  r'<agent_skill id="(skill-[a-f0-9]{24})">',
                ).firstMatch(system)!.group(1),
                'path': 'references/note.md',
              };
            } else if (scenario == 'preload' &&
                !called('write_task_text_file')) {
              expect(serialized, contains('PRELOADED_RESOURCE'));
              tool = 'write_task_text_file';
              input = {'path': 'report.txt', 'text': 'verified child output'};
            } else if (scriptNetwork) {
              if (!called('execute_skill_script')) {
                tool = 'execute_skill_script';
                input = {
                  'skill_id': scenario == 'preload-script-network'
                      ? RegExp(
                          r'<agent_skill id="(skill-[a-f0-9]{24})">',
                        ).firstMatch(system)!.group(1)
                      : RegExp(
                          r'agent-[a-f0-9]{24}',
                        ).firstMatch(system)!.group(0),
                  'script_path': 'scripts/check.py',
                  'language': 'python',
                  'arguments': [r'literal; $(not-a-host-command)'],
                  'domains': ['example.com'],
                  'purpose': 'Fetch delegated task data',
                };
              }
            } else if (mcp) {
              final remote =
                  (body['tools'] as List).whereType<Map>().singleWhere(
                        (entry) => entry['function']['description']
                            .toString()
                            .contains('“make_card”'),
                      )['function']['name']
                      as String;
              if (!called(remote)) {
                tool = remote;
                input = rootHooks ? {'recipient': 'original'} : {};
              }
            } else if (scenario == 'nested' &&
                system.contains('AGENT_RUNTIME_WRITER')) {
              if (!called('search_plugin_agents')) {
                tool = 'search_plugin_agents';
                input = {'query': 'helper'};
              } else if (!called('run_plugin_agent')) {
                tool = 'run_plugin_agent';
                input = {
                  'agent_id': RegExp(
                    r'agent-[a-f0-9]{24}',
                  ).allMatches(serialized).last.group(0),
                  'task': 'Write the verified task note',
                };
              }
            } else if (!called('write_task_text_file')) {
              // Deliberately request a forbidden function in plan mode: the SDK
              // middleware must reject it even though the provider invents a call.
              tool = 'write_task_text_file';
              input = {'path': 'report.txt', 'text': 'verified child output'};
            }
          } else if (tools.contains('set_task_deliverables')) {
            if (!called('set_task_deliverables')) {
              tool = 'set_task_deliverables';
              input = {
                'steps': ['Delegate the note'],
                'skill_ids': [],
                'no_skill_reason': 'Use selected plugin Agent',
                'tools': [
                  {'name': 'run_plugin_agent', 'count': 1},
                ],
                'artifacts': scenario == 'plan' || mcp || scriptNetwork
                    ? []
                    : [
                        {'media_type': 'text/plain', 'count': 1},
                      ],
              };
            } else if (!called('search_plugin_agents')) {
              tool = 'search_plugin_agents';
              input = {'query': 'writer'};
            } else if (!called('run_plugin_agent')) {
              tool = 'run_plugin_agent';
              input = {
                'agent_id': RegExp(
                  r'agent-[a-f0-9]{24}',
                ).allMatches(serialized).last.group(0),
                'task': 'Write the verified task note',
              };
            }
          }
          final delta = tool == null
              ? {'content': child ? 'Child task completed' : '【准备完成】'}
              : {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call-$providerCalls',
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
                {'index': 0, 'delta': delta, 'finish_reason': tool == null ? 'stop' : 'tool_calls'},
              ],
            })}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        });
        try {
          final result = await Process.run(
            Platform.resolvedExecutable,
            [
              '--disable-dart-dev',
              '--packages=.dart_tool/package_config.json',
              'test/support/plugin_agent_runtime_fixture.dart',
              scenario,
            ],
            environment: {
              'MIMO_API_KEY': 'fixture-only',
              'MIMO_BASE_URL': 'http://127.0.0.1:${server.port}/v1',
              'XIAOQI_CAPTURE_TRACES': '0',
            },
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stderr}'.substring(
              0,
              result.stderr.toString().length.clamp(0, 2500),
            ),
          );
          final line = result.stdout
              .toString()
              .split('\n')
              .singleWhere((line) => line.startsWith('RESULT:'));
          final value = jsonDecode(line.substring(7)) as Map;
          expect(value['provider_calls'], providerCalls);
          if (scenario == 'ignored-plugin-fields') {
            expect(value['external_calls'], 0);
            expect(value['script_runs'], 0);
          }
          expect(childToolSets, isNotEmpty);
          for (final names in childToolSets) {
            if (!mcp && !scriptNetwork) {
              expect(names, isNot(contains('execute_shell')));
              expect(names, isNot(contains('execute_python')));
            }
            expect(names, isNot(contains('set_task_deliverables')));
            if (scenario == 'plan')
              expect(names, isNot(contains('write_task_text_file')));
          }
          if (scriptNetwork) {
            expect(value['before_approval'], 0);
            expect(value['script_runs'], 1);
            expect(value['network_grants'], isEmpty);
            expect(value['completed'], 1);
            expect(value['missing'], isFalse);
          } else if (mcp) {
            expect(value['before_approval'], 0);
            final approved = const {
              'approval',
              'ignored-plugin-fields-approval',
              'root-hook-approval',
            }.contains(scenario);
            expect(value['external_calls'], approved ? 1 : 0);
            expect(value['completed'], approved ? 1 : 0);
            expect(value['missing'], !approved);
          } else if (scenario == 'plan') {
            expect(value['contents'], isEmpty);
            expect(value['completed'], 0);
            expect(value['missing'], isTrue);
          } else if (rootHooks) {
            expect(
              value['contents'],
              scenario == 'root-hook-rewrite'
                  ? ['verified rewritten output']
                  : isEmpty,
            );
            expect(value['missing'], scenario != 'root-hook-rewrite');
          } else {
            expect(value['contents'], ['verified child output']);
            expect(value['completed'], scenario == 'nested' ? 2 : 1);
            expect(value['missing'], isFalse);
          }
          if (rootHooks) {
            expect(value['code_runs'], scenario == 'root-hook-deny' ? 1 : 2);
            final hooks = (value['hook_runs'] as List)
                .whereType<Map>()
                .toList();
            expect(
              hooks.where((h) => h['hook_event_name'] == 'PreToolUse'),
              hasLength(1),
            );
            expect(
              hooks.where(
                (h) =>
                    h['hook_event_name'] ==
                    (scenario == 'root-hook-invalid'
                        ? 'PostToolUseFailure'
                        : 'PostToolUse'),
              ),
              hasLength(scenario == 'root-hook-deny' ? 0 : 1),
            );
            if (scenario == 'root-hook-approval') {
              expect(hooks.last['tool_input'], {'recipient': 'changed'});
              expect(value['before_approval'], 0);
            }
          }
        } finally {
          await serving.cancel();
          await server.close(force: true);
        }
      },
    );
  }
}
