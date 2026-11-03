import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/learning_notes.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory root;
  late CloudStore store;
  setUp(() {
    root = Directory.systemTemp.createTempSync('native-notes-');
    store = CloudStore(root: root.path);
    store.put('task/alice/task-1', {'events': []}, null);
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });
  List<Map<String, dynamic>> submit({bool enabled = true, String topic = ''}) =>
      LearningNotes.submit(
        store,
        tenant: 'alice',
        taskId: 'task-1',
        identity: 'turn-1',
        conversationId: 'chat-1',
        messageId: 'message-1',
        sourceText: '怎么复习？',
        catalog: [
          {'id': 'known-topic', 'title': '学习方法'},
        ],
        explicitlyEnabled: enabled,
        input: {
          'notes': [
            {
              'topic_id': topic,
              'title': '主动回忆',
              'summary': '先尝试提取，再核对。',
              'sections': [
                {
                  'heading': '练习',
                  'items': ['合上书回答问题'],
                },
              ],
            },
          ],
        },
      );
  test(
    'explicit native authorization and catalog prevent unrelated note writes',
    () {
      expect(() => submit(enabled: false), throwsStateError);
      expect(() => submit(topic: 'foreign-topic'), throwsFormatException);
      expect(store.get('task/alice/task-1')!.value['learning_notes'], isNull);
      expect(store.get('task/bob/task-1'), isNull);
    },
  );
  test('task scoped retry returns the same receipt and original source', () {
    final first = submit(topic: 'known-topic');
    final revision = store.get('task/alice/task-1')!.revision;
    final again = submit(topic: 'known-topic');
    expect(again, first);
    expect(store.get('task/alice/task-1')!.revision, revision);
    expect(first.single['conversation_id'], 'chat-1');
    expect(first.single['message_id'], 'message-1');
    expect(first.single['source_text'], '怎么复习？');
    expect(first.single.keys, isNot(contains('delta')));
  });
}
