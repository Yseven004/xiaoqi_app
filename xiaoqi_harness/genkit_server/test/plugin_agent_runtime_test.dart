import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  for (final scenario in [
    'write',
    'model-alias',
    'model-alias-nested',
    'ignored-plugin-fields',
    'ignored-plugin-fields-approval',
    'preload',
    'preload-script-network',
    'skill-hook-once',
    'skill-hook-block',
    'skill-hook-approval',
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
    'root-hook-readonly',
    'root-life-context',
    'root-life-approval',
    'root-life-deny',
    'root-life-stop',
    'root-life-async-stop',
    'fork-write',
    'fork-plan',
    'fork-custom',
    'fork-approval',
    'fork-denied',
    'fork-disabled',
    'fork-source-changed',
    'fork-unknown',
    'fork-dynamic',
    'fork-dynamic-plan',
    'fork-dynamic-approval',
    'fork-dynamic-denied',
  ]) {
    test(
      'real runtime agent $scenario preserves task tools, budget and completion evidence',
      () async {
        var providerCalls = 0;
        final scriptNetwork = scenario.endsWith('script-network');
        final rootHooks = scenario.startsWith('root-hook-');
        final rootLifecycle = scenario.startsWith('root-life-');
        final skillHooks = scenario.startsWith('skill-hook-');
        final fork = scenario.startsWith('fork-');
        final childToolSets = <Set<String>>[];
        var childHistoryLeaked = false;
        final childModels = <String>{};
        var modelMappingRecorded = false;
        final mcp = const {
          'approval',
          'ignored-plugin-fields-approval',
          'denied',
          'dontask',
          'disabled',
          'readonly',
          'root-hook-approval',
          'skill-hook-approval',
          'root-life-approval',
          'fork-approval',
          'fork-denied',
          'fork-disabled',
          'fork-source-changed',
          'fork-dynamic-approval',
          'fork-dynamic-denied',
        }.contains(scenario);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serving = server.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          providerCalls++;
          final serialized = jsonEncode(body);
          modelMappingRecorded |=
              serialized.contains('插件声明模型 sonnet') &&
              serialized.contains('deepseek-flash');
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
          var child =
              system.contains('AGENT_RUNTIME_WRITER') ||
              system.contains('AGENT_RUNTIME_HELPER');
          final tools = (body['tools'] as List? ?? [])
              .whereType<Map>()
              .map((t) => t['function']['name'].toString())
              .toSet();
          child =
              child ||
              (fork &&
                  tools.isNotEmpty &&
                  !tools.contains('set_task_deliverables'));
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
            if (scenario.startsWith('fork-dynamic')) {
              expect(serialized, contains('DYNAMIC_CONTEXT_VERIFIED'));
              expect(serialized, isNot(contains('!`printf')));
            }
            childModels.add(body['model'].toString());
            childHistoryLeaked |= serialized.contains(
              'PARENT_ONLY_PRIVATE_HISTORY',
            );
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
                input = rootHooks || skillHooks
                    ? {'recipient': 'original'}
                    : {};
              }
            } else if (scenario.endsWith('nested') &&
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
            } else if (scenario == 'root-hook-readonly') {
              if (!called('read_task_text_file')) {
                tool = 'read_task_text_file';
                input = {'path': 'report.txt'};
              }
            } else if (skillHooks) {
              final writes = messages
                  .expand(
                    (m) => (m['tool_calls'] as List? ?? []).whereType<Map>(),
                  )
                  .where((t) => t['function']['name'] == 'write_task_text_file')
                  .length;
              if (writes < (scenario == 'skill-hook-block' ? 3 : 2)) {
                tool = 'write_task_text_file';
                input = {
                  'path': 'report-$writes.txt',
                  'text': 'verified child output',
                };
              }
            } else if (!called('write_task_text_file')) {
              // Deliberately request a forbidden function in plan mode: the SDK
              // middleware must reject it even though the provider invents a call.
              tool = 'write_task_text_file';
              input = {'path': 'report.txt', 'text': 'verified child output'};
            }
          } else if (tools.contains('set_task_deliverables')) {
            if (rootLifecycle) {
              expect(system, contains('ROOT_STARTUP_CONTEXT'));
              expect(system, contains('ROOT_PROMPT_CONTEXT'));
            }
            if ((scenario == 'root-life-stop' ||
                    scenario == 'root-life-async-stop') &&
                serialized.contains('STOP_REVIEW_REQUIRED') &&
                !called('write_task_text_file')) {
              tool = 'write_task_text_file';
              input = {'path': 'review.txt', 'text': 'resolved review finding'};
            } else if (!called('set_task_deliverables')) {
              tool = 'set_task_deliverables';
              input = {
                'steps': ['Delegate the note'],
                'skill_ids': [],
                'no_skill_reason': 'Use selected plugin Agent',
                'tools': [
                  {
                    'name': fork ? 'run_plugin_command' : 'run_plugin_agent',
                    'count': 1,
                  },
                ],
                'artifacts':
                    scenario == 'plan' ||
                        scenario == 'root-hook-readonly' ||
                        mcp ||
                        scriptNetwork
                    ? []
                    : [
                        {'media_type': 'text/plain', 'count': 1},
                      ],
              };
            } else if (!called(
              fork ? 'search_plugin_commands' : 'search_plugin_agents',
            )) {
              tool = fork ? 'search_plugin_commands' : 'search_plugin_agents';
              input = {'query': fork ? 'work' : 'writer'};
            } else if (!called(
              fork ? 'run_plugin_command' : 'run_plugin_agent',
            )) {
              tool = fork ? 'run_plugin_command' : 'run_plugin_agent';
              input = fork
                  ? {
                      'command_id': RegExp(
                        r'command-[a-f0-9]{24}',
                      ).allMatches(serialized).last.group(0),
                      'arguments': r'literal; $(no-shell)',
                    }
                  : {
                      'agent_id': RegExp(
                        r'agent-[a-f0-9]{24}',
                      ).allMatches(serialized).last.group(0),
                      'task': 'Write the verified task note',
                    };
            } else if (skillHooks && !called('write_task_text_file')) {
              tool = 'write_task_text_file';
              input = {'path': 'parent.txt', 'text': 'parent output'};
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
              if (scenario.startsWith('model-alias')) ...{
                'DEEPSEEK_API_KEY': 'fixture-only',
                'DEEPSEEK_BASE_URL': 'http://127.0.0.1:${server.port}/v1',
              },
            },
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          if (scenario == 'root-life-deny') {
            expect(result.exitCode, isNot(0));
            expect(result.stderr, contains('prompt blocked'));
            expect(childToolSets, isEmpty);
            expect(providerCalls, 1);
            return;
          }
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
          if (scenario.startsWith('model-alias')) {
            expect(childModels, {'deepseek-flash'});
            expect(modelMappingRecorded, isTrue);
          }
          if (scenario == 'ignored-plugin-fields') {
            expect(value['external_calls'], 0);
            expect(value['script_runs'], 0);
          }
          expect(childHistoryLeaked, isFalse);
          if (scenario != 'fork-unknown') expect(childToolSets, isNotEmpty);
          if (scenario == 'fork-unknown') expect(childToolSets, isEmpty);
          for (final names in childToolSets) {
            if (!mcp &&
                !scriptNetwork &&
                (!fork ||
                    scenario.endsWith('-plan') ||
                    scenario == 'fork-custom')) {
              expect(names, isNot(contains('execute_shell')));
              expect(names, isNot(contains('execute_python')));
            }
            expect(names, isNot(contains('set_task_deliverables')));
            if (scenario == 'plan' ||
                scenario.endsWith('-plan') ||
                scenario == 'root-hook-readonly')
              expect(names, isNot(contains('write_task_text_file')));
          }
          if (fork) {
            final success = !const {
              'fork-plan',
              'fork-dynamic-plan',
              'fork-dynamic-denied',
              'fork-denied',
              'fork-disabled',
              'fork-source-changed',
              'fork-unknown',
            }.contains(scenario);
            expect(value['command_completed'], success ? 1 : 0);
            expect(value['missing'], !success);
            if (scenario.startsWith('fork-dynamic')) {
              expect(value['code_runs'], 1);
            }
            if (mcp) {
              expect(
                value['external_calls'],
                scenario.endsWith('approval') ? 1 : 0,
              );
              expect(value['before_approval'], 0);
            } else {
              expect(
                value['contents'],
                success ? ['verified child output'] : isEmpty,
              );
            }
          } else if (scriptNetwork) {
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
              'skill-hook-approval',
              'root-life-approval',
            }.contains(scenario);
            expect(value['external_calls'], approved ? 1 : 0);
            expect(value['completed'], approved ? 1 : 0);
            expect(value['missing'], !approved);
          } else if (scenario == 'plan') {
            expect(value['contents'], isEmpty);
            expect(value['completed'], 0);
            expect(value['missing'], isTrue);
          } else if (scenario == 'root-hook-readonly') {
            expect(value['contents'], ['original task note']);
            expect(value['missing'], isFalse);
            expect(value['completed'], 1);
          } else if (scenario == 'root-life-stop' ||
              scenario == 'root-life-async-stop') {
            expect(
              value['contents'],
              unorderedEquals([
                'verified child output',
                'resolved review finding',
              ]),
            );
            expect(value['completed'], 1);
            expect(value['missing'], isFalse);
          } else if (skillHooks) {
            expect(
              value['contents'],
              unorderedEquals([
                'verified rewritten output',
                'verified child output',
                'parent output',
              ]),
              reason: jsonEncode(value),
            );
            expect(value['completed'], 1);
            expect(value['missing'], isFalse);
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
            expect(value['completed'], scenario.endsWith('nested') ? 2 : 1);
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
          if (skillHooks) {
            final hooks = (value['hook_runs'] as List)
                .whereType<Map>()
                .toList();
            expect(hooks, hasLength(scenario == 'skill-hook-block' ? 2 : 1));
            expect(value['code_runs'], hooks.length);
            expect(hooks.every((h) => h['session_id'] != 'turn'), isTrue);
            expect(value['contents'], contains('parent output'));
          }
          if (rootLifecycle) {
            final hooks = (value['hook_runs'] as List)
                .whereType<Map>()
                .toList();
            expect(hooks.map((h) => h['hook_event_name']), [
              'SessionStart',
              'UserPromptSubmit',
              if (scenario == 'root-life-stop' ||
                  scenario == 'root-life-async-stop') ...[
                'Stop',
                'Stop',
              ],
            ]);
            expect(
              value['code_runs'],
              (scenario == 'root-life-stop' ||
                      scenario == 'root-life-async-stop')
                  ? 4
                  : 2,
            );
            if (scenario == 'root-life-stop' ||
                scenario == 'root-life-async-stop')
              expect(
                hooks
                    .where((h) => h['hook_event_name'] == 'Stop')
                    .map((h) => h['stop_hook_active']),
                [false, true],
              );
          }
        } finally {
          await serving.cancel();
          await server.close(force: true);
        }
      },
    );
  }
}
