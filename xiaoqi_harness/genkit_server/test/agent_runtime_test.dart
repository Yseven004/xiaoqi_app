import 'dart:convert';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';

void main() {
  test('keeps ordinary conversation away from optional tools', () {
    expect(
      agentToolNamesForRequest(latestUserText: '你好，讲解一下马斯克第一性原理'),
      isEmpty,
    );
    expect(agentToolNamesForRequest(latestUserText: 'Python 是什么？'), isEmpty);
    expect(agentToolNamesForRequest(latestUserText: '请问可以生成图片吗？'), isEmpty);
  });

  test('only exposes tools that match an explicit request', () {
    expect(agentToolNamesForRequest(latestUserText: '帮我画一张猫的图片'), [
      'generate_image',
    ]);
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
