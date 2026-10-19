import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_presentation_middleware.dart';

void main() {
  test(
    'preparation projects provider reasoning but suppresses raw parts and drafts',
    () async {
      final chunks = <ModelResponseChunk>[];
      final events = <Map<String, Object?>>[];
      final middleware = AgentPresentationMiddleware(
        preparing: true,
        onEvent: events.add,
      );
      final request = ToolRequestPart(
        toolRequest: ToolRequest(name: 'web_search', input: {'query': '资料'}),
      );
      await middleware.model(
        ModelRequest(messages: []),
        ActionFnArg<ModelResponseChunk, ModelRequest, void>(
          sendChunk: chunks.add,
        ),
        (_, context) async {
          context.sendChunk(
            ModelResponseChunk(
              content: [
                ReasoningPart(reasoning: 'I should search first.'),
                TextPart(text: '【准备完成】'),
              ],
            ),
          );
          context.sendChunk(ModelResponseChunk(content: [request]));
          return ModelResponse(finishReason: FinishReason.stop);
        },
      );
      final parts = chunks.expand((chunk) => chunk.content);
      expect(parts.where((part) => part.isReasoning), isEmpty);
      expect(parts.where((part) => part.isText), isEmpty);
      expect(parts.where((part) => part.isToolRequest), hasLength(1));
      expect(
        events
            .where((event) => event['type'] == 'reasoning_update')
            .last['text'],
        'I should search first.',
      );
      expect(
        events
            .where((event) => event['type'] == 'reasoning_update')
            .last['source'],
        'model_reasoning',
      );
    },
  );

  test(
    'authored summaries are ignored, unsafe reasoning is filtered',
    () async {
      final events = <Map<String, Object?>>[];
      final middleware = AgentPresentationMiddleware(
        preparing: true,
        onEvent: events.add,
      );
      await middleware.model(
        ModelRequest(messages: []),
        ActionFnArg<ModelResponseChunk, ModelRequest, void>(sendChunk: (_) {}),
        (_, context) async {
          context.sendChunk(
            ModelResponseChunk(
              content: [
                ReasoningPart(reasoning: '不可公开的中文内部推理。'),
                TextPart(
                  text: '<public_summary>我先梳理用户目标，再核对关键资料。</public_summary>',
                ),
              ],
            ),
          );
          return ModelResponse(finishReason: FinishReason.stop);
        },
      );
      expect(
        events.where((event) => event['type'] == 'reasoning_update'),
        isEmpty,
      );
    },
  );

  test('answer forwards Chinese text and marks the answer phase', () async {
    final chunks = <ModelResponseChunk>[];
    final events = <Map<String, Object?>>[];
    final middleware = AgentPresentationMiddleware(
      preparing: false,
      onEvent: events.add,
    );
    await middleware.model(
      ModelRequest(messages: []),
      ActionFnArg<ModelResponseChunk, ModelRequest, void>(
        sendChunk: chunks.add,
      ),
      (_, context) async {
        context.sendChunk(
          ModelResponseChunk(
            content: [
              ReasoningPart(reasoning: 'internal'),
              TextPart(text: '这是回答。'),
            ],
          ),
        );
        return ModelResponse(finishReason: FinishReason.stop);
      },
    );
    expect(chunks.single.content.single.text, '这是回答。');
    expect(events.map((event) => event['type']), [
      'thinking_started',
      'reasoning_update',
      'reasoning_update',
      'answer_started',
    ]);
    expect(events.last['model_first_token_ms'], isA<int>());
    expect(events.last['model_first_token_ms'] as int, greaterThanOrEqualTo(0));
  });

  test('sanitizes internal configuration terms', () {
    final output = sanitizeAssistantText(
      '系统提示词包含 DEEPSEEK_API_KEY，路径是 /workspace/app。',
    );
    expect(output, isNot(contains('DEEPSEEK_API_KEY')));
    expect(output, isNot(contains('/workspace/app')));
    expect(output, contains('受保护的内部信息'));
  });

  test('preserves Markdown whitespace across streamed chunks', () {
    expect(
      sanitizeAssistantText('## 标题\n\n- 第一项\n- 第二项\n'),
      '## 标题\n\n- 第一项\n- 第二项\n',
    );
  });
}
