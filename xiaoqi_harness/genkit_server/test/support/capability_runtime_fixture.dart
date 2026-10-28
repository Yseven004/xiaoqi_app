import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit/experimental.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class FixtureImages extends ImageService {
  FixtureImages(super.store) : super(apiKey: 'local-fixture');
  final generated = <String>{};
  @override
  Future<Map<String, dynamic>> generate({
    required String taskId,
    required String prompt,
    String? imageUrl,
    int count = 1,
    String? size,
    String? tenantId,
    String? idempotencyKey,
    ArtifactRecorder? recordArtifact,
  }) async {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jGJ0AAAAASUVORK5CYII=',
    );
    final id = sha256.convert(utf8.encode(prompt)).toString().substring(0, 16);
    final key = 'tenants/personal/tasks/$taskId/artifacts/$id';
    store.putTaskBlob(key, bytes);
    final taskKey = 'task/personal/$taskId';
    final current = store.get(taskKey)!;
    final artifacts = (current.value['artifacts'] as List).cast<Map>();
    if (generated.add(prompt)) {
      store.put(taskKey, {
        ...current.value,
        'artifacts': [
          ...artifacts,
          {
            'id': id,
            'name': 'page-$id.png',
            'media_type': 'image/png',
            'size': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
            'object_key': key,
          },
        ],
      }, current.revision);
    }
    return {
      'ok': true,
      'artifacts': [
        {'id': id, 'media_type': 'image/png'},
      ],
    };
  }
}

