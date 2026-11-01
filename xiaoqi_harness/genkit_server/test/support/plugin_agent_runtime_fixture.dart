import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agents.dart';
import 'package:xiaoqi_genkit_server/src/plugin_commands.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'mcp_runtime_fixture.dart' show FixtureMcpConnections;

Future<void> main(List<String> args) async {
  final root = await Directory.systemTemp.createTemp('plugin-agent-runtime-');
  final store = CloudStore(root: root.path);
  final scenario = args.single;
  final fork = scenario.startsWith('fork-');
  final rootHooks = scenario.startsWith('root-hook-');
  final rootLifecycle = scenario.startsWith('root-life-');
  final skillHooks = scenario.startsWith('skill-hook-');
  final hookCounter = File('${root.path}/hook-count.json');
  final scriptNetwork = scenario.endsWith('script-network');
  final preloadSkill =
      scenario == 'preload' ||
      scenario == 'preload-script-network' ||
      skillHooks;
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
  if (rootHooks || skillHooks || rootLifecycle) {
    final worker = File('${root.path}/hook_worker.py');
    worker.writeAsStringSync('''
import json,pathlib,sys,traceback
def report_error(kind,error,tb):
 pathlib.Path(${jsonEncode('${root.path}/hook-worker-error.log')}).write_text(''.join(traceback.format_exception(kind,error,tb))+'\\nINPUT='+json.dumps(globals().get('i')),encoding='utf-8')
 sys.__excepthook__(kind,error,tb)
sys.excepthook=report_error
r=json.loads(sys.stdin.buffer.readline().decode('utf-8'))
if r.get('action'):
 assert r['action'] != 'network_token'
 print(json.dumps({'ok':True,'acknowledged':True}))
else:
 assert r['authorized_domains'] == [] and r['language'] == 'javascript'
 assert r['execution_profile'] == ('plugin_hook_read_only' if ${jsonEncode(scenario)} == 'root-hook-readonly' else 'plugin_hook')
 if ${skillHooks ? 'True' : 'False'}:
  assert 'skills/note/SKILL.md' in r['skill_files'] and '.claude-plugin/plugin.json' in r['skill_files']
 else: assert 'hooks/hooks.json' in r['skill_files']
 line=r['code'].splitlines()[0]
 spec=json.loads(json.loads(line.split('JSON.parse(',1)[1].rsplit(');',1)[0]))
 if ${skillHooks ? 'True' : 'False'}: assert spec['skillDirectory']=='/workspace/skill/skills/note'
 i=spec['input']; event=i['hook_event_name']
 assert i['cwd']=='/workspace/work'
 if not ${rootLifecycle ? 'True' : 'False'}: assert i['tool_use_id']
 counter=pathlib.Path(${jsonEncode(hookCounter.path)})
 records=json.loads(counter.read_text()) if counter.exists() else []
 records.append(i); counter.write_text(json.dumps(records))
 if ${rootLifecycle ? 'True' : 'False'}:
  assert event in ('SessionStart','UserPromptSubmit')
  if event=='SessionStart': assert i['source']=='startup'
  else: assert i['prompt']=='请使用 writer Agent 完成任务笔记'
  envelope={'xiaoqi_hook_command_v1':{'matched':True,'timed_out':False,
   'exit_code':2 if ${jsonEncode(scenario)}=='root-life-deny' and event=='UserPromptSubmit' else 0,
   'stdout':'ROOT_STARTUP_CONTEXT' if event=='SessionStart' else 'ROOT_PROMPT_CONTEXT',
   'stderr':'prompt blocked'}}
  print(json.dumps({'type':'result','ok':True,'execution_id':r['execution_id'],'stdout':json.dumps(envelope),'artifacts':[],'cleanup_pending':False}))
  sys.exit(0)
 specific={'hookEventName':event}
 exit_code=0
 if event=='PreToolUse':
  if ${skillHooks ? 'True' : 'False'}:
   assert event=='PreToolUse'
   if ${jsonEncode(scenario)} == 'skill-hook-approval':
    assert i['tool_input']=={'recipient':'original'}
    specific.update({'permissionDecision':'ask','updatedInput':{'recipient':'changed'}})
   elif ${jsonEncode(scenario)} == 'skill-hook-block' and len(records)==1:
    exit_code=2
   else: specific['updatedInput']={'content':'verified rewritten output'}
  elif ${jsonEncode(scenario)} == 'root-hook-readonly':
   assert i['permission_mode']=='plan' and i['tool_name']=='Read'
   assert i['tool_input']=={'file_path':'report.txt'}
  elif ${jsonEncode(scenario)} == 'root-hook-deny': specific['permissionDecision']='deny'
  elif ${jsonEncode(scenario)} == 'root-hook-approval':
   assert i['tool_input']=={'recipient':'original'}
   specific.update({'permissionDecision':'ask','updatedInput':{'recipient':'changed'}})
  else:
   assert i['tool_input']=={'file_path':'report.txt','content':'verified child output'}
   specific['updatedInput']={'content': 7 if ${jsonEncode(scenario)} == 'root-hook-invalid' else 'verified rewritten output'}
 else:
  if ${jsonEncode(scenario)} == 'root-hook-readonly':
   assert i['permission_mode']=='plan' and 'original task note' in str(i['tool_response'])
  specific['additionalContext']='ROOT_HOOK_OBSERVED_RESULT'
 output={'hookSpecificOutput':specific}
 envelope={'xiaoqi_hook_command_v1':{'matched':True,'timed_out':False,'exit_code':exit_code,'stdout':json.dumps(output),'stderr':'guard denied' if exit_code==2 else ''}}
 print(json.dumps({'type':'result','ok':True,'execution_id':r['execution_id'],'stdout':json.dumps(envelope),'artifacts':[],'cleanup_pending':False}))
''');
    codeExecutor = DockerCodeExecutionService(
      store,
      workerPath: worker.path,
      pythonExecutable:
          Platform.environment['XIAOQI_TEST_PYTHON'] ??
          (Platform.isWindows ? 'python' : 'python3'),
    );
  }
  if (scenario.startsWith('fork-dynamic')) {
    final worker = File('${root.path}/context_worker.py');
    worker.writeAsStringSync('''
import json,sys
r=json.loads(sys.stdin.readline())
if r.get('action'):
 print(json.dumps({'ok':True,'acknowledged':True}))
else:
 assert r['execution_profile'] == ${jsonEncode(scenario.endsWith('-plan') ? 'plugin_command_context_read_only' : 'plugin_command_context')}
 assert r['authorized_domains']==[] and r['language']=='javascript'
 line=r['code'].splitlines()[0]
 spec=json.loads(json.loads(line.split('JSON.parse(',1)[1].rsplit(');',1)[0]))
 assert spec['commands']==["printf 'DYNAMIC_%s' CONTEXT_VERIFIED"]
 assert spec['arguments']=='literal; \$(no-shell)'
 output={'xiaoqi_command_context_v1':{'ok':True,'outputs':['DYNAMIC_CONTEXT_VERIFIED']}}
 print(json.dumps({'type':'result','ok':True,'execution_id':r['execution_id'],'stdout':json.dumps(output),'artifacts':[],'cleanup_pending':False}))
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
                'properties': rootHooks || skillHooks
                    ? {
                        'recipient': {'type': 'string'},
                      }
                    : {},
                if (rootHooks || skillHooks) 'required': ['recipient'],
                'additionalProperties': false,
              },
            },
          ],
        };
      case 'tools/call':
        if ((rootHooks || skillHooks) &&
            body['params']['arguments']['recipient'] != 'changed') {
          throw StateError(
            'hook rewritten recipient was not authorized/executed',
          );
        }
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
    if (fork)
      'commands/work.md': utf8.encode(
        '---\ndescription: Execute standalone command task\ncontext: fork\nbackground: false\n'
        '${scenario.endsWith('-plan')
            ? 'agent: Explore\n'
            : scenario == 'fork-custom'
            ? 'agent: writer\n'
            : scenario == 'fork-unknown'
            ? 'agent: missing-agent\n'
            : ''}'
        '---\n${scenario.startsWith('fork-dynamic') ? "!`printf 'DYNAMIC_%s' CONTEXT_VERIFIED`\n" : ''}'
        'FORK_COMMAND_BODY: Write report.txt containing verified child output. Arguments=\$ARGUMENTS',
      ),
    '.claude-plugin/plugin.json': utf8.encode('{"name":"agent-fixture"}'),
    if (rootHooks || rootLifecycle)
      'hooks/hooks.json': utf8.encode(
        jsonEncode({
          'hooks': {
            for (final event
                in (rootLifecycle
                    ? ['SessionStart', 'UserPromptSubmit']
                    : ['PreToolUse', 'PostToolUse', 'PostToolUseFailure']))
              event: [
                {
                  'matcher': rootLifecycle
                      ? null
                      : scenario == 'root-hook-approval'
                      ? r'^mcp__Library__make_card$'
                      : scenario == 'root-hook-readonly'
                      ? r'^Read$'
                      : r'^Write$',
                  'hooks': [
                    {'type': 'command', 'command': 'fixture-hook'},
                  ],
                },
              ],
          },
        }),
      ),
    'agents/writer.md': utf8.encode(
      '---\nname: writer\ndescription: Write task notes\n${scenario.startsWith('model-alias') ? 'model: sonnet\n' : ''}${mcp ? '' : toolHeader}${preloadSkill ? 'skills: [note]\n' : ''}${scenario == 'plan' || scenario == 'readonly' || scenario == 'root-hook-readonly'
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
        '---\nname: note\ndescription: Agent note conventions\n'
        '${skillHooks ? 'hooks: ${jsonEncode({
                'PreToolUse': [
                  {
                    'matcher': scenario == 'skill-hook-approval' ? r'^mcp__Library__make_card$' : '^Write\$',
                    'hooks': [
                      {'type': 'command', 'command': 'fixture-skill-hook', 'once': true},
                    ],
                  },
                ],
              })}\n' : ''}'
        '---\nFULL_PRELOADED_SKILL: Read references/note.md before writing the report.',
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
    if (fork) ...PluginCommand.inspect(files, '', {}),
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
  if (scenario == 'root-hook-readonly') {
    const key = 'tenants/personal/tasks/turn/artifacts/readonly-seed';
    final bytes = utf8.encode('original task note');
    store.putTaskBlob(key, bytes);
    final task = store.get('task/personal/turn')!;
    store.put('task/personal/turn', {
      ...task.value,
      'artifacts': [
        {
          'id': 'readonly-seed',
          'name': 'report.txt',
          'media_type': 'text/plain',
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
          'object_key': key,
        },
      ],
    }, task.revision);
  }
  if (mcp)
    store.put('mcp/personal/library', {
      'id': 'library',
      'name': 'Library',
      'status': 'ready',
      'url': 'https://example.com/mcp',
      'catalog_id': 'fixture',
    }, null);
  final selected = components.singleWhere(
    (entry) => entry['name'] == (fork ? 'work' : 'writer'),
  );
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
        if (fork)
          Message(
            role: Role.user,
            content: [TextPart(text: 'PARENT_ONLY_PRIVATE_HISTORY')],
          ),
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
      if (skillHooks &&
          !result.messages
              .expand((m) => m.content)
              .any(
                (p) =>
                    p.isToolRequest &&
                    p.metadata?['interrupt'] is Map &&
                    p.metadata?['pendingOutput'] == null,
              )) {
        stderr.writeln(
          jsonEncode(
            result.messages
                .expand((m) => m.content)
                .where(
                  (part) =>
                      part.isToolResponse &&
                      part.toolResponse!.name.split('/').last ==
                          'run_plugin_agent',
                )
                .map((part) => part.toJson())
                .toList(),
          ),
        );
      }
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
      if (scenario == 'disabled' || scenario == 'fork-disabled') {
        final source = store.get('cap/personal/agents')!;
        store.put('cap/personal/agents', {
          ...source.value,
          'enabled': false,
        }, source.revision);
      }
      if (scenario == 'fork-source-changed') {
        final source = store.get('cap/personal/agents')!;
        store.putImmutable('packages/agents-changed', {
          ...files,
          'commands/work.md': utf8.encode(
            '---\ncontext: fork\n---\nChanged command',
          ),
        });
        store.put('cap/personal/agents', {
          ...source.value,
          'versions': [
            for (final version in source.value['versions'] as List)
              {...version as Map, 'artifact_key': 'packages/agents-changed'},
          ],
        }, source.revision);
      }
      result = await runtime().runAgentTurn(
        tenantId: 'personal',
        taskId: 'turn',
        request: request,
        messages: result.messages,
        restart: [
          pending.restart({
            'approved':
                scenario != 'denied' &&
                scenario != 'fork-denied' &&
                scenario != 'fork-dynamic-denied',
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
        if (fork) 'command_completed': (task['completed_plugin_commands'] as Map? ?? {}).length,
        'provider_calls': task['model_request_runs'],
        'external_calls': calls,
        'before_approval': beforeApproval,
        'script_runs': scriptCounter.existsSync() ? int.parse(scriptCounter.readAsStringSync()) : 0,
        'code_runs': task['code_execution_runs'],
        'network_grants': task['authorized_network_domains'],
        if (rootHooks || skillHooks || rootLifecycle) 'hook_runs': hookCounter.existsSync() ? jsonDecode(hookCounter.readAsStringSync()) : [],
        'events': events,
      })}',
    );
  } finally {
    final workerError = File('${root.path}/hook-worker-error.log');
    if (workerError.existsSync())
      stderr.writeln(workerError.readAsStringSync());
    await serving.cancel();
    await rpc.close(force: true);
    store.close();
    await root.delete(recursive: true);
  }
}
