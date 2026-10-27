import 'dart:async';
import 'public_reasoning_buffer.dart';

/// Correlates runtime evidence with the invocation enclosing it, including
/// concurrent calls of the same tool. Never serialized to the client.
const publicProcessInvocation = #xiaoqiPublicProcessInvocation;

String publicToolName(String raw) => switch (raw.split('/').last) {
  'web_search' => 'web_search',
  'web_fetch' => 'web_fetch',
  'execute_python' => 'execute_python',
  'execute_shell' => 'execute_shell',
  'execute_skill_script' => 'execute_skill_script',
  'use_skill' => 'use_skill',
  'set_task_deliverables' => 'task_plan',
  'read_skill_resource' => 'read_skill_resource',
  'read_task_material' => 'read_task_material',
  'read_mcp_resource' => 'read_mcp_resource',
  'generate_image' => 'generate_image',
  _ when raw.startsWith('mcp_') || raw.startsWith('MCP') => 'mcp_tool',
  _ => 'tool',
};

String publicToolLabel(String tool) => switch (tool) {
  'web_search' => '联网搜索',
  'web_fetch' => '阅读网页',
  'execute_python' => '代码执行',
  'execute_shell' => '命令执行',
  'execute_skill_script' => '技能脚本',
  'use_skill' => '读取技能',
  'task_plan' => '核对交付要求',
  'read_skill_resource' => '读取技能资料',
  'read_task_material' => '读取附件',
  'read_mcp_resource' => '读取 MCP 文件',
  'generate_image' => '图片生成',
  'mcp_tool' => 'MCP 工具',
  'mcp_connection' => 'MCP 连接器',
  _ => '工具调用',
};

/// The only projection of runtime events allowed into the chat's custom state.
class PublicAgentProcess {
  PublicAgentProcess(this.turnId);
  final String turnId;
  final _rows = <Map<String, dynamic>>[];
  final _invocations = <Object, int>{};
  final _unscoped = <String, int>{};
  final _reasoning = <String, int>{};
  var _sequence = 0;

  List<Map<String, dynamic>> get rows =>
      _rows.map((row) => Map<String, dynamic>.from(row)).toList();

  Map<String, dynamic>? add(Map<String, Object?> event) {
    final type = event['type']?.toString() ?? '';
    if (type == 'reasoning_update') {
      final text = event['text']?.toString() ?? '';
      final id = event['reasoning_id']?.toString() ?? '';
      final revision = event['revision'];
      final status = event['status'];
      if (event['source'] != 'model_reasoning' ||
          id.isEmpty ||
          revision is! int ||
          revision < 1 ||
          text.trim().isEmpty ||
          !isPublicReasoning(text) ||
          !const {
            'running',
            'completed',
            'stopped',
            'incomplete',
          }.contains(status)) {
        return null;
      }
      final index = _reasoning[id];
      final fields = <String, dynamic>{
        'kind': 'reasoning',
        'type': type,
        'source': 'model_reasoning',
        'revision': revision,
        'status': status,
        'text': text,
      };
      if (index == null) {
        _reasoning[id] = _rows.length;
        return _insert(fields);
      }
      if (revision <= (_rows[index]['revision'] as int)) return null;
      final row = <String, dynamic>{..._rows[index], ...fields};
      _rows[index] = row;
      return row;
    }
    var tool = publicToolName(event['tool']?.toString() ?? '');
    if (type.startsWith('mcp_connection')) tool = 'mcp_connection';
    if (type == 'reading_material') tool = 'read_task_material';
    if (type == 'image_generation_started') tool = 'generate_image';
    final status = switch (type) {
      'tool_requested' ||
      'tool_started' ||
      'mcp_tool_started' ||
      'mcp_connection_started' ||
      'reading_material' ||
      'image_generation_started' => 'running',
      'tool_succeeded' ||
      'mcp_tool_succeeded' ||
      'mcp_connection_ready' => 'completed',
      'tool_failed' || 'mcp_tool_failed' => 'failed',
      'tool_cancelled' => 'stopped',
      'tool_skipped' => 'skipped',
      'tool_returned' =>
        const {
              'running',
              'completed',
              'waiting',
              'failed',
              'skipped',
              'incomplete',
            }.contains(event['status'])
            ? event['status']!.toString()
            : 'incomplete',
      'network_permission_required' ||
      'mcp_tool_approval_required' ||
      'permission_required' => 'waiting',
      'extension_execution_unverified' => 'incomplete',
      _ => null,
    };
    if (status == null) return null;
    final invocation = Zone.current[publicProcessInvocation];
    var index = invocation == null ? _unscoped[tool] : _invocations[invocation];
    // A new unscoped start after a terminal result is a new invocation.
    if (index != null &&
        invocation == null &&
        status == 'running' &&
        !_active(_rows[index]))
      index = null;
    if (index == null) {
      index = _rows.length;
      _insert({'kind': 'event', 'tool': tool});
      if (invocation == null) {
        _unscoped[tool] = index;
      } else {
        _invocations[invocation] = index;
      }
    }
    final previous = _rows[index];
    // Runtime failure/skip evidence beats the generic "tool returned" hook.
    if (type == 'tool_returned' && !_active(previous)) return null;
    final count = event['source_count'];
    final sourceCount = count is num && count.isFinite && count >= 0
        ? count.toInt()
        : null;
    final label = publicToolLabel(tool);
    final text = switch (status) {
      'running' => '正在$label',
      'waiting' => '等待操作确认',
      'completed' when tool == 'web_search' && sourceCount != null =>
        '搜索到 $sourceCount 个网页',
      'completed' => '已完成$label',
      'failed' => '$label未完成',
      'skipped' => '已跳过$label',
      'stopped' => '$label已停止',
      _ => '$label未完成',
    };
    final row = <String, dynamic>{
      ...previous,
      'tool': tool,
      'type': switch (status) {
        'completed' => 'tool_succeeded',
        'failed' => 'tool_failed',
        'skipped' => 'tool_skipped',
        _ => 'tool_started',
      },
      'status': status,
      'text': text,
      if (sourceCount != null) 'source_count': sourceCount,
    };
    _rows[index] = row;
    return row;
  }

  void finish(String status) {
    if (status == 'waiting') return;
    for (var index = 0; index < _rows.length; index++) {
      final row = _rows[index];
      if (!_active(row)) continue;
      final stopped = status == 'stopped';
      if (row['kind'] == 'reasoning') {
        _rows[index] = {
          ...row,
          'status': stopped ? 'stopped' : 'incomplete',
          'revision': (row['revision'] as int) + 1,
        };
        continue;
      }
      _rows[index] = {
        ...row,
        'status': stopped ? 'stopped' : 'incomplete',
        'text':
            '${publicToolLabel(row['tool']?.toString() ?? '')}${stopped ? '已停止' : '未完成'}',
      };
    }
  }

  bool _active(Map<String, dynamic> row) =>
      row['status'] == null ||
      row['status'] == 'running' ||
      row['status'] == 'waiting';

  Map<String, dynamic> _insert(Map<String, dynamic> fields) {
    final sequence = ++_sequence;
    final row = <String, dynamic>{
      'step_id': '$turnId:$sequence',
      'sequence': sequence,
      ...fields,
    };
    _rows.add(row);
    return row;
  }
}
