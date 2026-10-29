import 'dart:async';
import 'dart:convert';
import 'package:genkit/genkit.dart';
import 'plugin_hook_output.dart';
import 'plugin_hook_tool_journal.dart';
import 'tool_execution.dart';

/// Task-local shared state across parent and delegated Agent middleware.
class PluginHookControl {
  String? stopReason;
  static final _ask = Object();
  static bool get asksPermission => Zone.current[_ask] == true;
}

/// A source protocol view of one host tool. Rewrites stay on this same tool;
/// the SDK subsequently validates its input schema and its native handler
/// recomputes the current action authorization using the changed arguments.
class PluginHookTool {
  PluginHookTool(this.name, this.input, this.rewrite, {this.canAsk = false});
  final String name;
  final Map<String, dynamic> input;
  final Map<String, dynamic> Function(Map<String, dynamic>) rewrite;
  final bool canAsk;

  static PluginHookTool native(String name, Map<String, dynamic> input) {
    final short = name.split('/').last;
    final fields = switch (short) {
      'write_task_text_file' => const {'path': 'file_path', 'text': 'content'},
      'read_task_text_file' => const {'path': 'file_path'},
      'execute_shell' => const {'code': 'command'},
      _ => const <String, String>{},
    };
    final canonical = Map<String, dynamic>.from(input);
    for (final entry in fields.entries) {
      if (canonical.containsKey(entry.key)) {
        canonical[entry.value] = canonical.remove(entry.key);
      }
    }
    return PluginHookTool(
      switch (short) {
        'write_task_text_file' => 'Write',
        'read_task_text_file' => 'Read',
        'execute_shell' => 'Bash',
        _ => short,
      },
      canonical,
      (updates) {
        final rewritten = {...canonical, ...updates};
        for (final entry in fields.entries) {
          if (updates.containsKey(entry.key)) {
            throw StateError('hook 改写需要使用源协议字段 ${entry.value}');
          }
          if (rewritten.containsKey(entry.value)) {
            rewritten[entry.key] = rewritten.remove(entry.value);
          }
        }
        return rewritten;
      },
    );
  }
}

typedef PluginHookDispatch =
    Future<List<PluginHookOutput>> Function(
      String event,
      String invocation,
      Map<String, dynamic> input,
    );

class PluginHookMiddleware extends GenerateMiddleware {
  PluginHookMiddleware({
    required this.execution,
    required this.dispatch,
    required this.describe,
    required this.checkSources,
    required this.control,
    required this.hasHooks,
    required this.validateInput,
  });
  final ToolExecution Function() execution;
  final PluginHookDispatch dispatch;
  final PluginHookTool Function(String, Map<String, dynamic>) describe;
  final void Function(PluginHookTool) checkSources;
  final PluginHookControl control;
  final bool Function(PluginHookTool) hasHooks;
  final Future<bool> Function(String, Object?) validateInput;

  void check() {
    execution().check('read');
    if (control.stopReason != null) throw StateError(control.stopReason!);
  }

  @override
  Future<ModelResponse> model(
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> context,
    Future<ModelResponse> Function(
      ModelRequest,
      ActionFnArg<ModelResponseChunk, ModelRequest, void>,
    )
    next,
  ) {
    check();
    return next(request, context);
  }

