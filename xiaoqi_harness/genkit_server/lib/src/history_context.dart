import 'package:genkit/genkit.dart';

/// Builds an inference view only. The persisted conversation remains intact.
List<Message> withoutHistoricalSkillBodies(
  List<Message> messages,
  Set<String> historicalSkillRefs,
) {
  return messages
      .map(
        (message) => Message(
          role: message.role,
          metadata: message.metadata,
          content: message.content.map((part) {
            final response = part.toJson()['toolResponse'];
            if (response is! Map ||
                !const {
                  'use_skill',
                  'read_skill_resource',
                }.contains(response['name']) ||
                !historicalSkillRefs.contains(response['ref']))
              return part;
            return ToolResponsePart(
              toolResponse: ToolResponse(
                name: response['name'] as String,
                ref: response['ref'] as String,
                output:
                    '此技能资料属于已结束的历史轮次。历史执行记录仍保留；'
                    '它不构成本轮要求。需要时应按本轮契约重新读取相关技能。',
              ),
            );
          }).toList(),
        ),
      )
      .toList();
}
