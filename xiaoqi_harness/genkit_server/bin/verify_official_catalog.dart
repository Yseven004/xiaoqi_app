import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';

import '../lib/src/agent_runtime.dart';
import '../lib/src/image_service.dart';
import '../lib/src/official_catalog.dart';
import '../lib/src/skill_market.dart';
import '../lib/src/store.dart';
import '../lib/src/release_verification.dart';

/// Runs real curated packages against synthetic material in an isolated store.
Future<void> main(List<String> arguments) async {
  final profile = ReleaseVerificationProfile.fromArguments(arguments);
  stdout.writeln(jsonEncode(profile.report(curated: true)));
  final root = await Directory.systemTemp.createTemp('curated-release-probe-');
  final store = CloudStore(root: root.path);
  const tenant = 'official-catalog-probe';
  const source =
      '# 主动回忆练习\n\n## 第一章：先尝试提取\n'
      '主动回忆是在不看资料时尝试回答问题，再用原材料核对。'
      '三个步骤：合上资料；用自己的话回答；对照原文记录遗漏。'
      '反模式：尚未尝试就看答案，把熟悉感当成掌握。\n\n'
      '## 第二章：间隔复习\n在不同时间再次提取同一知识，优先处理上一轮遗漏。'
      '原则：先回忆，再核对；保留修正依据；适度重复。';
  try {
    seedOfficialCatalog(store);
    for (final id in profile.curatedPackages) {
      final publicId = SkillMarket.publicationId('_official-curated', id);
      final publication = store.get('skill-market/$publicId')!;
      final installed = SkillMarket(
        store,
      ).install(tenant, publicId, publication.revision);
      final book = id == 'book-to-skill';
      final prompt = book
          ? '用已选 Book to Skill 完整转换所附原创短文，制作私有技能 ZIP：'
                '提取框架、原则、技巧和反模式，包含 SKILL.md 和章节引用资料。'
                '实际运行适配提取脚本、检查上游安全扫描，交付真实文件，不只返回方案。'
                '材料在 /workspace/materials/1-learning-source.md；不发布或安装产物。'
          : '用已选 Study Notes Studio 把所附短文做成一张 3:4 学霸复习笔记图。'
                '概览模式，调用图片生成模型，保留中文手写笔记风格。只生成一张图片。';
      store.put('task/$tenant/$id', {'artifacts': [], 'events': []}, null);
      final controller = CancellationController();
      final timer = Timer(const Duration(minutes: 8), controller.cancel);
      final events = <Map<String, Object?>>[];
      try {
        final result =
            await GenkitXiaoqiAgentRuntime(
              store,
              ImageService(store),
            ).runAgentTurn(
              tenantId: tenant,
              taskId: id,
              request: {
                'model_id': 'deepseek-flash',
                'current_turn_text': prompt,
                'network_mode': 'off',
                'reasoning_level': 'medium',
                'image_budget': book ? 0 : 1,
                'materials': [
                  {
                    'id': 'source',
                    'name': 'learning-source.md',
                    'content': source,
                  },
                ],
                'selected_capabilities': [
                  {
                    'id': installed.value['id'],
                    'version_id': installed.value['current_version_id'],
                  },
                ],
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
            (store.get('task/$tenant/$id')!.value['artifacts'] as List)
                .whereType<Map>()
                .toList();
        final tools = events
            .where((e) => e['type'] == 'tool_succeeded')
            .map((e) => e['tool'])
            .toList();
        final integrity = artifacts.every(
          (a) =>
              sha256.convert(store.getObject(a['object_key'])).toString() ==
              a['sha256'],
        );
        var delivered = false;
        if (book) {
          for (final artifact in artifacts.where(
            (a) => a['name'].toString().endsWith('.zip'),
          )) {
            final files = ZipDecoder().decodeBytes(
              store.getObject(artifact['object_key']),
            );
            delivered |=
                files.any(
                  (f) => f.name == 'SKILL.md' || f.name.endsWith('/SKILL.md'),
                ) &&
                files.any(
                  (f) =>
                      f.name.contains('chapter') ||
                      f.name.contains('reference'),
                );
          }
        } else {
          delivered =
              artifacts
                  .where((a) => a['media_type'].toString().startsWith('image/'))
                  .length ==
              1;
        }
        final passed =
            !result.extensionEvidenceMissing &&
            integrity &&
            delivered &&
            tools.contains('read_skill_resource') &&
            tools.contains('read_task_material') &&
            tools.contains(book ? 'execute_skill_script' : 'generate_image');
        stdout.writeln(
          jsonEncode({
            'check': id,
            'verified': passed,
            'artifacts': artifacts.length,
            'integrity': integrity,
            'tools': tools,
            if (!passed) 'failure': result.text,
            if (!passed)
              'failed_tools': events
                  .where((e) => e['type'] == 'tool_failed')
                  .toList(),
          }),
        );
        if (!passed)
          throw StateError('Curated package live verification failed: $id');
      } finally {
        timer.cancel();
        controller.cancel();
        final current = store.get('cap/$tenant/${installed.value['id']}')!;
        store.put('cap/$tenant/${installed.value['id']}', {
          ...current.value,
          'enabled': false,
        }, current.revision);
      }
    }
  } finally {
    store.close();
    await root.delete(recursive: true);
  }
}
