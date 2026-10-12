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
    expect(agentShouldGenerateImage('给我解释一下马斯克第一性原理，再加上一张图片给我更直观地理解'), isTrue);
    expect(agentShouldGenerateImage('帮我解释光合作用并配图'), isTrue);
    expect(agentShouldGenerateImage('解释光合作用，然后画一张图'), isTrue);
  });

  test(
    'keeps explanations for requests that ask for an accompanying image',
    () {
      expect(
        agentImageRequestNeedsTextAnswer('给我解释一下马斯克第一性原理，再加上一张图片给我更直观地理解'),
        isTrue,
      );
      expect(agentImageRequestNeedsTextAnswer('帮我做一张动漫风景图片'), isFalse);
      expect(agentImageRequestNeedsTextAnswer('解释光合作用，然后画一张图'), isTrue);
      expect(
        agentImageRequestNeedsTextAnswer('生成一张图片给我讲解一下牛顿的第一定律'),
        isTrue,
      );
    },
  );

  test(
    'defaults image requests to portrait 3:4 unless a frame was specified',
    () {
      expect(agentImagePrompt('生成一张森林图片'), contains('竖版 3:4'));
      expect(agentImagePrompt('生成一张 16:9 横版森林图片'), isNot(contains('竖版 3:4')));
      expect(agentImagePrompt('生成一张 1024x1536 图片'), isNot(contains('竖版 3:4')));
    },
  );

  test('keeps the complete topic when compiling a visual prompt', () {
    const request = '生成图片给我讲解一下牛顿的第一定律';
    final brief = compileVisualBrief(request, supplementalExplanation: true);
    expect(brief.attributionContext, contains('牛顿'));
    expect(brief.providerPrompt, contains('第一定律'));
    expect(brief.providerPrompt, isNot(contains('牛顿')));
    expect(brief.providerPrompt, isNot(contains('生成图片')));
  });

  test('compiles public-figure attribution as a generic concept brief', () {
    final brief = compileVisualBrief(
      '给我讲解马斯克第一性原理，顺便生成一张图片给我加以理解',
      supplementalExplanation: true,
    );
    expect(brief.attributionContext, contains('马斯克'));
    expect(brief.providerPrompt, contains('第一性原理'));
    expect(brief.providerPrompt, isNot(contains('马斯克')));
    expect(brief.people, 'none');
    expect(brief.likenessRequired, isFalse);
  });

  test('does not infer tool availability from user keywords', () {
    expect(
      agentToolNamesForRequest(latestUserText: '你好，讲解一下马斯克第一性原理'),
      isEmpty,
    );
    expect(agentToolNamesForRequest(latestUserText: 'Python 是什么？'), isEmpty);
    expect(agentToolNamesForRequest(latestUserText: '请问可以生成图片吗？'), isEmpty);
  });

  test('exposes configured tools regardless of the current user wording', () {
    final ordinary = agentToolNamesForRequest(
      latestUserText: '你好，讲解一下第一性原理',
      imageGenerationAvailable: true,
      codeExecutionAvailable: true,
      webSearchAvailable: true,
      skillsAvailable: true,
    );
    final codeQuestion = agentToolNamesForRequest(
      latestUserText: 'Python 是什么？',
      imageGenerationAvailable: true,
      codeExecutionAvailable: true,
      webSearchAvailable: true,
      skillsAvailable: true,
    );
    expect(ordinary, [
      'execute_python',
      'generate_image',
      'execute_skill_script',
      'read_skill_resource',
      'web_search',
      'use_skill',
    ]);
    expect(codeQuestion, ordinary);
    expect(
      agentToolNamesForRequest(
        latestUserText: '普通问答',
        imageGenerationAvailable: false,
        codeExecutionAvailable: false,
      ),
      isEmpty,
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
    var imageGenerationStarted = false;

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
        onImageGenerationStarted: () => imageGenerationStarted = true,
      );

      expect(images.prompt, contains('动漫风景图'));
      expect(images.prompt, isNot(contains('生成一张')));
      expect(images.count, 1);
      expect(imageGenerationStarted, isTrue);
      expect(answer, '图片已生成。');
      expect(deltas, ['图片已生成。']);
    } finally {
      store.close();
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'selected create-image action with empty current input asks first',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'xiaoqi-agent-empty-image-test-',
      );
      final store = CloudStore(root: directory.path);
      final images = _RecordingImageService(store);
      final runtime = GenkitXiaoqiAgentRuntime(store, images);

      try {
        final answer = await runtime.run(
          tenantId: 'personal',
          taskId: 'empty-image-action-test',
          request: {
            'model_id': 'deepseek-flash',
            'capability': {'type': 'action', 'id': 'create-image'},
            'current_turn_text': '',
            'messages': [
              {'role': 'user', 'content': '我选择了“创建图像”，请结合当前对话继续。'},
            ],
          },
          onDelta: (_) {},
          cancellation: CancellationController().token,
        );

        expect(answer, contains('你想生成什么内容的图片'));
        expect(images.prompt, isNull);
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

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

      expect(images.prompt, contains('动漫风景'));
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

      expect(images.prompt, contains('修改这张图片，让它变成动漫风格'));
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
