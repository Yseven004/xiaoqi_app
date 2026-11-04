import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';

void main() {
  final now = DateTime(2026, 10, 19);
  final selected = <String, Object?>{
    'type': 'plugin',
    'id': 'notes',
    'version_id': 'v1',
    'name': 'Notes',
  };
  test(
    'capability scope survives persistence, followups and explicit removal',
    () {
      AiConversationMessage message(
        String text, {
        Map<String, Object?>? metadata,
        String operation = 'inherit',
      }) => AiConversationMessage(
        text: text,
        isUser: true,
        createdAt: now,
        capabilityMetadata: metadata,
        capabilityScopeOperation: operation,
      );
      final first = message('', metadata: selected, operation: 'replace');
      final followup = message('请用它整理');
      final conversation = AiConversationRecord(
        id: 'book',
        title: 'Book',
        createdAt: now,
        updatedAt: now,
        messages: [first, followup],
      );
      expect(conversation.activeCapabilityMetadata, selected);
      final cleared = message('继续', operation: 'clear');
      final restored = AiConversationMessage.fromJson(cleared.toJson());
      expect(restored.capabilityScopeOperation, 'clear');
      final afterRemoval = AiConversationRecord(
        id: 'book',
        title: 'Book',
        createdAt: now,
        updatedAt: now,
        messages: [first, followup, restored],
      );
      expect(afterRemoval.activeCapabilityMetadata, isNull);
      expect(first.copyWith(text: '重新提问').capabilityMetadata, selected);
    },
  );

  test('paused and waiting work stays open; completed work starts fresh', () {
    final question = AiConversationMessage(
      id: 'question',
      text: '分析资料',
      isUser: true,
      workId: 'work-1',
      problemAttemptStageId: 'stage-1',
      createdAt: now,
      capabilityMetadata: selected,
      capabilityScopeOperation: 'replace',
    );
    AiConversationRecord conversationWith(String status) {
      final answer = AiConversationMessage(
        id: 'answer-$status',
        text: '进度说明',
        isUser: false,
        parentMessageId: question.id,
        workId: question.workId,
        problemAttemptStageId: question.problemAttemptStageId,
        createdAt: now,
        agentProcessStatus: status,
      );
      final record = AiConversationRecord.empty()
          .copyWith(nodes: [question])
          .appendAnswerVersion(question.id, answer);
      return AiConversationRecord.fromJson(record.toJson());
    }

    final paused = conversationWith('paused');
    expect(paused.hasOpenWork, isTrue);
    expect(paused.activeWorkId, 'work-1');
    expect(paused.latestUserMessage!.problemAttemptStageId, 'stage-1');
    expect(paused.activeCapabilityMetadata, selected);

    expect(conversationWith('waiting_for_user').hasOpenWork, isTrue);
    expect(conversationWith('completed').hasOpenWork, isFalse);
  });
}
