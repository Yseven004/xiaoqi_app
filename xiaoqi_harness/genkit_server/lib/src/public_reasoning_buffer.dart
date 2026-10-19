/// This projection is deliberately separate from private model history. It
/// never rewrites reasoning or uses a second model to invent an explanation.
bool isPublicReasoning(
  String text, {
  Iterable<String> protectedValues = const [],
}) {
  if (protectedValues.any(
    (value) => value.length >= 6 && text.contains(value),
  )) {
    return false;
  }
  return !RegExp(
    r'system\s*(?:prompt|instruction)|developer\s*(?:prompt|instruction)|internal\s*(?:reasoning|configuration)|系统提示|系统指令|内部提示|内部推理|内部指令|开发者指令|'
    r'api[ _-]?key|access[ _-]?key|secret|bearer|password|\btokens?\b|密码|凭据|密钥|'
    r'环境变量|服务[端器]+配置|后端|内部[配参日路]|请求参数|原始日志|堆栈|文件路径|目录|\.env\b|\.pem\b|'
    r'[A-Z][A-Z0-9]+_[A-Z0-9_]+|[a-z]:[\\/]|/(?:opt|workspace|home|tmp|etc|var|usr|app|srv|root|data|mnt)/|'
    r'localhost|127\.0\.0\.1|\b10\.\d+\.\d+\.\d+|\b192\.168\.|\b172\.(?:1[6-9]|2\d|3[01])\.|'
    r'sk-[a-z0-9_-]+|eyJ[a-z0-9_-]+\.|'
    r'忽略.{0,20}(?:指令|规则)|(?:泄露|输出|展示).{0,20}(?:提示词|密钥|配置)|'
    r'ignore.{0,30}instructions|public_summary|准备阶段|准备完成|独立阶段|禁用工具|'
    r'<[/!]?[a-z][^>]*>|```|authorization\s*:|token\s*[:=]',
    caseSensitive: false,
  ).hasMatch(text);
}

/// Buffers complete sentences/paragraphs so a secret split across transport
/// chunks cannot be published a fragment at a time. A rejected sentence also
/// quarantines its paragraph (including a following credential value).
class PublicReasoningBuffer {
  PublicReasoningBuffer({
    required this.onUpdate,
    this.protectedValues = const [],
  });
  final void Function(String text, int revision, String status) onUpdate;
  final Iterable<String> protectedValues;
  String _raw = '';
  String _pending = '';
  String _visible = '';
  String _status = 'running';
  int _revision = 0;
  bool _quarantined = false;
  bool _ended = false;

  void add(String delta) {
    if (_ended || delta.isEmpty) return;
    _raw += delta;
    _pending += delta;
    final boundary = RegExp(r'[。！？!?]+[”’）)]*|\.(?=\s)|\n[ \t]*\n');
    while (true) {
      final match = boundary.firstMatch(_pending);
      if (match == null) break;
      final unit = _pending.substring(0, match.end);
      _pending = _pending.substring(match.end);
      _publishUnit(unit);
    }
  }

  void _publishUnit(String unit) {
    if (!isPublicReasoning(unit, protectedValues: protectedValues)) {
      _quarantined = true;
    }
    if (!_quarantined) {
      _visible += unit;
      _emit();
    }
    if (unit.contains(RegExp(r'\n[ \t]*\n'))) {
      if (_quarantined && _visible.isNotEmpty && !_visible.endsWith('\n\n')) {
        _visible += '\n\n';
      }
      _quarantined = false;
    }
  }

  void _emit({String? status}) {
    final changedStatus = status != null && status != _status;
    if (status != null) _status = status;
    if (_visible.trim().isEmpty) return;
    // A new revision always carries the cumulative public text, never a delta.
    if (changedStatus || status == null) {
      onUpdate(_visible.trim(), ++_revision, _status);
    }
  }

  /// A tool request or final-answer text establishes a semantic boundary even
  /// if the model did not end its reasoning with punctuation.
  void boundary() {
    if (_ended) return;
    if (_pending.isNotEmpty) _publishUnit(_pending);
    _pending = '';
    _emit(status: 'completed');
  }

  void finish({String finalText = '', String status = 'completed'}) {
    if (_ended) return;
    // Final responses are cumulative; reconcile only a missing suffix.
    if (status == 'completed' && finalText.startsWith(_raw)) {
      add(finalText.substring(_raw.length));
    }
    if (status == 'completed') boundary();
    _pending = ''; // Never flush a partial sensitive sentence on cancellation.
    _emit(status: status);
    _ended = true;
  }
}
