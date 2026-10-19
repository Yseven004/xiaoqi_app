final _savedToolProtocol = RegExp(
  r'<[｜|]DSML[｜|]\s*(?:calls|tool_calls)\b[\s\S]*?</[｜|]DSML[｜|]\s*(?:calls|tool_calls)\s*>',
);
const _toolProtocolPrefixes = ['<｜DSML｜', '</｜DSML｜', '<|DSML|', '</|DSML|'];

/// Hide old malformed model output without changing stored conversation data.
String visibleChatAssistantText(String text) {
  var visible = text.replaceAll(_savedToolProtocol, '');
  for (final marker in _toolProtocolPrefixes) {
    final start = visible.indexOf(marker);
    if (start >= 0) visible = visible.substring(0, start);
  }
  final start = visible.lastIndexOf('<');
  if (start >= 0) {
    final suffix = visible.substring(start);
    if ((suffix.contains('｜') || suffix.contains('|')) &&
        _toolProtocolPrefixes.any((marker) => marker.startsWith(suffix))) {
      visible = visible.substring(0, start);
    }
  }
  return visible;
}

String savedChatProcessStatus(String? status, {required bool isIncomplete}) =>
    switch (status) {
      'completed' => 'completed',
      'stopped' => 'stopped',
      'failed' => 'failed',
      _ => isIncomplete ? 'stopped' : 'completed',
    };

/// Merge snapshots by step identity; terminal states update the original row.
List<Map<String, Object?>> mergeChatProcessDetails(
  Iterable<Map<String, Object?>> details,
) {
  final rows = <Map<String, Object?>>[];
  final positions = <String, int>{};
  for (final detail in details) {
    final text = detail['text']?.toString().trim() ?? '';
    if (text.isEmpty || detail['type'] == 'thinking_update') continue;
    final row = <String, Object?>{
      for (final key in const [
        'step_id',
        'sequence',
        'kind',
        'type',
        'status',
        'tool',
        'source_count',
        'source',
        'revision',
      ])
        if (detail[key] != null) key: detail[key],
      'text': text,
    };
    final id = row['step_id']?.toString();
    final index = id == null ? null : positions[id];
    if (index == null) {
      if (id != null) positions[id] = rows.length;
      rows.add(row);
    } else {
      if (row['revision'] is int &&
          rows[index]['revision'] is int &&
          (row['revision'] as int) <= (rows[index]['revision'] as int)) {
        continue;
      }
      rows[index] = row;
    }
  }
  return rows;
}

/// A saved or disconnected message cannot have a live tool. Missing terminal
/// evidence is incomplete, even when the answer itself succeeded.
List<Map<String, Object?>> settleChatProcessDetails(
  Iterable<Map<String, Object?>> details, {
  required String status,
}) => mergeChatProcessDetails(details)
    .map((row) {
      final state = row['status'];
      final text = row['text']!.toString();
      final legacyActive = state == null && text.startsWith('正在');
      if (state != 'running' && state != 'waiting' && !legacyActive) return row;
      final stopped = status == 'stopped';
      if (row['kind'] == 'reasoning' && row['source'] == 'model_reasoning') {
        return <String, Object?>{
          ...row,
          'status': stopped ? 'stopped' : 'incomplete',
        };
      }
      final label = text.replaceFirst(RegExp(r'^正在'), '');
      return <String, Object?>{
        ...row,
        'status': stopped ? 'stopped' : 'incomplete',
        'text': '$label（${stopped ? '已停止' : '未记录完成结果'}）',
      };
    })
    .toList(growable: false);
