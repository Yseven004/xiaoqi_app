import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agents.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'mcp_runtime_fixture.dart' show FixtureMcpConnections;

Future<void> main(List<String> args) async {
  final root = await Directory.systemTemp.createTemp('plugin-agent-runtime-');
  final store = CloudStore(root: root.path);
  final scenario = args.single;
  final scriptNetwork = scenario.endsWith('script-network');
  final preloadSkill =
      scenario == 'preload' || scenario == 'preload-script-network';
  final scriptCounter = File('${root.path}/script-count');
  DockerCodeExecutionService? codeExecutor;
  if (scriptNetwork) {
    final worker = File('${root.path}/network_worker.py');
    worker.writeAsStringSync('''
import json,pathlib,sys
r=json.loads(sys.stdin.readline())
if r.get('action') == 'network_token':
 print(json.dumps({'ok':True,'network_token':'123456789.${'a' * 64}'}))
elif r.get('action'):
 print(json.dumps({'ok':True}))
else:
 assert r['authorized_domains'] == ['example.com']
 assert r['script_path'] == 'scripts/check.py'
 assert r['arguments'] == ['literal; \$(not-a-host-command)']
 counter=pathlib.Path(${jsonEncode(scriptCounter.path)})
 counter.write_text(str(int(counter.read_text())+1 if counter.exists() else 1))
 print(json.dumps({'type':'result','ok':True,'stdout':'verified agent network script','artifacts':[],'cleanup_pending':False}))
''');
    codeExecutor = DockerCodeExecutionService(
      store,
      workerPath: worker.path,
      pythonExecutable:
          Platform.environment['XIAOQI_TEST_PYTHON'] ??
          (Platform.isWindows ? 'python' : 'python3'),
    );
  }
  final toolHeader = scriptNetwork
      ? 'tools: [Read, Bash]\n'
      : 'tools: [Read, Write, Agent]\n';
  final mcp = const {
    'approval',
    'ignored-plugin-fields-approval',
    'denied',
    'dontask',
    'disabled',
    'readonly',
  }.contains(scenario);
  final rpc = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var calls = 0;
  final serving = rpc.listen((request) async {
    if (request.method != 'POST') {
      request.response.statusCode = 405;
      await request.response.close();
      return;
    }
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    if (body['id'] == null) {
      request.response.statusCode = 202;
      await request.response.close();
      return;
    }
    final Object? value;
    switch (body['method']) {
      case 'initialize':
        value = {
          'protocolVersion': '2025-11-25',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fixture', 'version': '1'},
        };
      case 'tools/list':
        value = {
          'tools': [
            {
              'name': 'make_card',
              'description': 'Execute approved fixture effect',
              'inputSchema': {
                'type': 'object',
                'properties': {},
                'additionalProperties': false,
              },
            },
          ],
        };
      case 'tools/call':
        calls++;
        value = {
          'content': [
            {'type': 'text', 'text': 'verified external child effect'},
          ],
        };
      case 'ping':
        value = {};
      default:
        value = null;
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': body['id'],
        if (value != null)
          'result': value
        else
          'error': {'code': -32601, 'message': 'Method not found'},
      }),
    );
    await request.response.close();
  });
  final files = <String, List<int>>{
    '.claude-plugin/plugin.json': utf8.encode('{"name":"agent-fixture"}'),
    'agents/writer.md': utf8.encode(
      '---\nname: writer\ndescription: Write task notes\n${mcp ? '' : toolHeader}${preloadSkill ? 'skills: [note]\n' : ''}${scenario == 'plan' || scenario == 'readonly'
          ? 'permissionMode: plan\n'
          : scenario == 'dontask'
          ? 'permissionMode: dontAsk\n'
          : ''}${scenario.startsWith('ignored-plugin-fields') ? 'mcpServers: [not-a-root-server]\nhooks: {PreToolUse: [{command: never-execute-this-field}]}\n' : ''}---\nAGENT_RUNTIME_WRITER: Write report.txt containing verified child output.',
    ),
    'agents/helper.md': utf8.encode(
      '---\nname: helper\ndescription: Write delegated notes\ntools: [Read, Write]\n---\nAGENT_RUNTIME_HELPER: Write report.txt containing verified child output.',
    ),
    if (scriptNetwork)
      'scripts/check.py': utf8.encode('print("source-bound agent script")'),
    if (preloadSkill)
      'skills/note/SKILL.md': utf8.encode(
        '---\nname: note\ndescription: Agent note conventions\n---\nFULL_PRELOADED_SKILL: Read references/note.md before writing the report.',
      ),
    if (preloadSkill)
      'skills/note/references/note.md': utf8.encode(
        'PRELOADED_RESOURCE: verified child output',
      ),
    if (preloadSkill && scriptNetwork)
      'skills/note/scripts/check.py': utf8.encode(
        'print("source-bound preloaded script")',
      ),
  };
  final components = <Map<String, dynamic>>[
    ...PluginAgentDefinition.inspect(files, '', {}),
    if (preloadSkill)
      {
        'id': 'note',
        'type': 'skill',
        'root': 'skills/note',
        'name': 'note',
        'description': 'Agent note conventions',
        'status': 'supported',
      },
  ];
  store.putImmutable('packages/agents', files);
  store.put('cap/personal/agents', {
    'id': 'agents',
    'kind': 'plugin',
    'name': 'agent-fixture',
    'origin': 'upload',
    'enabled': true,
    'current_version_id': 'v1',
    'versions': [
      {
        'id': 'v1',
        'artifact_key': 'packages/agents',
        'components': components,
        'plugin_agent_profile': 1,
        'plugin_command_profile': 1,
      },
    ],
  }, null);
  store.put('task/personal/turn', {'artifacts': []}, null);
  if (mcp)
    store.put('mcp/personal/library', {
      'id': 'library',
      'name': 'Library',
      'status': 'ready',
      'url': 'https://example.com/mcp',
      'catalog_id': 'fixture',
    }, null);
  final selected = components.singleWhere((entry) => entry['name'] == 'writer');
  final events = <Map<String, Object?>>[];
  try {
    GenkitXiaoqiAgentRuntime runtime() => GenkitXiaoqiAgentRuntime(
      store,
      ImageService(store, apiKey: 'fixture-unused'),
      codeExecutor: codeExecutor,
      mcpConnections: mcp ? FixtureMcpConnections(store, rpc.port) : null,
    );
    final request = <String, dynamic>{
      'model_id': 'mimo-v2.6-flash',
      'current_turn_text': '请使用 writer Agent 完成任务笔记',
      'network_mode': 'off',
      'selected_capabilities': [
        {'id': 'agents', 'version_id': 'v1', 'component_id': selected['id']},
      ],
      if (mcp)
        'selected_mcp_connections': [
          {'id': 'library'},
        ],
    };
    var result = await runtime().runAgentTurn(
      tenantId: 'personal',
      taskId: 'turn',
      request: {
        ...request,
        'model_id': 'mimo-v2.6-flash',
        'current_turn_text': '请使用 writer Agent 完成任务笔记',
        'network_mode': 'off',
        'selected_capabilities': [
          {'id': 'agents', 'version_id': 'v1', 'component_id': selected['id']},
        ],
        'messages': [
          {'role': 'user', 'content': '请使用 writer Agent 完成任务笔记'},
        ],
      },
      messages: [
        Message(
          role: Role.user,
          content: [TextPart(text: '请使用 writer Agent 完成任务笔记')],
        ),
      ],
      onChunk: (_) {},
      onProcessEvent: events.add,
      cancellation: CancellationController().token,
    );
    final beforeApproval =
        calls +
        (scriptCounter.existsSync()
            ? int.parse(scriptCounter.readAsStringSync())
            : 0);
    if (scriptNetwork ||
        (mcp && !const {'dontask', 'readonly'}.contains(scenario))) {
      final pending = result.messages
          .expand((m) => m.content)
          .where((p) => p.isToolRequest)
          .where(
            (p) =>
                p.metadata?['interrupt'] is Map &&
                p.metadata?['pendingOutput'] == null,
          )
          .map(
            (p) => ToolRequestPart(
              toolRequest: p.toolRequest!,
              metadata: p.metadata,
            ),
          )
          .single;
      final permission = pending.metadata!['interrupt'] as Map;
      if (scenario == 'disabled') {
        final source = store.get('cap/personal/agents')!;
        store.put('cap/personal/agents', {
          ...source.value,
          'enabled': false,
        }, source.revision);
      }
      result = await runtime().runAgentTurn(
        tenantId: 'personal',
        taskId: 'turn',
        request: request,
        messages: result.messages,
        restart: [
          pending.restart({
            'approved': scenario != 'denied',
            'approval_hash': permission['approval_hash'],
            if (permission['domains'] != null) 'domains': permission['domains'],
          }),
        ],
        onChunk: (_) {},
        onProcessEvent: events.add,
        cancellation: CancellationController().token,
      );
    }
    final task = store.get('task/personal/turn')!.value;
    final artifacts = (task['artifacts'] as List).whereType<Map>();
    stdout.writeln(
      'RESULT:${jsonEncode({
        'missing': result.extensionEvidenceMissing,
        'text': result.text,
        'contents': [for (final artifact in artifacts) utf8.decode(store.getObject(artifact['object_key'].toString()))],
        'loaded': (task['loaded_plugin_agents'] as Map? ?? {}).length,
        'completed': (task['completed_plugin_agents'] as Map? ?? {}).length,
        'provider_calls': task['model_request_runs'],
        'external_calls': calls,
        'before_approval': beforeApproval,
        'script_runs': scriptCounter.existsSync() ? int.parse(scriptCounter.readAsStringSync()) : 0,
        'network_grants': task['authorized_network_domains'],
        'events': events,
      })}',
    );
  } finally {
    await serving.cancel();
    await rpc.close(force: true);
    store.close();
    await root.delete(recursive: true);
  }
}
