import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'plugin_hook_fixtures.dart';

/// Deterministic local model responses drive the production Agent/tool code.
/// The MCP process and Shell helper still execute in real isolated containers.
Future<void> verifyStdioAgent(
  CloudStore store,
  DockerCodeExecutionService executor,
  String tenant,
  Map<String, List<int>> installedFiles, {
  bool mixedDeclarations = false,
  bool rootHooks = false,
  bool readOnlyDelegate = false,
}) async {
  const task = 'agent-mcp-shell';
  const text = '使用文件插件写入文件，运行 Shell 核对，再调用插件命令脚本生成结果文件。';
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 40443);
  final serving = server.listen((request) async {
    try {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final serialized = jsonEncode(body['messages']);
      if (serialized.contains('XIAOQI_TURN_INTENT_V1')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'local-intent',
            'choices': [
              {
                'index': 0,
                'message': {
                  'role': 'assistant',
                  'content': jsonEncode({
                    'mode': 'workflow',
                    'answer_required': true,
                    'image_count': 0,
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
      final tools = (body['tools'] as List? ?? []).whereType<Map>().toList();
      String alias(String original) =>
          tools.firstWhere(
                (tool) => tool['function']['description'].toString().contains(
                  '“$original”',
                ),
              )['function']['name']
              as String;
      final preparing = body['tool_choice'] != 'none';
      String? name;
      Map<String, dynamic>? input;
      final child =
          readOnlyDelegate &&
          (body['messages'] as List).whereType<Map>().any(
            (message) =>
                message['role'] == 'system' &&
                message['content'].toString().contains(
                  'READ_ONLY_HOOK_GATE_AGENT',
                ),
          );
      if (preparing && child) {
        final names = tools.map((tool) => tool['function']['name']).toSet();
        if (names.contains('write_task_text_file') ||
            names.contains('execute_shell')) {
          throw StateError(
            'Read-only delegated Agent exposed a write/code tool',
          );
        }
        if (!serialized.contains('"name":"read_task_text_file"')) {
          name = 'read_task_text_file';
          input = {'path': 'agent.txt'};
        }
      } else if (preparing) {
        final write = alias('write_file');
        final read = alias('read_text_file');
        final skill = RegExp(
          r'skill-[a-f0-9]{24}',
        ).firstMatch(serialized)?.group(0);
        if (skill == null)
          throw StateError('Selected skill was not exposed alongside MCP');
        bool called(String tool) => serialized.contains('"name":"$tool"');
        if (!called('set_task_deliverables')) {
          name = 'set_task_deliverables';
          input = {
            'steps': ['写入文件', '核对文件', '执行 Shell 接力', '调用插件命令及脚本'],
            'skill_ids': [skill],
            'tools': [
              {'name': write, 'count': 1},
              {'name': read, 'count': 1},
              {'name': 'execute_shell', 'count': 1},
              {'name': 'search_plugin_commands', 'count': 1},
              {'name': 'run_plugin_command', 'count': 1},
              {'name': 'execute_skill_script', 'count': 1},
              if (readOnlyDelegate)
                {'name': 'search_plugin_agents', 'count': 1},
              if (readOnlyDelegate) {'name': 'run_plugin_agent', 'count': 1},
            ],
            'artifacts': [
              {'media_type': 'text/plain', 'count': 3},
            ],
          };
        } else if (!called(write)) {
          name = write;
          input = {
            'path': '/workspace/output/agent.txt',
            'content': 'agent-mcp-payload',
          };
        } else if (!called(read)) {
          name = read;
          input = {'path': '/workspace/output/agent.txt'};
        } else if (!called('execute_shell')) {
          name = 'execute_shell';
          input = {
            'code': hookGateShellCode,
            'arguments': hookGateShellArguments,
          };
        } else if (!called('search_plugin_commands')) {
          name = 'search_plugin_commands';
          input = {'query': 'verify-command'};
        } else if (!called('run_plugin_command')) {
          name = 'run_plugin_command';
          input = {
            'command_id': RegExp(
              r'command-[a-f0-9]{24}',
            ).firstMatch(serialized)!.group(0),
            'arguments': 'Verify script handoff',
          };
        } else if (!called('execute_skill_script')) {
          name = 'execute_skill_script';
          input = {
            'skill_id': RegExp(
              r'command-[a-f0-9]{24}',
            ).firstMatch(serialized)!.group(0),
            'script_path': 'scripts/verify-command.py',
            'language': 'python',
            'arguments': [r'command; $(touch /workspace/output/unwanted)'],
          };
        } else if (readOnlyDelegate && !called('search_plugin_agents')) {
          name = 'search_plugin_agents';
          input = {'query': 'readonly-verifier'};
        } else if (readOnlyDelegate && !called('run_plugin_agent')) {
          name = 'run_plugin_agent';
          input = {
            'agent_id': RegExp(
              r'agent-[a-f0-9]{24}',
            ).firstMatch(serialized)!.group(0),
            'task':
                'Read agent.txt and report its original content without writing files.',
          };
        }
      }
      final delta = name == null
          ? {'content': preparing ? '【准备完成】' : '文件已写入、核对并完成命令接力。'}
          : {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call-${DateTime.now().microsecondsSinceEpoch}',
                  'type': 'function',
                  'function': {'name': name, 'arguments': jsonEncode(input)},
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
          'id': 'local-model',
          'choices': [
            {'index': 0, 'delta': delta, 'finish_reason': null},
          ],
        })}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({
          'id': 'local-model',
          'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': name == null ? 'stop' : 'tool_calls'},
          ],
        })}\n\ndata: [DONE]\n\n',
      );
      await request.response.close();
    } catch (error) {
      final message = error.toString();
      stderr.writeln(
        'LOCAL_GATE_MODEL_ERROR ${message.substring(0, message.length > 300 ? 300 : message.length)}',
      );
      request.response.statusCode = 500;
      await request.response.close();
    }
  });
  final package =
      'verification/stdio-plugin${mixedDeclarations ? '-mixed' : ''}';
  final serverConfig = {
    'command': 'npx',
    'args': [
      '@modelcontextprotocol/server-filesystem@2.0.1',
      '/workspace/output',
    ],
  };
  store.putImmutable(package, {
    ...installedFiles,
    'commands/verify.md': utf8.encode(
      '---\ndescription: Verify a literal command script handoff\n---\nRun scripts/verify-command.py using execute_skill_script. \$ARGUMENTS',
    ),
    'scripts/verify-command.py': utf8.encode(r'''
import pathlib,sys
assert sys.argv[1:] == ['command; $(touch /workspace/output/unwanted)']
pathlib.Path('/workspace/output/plugin-command.txt').write_text('plugin-command-script-verified')
'''),
    'SKILL.md': utf8.encode(
      '---\nname: file-workflow\ndescription: Use filesystem MCP and a Shell helper to deliver verified files\n---\nWrite and read the file with the filesystem MCP. Then use execute_shell to read the task input manifest and produce the verified helper file.\n',
    ),
    if (readOnlyDelegate)
      'agents/readonly-verifier.md': utf8.encode(
        '---\nname: readonly-verifier\ndescription: Read the verified task file\ntools: [Read]\npermissionMode: plan\n---\nREAD_ONLY_HOOK_GATE_AGENT: Read agent.txt and report its contents.\n',
      ),
    if (rootHooks)
      'hooks/hooks.json': utf8.encode(
        jsonEncode({
          'hooks': {
            for (final event in ['PreToolUse', 'PostToolUse'])
              event: [
                {
                  'matcher': readOnlyDelegate ? r'^Bash$|^Read$' : r'^Bash$',
                  'hooks': [
                    {
                      'type': 'command',
                      'onFailure': 'block',
                      'command':
                          'python3 "\$CLAUDE_PLUGIN_ROOT/hooks/${event == 'PreToolUse' ? 'pre' : 'post'}.py"',
                    },
                  ],
                },
              ],
          },
        }),
      ),
    if (rootHooks)
      'hooks/pre.py': utf8.encode(
        readOnlyDelegate
            ? hookGateWithReadOnly(hookGatePreScript)
            : hookGatePreScript,
      ),
    if (rootHooks)
      'hooks/post.py': utf8.encode(
        readOnlyDelegate
            ? hookGateWithReadOnly(hookGatePostScript)
            : hookGatePostScript,
      ),
    '.mcp.json': utf8.encode(
      jsonEncode({
        'mcpServers': mixedDeclarations ? {} : {'filesystem': serverConfig},
      }),
    ),
    if (mixedDeclarations)
      '.claude-plugin/plugin.json': utf8.encode(
        jsonEncode({
          'name': 'mixed-filesystem',
          'mcpServers': [
            './config/first.json',
            {'filesystem': serverConfig},
          ],
        }),
      ),
    if (mixedDeclarations)
      'config/first.json': utf8.encode(
        jsonEncode({
          'mcpServers': {
            'filesystem': {
              'command': 'node',
              'args': ['/workspace/skill/never-start.mjs'],
            },
          },
        }),
      ),
  });
  store.put('cap/$tenant/filesystem', {
    'id': 'filesystem',
    'name': 'Filesystem verification',
    'kind': 'plugin',
    'origin': 'github',
    'enabled': true,
    'current_version_id': 'v1',
    'components': [
      {'id': 'filesystem', 'type': 'mcp', 'status': 'supported', 'root': ''},
      {
        'id': 'instructions',
        'type': 'skill',
        'status': 'supported',
        'root': '',
        'name': 'File workflow',
        'description': 'Use MCP and Shell together',
      },
    ],
    'versions': [
      {
        'id': 'v1',
        'artifact_key': package,
        'components': [
          {
            'id': 'command',
            'type': 'command',
            'root': '',
            'source_path': 'commands/verify.md',
            'name': 'verify-command',
            'description': 'Verify a literal command script handoff',
            'status': 'supported',
            'has_scripts': true,
          },
          {
            'id': 'filesystem',
            'type': 'mcp',
            'status': 'supported',
            'root': '',
          },
          {
            'id': 'instructions',
            'type': 'skill',
            'status': 'supported',
            'root': '',
            'name': 'File workflow',
            'description': 'Use MCP and Shell together',
          },
        ],
      },
    ],
  }, null);
  store.put('task/$tenant/$task', {
    'status': 'running',
    'artifacts': [],
    'events': [],
  }, null);
  final events = <Map<String, Object?>>[];
  try {
    final result =
        await GenkitXiaoqiAgentRuntime(
          store,
          ImageService(store),
          codeExecutor: executor,
        ).runAgentTurn(
          tenantId: tenant,
          taskId: task,
          request: {
            'model_id': 'mimo-v2.6-flash',
            'current_turn_text': text,
            'selected_capabilities': [
              {'id': 'filesystem', 'version_id': 'v1'},
            ],
          },
          messages: agentMessagesFromRequest([
            {'role': 'user', 'content': text},
          ]),
          onChunk: (_) {},
          onProcessEvent: events.add,
          cancellation: CancellationController().token,
        );
    if (result.extensionEvidenceMissing) {
      throw StateError(
        'Agent delivery evidence incomplete; hooks=${jsonEncode(events.where((e) => e['tool'] == 'plugin_hook').map((e) => {'type': e['type'], 'event': e['hook_event'], if (e['message'] != null) 'message': e['message'].toString().substring(0, e['message'].toString().length.clamp(0, 300))}).toList())}',
      );
    }
    if (result.activeCapabilities?.any(
          (capability) =>
              capability['id'] == 'filesystem' &&
              capability['component_id'] == 'instructions',
        ) !=
        true) {
      throw StateError(
        'Selected skill did not remain active during mixed execution',
      );
    }
    final artifacts =
        (store.get('task/$tenant/$task')!.value['artifacts'] as List)
            .whereType<Map>();
    for (final expected in {
      'agent.txt': 'agent-mcp-payload',
      'agent-helper.txt': 'agent-shell-verified',
      'plugin-command.txt': 'plugin-command-script-verified',
      if (rootHooks) 'hook-verified.txt': 'hook-shell-verified',
    }.entries) {
      final matches = artifacts
          .where((artifact) => artifact['name'] == expected.key)
          .toList();
      if (matches.length != 1) {
        throw StateError(
          'Agent artifact ${expected.key} count=${matches.length}; '
          'names=${artifacts.map((a) => a['name']).join(',')}; '
          'code_runs=${store.get('task/$tenant/$task')!.value['code_execution_runs']}; '
          'hooks=${jsonEncode(events.where((e) => e['tool'] == 'plugin_hook').map((e) => {'type': e['type'], 'event': e['hook_event'], if (e['message'] != null) 'message': e['message'].toString().substring(0, e['message'].toString().length.clamp(0, 300))}).toList())}',
        );
      }
      final item = matches.single;
      if (utf8.decode(store.getObject(item['object_key'])) != expected.value)
        throw StateError('Agent artifact integrity failed');
    }
    // The same task budget charges one MCP process, one Shell helper, one
    // installed script and (when enabled) the two real command hooks.
    final expectedCodeRuns =
        3 + (rootHooks ? 2 : 0) + (readOnlyDelegate ? 2 : 0);
    if ((store.get('task/$tenant/$task')!.value['code_execution_runs'] !=
            expectedCodeRuns) ||
        (rootHooks &&
            (events
                        .where(
                          (e) =>
                              e['type'] == 'tool_succeeded' &&
                              e['tool'] == 'plugin_hook',
                        )
                        .length !=
                    (readOnlyDelegate ? 4 : 2) ||
                artifacts.length != 4))) {
      throw StateError(
        'Real Agent hook execution, budget or protocol artifact boundary failed; '
        'code_runs=${store.get('task/$tenant/$task')!.value['code_execution_runs']}; '
        'artifacts=${artifacts.map((a) => a['name']).join(',')}; '
        'hooks=${jsonEncode(events.where((e) => e['tool'] == 'plugin_hook').map((e) => {'type': e['type'], 'event': e['hook_event'], if (e['message'] != null) 'message': e['message'].toString().substring(0, e['message'].toString().length.clamp(0, 300))}).toList())}',
      );
    }
    if (readOnlyDelegate &&
        ((store.get('task/$tenant/$task')!.value['completed_plugin_agents']
                            as Map? ??
                        {})
                    .length !=
                1 ||
            utf8.decode(store.getImmutable(package)['SKILL.md']!) !=
                '---\nname: file-workflow\ndescription: Use filesystem MCP and a Shell helper to deliver verified files\n---\nWrite and read the file with the filesystem MCP. Then use execute_shell to read the task input manifest and produce the verified helper file.\n')) {
      throw StateError(
        'Read-only delegated Agent did not complete or changed immutable source',
      );
    }
    if (!events.any(
      (event) =>
          event['type'] == 'tool_succeeded' && event['tool'] == 'execute_shell',
    )) {
      throw StateError('Agent did not execute the Shell helper');
    }
    if (artifacts.any((a) => a['name'] == 'unwanted') ||
        !events.any(
          (event) =>
              event['type'] == 'tool_succeeded' &&
              event['tool'] == 'execute_skill_script',
        ) ||
        result.activeCapabilities?.any((c) => c['component_id'] == 'command') !=
            true) {
      throw StateError(
        'Plugin command/script lifecycle or literal argv failed',
      );
    }
  } finally {
    await server.close(force: true);
    await serving.cancel();
  }
}
