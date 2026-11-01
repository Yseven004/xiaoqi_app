import 'package:genkit/genkit.dart';
import 'code_execution_service.dart';
import 'plugin_hook_catalog.dart';
import 'plugin_hook_command.dart';
import 'plugin_hook_event_journal.dart';
import 'plugin_hook_output.dart';
import 'plugin_hook_runner.dart';
import 'store.dart';
import 'tool_execution.dart';

/// Logical task lifecycle, separate from individual SDK tool requests. A root
/// event never borrows an invented tool ref or a private child's identity.
class PluginHookLifecycle {
  PluginHookLifecycle({
    required this.store,
    required this.catalog,
    required this.executor,
    required this.aliases,
    required this.onEvent,
  });
  final CloudStore store;
  final SelectedPluginHooks catalog;
  final DockerCodeExecutionService executor;
  final Iterable<String> Function() aliases;
  final void Function(Map<String, Object?>) onEvent;
  final _results = <String, PluginHookOutput?>{};

  bool has(String event) =>
      aliases().any((id) => catalog.definition(id).event == event);

  Future<List<PluginHookOutput>> dispatch({
    required String event,
    required String eventIdentity,
    required ToolExecution execution,
    required Map<String, dynamic> input,
    required CancellationToken cancellation,
    required List<Map<String, dynamic>> materials,
  }) async {
    if (!execution.contract.executesWorkflow) return const [];
    void check() {
      cancellation.throwIfCancelled();
      execution.check('workspace');
      if (!execution.contract.executesWorkflow)
        throw StateError('当前阶段不执行生命周期 hook');
    }

    check();
    final results = <PluginHookOutput>[];
    for (final id in aliases().toList()) {
      final hook = catalog.definition(id);
      if (hook.event != event || PluginHookCommand.unsupported(hook) != null)
        continue;
      final binding = catalog.fingerprint(id);
      final match = event == 'SessionStart' ? input['source'].toString() : '';
      if (PluginHookCommand.trivialMatch(hook.matcher, match) == false)
        continue;
      final invocation = ToolExecution.digest([
        execution.requestIdentity,
        event,
        eventIdentity,
      ]);
      final cache = ToolExecution.digest([binding, hook.id, invocation]);
      void checkSource() {
        check();
        catalog.files(id);
      }

      checkSource();
      PluginHookOutput? result;
      if (_results.containsKey(cache)) {
        result = _results[cache];
      } else {
        onEvent({
          'type': 'tool_started',
          'tool': 'plugin_hook',
          'capability_name': catalog.entries[id]!['plugin_name'],
          'hook_event': event,
        });
        Future<PluginHookOutput?> execute() => PluginHookRunner(executor).run(
          execution: execution,
          hook: hook,
          sourceBinding: binding,
          invocation: invocation,
          input: {...input, 'hook_event_name': event},
          matchValue: match,
          sourceFiles: () => catalog.files(id),
          cancellation: cancellation,
          materials: materials,
        );
        result = event == 'SessionStart'
            ? await PluginHookEventJournal(
                store,
                'private_plugin_lifecycle/${execution.tenantId}/${execution.taskId}/startup/${ToolExecution.digest([binding, hook.id])}',
              ).run(
                invocation: invocation,
                inputBinding: ToolExecution.digest(input),
                check: checkSource,
                execute: execute,
                returnForLaterEvents: true,
              )
            : await execute();
        checkSource();
        _results[cache] = result;
        onEvent({
          'type': result == null
              ? 'tool_skipped'
              : result.error == null
              ? 'tool_succeeded'
              : 'tool_failed',
          'tool': 'plugin_hook',
          'capability_name': catalog.entries[id]!['plugin_name'],
          'hook_event': event,
          if (result?.systemMessage != null) 'message': result!.systemMessage,
          if (result?.error != null) 'message': result!.error,
        });
      }
      if (result != null) results.add(result);
      if (result?.preventAction == true || result?.stopProcessing == true)
        break;
    }
    check();
    return results;
  }

  Future<List<String>> beforeTurn({
    required ToolExecution execution,
    required String prompt,
    required String model,
    required CancellationToken cancellation,
    required List<Map<String, dynamic>> materials,
  }) async {
    final context = <String>[];
    for (final event in const ['SessionStart', 'UserPromptSubmit']) {
      final results = await dispatch(
        event: event,
        eventIdentity: 'logical-turn',
        execution: execution,
        input: {
          'session_id': execution.taskId,
          'cwd': '/workspace/work',
          'permission_mode': 'default',
          if (event == 'SessionStart') ...{'source': 'startup', 'model': model},
          if (event == 'UserPromptSubmit') 'prompt': prompt,
        },
        cancellation: cancellation,
        materials: materials,
      );
      for (final result in results) {
        if (result.preventAction || result.stopProcessing) {
          throw StateError(result.reason ?? '插件生命周期 hook 阻止了当前任务');
        }
        if (result.additionalContext case final String value)
          context.add(value);
      }
    }
    return context;
  }
}
