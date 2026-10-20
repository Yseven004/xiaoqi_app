import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/chat_completion_service.dart';
import 'package:xiaoqi_genkit_server/src/model_limits.dart';

void main() {
  test('current model limits match their first-party API specifications', () {
    expect(ModelLimits.forModel('deepseek-flash').contextTokens, 1048576);
    expect(ModelLimits.forModel('deepseek-flash').maxOutputTokens, 393216);
    expect(ModelLimits.forModel('mimo-v2.6-flash').contextTokens, 1048576);
    expect(ModelLimits.forModel('mimo-v2.6-flash').maxOutputTokens, 131072);
    expect(() => ModelLimits.forModel('unknown'), throwsArgumentError);
  });

  test(
    'helper API preserves long input and uses the official output ceiling',
    () async {
      final text = List.filled(1050000, '字').join();
      ChatCompletionInput? captured;
      final service = ChatCompletionService(
        environment: const {'DEEPSEEK_API_KEY': 'synthetic-test-key'},
        generate: (input) async {
          captured = input;
          return '完成';
        },
      );
      final response = await service.handle(
        Request(
          'POST',
          Uri.parse('http://localhost/v1/chat/completions'),
          body: jsonEncode({
            'model_id': 'deepseek-flash',
            'max_tokens': 128,
            'messages': [
              {'role': 'user', 'content': text},
            ],
          }),
        ),
      );
      expect(response.statusCode, 200);
      expect(captured!.maxTokens, 393216);
      expect(captured!.messages.single.content.single.toJson()['text'], text);
    },
  );
}
