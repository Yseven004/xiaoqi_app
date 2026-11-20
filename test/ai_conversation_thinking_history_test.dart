import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';
import 'package:xiaoqi_app/services/reading_task_context.dart';

void main() {
  test('selected book passage survives reload and question edits', () {
    final reference = readingPassageMarkdown(
      source: '测试资料.epub',
      locator: '第一章',
      text: '第一行\r\n第二行',
    );
    final question = AiConversationMessage(
      id: 'reading-question',
      text: '解释这段',
      displayText: '解释这段',
      readingPassage: reference,
      isUser: true,
      createdAt: DateTime(2026, 11, 20),
    );
    final record = AiConversationRecord.empty(
      bookId: 7,
    ).copyWith(nodes: [question]);
    final restored = AiConversationRecord.fromJson(record.toJson());
    final edited = AiConversationMessage(
      text: '举个例子',
      displayText: '举个例子',
      isUser: true,
      createdAt: question.createdAt.add(const Duration(seconds: 1)),
    );
    final branch = restored.appendQuestionVersion(question.id, edited);
    expect(restored.bookId, 7);
    expect(branch.messages.single.readingPassage, reference);
    expect(branch.messages.single.readingPassage, contains('> 第一行\n> 第二行'));
    expect(branch.messages.single.displayText, '举个例子');
  });

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
