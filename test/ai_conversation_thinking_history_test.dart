import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';

void main() {
  test(
    'a stopped process-only answer survives the visible path and JSON round trip',
    () {
      final question = AiConversationMessage(
        id: 'question',
        text: '分析资料',
        isUser: true,
        createdAt: DateTime(2026, 10, 18),
      );
      final stopped = AiConversationMessage(
        id: 'stopped',
        text: '',
        isUser: false,
        parentMessageId: question.id,
        createdAt: question.createdAt,
        isIncomplete: true,
        agentProcessSummary: '已读取附件',
        agentProcessDetails: const [
          {'kind': 'reasoning', 'text': '先核对资料。'},
        ],
        agentProcessDurationMs: 1200,
        agentProcessStatus: 'stopped',
      );
      final record = AiConversationRecord.empty()
          .copyWith(nodes: [question])
          .appendAnswerVersion(question.id, stopped);
      final restored = AiConversationRecord.fromJson(record.toJson());
      expect(restored.messages.map((message) => message.id), [
        'question',
        'stopped',
      ]);
      expect(
        restored.messages.last.agentProcessDetails.single['text'],
        '先核对资料。',
      );
      expect(
        restored.answerVersionsFor(restored.messages.last).single.id,
        'stopped',
      );
      expect(restored.messages.last.agentProcessExpanded, isFalse);
    },
  );

  test(
    'a newly selected process-only version does not reveal the previous answer instead',
    () {
      final question = AiConversationMessage(
        id: 'question',
        text: '重新分析',
        isUser: true,
        createdAt: DateTime(2026, 10, 18),
      );
      final oldAnswer = AiConversationMessage(
        id: 'old',
        text: '旧答案',
        isUser: false,
        createdAt: question.createdAt,
      );
      final newAnswer = AiConversationMessage(
        id: 'new',
        text: '',
        isUser: false,
        createdAt: question.createdAt,
        agentProcessStatus: 'stopped',
        agentProcessSummary: '思考过程',
        isIncomplete: true,
      );
      final record = AiConversationRecord.empty()
          .copyWith(nodes: [question])
          .appendAnswerVersion(question.id, oldAnswer)
          .appendAnswerVersion(question.id, newAnswer);
      expect(record.messages.last.id, 'new');
      expect(record.answerVersionsFor(record.messages.last), hasLength(2));
      expect(record.previewDeleteReply('new'), isNotNull);
    },
  );
}
