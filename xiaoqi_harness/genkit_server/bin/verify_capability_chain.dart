import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';

import '../lib/src/agent_runtime.dart';
import '../lib/src/image_service.dart';
import '../lib/src/release.dart';
import '../lib/src/store.dart';
import '../lib/src/release_verification.dart';

/// Live release gate: synthetic data in a temporary store, two image requests
/// at most. Emits counters and integrity checks, never credentials or user data.
Future<void> main(List<String> arguments) async {
  final profile = ReleaseVerificationProfile.fromArguments(arguments);
  stdout.writeln(jsonEncode(profile.report(curated: false)));
  final directory = await Directory.systemTemp.createTemp('capability-live-');
  final store = CloudStore(root: directory.path);
  const tenant = 'capability-release-probe';
  final images = ImageService(store);
  if (profile.requiresImageProvider && !images.isConfigured)
    throw StateError(
      'Live verification requires the configured image provider',
    );
  const text = '植物通过光合作用将光能转化为化学能。';
  final skill = utf8.encode(
    '---\nname: science-card\ndescription: 把科学短文整理成有真实原创图片的学习卡片，适合科学教材、课文和知识点整理。\n---\n'
    '先阅读 references/card-rules.md。用户要求学习卡时，必须生成一张真实图片，不能只写设计说明。先声明交付要求，其中包括读取资料一次、generate_image 一次、image/* 产物一个，然后执行。普通问候无需生成学习卡。',
  );
  store.putImmutable('probe/skill', {
    'SKILL.md': skill,
    'references/card-rules.md': utf8.encode(
      '每张学习卡必须包含真实生成的图片，图中文字简短，解释必须符合原文。',
    ),
  });
  store.putImmutable('probe/plugin', {
    'skills/card/SKILL.md': skill,
    'skills/card/references/card-rules.md': utf8.encode('学习卡交付一张真实图片。'),
  });
  store.putImmutable('probe/text', {
    'SKILL.md': utf8.encode(
      '---\nname: text-editor\ndescription: 将文字材料编辑成简洁、清楚的纯文字段落，不生成图片或文件。\n---\n'
      '先用 read_skill_resource 读取 references/card-rules.md，再声明仅包含资料读取的交付计划，artifacts 为空。只返回一段纯文字，不需要图片或文件，不调用 generate_image。',
    ),
    'references/card-rules.md': utf8.encode('只整理已给出的事实，输出一个简洁的纯文字段落。'),
  });
  void install(
    String id,
    String kind,
    String artifact, {
    bool enabled = true,
    bool textOnly = false,
  }) {
    store.put('cap/$tenant/$id', {
      'id': id,
      'kind': kind,
      'name': textOnly ? '纯文字编辑' : '科学学习卡',
      'description': textOnly ? '整理成简洁的纯文字段落，不需要图片或文件' : '把科学短文整理成带真实配图的学习卡',
      'enabled': enabled,
      'origin': 'github',
      'current_version_id': 'v1',
      'versions': [
        {
          'id': 'v1',
          'artifact_key': artifact,
          'components': [
            {
              'id': 'card',
              'root': kind == 'plugin' ? 'skills/card' : '',
              'name': textOnly ? 'text-editor' : 'science-card',
              'description': textOnly ? '编辑纯文字段落' : '把科学教材或短文做成包含真实图片的学习卡',
            },
          ],
        },
      ],
    }, null);
  }

  install('card-skill', 'skill', 'probe/skill');
  install('card-plugin', 'plugin', 'probe/plugin', enabled: false);
  try {
    for (final scenario in profile.capabilityScenarios) {
      final textOnly = scenario == 'text-only-skill';
      final ordinaryAnswer = scenario == 'ordinary-answer';
      final noWorkflow = scenario == 'unrelated' || ordinaryAnswer;
      if (textOnly) {
        for (final id in ['card-skill', 'card-plugin']) {
          final current = store.get('cap/$tenant/$id')!;
          store.put('cap/$tenant/$id', {
            ...current.value,
            'enabled': false,
          }, current.revision);
        }
        install('text-skill', 'skill', 'probe/text', textOnly: true);
      }
      if (scenario == 'explicit-plugin') {
        for (final id in ['card-skill', 'card-plugin']) {
          final current = store.get('cap/$tenant/$id')!;
          store.put('cap/$tenant/$id', {
            ...current.value,
            'enabled': id == 'card-plugin',
          }, current.revision);
        }
      }
      final prompt = textOnly
          ? '请用纯文字编辑技能将这段资料整理成一段简洁的纯文字，不需要图片或文件：$text'
          : ordinaryAnswer
          ? '请将这段资料整理成一段简洁的纯文字，不需要图片或文件：$text'
          : scenario == 'unrelated'
          ? '你好，请用一句话打个招呼。'
          : scenario == 'implicit-skill'
          ? '把这段科学知识做成一张配图学习卡：$text'
          : '请用已选扩展整理这段资料，做成一张学习卡：$text';
      store.put('task/$tenant/$scenario', {
        'artifacts': [],
        'events': [],
      }, null);
      final events = <Map<String, Object?>>[];
      final controller = CancellationController();
      final timer = Timer(const Duration(minutes: 6), controller.cancel);
      try {
        final result = await GenkitXiaoqiAgentRuntime(store, images)
            .runAgentTurn(
              tenantId: tenant,
              taskId: scenario,
              request: {
                'model_id': 'deepseek-flash',
                'current_turn_text': prompt,
                'network_mode': 'off',
                'reasoning_level': 'medium',
                'image_budget':
                    profile.requiresImageProvider && !noWorkflow && !textOnly
                    ? 1
                    : 0,
                'selected_capabilities': textOnly
                    ? [
                        {
                          'id': 'text-skill',
                          'version_id': 'v1',
                          'component_id': 'card',
                        },
                      ]
                    : scenario == 'explicit-plugin'
                    ? [
                        {
                          'id': 'card-plugin',
                          'version_id': 'v1',
                          'component_id': 'card',
                        },
                      ]
                    : [],
              },
              messages: [
                Message(
                  role: Role.user,
                  content: [TextPart(text: prompt)],
                ),
              ],
              onChunk: (_) {},
              onProcessEvent: events.add,
              cancellation: controller.token,
            );
        final artifacts =
            (store.get('task/$tenant/$scenario')!.value['artifacts'] as List)
                .whereType<Map>()
                .toList();
        final successful = events
            .where((event) => event['type'] == 'tool_succeeded')
            .map((event) => event['tool'])
            .toList();
        final expected = noWorkflow || textOnly ? 0 : 1;
        final integrity = artifacts.every((artifact) {
          final bytes = store.getObject(artifact['object_key']);
          return bytes.length == artifact['size'] &&
              sha256.convert(bytes).toString() == artifact['sha256'];
        });
        final passed =
            !result.extensionEvidenceMissing &&
            result.text.isNotEmpty &&
            artifacts.length == expected &&
            integrity &&
            (noWorkflow
                ? result.activeCapabilities?.isEmpty == true
                : result.activeCapabilities?.isNotEmpty == true &&
                      successful.contains('read_skill_resource') &&
                      (textOnly
                          ? !successful.contains('generate_image')
                          : successful.contains('generate_image')));
        stdout.writeln(
          jsonEncode({
            'check': scenario,
            'verified': passed,
            'release': releaseId,
            'contract': apiContractVersion,
            'active_skills': result.activeCapabilities?.length ?? 0,
            'resource_reads': successful
                .where((tool) => tool == 'read_skill_resource')
                .length,
            'image_calls': successful
                .where((tool) => tool == 'generate_image')
                .length,
            'artifacts': artifacts.length,
            'integrity': integrity,
            if (!passed) 'failure': result.text,
            if (!passed)
              'delivery': store
                  .get('task/$tenant/$scenario')!
                  .value['delivery_evidence'],
            if (!passed)
              'failed_tools': events
                  .where((event) => event['type'] == 'tool_failed')
                  .map(
                    (event) => {
                      'tool': event['tool'],
                      'message': event['message'],
                    },
                  )
                  .toList(),
          }),
        );
        if (!passed)
          throw StateError('Capability live verification failed: $scenario');
      } finally {
        timer.cancel();
        controller.cancel();
      }
    }
  } finally {
    store.close();
    await directory.delete(recursive: true);
  }
}
