import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart' show CancellationController;
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

// These unit cases exercise the executor after semantic routing. Real model
// classification is covered by the live intent gate and HTTP model fixtures.
String _classifiedImageTask(
  CloudStore store,
  String id,
  String text, {
  String mode = 'create',
}) {
  ToolExecution(
    store,
    'personal',
    id,
    TurnContract(mode: mode, imageLimit: 1),
    requestIdentity: ToolExecution.digest([id, text]),
    requestText: text,
  ).bind();
  return id;
}

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
    String? idempotencyKey,
    ArtifactRecorder? recordArtifact,
  }) async {
    this.prompt = prompt;
    this.count = count;
    this.imageUrl = imageUrl;
    return {'ok': true, 'count': 1, 'artifacts': []};
  }
}

void main() {
  test(
    'keeps explanations for requests that ask for an accompanying image',
    () {
      expect(
        agentImageRequestNeedsTextAnswer('给我解释一下马斯克第一性原理，再加上一张图片给我更直观地理解'),
        isTrue,
      );
      expect(agentImageRequestNeedsTextAnswer('帮我做一张动漫风景图片'), isFalse);
      expect(agentImageRequestNeedsTextAnswer('解释光合作用，然后画一张图'), isTrue);
      expect(agentImageRequestNeedsTextAnswer('生成一张图片给我讲解一下牛顿的第一定律'), isTrue);
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

  test('configured execution tools require the current turn contract', () {
    final ordinary = agentToolNamesForRequest(
      latestUserText: '你好，讲解一下第一性原理',
      imageGenerationAvailable: true,
      codeExecutionAvailable: true,
      webSearchAvailable: true,
      skillsAvailable: true,
    );
    expect(ordinary, ['web_search']);
    expect(
      agentToolNamesForRequest(
        latestUserText: '普通问答',
        imageGenerationAvailable: false,
        codeExecutionAvailable: false,
      ),
      isEmpty,
    );
  });

  test(
    'explains a single selected capability and gives a next action',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'xiaoqi-agent-capability-only-test-',
      );
      final store = CloudStore(root: directory.path);
      final runtime = GenkitXiaoqiAgentRuntime(
        store,
        _RecordingImageService(store),
      );

      try {
        final answer = await runtime.run(
          tenantId: 'personal',
          taskId: 'capability-only-test',
          request: {
            'model_id': 'deepseek-flash',
            'intent_mode': 'capability_only',
            'current_turn_text': '',
            'capability': {'type': 'skill', 'id': 'study-notes-studio'},
            'selected_capabilities': [
              {
                'type': 'skill',
                'id': 'study-notes-studio',
                'name': 'study-notes-studio',
                'description': '把学习资料整理成结构化笔记和复习提纲',
              },
            ],
            'messages': [
              {'role': 'user', 'content': '我选择了这个技能'},
            ],
          },
          onDelta: (_) {},
          cancellation: CancellationController().token,
        );

        expect(answer, contains('结构化笔记和复习提纲'));
        expect(answer, contains('直接告诉我目标'));
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('does not invent an attachment overview from its filename', () async {
    final directory = Directory.systemTemp.createTempSync(
      'xiaoqi-agent-attachment-only-test-',
    );
    final store = CloudStore(root: directory.path);
    final runtime = GenkitXiaoqiAgentRuntime(
      store,
      _RecordingImageService(store),
    );

    try {
      final answer = runtime.run(
        tenantId: 'personal',
        taskId: 'attachment-only-test',
        request: {
          'model_id': 'deepseek-flash',
          'intent_mode': 'attachment_only',
          'current_turn_text': '',
          'materials': [
            {'id': 'local', 'name': '课件.pdf', 'mime_type': 'application/pdf'},
          ],
          'messages': [
            {'role': 'user', 'content': '我上传了这个附件'},
          ],
        },
        onDelta: (_) {},
        cancellation: CancellationController().token,
      );

      await expectLater(
        answer,
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('附件尚未准备完成'),
          ),
        ),
      );
    } finally {
      store.close();
      directory.deleteSync(recursive: true);
    }
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
        taskId: _classifiedImageTask(store, 'image-action-test', '生成一张动漫风景图'),
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

  test(
    'semantically classified image requests reach the image executor',
    () async {
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
          taskId: _classifiedImageTask(
            store,
            'image-request-test',
            '帮我做一张动漫风景图片',
          ),
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
    },
  );

  test(
    'selected image action bypasses unrelated discoverable skills',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'image-action-skills-',
      );
      final store = CloudStore(root: directory.path);
      final images = _RecordingImageService(store);
      store.putImmutable('probe/writing', {
        'SKILL.md': utf8.encode(
          '---\nname: writing\ndescription: 润色文章。\n---\n润色用户提供的文章。',
        ),
      });
      store.put('cap/personal/writing', {
        'id': 'writing',
        'kind': 'skill',
        'name': '写作',
        'description': '润色文章',
        'enabled': true,
        'origin': 'github',
        'current_version_id': 'v1',
        'versions': [
          {
            'id': 'v1',
            'artifact_key': 'probe/writing',
            'components': [
              {
                'id': 'writing',
                'root': '',
                'name': 'writing',
                'description': '润色文章',
              },
            ],
          },
        ],
      }, null);
      try {
        final answer = await GenkitXiaoqiAgentRuntime(store, images).run(
          tenantId: 'personal',
          taskId: _classifiedImageTask(store, 'selected-cat', '小猫'),
          request: {
            'model_id': 'deepseek-flash',
            'capability': {'type': 'action', 'id': 'create-image'},
            'current_turn_text': '小猫',
            'messages': [
              {'role': 'user', 'content': '小猫'},
            ],
          },
          onDelta: (_) {},
          cancellation: CancellationController().token,
        );
        expect(answer, '图片已生成。');
        expect(images.prompt, contains('小猫'));
        expect(images.count, 1);
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

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
        taskId: _classifiedImageTask(
          store,
          'image-edit-test',
          '修改这张图片，让它变成动漫风格',
          mode: 'revise',
        ),
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
