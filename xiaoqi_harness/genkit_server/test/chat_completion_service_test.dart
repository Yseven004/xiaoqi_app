import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/chat_completion_service.dart';

void main() {
  test('routes a compatible chat request through the server model config', () async {
    ChatCompletionInput? captured;
    final service = ChatCompletionService(
      environment: const {
        'MIMO_API_KEY': 'test-server-key',
        'XIAOQI_DEFAULT_TEXT_MODEL': 'mimo-v2.5',
        'XIAOQI_TEXT_TEMPERATURE': '0.7',
      },
      generate: (input) async {
        captured = input;
        return '处理完成';
      },
    );

    final response = await service.handle(
      Request(
        'POST',
        Uri.parse('http://localhost/v1/chat/completions'),
        body: jsonEncode({
          'messages': [
            {'role': 'system', 'content': '遵循要求'},
            {'role': 'user', 'content': '请处理这段内容'},
          ],
          'max_output_tokens': 128,
        }),
      ),
    );

    expect(response.statusCode, 200);
    final decoded = jsonDecode(await response.readAsString()) as Map;
    final choices = decoded['choices'] as List;
    final message = choices.single['message'] as Map;
    expect(message['content'], '处理完成');
    expect(captured?.modelId, 'mimo-v2.5');
    expect(captured?.namespace, 'mimo');
    expect(captured?.apiKey, 'test-server-key');
    expect(captured?.temperature, 0.7);
    expect(captured?.maxTokens, 128);
    expect(captured?.messages[0].role, Role.system);
    expect(captured?.messages[1].role, Role.user);
  });

  test('preserves supported inline image input', () async {
    ChatCompletionInput? captured;
    final service = ChatCompletionService(
      environment: const {'DEEPSEEK_API_KEY': 'test-server-key'},
      generate: (input) async {
        captured = input;
        return '看到了图片';
      },
    );
    final image = base64Encode([1, 2, 3]);

    final response = await service.handle(
      Request(
        'POST',
        Uri.parse('http://localhost/v1/chat/completions'),
        body: jsonEncode({
          'model': 'deepseek-flash',
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '请分析图片'},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/png;base64,$image'},
                },
              ],
            },
          ],
        }),
      ),
    );

    expect(response.statusCode, 200);
    expect(captured?.messages.single.role, Role.user);
    expect(
      captured?.messages.single.content.any((part) => part.isMedia),
      isTrue,
    );
  });

  test('rejects unsupported models and malformed image URLs', () async {
    final service = ChatCompletionService(
      environment: const {'MIMO_API_KEY': 'test-server-key'},
      generate: (_) async => 'unused',
    );

    final unsupported = await service.handle(
      Request(
        'POST',
        Uri.parse('http://localhost/v1/chat/completions'),
        body: jsonEncode({
          'model': 'other-provider-model',
          'messages': [
            {'role': 'user', 'content': 'hello'},
          ],
        }),
      ),
    );
    expect(unsupported.statusCode, 400);

    final malformedImage = await service.handle(
      Request(
        'POST',
        Uri.parse('http://localhost/v1/chat/completions'),
        body: jsonEncode({
          'model': 'mimo-v2.5',
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {'url': 'https://example.com/image.png'},
                },
              ],
            },
          ],
        }),
      ),
    );
    expect(malformedImage.statusCode, 400);
  });

  test('returns a setup error when the server key is missing', () async {
    final service = ChatCompletionService(
      environment: const {},
      generate: (_) async => 'unused',
    );

    final response = await service.handle(
      Request(
        'POST',
        Uri.parse('http://localhost/v1/chat/completions'),
        body: jsonEncode({
          'model': 'mimo-v2.5',
          'messages': [
            {'role': 'user', 'content': 'hello'},
          ],
        }),
      ),
    );

    expect(response.statusCode, 503);
  });
}
