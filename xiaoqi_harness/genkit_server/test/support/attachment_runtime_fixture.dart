import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/attachment_service.dart';
import 'package:xiaoqi_genkit_server/src/chat_annotation_images.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class RecordingAttachments extends AttachmentService {
  RecordingAttachments(super.store);

  final calls = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> material(
    String tenant,
    String id, {
    String mode = 'overview',
    String query = '',
    List<int> pages = const [],
  }) async {
    calls.add({
      'tenant': tenant,
      'id': id,
      'mode': mode,
      'query': query,
      'pages': pages,
    });
    if (tenant != 'personal') {
      throw const AttachmentFailure(
        '附件不存在或已过期',
        code: 'not_found',
        statusCode: 404,
      );
    }
    if (id == 'image-resource') {
      return {
        'id': id,
        'name': '图片.png',
        'kind': 'image',
        'mime_type': 'image/png',
        'text': '',
      };
    }
    final selected = pages.isEmpty
        ? [1, 4, 8]
        : pages.where((page) => page <= 18).toList();
    final text = selected
        .map((page) => '第 $page 页：介绍植物如何通过光合作用获得能量。')
        .join('\n');
    return {
      'id': id,
      'name': '科学课件.pdf',
      'kind': 'pdf',
      'text': text,
      'read_pages': selected,
      'total_pages': 18,
      'coverage': '按需页面',
      'text_truncated': false,
      'segments': [
        for (final page in selected)
          {'page': page, 'source': 'native', 'text': text},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> imagePart(
    String tenant,
    String id, {
    int? maxBytes,
  }) async {
    if (tenant != 'personal' || id != 'image-resource') {
      throw const AttachmentFailure(
        '附件不存在或已过期',
        code: 'not_found',
        statusCode: 404,
      );
    }
    calls.add({'tenant': tenant, 'id': id, 'image': true});
    return {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,aW1hZ2U='},
    };
  }
}

Future<void> main(List<String> args) async {
  final directory = await Directory.systemTemp.createTemp(
    'attachment-runtime-fixture-',
  );
  final store = CloudStore(root: directory.path);
  final attachments = RecordingAttachments(store);
  final runtime = GenkitXiaoqiAgentRuntime(
    store,
    ImageService(store),
    attachments: attachments,
  );
  final scenario = args.single;
  final followup = scenario == 'followup';
  // The real API calls _ensureRemoteAgentTask before invoking this runtime.
  store.put('task/personal/attachment-$scenario', {
    'task_id': 'attachment-$scenario',
    'status': 'running',
    'events': [],
    'artifacts': [],
  }, null);
  final events = <Map<String, Object?>>[];
  try {
    final result = await runtime.runAgentTurn(
      tenantId: 'personal',
      taskId: 'attachment-$scenario',
      request: {
        'model_id': 'mimo-v2.6-flash',
        if (!followup) 'intent_mode': 'attachment_only',
        'current_turn_text': switch (scenario) {
          'full' => '请逐页分析全文',
          'followup' => '请解释之前的这张图片',
          _ => '',
        },
        if (scenario == 'mixed')
          'annotation_groups': [
            {
              'id': 'first',
              'number': 1,
              'text': '解释图',
              'image_ids': ['fixture-image'],
            },
          ],
        if (!followup)
          'materials': [
            {
              'id': 'local-id',
              'name': '附件',
              'attachment_id': scenario == 'image'
                  ? 'image-resource'
                  : 'document-resource',
            },
          ],
      },
      messages: followup
          ? [
              Message(
                role: Role.user,
                content: [
                  TextPart(text: '[注释 1] 解释图'),
                  MediaPart(
                    media: Media(
                      url: 'data:image/png;base64,aW1hZ2U=',
                      contentType: 'image/png',
                    ),
                    metadata: {groupedAnnotationMediaMarker: true},
                  ),
                ],
              ),
              Message(
                role: Role.model,
                content: [TextPart(text: '已看过注释图片。')],
              ),
              Message(
                role: Role.user,
                content: [TextPart(text: '请解释之前的这张图片')],
              ),
            ]
          : agentMessagesFromRequest([
              {
                'role': 'user',
                'content': scenario == 'mixed'
                    ? [
                        {'type': 'text', 'text': '[注释 1] 解释图'},
                        {
                          'type': 'image_url',
                          'image_url': {
                            'url': 'data:image/png;base64,aW1hZ2U=',
                          },
                        },
                      ]
                    : '我上传了附件',
              },
            ]),
      onChunk: (_) {},
      onProcessEvent: events.add,
      cancellation: CancellationController().token,
    );
    stdout.writeln(
      'RUNTIME_RESULT:${jsonEncode({'text': result.text, 'calls': attachments.calls, 'events': events})}',
    );
  } finally {
    await attachments.close();
    store.close();
    await directory.delete(recursive: true);
  }
}
