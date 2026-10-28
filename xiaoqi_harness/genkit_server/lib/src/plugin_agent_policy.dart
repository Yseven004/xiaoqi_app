import 'dart:convert';
import 'package:genkit/genkit.dart';
import 'execution_limits.dart';
import 'plugin_agents.dart';
import 'tool_execution.dart';

/// Host translation only narrows the parent's tools. Plugin metadata is not a
/// grant, and a nested child cannot escape an ancestor's plan/dontAsk policy.
class PluginAgentPolicy {
  PluginAgentPolicy(
    this.tools,
    this.issues, {
    required this.readOnly,
    required this.dontAsk,
    required this.maxTurns,
  });
  final List<String> tools, issues;
  final bool readOnly, dontAsk;
  final int maxTurns;

  static const _control = {'set_task_deliverables'};
  static const _readTools = {
    'list_task_files',
    'read_task_text_file',
    'read_task_material',
    'read_skill_resource',
    'read_plugin_agent_resource',
    'read_plugin_command_resource',
    'read_mcp_resource',
    'search_plugin_agents',
    'search_plugin_commands',
    'use_skill',
    'web_search',
    'run_plugin_agent',
  };
  static const _mapping = <String, List<String>>{
    'Read': [
      'list_task_files',
      'read_task_text_file',
      'read_task_material',
      'read_skill_resource',
      'read_plugin_agent_resource',
      'read_plugin_command_resource',
    ],
    'Write': ['list_task_files', 'write_task_text_file'],
    'Edit': ['list_task_files', 'edit_task_text_file'],
    'Glob': ['list_task_files'],
    'Grep': [
      'read_task_text_file',
      'read_task_material',
      'read_skill_resource',
      'read_plugin_agent_resource',
      'read_plugin_command_resource',
    ],
    'Bash': ['execute_shell', 'execute_python', 'execute_skill_script'],
    'WebSearch': ['web_search'],
    'WebFetch': ['web_fetch'],
    'Skill': ['use_skill', 'read_skill_resource'],
    'Agent': ['search_plugin_agents', 'run_plugin_agent'],
    'Task': ['search_plugin_agents', 'run_plugin_agent'],
  };
  static const _denyMapping = <String, List<String>>{
    'Write': ['write_task_text_file'],
    'Edit': ['edit_task_text_file'],
    'Skill': ['use_skill'],
    'Agent': ['run_plugin_agent'],
    'Task': ['run_plugin_agent'],
  };

