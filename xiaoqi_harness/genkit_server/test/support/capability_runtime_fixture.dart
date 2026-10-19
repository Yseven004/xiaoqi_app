import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
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
  final events = <Map<String, Object?>>[];
  try {
    final result = await GenkitXiaoqiAgentRuntime(store, images).runAgentTurn(
      tenantId: 'personal',
      taskId: 'turn',
      request: {
        'model_id': 'mimo-test',
        'current_turn_text': textOnly
            ? '请用纯文字整理这段材料，不需要图片或文件。'
            : '请整理成两页视觉学习笔记',
        'selected_capabilities': scenario == 'implicit'
            ? []
            : [
                {'id': 'notes', 'version_id': 'v1'},
              ],
      },
      messages: agentMessagesFromRequest([
        {
          'role': 'user',
          'content': textOnly ? '请用纯文字整理这段材料，不需要图片或文件。' : '请整理成两页视觉学习笔记',
        },
      ]),
      onChunk: (_) {},
      onProcessEvent: events.add,
      cancellation: CancellationController().token,
    );
    stdout.writeln(
      'RESULT:${jsonEncode({'text': result.text, 'missing': result.extensionEvidenceMissing, 'active': result.activeCapabilities, 'generated': images.generated.length, 'events': events, 'artifacts': (store.get('task/personal/turn')!.value['artifacts'] as List).length})}',
    );
  } finally {
    store.close();
    await directory.delete(recursive: true);
  }
}