  @override
  Future<ToolResult> tool(
    ToolRequestPart request,
    ActionFnArg<void, dynamic, void> context,
    Future<ToolResult> Function(
      ToolRequestPart,
      ActionFnArg<void, dynamic, void>,
    )
    next,
  ) async {
    check();
    final owner = execution();
    if (!owner.contract.executesWorkflow) return next(request, context);
    final original = request.toolRequest.input;
    if (original is! Map) return next(request, context);
    var input = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(original)) as Map,
    );
    var view = describe(request.toolRequest.name, input);
    if (!hasHooks(view)) return next(request, context);
    checkSources(view);
    final readOnly = context.context?['xiaoqi_plugin_agent_read_only'] == true;
    final ref = request.toolRequest.ref;
    // A missing ref cannot be guessed from arguments: two identical fresh
    // calls are distinct events while a resume must retain its original ID.
    if (ref == null || ref.isEmpty) {
      throw StateError('插件 hook 缺少原始工具事件标识，未提交目标工具');
    }
    final eventId = ToolExecution.digest([
      context.context?['xiaoqi_plugin_agent_invocation'],
      ref,
    ]);
    Map<String, dynamic> payload() => {
      'session_id': owner.taskId,
      'cwd': '/workspace/work',
      'permission_mode': readOnly ? 'plan' : 'default',
      'tool_name': view.name,
      'tool_input': view.input,
      'tool_use_id': ref,
    };
    final contexts = <String>[];
    var ask = false;
    final pre = await dispatch('PreToolUse', '$eventId:pre', payload());
    for (final result in pre) {
      if (result.additionalContext case final String value) contexts.add(value);
      if (result.stopProcessing)
        control.stopReason = result.reason ?? '插件 hook 已停止此任务';
      if (result.preventAction || result.stopProcessing) {
        return ToolResult.response(
          jsonEncode({
            'ok': false,
            'status': 'hook_denied',
            'retryable': false,
            'error': result.reason ?? '插件 hook 阻止了此工具调用',
            if (contexts.isNotEmpty) 'plugin_hook_context': contexts,
          }),
        );
      }
      if (result.permission == 'defer' ||
          (result.permission == 'ask' && !view.canAsk)) {
        return ToolResult.response(
          jsonEncode({
            'ok': false,
            'status': 'hook_mapping_unavailable',
            'retryable': false,
            'error': '此宿主工具尚未提供 hook ${result.permission} 对应流程，未执行目标工具',
          }),
        );
      }
      ask |= result.permission == 'ask';
      if (result.updatedInput != null) {
        input = view.rewrite(result.updatedInput!);
        view = describe(request.toolRequest.name, input);
      }
    }
    check();
    if (!await validateInput(request.toolRequest.name, input)) {
      await dispatch('PostToolUseFailure', '$eventId:failure', {
        ...payload(),
        'error': '参数不符合当前工具 schema',
        'is_interrupt': false,
      });
      return ToolResult.response(
        jsonEncode({
          'ok': false,
          'status': 'invalid_arguments',
          'retryable': true,
          'error': '参数不符合当前工具 schema，未提交目标工具',
        }),
      );
    }
    check();
    checkSources(view);
    final effective = ToolRequestPart.fromJson(
      jsonDecode(jsonEncode(request.toJson())) as Map<String, dynamic>,
    );
    effective.toolRequest.input = input;
    final ToolResult result;
    try {
      result = await ToolExecution.withAuthorityCheck(
        () => checkSources(view),
        () => PluginHookToolJournal(owner).run(
          invocation: eventId,
          arguments: {'tool': request.toolRequest.name, 'input': input},
          resumed: request.metadata?['resumed'] != null,
          invoke: () => runZoned(
            () => next(effective, context),
            zoneValues: {
              PluginHookControl._ask: ask || PluginHookControl.asksPermission,
            },
          ),
        ),
      );
    } on Object catch (error) {
      // Source withdrawal, cancellation and budget checks still terminate the
      // original call. Post-failure feedback cannot authorize its replay.
      check();
      await dispatch('PostToolUseFailure', '$eventId:failure', {
        ...payload(),
        'error': error.runtimeType.toString(),
        'is_interrupt': context.cancel?.isCancelled == true,
      });
      rethrow;
    }
    if (result is ToolInterruptResult) return result;
    check();
    final response = result as ToolResponseResult;
    Object? output = response.output;
    Object? structured = output;
    if (output is String) {
      try {
        structured = jsonDecode(output);
      } on FormatException {
        /* plain text */
      }
    }
    final failed =
        structured is Map &&
        (structured['ok'] == false || structured['isError'] == true);
    final post = await dispatch(
      failed ? 'PostToolUseFailure' : 'PostToolUse',
      '$eventId:${failed ? 'failure' : 'post'}',
      {
        ...payload(),
        if (failed) 'error': structured else 'tool_response': structured,
        if (failed) 'is_interrupt': false,
      },
    );
    var replaced = false;
    for (final hook in post) {
      if (hook.additionalContext case final String value) contexts.add(value);
      if (hook.stopProcessing)
        control.stopReason = hook.reason ?? '插件 hook 已停止此任务';
      if (hook.hasUpdatedToolOutput &&
          (!hook.mcpOnlyOutput || view.name.startsWith('mcp__'))) {
        output = response.output is String && hook.updatedToolOutput is! String
            ? jsonEncode(hook.updatedToolOutput)
            : hook.updatedToolOutput;
        replaced = true;
      }
    }
    checkSources(view);
    if (!replaced && contexts.isEmpty) return result;
    if (contexts.isNotEmpty) {
      if (output is String) {
        try {
          final map = jsonDecode(output);
          output = map is Map
              ? jsonEncode({...map, 'plugin_hook_context': contexts})
              : '$output\n\n插件 hook 上下文：\n${contexts.join('\n')}';
        } on FormatException {
          output = '$output\n\n插件 hook 上下文：\n${contexts.join('\n')}';
        }
      }
    }
    return ToolResult.response(
      output,
      parts: replaced ? null : response.parts,
      metadata: response.metadata,
    );
  }
}
