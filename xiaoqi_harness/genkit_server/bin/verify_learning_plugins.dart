import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:shelf/shelf.dart' show Request;
import '../lib/src/agent_runtime.dart';
import '../lib/src/attachment_service.dart';
import '../lib/src/image_service.dart';
import '../lib/src/learning_notes.dart';
import '../lib/src/official_catalog.dart';
import '../lib/src/skill_market.dart';
import '../lib/src/store.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('native-learning-probe-');
  final store = CloudStore(root: root.path);
  final attachments = AttachmentService(store);
  const tenant = 'native-learning-probe';
  try {
    seedOfficialCatalog(store);
    for (final id in [
      'learning-notes-manager',
      'original-reading-annotations',
    ]) {
      final annotation = id == 'original-reading-annotations';
      Map<String, dynamic>? preparedImage;
      if (annotation) {
        final bytes = File('learning-probe.png').readAsBytesSync();
        final upload = await attachments.upload(
          Request(
            'POST',
            Uri.parse('http://probe/attachments'),
            headers: {
              'content-type': 'image/png',
              'content-length': '${bytes.length}',
              'x-xiaoqi-filename': 'learning-annotation.png',
            },
            body: bytes,
          ),
          tenant,
        );
        preparedImage = Map<String, dynamic>.from(
          jsonDecode(await upload.readAsString()) as Map,
        );
        if (upload.statusCode != 202 || preparedImage['ready'] != true)
          throw StateError('Probe image preparation failed');
      }
      final publicId = SkillMarket.publicationId('_official-curated', id);
      final publication = store.get('skill-market/$publicId')!;
      final installed = SkillMarket(
        store,
      ).install(tenant, publicId, publication.revision);
      final prompt = annotation
          ? '请用已选原文批注笔记处理这张原创学习材料图片。只做一处：在“先回忆”三个字下分别画小三角，边批“先尝试提取知识”。保留原图，实际调用包内扫描和渲染脚本，交付一张 PNG；不要调用生图模型。图片材料在 /workspace/materials/1-learning-annotation.png。'
          : '请解释主动回忆的含义和三个练习步骤。已明确启用学习笔记管家，请把本轮确定的新知识整理为一份原生笔记补充，使用 append_learning_notes；主题不确定时新建。正常回答问题，不要生成文件或声称客户端已经保存。';
      store.put('task/$tenant/$id', {'events': [], 'artifacts': []}, null);
      final cancellation = CancellationController();
      final timer = Timer(const Duration(minutes: 8), cancellation.cancel);
      final events = <Map<String, Object?>>[];
      try {
        final result =
            await GenkitXiaoqiAgentRuntime(
              store,
              ImageService(store),
              attachments: attachments,
            ).runAgentTurn(
              tenantId: tenant,
              taskId: id,
              request: {
                'model_id': 'deepseek-flash',
                'network_mode': 'off',
                'reasoning_level': 'medium',
                'workflow_id': 'probe-chat',
                'user_message_id': 'probe-message',
                'current_turn_text': prompt,
                'learning_note_topics': const [],
                'image_budget': annotation ? 1 : 0,
                'selected_capabilities': [
                  {
                    'id': installed.value['id'],
                    'version_id': installed.value['current_version_id'],
                  },
                ],
                'materials': annotation
                    ? [
                        {
                          'id': 'source',
                          'name': 'learning-annotation.png',
                          'attachment_id': preparedImage!['id'],
                          'kind': 'image',
                        },
                      ]
                    : const [],
              },
              messages: [
                Message(
                  role: Role.user,
                  content: [TextPart(text: prompt)],
                ),
              ],
              onChunk: (_) {},
              onProcessEvent: events.add,
              cancellation: cancellation.token,
            );
        final task = store.get('task/$tenant/$id')!.value;
        final artifacts = (task['artifacts'] as List? ?? const [])
            .whereType<Map>()
            .toList();
        final tools = events
            .where((e) => e['type'] == 'tool_succeeded')
            .map((e) => e['tool'])
            .toList();
        final bool verified;
        var annotationChecks = <String, bool>{};
        if (annotation) {
          final images = artifacts
              .where((a) => a['media_type'] == 'image/png')
              .toList();
          final skillScriptCount = tools
              .where((t) => t == 'execute_skill_script')
              .length;
          final usedImageGeneration = tools.contains('generate_image');
          final nativeAnnotation = task['native_annotation'] == true;
          final ocrArtifacts = artifacts
              .where((a) => a['name'].toString().startsWith('annotation-ocr-'))
              .toList();
          final allOcrArtifactsAreInternal = ocrArtifacts.every(
            (a) => a['internal'] == true,
          );
          final checks = <String, bool>{
            'exactly_one_png': images.length == 1,
            'at_least_two_skill_script_calls': skillScriptCount >= 2,
            'no_image_generation': !usedImageGeneration,
            'native_annotation_enabled': nativeAnnotation,
            'ocr_evidence_internal': allOcrArtifactsAreInternal,
          };
          annotationChecks = checks;
          verified = checks.values.every((passed) => passed);
          stdout.writeln(
            jsonEncode({
              'annotation_checks': checks,
              'png_artifact_count': images.length,
              'skill_script_call_count': skillScriptCount,
              'used_image_generation': usedImageGeneration,
              'native_annotation_enabled': nativeAnnotation,
              'ocr_evidence_count': ocrArtifacts.length,
              'ocr_evidence_internal': allOcrArtifactsAreInternal,
              'artifact_media_types': artifacts
                  .map((a) => a['media_type']?.toString() ?? 'missing')
                  .toSet()
                  .toList(),
            }),
          );
        } else {
          final updates = task['learning_notes'] as List? ?? const [];
          verified =
              updates.isNotEmpty &&
              tools.contains('append_learning_notes') &&
              artifacts.isEmpty &&
              updates.whereType<Map>().every(
                (u) =>
                    u['conversation_id'] == 'probe-chat' &&
                    u['message_id'] == 'probe-message',
              );
          LearningNotes.topics(const []);
        }
        stdout.writeln(
          jsonEncode({
            'check': id,
            'verified': verified,
            'tools': tools,
            'artifacts': artifacts.length,
            'extension_evidence_missing': result.extensionEvidenceMissing,
          }),
        );
        if (!verified || result.extensionEvidenceMissing) {
          final failedChecks = annotationChecks.entries
              .where((entry) => !entry.value)
              .map((entry) => entry.key)
              .join(',');
          throw StateError(
            'Native learning plugin live verification failed: $id; '
            'failed_checks=$failedChecks; '
            'extension_evidence_missing=${result.extensionEvidenceMissing}',
          );
        }
      } finally {
        timer.cancel();
      }
    }
  } finally {
    await attachments.close();
    store.close();
    await root.delete(recursive: true);
  }
}
