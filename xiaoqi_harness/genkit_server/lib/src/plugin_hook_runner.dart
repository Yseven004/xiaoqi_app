import 'dart:convert';
import 'package:genkit/genkit.dart';
import 'code_execution_service.dart';
import 'plugin_hooks.dart';
import 'plugin_hook_command.dart';
import 'plugin_hook_output.dart';
import 'tool_execution.dart';

/// Runs a source-bound command through the existing isolated code pipeline.
/// Source binding and original event identity come from the host, not a model.
/// Lifecycle dispatch is deliberately separate from this execution adapter.
class PluginHookRunner {
  PluginHookRunner(this.executor);
  final DockerCodeExecutionService executor;

  Future<PluginHookOutput?> run({
    required ToolExecution execution,
    required PluginHook hook,
    required String sourceBinding,
    required String invocation,
    required Map<String, dynamic> input,
    required String matchValue,
    required Map<String, List<int>> Function() sourceFiles,
    required CancellationToken cancellation,
    List<Map<String, dynamic>> materials = const [],
  }) async {
    void validateSource() {
      cancellation.throwIfCancelled();
      if (!execution.contract.executesWorkflow) {
        throw StateError('只读回答阶段不运行插件工作流 hook');
      }
      sourceFiles(); // Revalidate enabled state and exact immutable version.
    }

    void check() {
      execution.check('workspace');
      validateSource();
    }

    check();
    if (PluginHookCommand.trivialMatch(hook.matcher, matchValue) == false)
      return null;
    if (sourceBinding.isEmpty || invocation.isEmpty) {
      throw StateError('hook 必须绑定原始来源及事件调用');
    }
    final issue = PluginHookCommand.unsupported(hook);
    if (issue != null) throw StateError(issue);
    // Once-only skill hooks need a session lifecycle binding. Do not silently
    // reinterpret them as once per tool call or reuse a different input hash.
    if (hook.config['once'] == true) {
      throw StateError('once hook 尚需会话生命周期映射');
    }
    final snapshot = jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
    final code = PluginHookCommand.program(
      hook,
      snapshot,
      matchValue: matchValue,
    );
    final result = await ToolExecution.withAuthorityCheck(
      validateSource,
      () => execution.authorizedCode(
        slot: 'plugin-hook:$sourceBinding:${hook.id}:$invocation',
        arguments: {
          'source_binding': sourceBinding,
          'source_path': hook.sourcePath,
          'pointer': hook.pointer,
          'event': hook.event,
          'config': hook.config,
          'matcher': hook.matcher,
          'input': snapshot,
          'match_value': matchValue,
        },
        effectsPossible: (error) => error is SandboxExecutionError,
        invoke: (operationId) async {
          final files = sourceFiles();
          final output = await executor.execute(
            tenantId: execution.tenantId,
            taskId: execution.taskId,
            code: code,
            language: 'javascript',
            profile: snapshot['permission_mode'] == 'plan'
                ? SandboxExecutionProfile.pluginHookReadOnly
                : SandboxExecutionProfile.pluginHook,
            // A plugin declaration never adds network access. Hook HTTP and
            // prompt handlers will need their own exact action authorization.
            authorizedDomains: const [],
            materials: materials,
            skillFiles: files,
            cancellation: cancellation,
            beforeSubmit: check,
            scopeOperationId: operationId,
          );
          return {'ok': true, 'output': output};
        },
      ),
    );
    check();
    // execute() adds artifact descriptions after stdout. The launcher emits
    // one envelope line; source command stdout/stderr are JSON-escaped inside.
    final Map<String, dynamic> output;
    try {
      output = PluginHookCommand.result(
        (result['output'] as String).split('\n').first,
      );
    } on FormatException {
      return PluginHookOutput.parse(
        event: hook.event,
        exitCode: null,
        stdout: '',
        stderr: 'hook 执行未返回有效协议结果',
        failureBlocks: hook.config['onFailure'] == 'block',
      );
    }
    if (output['matched'] == false && output['stderr'] == '') return null;
    return PluginHookOutput.parse(
      event: hook.event,
      exitCode: output['exit_code'] as int?,
      stdout: output['stdout'] as String,
      stderr: output['stderr'] as String,
      timedOut: output['timed_out'] == true,
      failureBlocks: hook.config['onFailure'] == 'block',
    );
  }
}
