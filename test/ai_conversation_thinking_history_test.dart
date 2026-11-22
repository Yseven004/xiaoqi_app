import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';
import 'package:xiaoqi_app/services/reading_task_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    expect(restored.isReadingCompanion, isTrue);
    expect(restored.companionPassage, reference);
    expect(restored.companionPassageExcerpt, '第一行\n第二行');
    expect(restored.companionSourceId, isNull);
    expect(branch.toJson()['reading_companion'], isTrue);
    expect(branch.messages.single.readingPassage, reference);
    expect(branch.messages.single.readingPassage, contains('> 第一行\n> 第二行'));
    expect(branch.messages.single.displayText, '举个例子');
    expect(branch.companionPassageExcerpt, restored.companionPassageExcerpt);
  });

  test('companion origin and material survive without a quoted passage', () {
    final conversation = AiConversationRecord.empty(
      bookId: 7,
      readingCompanion: true,
      companionSourceId: 11,
    ).copyWith(title: '本章讨论');
    final restored = AiConversationRecord.fromJson(conversation.toJson());
    expect(restored.isReadingCompanion, isTrue);
    expect(restored.companionSourceId, 11);
    expect(restored.companionPassageExcerpt, isNull);
    expect(AiConversationRecord.empty(bookId: 7).isReadingCompanion, isFalse);
  });

  test(
    'companion history starts at a question and sorts by actual use',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final history = AiConversationHistoryService(preferences: preferences);
      final firstDay = DateTime(2020, 3, 1);
      final nextDay = firstDay.add(const Duration(days: 1));
      AiConversationRecord draft(String id) => AiConversationRecord(
        id: id,
        title: id,
        bookId: 7,
        readingCompanion: true,
        messages: const [],
        createdAt: firstDay,
        updatedAt: firstDay,
      );
      final pending = draft('never-sent');
      await history.saveTransactional(pending);
      await history.markCompanionOpened(pending.id);
      expect(await history.get(pending.id), isNull);

      final free = draft('free').copyWith(
        nodes: [
          AiConversationMessage(
            text: '本书的主题？',
            isUser: true,
            createdAt: firstDay,
          ),
        ],
      );
      final selected = draft('selected').copyWith(
        nodes: [
          AiConversationMessage(
            text: '解释这段',
            isUser: true,
            createdAt: nextDay,
            readingPassage: readingPassageMarkdown(
              source: '资料',
              locator: '第三章',
              text: '这一段原文。',
            ),
          ),
        ],
      );
      await history.save(free);
      await history.save(selected);
      Future<List<String>> order(AiConversationHistoryService service) async =>
          (await service.list(
            bookId: 7,
            companionMode: true,
          )).map((record) => record.id).toList();
      expect(await order(history), ['selected', 'free']);

      final staleFree = (await history.get(free.id))!;
      final backgroundReply = selected
          .appendAnswerVersion(
            selected.nodes.single.id,
            AiConversationMessage(
              text: '回答',
              isUser: false,
              createdAt: DateTime.now(),
            ),
          )
          .copyWith(updatedAt: DateTime.now());
      await Future.wait([
        history.markCompanionOpened(free.id),
        history.saveTransactional(staleFree),
        history.save(backgroundReply),
      ]);
      expect(await order(history), ['free', 'selected']);
      final reloaded = AiConversationHistoryService(preferences: preferences);
      expect(await order(reloaded), ['free', 'selected']);
      final reopened = (await reloaded.get('free'))!;
      expect(reopened.updatedAt, firstDay);
      expect(reopened.companionOpenedAt, isNotNull);
      expect(reopened.companionLastUsedAt, reopened.companionOpenedAt);
      expect((await reloaded.get('selected'))!.companionLastUsedAt, nextDay);
      expect(reopened.companionPassage, isNull);

      await reloaded.delete([free.id]);
      await reloaded.markCompanionOpened(free.id);
      expect(await order(reloaded), ['selected']);
      expect(await reloaded.get(free.id), isNull);
    },
  );

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
