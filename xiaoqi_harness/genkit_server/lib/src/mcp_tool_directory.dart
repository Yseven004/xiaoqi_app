import 'dart:convert';

/// Keeps the complete discovered catalog outside the model's tool definitions.
/// Large connectors expose bounded search plus a schema-validated call gateway.
class McpToolDirectory {
  McpToolDirectory(Iterable<Map<String, dynamic>> tools) {
    for (final tool in tools) {
      final name = tool['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      if (_tools.containsKey(name)) {
        throw FormatException('MCP 工具目录包含重复名称：$name');
      }
      _tools[name] = Map<String, dynamic>.from(tool);
    }
  }

  final _tools = <String, Map<String, dynamic>>{};
  Iterable<Map<String, dynamic>> get tools => _tools.values;
  Map<String, dynamic>? lookup(String name) => _tools[name];

  Map<String, dynamic> search(String query, {int offset = 0, int limit = 5}) {
    if (offset < 0 || limit < 1 || limit > 8) {
      throw const FormatException('工具目录分页参数无效');
    }
    final terms = query
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    final matches =
        tools.where((tool) {
          final text = '${tool['name']} ${tool['description'] ?? ''}'
              .toLowerCase();
          return terms.every(text.contains);
        }).toList()..sort((a, b) {
          final exactA =
              a['name'].toString().toLowerCase() == query.toLowerCase().trim();
          final exactB =
              b['name'].toString().toLowerCase() == query.toLowerCase().trim();
          if (exactA != exactB) return exactA ? -1 : 1;
          return a['name'].toString().compareTo(b['name'].toString());
        });
    final page = matches.skip(offset).take(limit).toList();
    return {
      'total': matches.length,
      'offset': offset,
      'tools': [
        for (final tool in page)
          {
            'name': tool['name'],
            'description': tool['description'],
            'inputSchema': tool['inputSchema'],
          },
      ],
      if (offset + page.length < matches.length)
        'next_offset': offset + page.length,
    };
  }

  static List<Map<String, dynamic>> gatewayTools() => [
    {
      'name': 'search_tools',
      'description': '检索连接器完整工具目录，返回真实工具名和输入 schema。支持分页。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'maxLength': 500},
          'offset': {'type': 'integer', 'minimum': 0},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 8},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'call_tool',
      'description':
          '调用目录中的工具。先检索目录，提供精确 tool_name 和符合其 schema 的 arguments；权限按实际工具判断。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'tool_name': {'type': 'string', 'minLength': 1},
          'arguments': {'type': 'object', 'additionalProperties': true},
        },
        'required': ['tool_name', 'arguments'],
        'additionalProperties': false,
      },
    },
  ];
}

/// Publishes only a complete catalog read unaffected by list-change events.
/// Failed refreshes leave the old snapshot inaccessible until recovery succeeds.
class LiveMcpToolDirectory {
  LiveMcpToolDirectory(this.readTools);

  final Future<List<Map<String, dynamic>>> Function() readTools;
  McpToolDirectory? _current;
  Future<McpToolDirectory>? _loading;
  var _generation = 0;
  var _loadedGeneration = -1;
  var revision = 0;
  String? _contents;

  bool get stale => _loadedGeneration != _generation;
  void invalidate() => _generation++;

  Future<McpToolDirectory> load({bool force = false}) async {
    final loading = _loading;
    if (loading != null) return await loading;
    if (!force && !stale && _current != null) return _current!;
    // A failed forced read must not make the previous snapshot look current.
    invalidate();
    final pending = _reload();
    _loading = pending;
    try {
      return await pending;
    } finally {
      _loading = null;
    }
  }

  Future<McpToolDirectory> _reload() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final generation = _generation;
      final next = McpToolDirectory(await readTools());
      if (generation != _generation) continue;
      final contents = jsonEncode(next.tools.toList());
      if (contents != _contents) revision++;
      _contents = contents;
      _current = next;
      _loadedGeneration = generation;
      return next;
    }
    throw StateError('MCP 工具目录在读取时持续变化，请重新检索');
  }
}
