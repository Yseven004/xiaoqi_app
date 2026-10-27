import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
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
  final textOnly = scenario.startsWith('text-only');
  final taskText = scenario == 'text-only-search'
      ? '请用技能检索三个不同来源并用纯文字说明。'
      : scenario == 'text-only-shell'
      ? '请用 Shell 处理任务资料并返回纯文字，不需要图片或文件。'
      : textOnly
      ? '请用纯文字整理这段材料，不需要图片或文件。'
      : '请整理成两页视觉学习笔记';
  DockerCodeExecutionService? codeExecutor;
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
    if (scenario == 'script-available')
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
  if (scenario == 'explicit-partial') {
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
  final events = <Map<String, Object?>>[];
  final telemetry =
      (Platform.environment['GENKIT_TELEMETRY_SERVER'] ?? '').isEmpty
      ? null
      : Genkit(promptDir: null, isDevEnv: true);
  try {
    final result =
        await GenkitXiaoqiAgentRuntime(
          store,
          images,
          codeExecutor: codeExecutor,
        ).runAgentTurn(
          tenantId: 'personal',
          taskId: 'turn',
          request: {
            'model_id': 'mimo-v2.6-flash',
            'current_turn_text': taskText,
            'selected_capabilities': scenario == 'implicit'
                ? []
                : [
                    {'id': 'notes', 'version_id': 'v1'},
                    if (scenario == 'explicit-partial')
                      {'id': 'unavailable', 'version_id': 'v1'},
                  ],
          },
          messages: agentMessagesFromRequest([
            {'role': 'user', 'content': taskText},
          ]),
          onChunk: (_) {},
          onProcessEvent: events.add,
          cancellation: CancellationController().token,
        );
    stdout.writeln(
      'RESULT:${jsonEncode({'text': result.text, 'missing': result.extensionEvidenceMissing, 'active': result.activeCapabilities, 'generated': images.generated.length, 'events': events, 'operation_count': (store.get('task/personal/turn')!.value['scope_operations'] as Map? ?? const {}).length, 'artifacts': (store.get('task/personal/turn')!.value['artifacts'] as List).length})}',
    );
  } finally {
    await telemetry?.shutdown();
    store.close();
    await directory.delete(recursive: true);
  }
}