  static PluginAgentPolicy resolve(
    PluginAgentDefinition definition, {
    required Iterable<String> parentTools,
    required String model,
    bool ancestorReadOnly = false,
    bool ancestorDontAsk = false,
    ExecutionLimits limits = const ExecutionLimits(),
  }) {
    final available = parentTools
        .where((tool) => !_control.contains(tool))
        .toSet();
    final issues = <String>[];
    if (definition.model != 'inherit' && definition.model != model)
      issues.add('需要配置 Agent 指定的模型 ${definition.model}；不会静默替换当前模型');
    final metadata = definition.metadata;
    const known = {
      'name',
      'description',
      'tools',
      'disallowedTools',
      'model',
      'maxTurns',
      'permissionMode',
      'color',
      'skills',
      'mcpServers',
      'hooks',
      'memory',
      'background',
      'isolation',
    };
    for (final key in metadata.keys.where((key) => !known.contains(key)))
      issues.add('Agent 字段 $key 需要对应宿主适配');
    for (final key in [
      'skills',
      'mcpServers',
      'hooks',
      'memory',
      'isolation',
    ]) {
      final value = metadata[key];
      if (value != null &&
          value != '' &&
          !(value is List && value.isEmpty) &&
          !(value is Map && value.isEmpty))
        issues.add('Agent 的 $key 需要对应宿主配置');
    }
    if (metadata['background'] == true) issues.add('Agent 请求后台运行，需要后台会话适配');
    final mode = metadata['permissionMode'] ?? 'default';
    if (!const {
      'default',
      'acceptEdits',
      'dontAsk',
      'bypassPermissions',
      'plan',
    }.contains(mode))
      issues.add('Agent 权限模式 $mode 暂无宿主映射');
    final readOnly = ancestorReadOnly || mode == 'plan';
    final dontAsk =
        ancestorDontAsk ||
        const {'dontAsk', 'bypassPermissions', 'plan'}.contains(mode);
    Set<String> translate(Iterable<String> requested, {bool deny = false}) {
      final result = <String>{};
      for (final name in requested) {
        final mapped =
            (deny ? _denyMapping[name] : null) ??
            _mapping[name] ??
            (available.contains(name) ? [name] : const <String>[]);
        final found = mapped.where(available.contains).toSet();
        if (mapped.isEmpty || (!deny && found.isEmpty && !readOnly))
          issues.add('Agent 工具 $name 没有可用宿主映射');
        result.addAll(found);
      }
      return result;
    }

    final selected = definition.tools == null
        ? {...available}
        : translate(definition.tools!);
    selected.removeAll(translate(definition.disallowedTools, deny: true));
    if (readOnly)
      selected.removeWhere(
        (tool) => !_readTools.contains(tool) && !tool.startsWith('mcp_'),
      );
    return PluginAgentPolicy(
      selected.toList()..sort(),
      issues,
      readOnly: readOnly,
      dontAsk: dontAsk,
      maxTurns: (definition.maxTurns ?? limits.modelTurns).clamp(
        1,
        limits.modelTurns,
      ),
    );
  }
}

class PluginAgentGuard extends GenerateMiddleware {
  PluginAgentGuard({
    required this.owner,
    required this.policy,
    required this.validateSource,
    required this.cancellation,
    required this.onEvent,
  });
  final ToolExecution owner;
  final PluginAgentPolicy policy;
  final void Function() validateSource;
  final CancellationToken cancellation;
  final void Function(Map<String, dynamic>) onEvent;
  void check() {
    cancellation.throwIfCancelled();
    owner.check('read');
    validateSource();
  }

  @override
  Future<ModelResponse> model(
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    Future<ModelResponse> Function(
      ModelRequest,
      ActionFnArg<ModelResponseChunk, ModelRequest, void>,
    )
    next,
  ) {
    check();
    return next(request, ctx);
  }

  @override
  Future<ToolResult> tool(
    ToolRequestPart request,
    ActionFnArg<void, dynamic, void> ctx,
    Future<ToolResult> Function(
      ToolRequestPart,
      ActionFnArg<void, dynamic, void>,
    )
    next,
  ) async {
    check();
    final name = request.toolRequest.name;
    if (!policy.tools.any(
      (allowed) => name == allowed || name == '/tool/$allowed',
    )) {
      onEvent({
        'type': 'tool_skipped',
        'tool': name,
        'reason': 'agent_tool_restricted',
      });
      return ToolResult.response(
        jsonEncode({
          'ok': false,
          'status': 'denied',
          'error': '此工具不在当前 Agent 的任务权限范围内',
        }),
      );
    }
    final result = await ToolExecution.withAuthorityCheck(
      validateSource,
      () => next(request, ctx),
    );
    if (policy.dontAsk && result is ToolInterruptResult) {
      final data = result.data;
      final label = data is Map && data['type'] == 'mcp_tool_approval'
          ? 'MCP · ${data['connection_name']} · ${data['tool_name']}'
          : name;
      onEvent({
        'type': 'tool_skipped',
        'tool': label,
        'reason': 'agent_permission_mode',
      });
      return ToolResult.response(
        jsonEncode({
          'ok': false,
          'status': 'denied',
          'error': 'Agent 权限模式不申请新授权；已有任务授权仍有效，未授权动作没有执行',
        }),
      );
    }
    return result;
  }
}
