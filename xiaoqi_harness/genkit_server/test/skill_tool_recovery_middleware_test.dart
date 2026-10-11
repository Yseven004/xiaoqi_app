import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/skill_tool_recovery_middleware.dart';

void main() {
  test(
    'a missing skill name returns recoverable guidance to the model',
    () async {
      final events = <Map<String, Object?>>[];
      final middleware = SkillToolRecoveryMiddleware(
        skillIds: ['zeta', 'alpha', 'alpha'],
        onEvent: events.add,
      );
      final request = ToolRequestPart(
        toolRequest: ToolRequest(
          name: 'use_skill',
          input: {'skillName': 'display name'},
        ),
      );

      final result = await middleware.tool(
        request,
        ActionFnArg<void, dynamic, void>(),
        (_, _) async => throw StateError('skill not found'),
      );

      expect(result, isA<ToolResponseResult>());
      final output = (result as ToolResponseResult).output as String;
      final payload = jsonDecode(output) as Map<String, dynamic>;
      expect(payload['ok'], isFalse);
      expect(payload['available_skill_ids'], ['alpha', 'zeta']);
      expect(payload['instruction'], contains('继续完成用户请求'));
      expect(events.map((event) => event['type']), [
        'tool_started',
        'tool_failed',
      ]);
    },
  );

  test('a valid skill result passes through unchanged', () async {
    final events = <Map<String, Object?>>[];
    final middleware = SkillToolRecoveryMiddleware(
      skillIds: ['alpha'],
      onEvent: events.add,
    );
    final request = ToolRequestPart(
      toolRequest: ToolRequest(
        name: 'use_skill',
        input: {'skillName': 'alpha'},
      ),
    );

    final result = await middleware.tool(
      request,
      ActionFnArg<void, dynamic, void>(),
      (_, _) async => ToolResult.response('skill instructions'),
    );

    expect((result as ToolResponseResult).output, 'skill instructions');
    expect(events.map((event) => event['type']), [
      'tool_started',
      'tool_succeeded',
    ]);
  });
}
