import 'dart:async';

/// Correlates runtime evidence with the invocation enclosing it, including
/// concurrent calls of the same tool. Never serialized to the client.
const publicProcessInvocation = #xiaoqiPublicProcessInvocation;

String publicToolName(String raw) => switch (raw.split('/').last) {
  'web_search' => 'web_search',
  'web_fetch' => 'web_fetch',
  'execute_python' => 'execute_python',
  'execute_skill_script' => 'execute_skill_script',
  'use_skill' => 'use_skill',
  'read_skill_resource' => 'read_skill_resource',
  'read_task_material' => 'read_task_material',
  'generate_image' => 'generate_image',
  _ when raw.startsWith('mcp_') || raw.startsWith('MCP') => 'mcp_tool',
  _ => 'tool',
};

String publicToolLabel(String tool) => switch (tool) {
  'web_search' => '联网搜索',
  'web_fetch' => '阅读网页',
  'execute_python' => '代码执行',
  'execute_skill_script' => '技能脚本',
  'use_skill' => '读取技能',
  'read_skill_resource' => '读取技能资料',
  'read_task_material' => '读取附件',
  'generate_image' => '图片生成',
  'mcp_tool' => 'MCP 工具',
  'mcp_connection' => 'MCP 连接',
  _ => '工具调用',
};

/// Reject the whole public paragraph, rather than replacing a keyword and
/// accidentally retaining its value. Called only after a complete block.
String? publicProcessSummary(String raw) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty ||
      text.length > 480 ||
      !RegExp(r'[\u3400-\u9fff]').hasMatch(text))
    return null;
  final privateContent = RegExp(
    r'system\s*prompt|系统提示|系统指令|内部提示|内部指令|开发者指令|'
    r'api[ _-]?key|access[ _-]?key|secret|token|bearer|password|密码|凭据|密钥|'
    r'环境变量|服务[端器]+配置|后端|内部[配参日路]|请求参数|原始日志|堆栈|文件路径|目录|\.env\b|\.pem\b|'
    r'[A-Z][A-Z0-9]+_[A-Z0-9_]+|[a-z]:[\\/]|/(?:opt|workspace|home|tmp|etc|var|usr)/|'
    r'https?://|localhost|127\.0\.0\.1|\b10\.\d+\.\d+\.\d+|\b192\.168\.|'
    r'sk-[a-z0-9_-]+|eyJ[a-z0-9_-]+\.|'
    r'忽略.{0,12}(?:指令|规则)|(?:泄露|输出|展示).{0,12}(?:提示词|密钥|配置)|'
    r'ignore.{0,20}instructions|<|>|```|\{|\}',
    caseSensitive: false,
  );
  if (privateContent.hasMatch(text)) return null;
  final sentences = RegExp(r'[^。！？!?]+[。！？!?]').allMatches(text).toList();
  if (sentences.isEmpty) return null;
  return sentences.take(3).map((match) => match.group(0)!.trim()).join();
}

/// Accepts explicitly authored public explanations, never ReasoningPart text.
class PublicSummaryBuffer {
  PublicSummaryBuffer(this.onSummary);
  final void Function(String) onSummary;
  var _buffer = '';
  var _sentenceCount = 0;
  final _published = <String>{};

  void add(String delta) {
    _buffer += delta;
    const start = '<public_summary>';
    const end = '</public_summary>';
    while (true) {
      final begin = _buffer.indexOf(start);
      if (begin < 0) {
        // Keep only enough to recognize an opening tag split across chunks.
        if (_buffer.length > start.length) {
          _buffer = _buffer.substring(_buffer.length - start.length);
        }
        return;
      }
      if (begin > 0) _buffer = _buffer.substring(begin);
      final close = _buffer.indexOf(end, start.length);
      if (close < 0) {
        if (_buffer.length > 4096) _buffer = '';
        return;
      }
      final summary = publicProcessSummary(
        _buffer.substring(start.length, close),
      );
      _buffer = _buffer.substring(close + end.length);
      if (summary != null && _sentenceCount < 3 && _published.add(summary)) {
        final sentences = RegExp(
          r'[^。！？!?]+[。！？!?]',
        ).allMatches(summary).take(3 - _sentenceCount).toList();
        _sentenceCount += sentences.length;
        onSummary(sentences.map((match) => match.group(0)).join());
      }
    }
  }
}

/// The only projection of runtime events allowed into the chat's custom state.
class PublicAgentProcess {
  PublicAgentProcess(this.turnId);
  final String turnId;
  final _rows = <Map<String, dynamic>>[];
  final _invocations = <Object, int>{};
  final _unscoped = <String, int>{};
  var _sequence = 0;

  List<Map<String, dynamic>> get rows =>
      _rows.map((row) => Map<String, dynamic>.from(row)).toList();

  Map<String, dynamic>? add(Map<String, Object?> event) {
    final type = event['type']?.toString() ?? '';
    if (type == 'reasoning_update') {
      final text = publicProcessSummary(event['text']?.toString() ?? '');
      if (text == null) return null;
      final counts = RegExp(r'(\d+)\s*个?\s*(?:网页|页面|来源)').allMatches(text);
      if (counts.any(
        (match) => !_rows.any(
          (row) =>
              row['status'] == 'completed' &&
              row['source_count'] == int.tryParse(match.group(1)!),
        ),
      ))
        return null;
      return _insert({
        'kind': 'reasoning',
        'type': type,
        'status': 'completed',
        'text': text,
      });
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
