import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

/// Deterministic local model responses drive the production Agent/tool code.
/// The MCP process and Shell helper still execute in real isolated containers.
Future<void> verifyStdioAgent(
  CloudStore store,
  DockerCodeExecutionService executor,
  String tenant,
  Map<String, List<int>> installedFiles,
) async {
  const task = 'agent-mcp-shell';
  const text = '使用文件插件写入文件，再运行 Shell 核对并生成结果文件。';
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
      if (preparing) {
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
            'steps': ['写入文件', '核对文件', '执行 Shell 接力'],
            'skill_ids': [skill],
            'tools': [
              {'name': write, 'count': 1},
              {'name': read, 'count': 1},
              {'name': 'execute_shell', 'count': 1},
            ],
            'artifacts': [
              {'media_type': 'text/plain', 'count': 2},
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
            'code': r'''set -eu
python3 - <<'PY'
import json, pathlib
manifest = json.loads(pathlib.Path('/workspace/input_manifest.json').read_text())
item = next(item for item in manifest['inputs'] if item['name'] == 'agent.txt')
assert pathlib.Path(item['path']).read_text() == 'agent-mcp-payload'
PY
printf '%s' "$1" > /workspace/output/agent-helper.txt
''',
            'arguments': ['agent-shell-verified'],
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
  store.putImmutable('verification/stdio-plugin', {
    ...installedFiles,
    'SKILL.md': utf8.encode(
      '---\nname: file-workflow\ndescription: Use filesystem MCP and a Shell helper to deliver verified files\n---\nWrite and read the file with the filesystem MCP. Then use execute_shell to read the task input manifest and produce the verified helper file.\n',
    ),
    '.mcp.json': utf8.encode(
      jsonEncode({
        'mcpServers': {
          'filesystem': {
            'command': 'npx',
            'args': [
              '@modelcontextprotocol/server-filesystem@2.0.1',
              '/workspace/output',
            ],
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
        'artifact_key': 'verification/stdio-plugin',
        'components': [
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
    if (result.extensionEvidenceMissing)
      throw StateError('Agent delivery evidence incomplete');
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
    }.entries) {
      final item = artifacts
          .where((artifact) => artifact['name'] == expected.key)
          .single;
      if (utf8.decode(store.getObject(item['object_key'])) != expected.value)
        throw StateError('Agent artifact integrity failed');
    }
    if (!events.any(
      (event) =>
          event['type'] == 'tool_succeeded' && event['tool'] == 'execute_shell',
    )) {
      throw StateError('Agent did not execute the Shell helper');
    }
  } finally {
    await server.close(force: true);
    await serving.cancel();
  }
}
