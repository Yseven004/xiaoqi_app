import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/domain/ai_chat_process.dart';

void main() {
  test(
    'saved old active or missing states follow the message terminal state',
    () {
      for (final state in [null, 'thinking', 'waiting', 'legacy']) {
        expect(savedChatProcessStatus(state, isIncomplete: false), 'completed');
        expect(savedChatProcessStatus(state, isIncomplete: true), 'stopped');
      }
      expect(savedChatProcessStatus('failed', isIncomplete: true), 'failed');
    },
  );
  test(
    'replaying a snapshot updates the same row without losing earlier steps',
    () {
      final started = <String, Object?>{
        'step_id': 'turn:1',
        'kind': 'event',
        'tool': 'web_search',
        'status': 'running',
        'text': '正在联网搜索',
      };
      final completed = {
        ...started,
        'status': 'completed',
        'text': '搜索到 5 个网页',
      };
      final details = mergeChatProcessDetails([
        started,
        completed,
        completed,
        for (var index = 2; index <= 60; index++)
          {
            'step_id': 'turn:$index',
            'kind': 'reasoning',
            'text': '第 $index 段公开说明。',
          },
      ]);
      expect(details, hasLength(60));
      expect(details.first['status'], 'completed');
      expect(details.first['text'], '搜索到 5 个网页');
      expect(details.last['step_id'], 'turn:60');
    },
  );

  test('completed answers do not manufacture tool success', () {
    final rows = settleChatProcessDetails([
      {'step_id': '1', 'kind': 'event', 'status': 'running', 'text': '正在读取附件'},
      {
        'step_id': '2',
        'kind': 'event',
        'status': 'completed',
        'text': '已完成联网搜索',
      },
    ], status: 'completed');
    expect(rows.first['status'], 'incomplete');
    expect(rows.first['text'], isNot(startsWith('正在')));
    expect(rows.last['status'], 'completed');
    expect(settleChatProcessDetails(rows, status: 'completed'), rows);
  });

  test(
    'stops and disconnects clear every active state and preserve finished evidence',
    () {
      for (final terminal in ['stopped', 'failed']) {
        final rows = settleChatProcessDetails([
          {'kind': 'event', 'status': 'waiting', 'text': '等待操作确认'},
          {'kind': 'event', 'status': 'failed', 'text': '代码执行未完成'},
        ], status: terminal);
        expect(
          rows.first['status'],
          terminal == 'stopped' ? 'stopped' : 'incomplete',
        );
        expect(rows.last['status'], 'failed');
      }
    },
  );

  test(
    'old histories retain explanations without inventing missing outcomes',
    () {
      final rows = settleChatProcessDetails([
        {'kind': 'event', 'type': 'thinking_update', 'text': '正在梳理问题'},
        {'kind': 'reasoning', 'text': '正在检查回答结构'},
        {'kind': 'reasoning', 'text': '先核对原始采访。', 'raw_log': 'private'},
      ], status: 'completed');
      expect(rows, hasLength(2));
      expect(rows.first['status'], 'incomplete');
      expect(rows.last['text'], '先核对原始采访。');
      expect(rows.last.containsKey('raw_log'), isFalse);
    },
  );
}
