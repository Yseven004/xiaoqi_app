import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart' show CancellationController;
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class _RecordingImageService extends ImageService {
  _RecordingImageService(super.store);

  String? prompt;
  int? count;
  String? imageUrl;

  @override
  Future<Map<String, dynamic>> generate({
    required String taskId,
    required String prompt,
    String? imageUrl,
    int count = 1,
    String? size,
    String? tenantId,
    ArtifactRecorder? recordArtifact,
  }) async {
    this.prompt = prompt;
    this.count = count;
    this.imageUrl = imageUrl;
    return {'ok': true, 'count': 1, 'artifacts': []};
  }
}

void main() {
  test('routes explicit image requests but not capability questions', () {
    expect(agentShouldGenerateImage('帮我做一张动漫风景图片'), isTrue);
    expect(agentShouldGenerateImage('生图啊？'), isTrue);
    expect(agentShouldGenerateImage('请问可以生成图片吗？'), isFalse);
    expect(agentShouldGenerateImage('怎么生成图片？'), isFalse);
    expect(agentShouldGenerateImage('帮我解释一下如何生成图片'), isFalse);
  });

  test('keeps ordinary conversation away from optional tools', () {
    expect(
      agentToolNamesForRequest(latestUserText: '你好，讲解一下马斯克第一性原理'),
      isEmpty,
    );
    expect(agentToolNamesForRequest(latestUserText: 'Python 是什么？'), isEmpty);
    expect(agentToolNamesForRequest(latestUserText: '请问可以生成图片吗？'), isEmpty);
  });

  test('does not expose image generation as an LLM tool', () {
    expect(agentToolNamesForRequest(latestUserText: '帮我做一张动漫风景图片'), isEmpty);
    expect(agentToolNamesForRequest(latestUserText: '运行这段 Python 代码'), [
      'execute_python',
    ]);
    expect(
      agentToolNamesForRequest(
        latestUserText: '按选中的技能处理',
        capabilitySelected: true,
        skillHasScripts: true,
      ),
      ['execute_python', 'execute_skill_script'],
    );
  });

  test('selected create-image action directly requests one image', () async {
    final directory = Directory.systemTemp.createTempSync(
      'xiaoqi-agent-image-test-',
    );
    final store = CloudStore(root: directory.path);
    final images = _RecordingImageService(store);
    final runtime = GenkitXiaoqiAgentRuntime(store, images);
    final deltas = <String>[];

    try {
      final answer = await runtime.run(
        tenantId: 'personal',
        taskId: 'image-action-test',
        request: {
          'model_id': 'deepseek-flash',
          'capability': {'type': 'action', 'id': 'create-image'},
          'messages': [
            {'role': 'user', 'content': '生成一张动漫风景图'},
          ],
        },
        onDelta: deltas.add,
        cancellation: CancellationController().token,
      );

      expect(images.prompt, '生成一张动漫风景图');
      expect(images.count, 1);
      expect(answer, '图片已生成。');
      expect(deltas, ['图片已生成。']);
    } finally {
      store.close();
      directory.deleteSync(recursive: true);
    }
  });

  test('normal image requests call the image service directly', () async {
    final directory = Directory.systemTemp.createTempSync(
      'xiaoqi-agent-image-request-test-',
    );
    final store = CloudStore(root: directory.path);
    final images = _RecordingImageService(store);
    final runtime = GenkitXiaoqiAgentRuntime(store, images);
    final deltas = <String>[];

    try {
      final answer = await runtime.run(
        tenantId: 'personal',
        taskId: 'image-request-test',
        request: {
          'model_id': 'deepseek-flash',
          'messages': [
            {'role': 'user', 'content': '帮我做一张动漫风景图片'},
          ],
        },
        onDelta: deltas.add,
        cancellation: CancellationController().token,
      );

      expect(images.prompt, '帮我做一张动漫风景图片');
      expect(images.count, 1);
      expect(images.imageUrl, isNull);
      expect(answer, '图片已生成。');
      expect(deltas, ['图片已生成。']);
    } finally {
      store.close();
      directory.deleteSync(recursive: true);
    }
  });

  test('passes an attached image to a direct edit request', () async {
    const sourceImage = 'data:image/png;base64,aW1hZ2U=';
    final directory = Directory.systemTemp.createTempSync(
      'xiaoqi-agent-image-edit-test-',
    );
    final store = CloudStore(root: directory.path);
    final images = _RecordingImageService(store);
    final runtime = GenkitXiaoqiAgentRuntime(store, images);

    try {
      await runtime.run(
        tenantId: 'personal',
        taskId: 'image-edit-test',
        request: {
          'model_id': 'deepseek-flash',
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '修改这张图片，让它变成动漫风格'},
                {
                  'type': 'image_url',
                  'image_url': {'url': sourceImage},
                },
              ],
            },
          ],
        },
        onDelta: (_) {},
        cancellation: CancellationController().token,
      );

      expect(images.prompt, '修改这张图片，让它变成动漫风格');
      expect(images.imageUrl, sourceImage);
      expect(images.count, 1);
    } finally {
      store.close();
      directory.deleteSync(recursive: true);
    }
  });

  test('preserves conversation roles, text, and image media', () {
    const imageUrl = 'data:image/png;base64,aW1hZ2U=';
    final messages = agentMessagesFromRequest([
      {'role': 'system', 'content': '回答要简洁'},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '这张图是什么？'},
          {
            'type': 'image_url',
            'image_url': {'url': imageUrl, 'detail': 'high'},
          },
        ],
      },
      {'role': 'assistant', 'content': '我来看看。'},
      {'role': 'user', 'content': '再解释一下。'},
    ]);

    expect(messages.map((message) => message.role.value), [
      'system',
      'user',
      'model',
      'user',
    ]);
    final parts = messages[1].content.map((part) => part.toJson()).toList();
    expect(parts[0]['text'], '这张图是什么？');
    final media = parts[1]['media'] as Map;
    expect(media['contentType'], 'image/png');
    expect(media['url'], imageUrl);
  });

  test('rejects unsupported image URLs with a readable error', () {
    expect(
      () => agentMessagesFromRequest([
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'https://example.com/image.png'},
            },
          ],
        },
      ]),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('只支持'),
        ),
      ),
    );
  });

  test('rejects images above the request size limit', () {
    final oversized = base64Encode(List<int>.filled(5 * 1024 * 1024 + 1, 0));
    expect(
      () => agentMessagesFromRequest([
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$oversized'},
            },
          ],
        },
      ]),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('5 MB'),
        ),
      ),
    );
  });
}
