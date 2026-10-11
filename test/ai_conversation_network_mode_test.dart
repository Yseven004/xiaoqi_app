import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';

void main() {
  test('new conversations default to network off', () {
    expect(AiConversationRecord.empty().networkMode, 'off');
  });

  test('legacy automatic and missing modes migrate to off', () {
    final base = {
      'id': 'conversation-test',
      'created_at': '2026-10-11T00:00:00.000Z',
      'updated_at': '2026-10-11T00:00:00.000Z',
      'messages': const [],
    };

    expect(
      AiConversationRecord.fromJson({...base, 'network_mode': 'auto'})
          .networkMode,
      'off',
    );
    expect(AiConversationRecord.fromJson(base).networkMode, 'off');
    expect(
      AiConversationRecord.fromJson({...base, 'network_mode': 'on'}).networkMode,
      'on',
    );
  });
}
