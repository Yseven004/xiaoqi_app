import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';

void main() {
  test('legacy flags discarded without changing conversation data', () {
    final base = AiConversationRecord.empty().toJson();
    for (final mode in ['on', 'off', 'auto']) {
      final record = AiConversationRecord.fromJson({
        ...base,
        'network_mode': mode,
      });
      expect(record.id, base['id']);
      expect(record.toJson(), base);
      expect(record.copyWith().toJson().containsKey('network_mode'), isFalse);
    }
  });
}