Future<void> main(List<String> args) async {
  final directory = await Directory.systemTemp.createTemp(
    'capability-runtime-',
  );
  final store = CloudStore(root: directory.path);
  final images = FixtureImages(store);
  final scenario = args.single;
  final scopeScenario = scenario.startsWith('scope-');
  final commandScenario =
      scenario.startsWith('text-only-plugin-command') ||
      scenario.startsWith('text-only-network-command');
  final userOnlyCommand = scenario == 'text-only-plugin-command-user-only';
  final textOnly = scenario.startsWith('text-only');
  final taskText = scenario.startsWith('text-only-plugin-command-direct')
      ? '/example:greet "hello world" A'
      : scenario == 'text-only-search'
      ? '请用技能检索三个不同来源并用纯文字说明。'
      : scenario == 'text-only-shell'
      ? '请用 Shell 处理任务资料并返回纯文字，不需要图片或文件。'
      : textOnly
      ? '请用纯文字整理这段材料，不需要图片或文件。'
      : '请整理成两页视觉学习笔记';
  DockerCodeExecutionService? codeExecutor;
  final networkScenario = scenario.startsWith('text-only-network-');
  final networkCounter = File('${directory.path}/network-executions');
  if (const {
    'scope-withdraw-code',
    'scope-reprepare-code',
  }.contains(scenario)) {
    final worker = File('${directory.path}/ordinary_worker.py');
    worker.writeAsStringSync(r'''
import json,sys
r=json.loads(sys.stdin.readline())
assert r['language'] == 'python'
assert r['authorized_domains'] == []
assert r['skill_files'] == {}
print(json.dumps({'type':'result','ok':True,'stdout':'ordinary-code-4','artifacts':[],'cleanup_pending':False}))
''');
    codeExecutor = DockerCodeExecutionService(
      store,
      workerPath: worker.path,
      pythonExecutable:
          Platform.environment['XIAOQI_TEST_PYTHON'] ??
          (Platform.isWindows ? 'python' : 'python3'),
    );
  }
  if (networkScenario) {
    final worker = File('${directory.path}/network_worker.py');
    worker.writeAsStringSync('''
import json,pathlib,sys
r=json.loads(sys.stdin.readline())
if r.get('action') == 'network_token':
 print(json.dumps({'ok':True,'network_token':'123456789.${'a' * 64}'}))
elif r.get('action'):
 print(json.dumps({'ok':True}))
else:
 assert r['authorized_domains'] == ['example.com']
 if '$scenario'.startswith('text-only-network-command'):
  assert r['script_path'] == 'scripts/check.py'
  assert r['arguments'] == ['literal; \$(not-a-host-command)']
 counter=pathlib.Path(${jsonEncode(networkCounter.path)})
 counter.write_text(str(int(counter.read_text())+1 if counter.exists() else 1))
 print(json.dumps({'type':'result','ok':True,'stdout':'network-routing-verified','artifacts':[],'cleanup_pending':False}))
''');
    codeExecutor = DockerCodeExecutionService(
      store,
      workerPath: worker.path,
      pythonExecutable:
          Platform.environment['XIAOQI_TEST_PYTHON'] ??
          (Platform.isWindows ? 'python' : 'python3'),
    );
  }
  if (scenario == 'text-only-workspace-retry') {
    final worker = File('${directory.path}/retry_worker.py');
    worker.writeAsStringSync('''
import json, pathlib, sys
json.loads(sys.stdin.readline())
counter = pathlib.Path(__file__).with_suffix('.count')
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
print(json.dumps({'type':'result', 'ok':attempt >= 3, 'stdout':'recovered' if attempt >= 3 else 'progress\\n' * 1000, 'stderr':'' if attempt >= 3 else 'FileNotFoundError: terminal-workspace-cause', 'artifacts':[], 'cleanup_pending':False}), flush=True)
''');
    codeExecutor = DockerCodeExecutionService(
      store,
      workerPath: worker.path,
      pythonExecutable:
          Platform.environment['XIAOQI_TEST_PYTHON'] ??
          (Platform.isWindows ? 'python' : 'python3'),
    );
  }
  if (scenario == 'text-only-shell') {
    final worker = File('${directory.path}/shell_worker.py');
    worker.writeAsStringSync(r'''
import json, sys
request = json.loads(sys.stdin.readline())
assert request['language'] == 'shell'
assert request['arguments'] == ['literal; $(not-a-host-command)', '']
assert request['authorized_domains'] == []
print(json.dumps({'type':'result','ok':True,'stdout':'shell-routing-verified','stderr':'','artifacts':[],'cleanup_pending':False}), flush=True)
''');
    codeExecutor = DockerCodeExecutionService(
      store,
      workerPath: worker.path,
      pythonExecutable:
          Platform.environment['XIAOQI_TEST_PYTHON'] ??
          (Platform.isWindows ? 'python' : 'python3'),
    );
  }
  store.putImmutable('packages/notes', {
    'SKILL.md': utf8.encode(
      textOnly
          ? '---\nname: text-editor\ndescription: Edit text into a concise paragraph.\n---\nTEXT_ONLY: Read references/rules.md and return text. No images or files are needed.'
          : '---\nname: notes\ndescription: Produce illustrated study notes with two real images.\n---\nREQUIRED_GRAPHIC: Produce two images with generate_image. Declare the delivery plan and verify both files. Read references/rules.md.',
    ),
    'references/rules.md': utf8.encode(
      textOnly
          ? 'Return one plain text paragraph.'
          : 'Each page needs its own real image.',
    ),
    if (scenario == 'script-available' || networkScenario)
      'scripts/check.py': utf8.encode('print("checked")'),
  });
  store.put('cap/personal/notes', {
    'id': 'notes',
    'kind': 'skill',
    'name': 'Notes',
    'description': textOnly
        ? 'Edit a concise plain text paragraph.'
        : 'Produce illustrated study notes with two real images.',
    'enabled': true,
    'current_version_id': 'v1',
    'versions': [
      {'id': 'v1', 'artifact_key': 'packages/notes'},
    ],
  }, null);
  store.put('task/personal/turn', {'artifacts': []}, null);
  if (commandScenario) {
    store.putImmutable('packages/commands', {
      '.claude-plugin/plugin.json': utf8.encode('{"name":"example"}'),
      'commands/greet.md': utf8.encode(
        '---\ndescription: Read a greeting reference\n${userOnlyCommand ? 'disable-model-invocation: true\n' : ''}---\nPLUGIN_COMMAND_BODY: Read references/greeting.md. First=\$0 second=\$1 all=\$ARGUMENTS',
      ),
      'references/greeting.md': utf8.encode(
        'PLUGIN_COMMAND_REFERENCE: Return a concise plain text greeting.',
      ),
      'scripts/check.py': utf8.encode('print("command checked")'),
    });
    store.put('cap/personal/commands', {
      'id': 'commands',
      'kind': 'plugin',
      'name': scenario == 'text-only-plugin-command-direct-renamed-changed'
          ? 'Renamed display label'
          : 'example',
      'origin': 'upload',
      'enabled': true,
      'current_version_id': 'v1',
      'versions': [
        {
          'id': 'v1',
          'artifact_key': 'packages/commands',
          'components': [
            {
              'id': 'greet',
              'type': 'command',
              'root': '',
              'source_path': 'commands/greet.md',
              'name': 'greet',
              'description': 'Read a greeting reference',
              'status': 'supported',
              'has_scripts': true,
              'user_only': userOnlyCommand,
            },
          ],
        },
      ],
    }, null);
  }
  if (scenario == 'explicit-partial' || scopeScenario) {
    store.put('cap/personal/unavailable', {
      'id': 'unavailable',
      'name': 'Unavailable plugin',
      'kind': 'plugin',
      'enabled': true,
      'current_version_id': 'v1',
      'versions': [
        {'id': 'v1', 'artifact_key': 'private-package-diagnostic'},
      ],
    }, null);
  }
  if (scopeScenario) {
    final task = store.get('task/personal/turn')!;
    store.put('task/personal/turn', {
      ...task.value,
      'steering_instructions': [
        {
          'message_id': 'correction-1',
          'sequence': 1,
          'status': 'received',
          'content': scenario == 'scope-keep-unavailable'
              ? '继续用所选技能和不可用插件完成原来的两页图片任务'
              : scenario == 'scope-withdraw-code'
              ? '撤回扩展任务，不使用任何扩展，只执行普通代码 print(2+2) 并纯文字报告结果'
              : '不用任何扩展了，撤回原任务，只用纯文字回答这段话',
        },
      ],
    }, task.revision);
  }
  final events = <Map<String, Object?>>[];
  final legacyText = <String>[];
  void event(Map<String, Object?> value) {
    events.add(value);
    if (const {
          'scope-withdraw-followup',
          'scope-reprepare-code',
        }.contains(scenario) &&
        value['type'] == 'steering_applied' &&
        value['sequence'] == 1) {
      final task = store.get('task/personal/turn')!;
      store.put('task/personal/turn', {
        ...task.value,
        'steering_instructions': [
          ...task.value['steering_instructions'] as List,
          {
            'message_id': 'correction-2',
            'sequence': 2,
            'status': 'received',
            'content': scenario == 'scope-reprepare-code'
                ? '撤回扩展，只执行普通代码 print(2+2) 并报告结果，标记 LATE_ORDINARY_CODE'
                : '再简短一点',
          },
        ],
      }, task.revision);
    }
  }

  final telemetry =
      (Platform.environment['GENKIT_TELEMETRY_SERVER'] ?? '').isEmpty
      ? null
      : Genkit(promptDir: null, isDevEnv: true);
  try {
    final runtime = GenkitXiaoqiAgentRuntime(
      store,
      images,
      codeExecutor: codeExecutor,
    );
    final request = <String, dynamic>{
      'model_id': 'mimo-v2.6-flash',
      'current_turn_text': taskText,
      'network_mode': scenario == 'text-only-network-on' ? 'on' : 'off',
      'selected_capabilities': userOnlyCommand
          ? []
          : commandScenario
          ? [
              {'id': 'commands', 'version_id': 'v1', 'component_id': 'greet'},
            ]
          : scenario == 'implicit'
          ? []
          : [
              {'id': 'notes', 'version_id': 'v1'},
              if (scenario == 'explicit-partial' || scopeScenario)
                {'id': 'unavailable', 'version_id': 'v1'},
            ],
      'messages': [
        {'role': 'user', 'content': taskText},
      ],
      if (scenario == 'text-only-network-file-changed')
        'materials': [
          {'id': 'source', 'name': 'source.txt', 'text': 'first version'},
        ],
    };
    if (scenario == 'text-only-network-legacy') {
      request.remove('current_turn_text');
      NetworkPermissionRequired? permission;
      try {
        await runtime.run(
          tenantId: 'personal',
          taskId: 'turn',
          request: request,
          onDelta: (_) {},
          cancellation: CancellationController().token,
        );
      } on NetworkPermissionRequired catch (required) {
        permission = required;
      }
      if (permission == null || networkCounter.existsSync())
        throw StateError('Expected unexecuted legacy approval');
      final current = store.get('task/personal/turn')!;
      store.put('task/personal/turn', {
        ...current.value,
        'tool_authorizations': {permission.approvalHash: true},
      }, current.revision);
      final text =
          await GenkitXiaoqiAgentRuntime(
            store,
            images,
            codeExecutor: codeExecutor,
          ).run(
            tenantId: 'personal',
            taskId: 'turn',
            request: request,
            onDelta: (_) {},
            cancellation: CancellationController().token,
          );
      stdout.writeln(
        'RESULT:${jsonEncode({'text': text, 'network_before_approval': 0, 'network_runs': int.parse(networkCounter.readAsStringSync()), 'network_grants': store.get('task/personal/turn')!.value['authorized_network_domains']})}',
      );
      return;
    }
    final first = await runtime.runAgentTurn(
      tenantId: 'personal',
      taskId: 'turn',
      request: request,
      messages: agentMessagesFromRequest([
        {'role': 'user', 'content': taskText},
      ]),
      onChunk: (_) {},
      onProcessEvent: event,
      onLegacyDelta: legacyText.add,
      cancellation: CancellationController().token,
    );
    var result = first;
    var beforeApproval = 0;
    if (networkScenario) {
      beforeApproval = networkCounter.existsSync()
          ? int.parse(networkCounter.readAsStringSync())
          : 0;
      final part = first.messages
          .expand((message) => message.content)
          .lastWhere(
            (part) => part.isToolRequest && part.metadata?['interrupt'] is Map,
          );
      final pending = ToolRequestPart(
        toolRequest: part.toolRequest!,
        metadata: part.metadata,
      );
      final permission = part.metadata!['interrupt'] as Map;
      if (scenario == 'text-only-network-command-renamed') {
        final plugin = store.get('cap/personal/commands')!;
        store.put('cap/personal/commands', {
          ...plugin.value,
          'name': 'Renamed while awaiting approval',
          'description': 'Updated display description',
        }, plugin.revision);
      }
      final restart = pending.restart({
        'approved': scenario != 'text-only-network-denied',
        'domains': permission['domains'],
        'approval_hash': permission['approval_hash'],
      });
      if (scenario == 'text-only-network-file-changed') {
        request['materials'] = [
          {
            'id': 'source',
            'name': 'source.txt',
            'text': 'changed after approval',
          },
        ];
      }
      result = await runtime.runAgentTurn(
        tenantId: 'personal',
        taskId: 'turn',
        request: request,
        messages: first.messages,
        restart: [restart],
        onChunk: (_) {},
        onProcessEvent: event,
        onLegacyDelta: legacyText.add,
        cancellation: CancellationController().token,
      );
    }
    stdout.writeln(
      'RESULT:${jsonEncode({'text': result.text, 'missing': result.extensionEvidenceMissing, 'active': result.activeCapabilities, 'generated': images.generated.length, 'events': events, 'legacy_text': legacyText.join(), 'code_runs': store.get('task/personal/turn')!.value['code_execution_runs'] ?? 0, 'operation_count': (store.get('task/personal/turn')!.value['scope_operations'] as Map? ?? const {}).length, 'artifacts': (store.get('task/personal/turn')!.value['artifacts'] as List).length, if (networkScenario) 'network_before_approval': beforeApproval, if (networkScenario) 'network_runs': networkCounter.existsSync() ? int.parse(networkCounter.readAsStringSync()) : 0, if (networkScenario) 'network_grants': store.get('task/personal/turn')!.value['authorized_network_domains'], if (networkScenario) 'network_interrupted': result.finishReason == AgentFinishReason.interrupted})}',
    );
  } finally {
    stdout.writeln(
      'MODEL_REQUESTS:${store.get('task/personal/turn')!.value['model_request_runs'] ?? 0}',
    );
    await telemetry?.shutdown();
    store.close();
    await directory.delete(recursive: true);
  }
}
