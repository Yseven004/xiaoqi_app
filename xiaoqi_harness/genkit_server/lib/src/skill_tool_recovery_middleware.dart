import 'dart:convert';

import 'package:genkit/genkit.dart';

/// Keeps a bad model-emitted skill name from aborting the whole agent turn.
///
/// Genkit's Skills middleware intentionally rejects names that do not match a
/// discovered skill directory. This adapter preserves that boundary and
/// returns the valid identifiers so the model can correct the call or answer
/// without a skill.
class SkillToolRecoveryMiddleware extends GenerateMiddleware {
  SkillToolRecoveryMiddleware({
    required Iterable<String> skillIds,
    required this.onEvent,
  }) : skillIds = List.unmodifiable(skillIds.toSet().toList()..sort());

  final List<String> skillIds;
  final void Function(Map<String, Object?> event) onEvent;

  @override
  Future<ToolResult> tool(
    ToolRequestPart request,
    ActionFnArg<void, dynamic, void> context,
    Future<ToolResult> Function(
      ToolRequestPart request,
      ActionFnArg<void, dynamic, void> context,
    )
    next,
  ) async {
    final name = request.toolRequest.name.split('/').last;
    if (name != 'use_skill') return next(request, context);

    onEvent({'type': 'tool_started', 'tool': 'use_skill'});
    try {
      final result = await next(request, context);
      onEvent({'type': 'tool_succeeded', 'tool': 'use_skill'});
      return result;
    } on Object {
      if (context.cancel?.isCancelled == true) rethrow;
      onEvent({
        'type': 'tool_failed',
        'tool': 'use_skill',
        'message': '技能标识未匹配到本轮可用目录',
      });
      return ToolResult.response(
        jsonEncode({
          'ok': false,
          'error': '技能标识未匹配到本轮可用目录。',
          'available_skill_ids': skillIds,
          'instruction':
              '只使用 available_skill_ids 中的精确标识重试一次；若没有相关技能，继续完成用户请求，不要再调用技能。',
        }),
      );
    }
  }
}
