import 'package:genkit/genkit.dart';

const _defaultInferenceContextCharacters = 48000;
const _defaultRecentInferenceTurns = 8;
const _defaultHistoricalToolResponseCharacters = 2400;

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

/// Returns a bounded model-only view while leaving the stored session intact.
///
/// The first user message preserves the work goal, recent complete turns keep
/// the active reasoning path, and old tool outputs are shortened before turns
/// are removed. This is a deterministic fallback for providers that do not
/// expose a shared token counter to Genkit Dart middleware.
List<Message> boundedInferenceHistory(
  List<Message> messages, {
  int maxCharacters = _defaultInferenceContextCharacters,
  int recentTurns = _defaultRecentInferenceTurns,
  int historicalToolResponseCharacters =
      _defaultHistoricalToolResponseCharacters,
}) {
  if (messages.isEmpty) return const [];

  final compactedTools = _boundToolResponses(
    messages,
    maxCharacters: historicalToolResponseCharacters,
  );
  if (_estimatedCharacters(compactedTools) <= maxCharacters) {
    return compactedTools;
  }

  final systemMessages = compactedTools
      .where((message) => message.role == Role.system)
      .toList(growable: false);
  final turns = <List<Message>>[];
  var currentTurn = <Message>[];
  for (final message in compactedTools.where(
    (message) => message.role != Role.system,
  )) {
    if (message.role == Role.user && currentTurn.isNotEmpty) {
      turns.add(currentTurn);
      currentTurn = <Message>[];
    }
    currentTurn.add(message);
  }
  if (currentTurn.isNotEmpty) turns.add(currentTurn);
  if (turns.isEmpty) return systemMessages;

  final keepCount = recentTurns.clamp(1, turns.length);
  final firstTurn = turns.first;
  final firstUser = firstTurn.where((message) => message.role == Role.user);
  final goal = firstUser.isEmpty ? null : _shortGoal(firstUser.first);
  final trailingTurns = turns.skip(turns.length - keepCount).toList();
  final goalAlreadyKept = turns.length <= keepCount;
  final omittedTurns = turns.length - trailingTurns.length;
  final omissionNotice = Message(
    role: Role.system,
    content: [
      TextPart(
        text:
            '上下文长度限制：较早的当前工作轮次已从本次模型输入省略，'
            '完整记录仍保存在会话中；不要臆造省略内容，需要时重新读取资料或询问用户。'
            '省略轮数：$omittedTurns。',
      ),
    ],
    metadata: const {'xiaoqi_context_omission': true},
  );

  var retainedTurns = trailingTurns;
  List<Message> build() => [
    ...systemMessages,
    omissionNotice,
    if (!goalAlreadyKept && goal != null) goal,
    ...retainedTurns.expand((turn) => turn),
  ];

  var bounded = build();
  while (_estimatedCharacters(bounded) > maxCharacters &&
      retainedTurns.length > 1) {
    retainedTurns = retainedTurns.skip(1).toList();
    bounded = build();
  }
  if (_estimatedCharacters(bounded) > maxCharacters && goal != null) {
    bounded = [
      ...systemMessages,
      omissionNotice,
      if (!goalAlreadyKept) _shortGoal(goal, maxCharacters: 2000),
      ...retainedTurns.expand((turn) => turn),
    ];
  }
  return bounded;
}

List<Message> _boundToolResponses(
  List<Message> messages, {
  required int maxCharacters,
}) {
  return [
    for (var messageIndex = 0; messageIndex < messages.length; messageIndex++)
      Message(
        role: messages[messageIndex].role,
        metadata: messages[messageIndex].metadata,
        content: [
          for (final part in messages[messageIndex].content)
            _boundToolResponse(
              part,
              maxCharacters: messageIndex >= messages.length - 3
                  ? maxCharacters * 4
                  : maxCharacters,
            ),
        ],
      ),
  ];
}

Part _boundToolResponse(Part part, {required int maxCharacters}) {
  final partJson = part.toJson();
  final rawResponse = partJson['toolResponse'];
  if (rawResponse is! Map) return part;
  final response = Map<String, dynamic>.from(rawResponse);
  final output = response['output'];
  if (_visibleSize(output) <= maxCharacters) return part;
  response['output'] = output is String
      ? '${output.substring(0, maxCharacters)}\n[旧工具结果已截断；需要时重新读取原始资料]'
      : '[旧结构化工具结果因上下文限制省略；需要时重新读取原始资料]';
  return ToolResponsePart.fromJson({'toolResponse': response});
}

Message _shortGoal(Message message, {int maxCharacters = 8000}) {
  var remaining = maxCharacters;
  final textParts = <Part>[];
  for (final part in message.content) {
    if (!part.isText || remaining <= 0) continue;
    final text = part.text ?? '';
    final kept = text.length <= remaining
        ? text
        : '${text.substring(0, remaining)}\n[起始目标节选]';
    textParts.add(TextPart(text: kept));
    remaining -= kept.length;
  }
  return Message(
    role: Role.user,
    metadata: message.metadata,
    content: textParts.isEmpty
        ? [TextPart(text: '当前工作的原始目标已保存在会话记录中。')]
        : textParts,
  );
}

int _estimatedCharacters(Iterable<Message> messages) => messages.fold(
  0,
  (total, message) =>
      total +
      message.content.fold(0, (sum, part) => sum + _visibleSize(part.toJson())),
);

int _visibleSize(Object? value, {String? key}) {
  if (value is String) {
    if (const {'url', 'data', 'bytes', 'inlineData'}.contains(key)) return 2048;
    return value.length;
  }
  if (value is Map) {
    return value.entries.fold(
      0,
      (sum, entry) =>
          sum + _visibleSize(entry.value, key: entry.key.toString()),
    );
  }
  if (value is Iterable) {
    return value.fold(0, (sum, item) => sum + _visibleSize(item));
  }
  return 16;
}
