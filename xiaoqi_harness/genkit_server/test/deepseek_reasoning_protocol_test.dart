import 'dart:convert';
import 'package:genkit/genkit.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_presentation_middleware.dart';

void main() {
  for (final effort in ['low', 'medium', 'high']) {
    test(
      'DeepSeek $effort enables thinking and replays private tool reasoning',
      () async {
        var calls = 0;
        final events = <Map<String, Object?>>[];
        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(body['thinking'], {'type': 'enabled'});
          expect(body['reasoning_effort'], effort);
          calls++;
          if (calls == 2) {
            final history = (body['messages'] as List).whereType<Map>();
            expect(
              history.any((m) => m['reasoning_content'] == '先计算结果。'),
              isTrue,
            );
          }
          return http.Response(
            jsonEncode({
              'id': 'native-test',
              'object': 'chat.completion',
              'created': 1,
              'model': 'deepseek-flash',
              'choices': [
                {
                  'index': 0,
                  'finish_reason': calls == 1 ? 'tool_calls' : 'stop',
                  'message': {
                    'role': 'assistant',
                    'content': calls == 1 ? '' : '结果为二。',
                    'reasoning_content': calls == 1 ? '先计算结果。' : '已得到结果，可以回答。',
                    if (calls == 1)
                      'tool_calls': [
                        {
                          'id': 'call-1',
                          'type': 'function',
                          'function': {'name': 'calculate', 'arguments': '{}'},
                        },
                      ],
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final ai = Genkit(
          plugins: [
            deepSeek(
              apiKey: 'test-only',
              httpClient: client,
              models: [CustomModelDefinition(name: 'deepseek-flash')],
            ),
          ],
        );
        ai.defineTool(name: 'calculate', description: 'Compute one plus one.',
          fn: (_, _) async => ToolResult.response(2));
        final presentation = ai.defineGenerateMiddleware<void>(
          name: 'native-presentation',
          create: (_, _) => AgentPresentationMiddleware(
            preparing: false,
            onEvent: events.add,
          ),
        );
        final response = await ai.generate(
          model: deepSeek.model('deepseek-flash'),
          prompt: '计算一加一。',
          toolNames: ['calculate'],
          config: OpenAIChatOptions(reasoningEffort: effort),
          use: [presentation()],
        );
        expect(response.text, '结果为二。');
        expect(calls, 2);
        expect(
          events.where((e) => e['source'] == 'model_reasoning'),
          isNotEmpty,
        );
        client.close();
      },
    );
  }
}
