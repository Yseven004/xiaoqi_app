import 'package:genkit/genkit.dart';
import 'code_execution_service.dart';
import 'plugin_hook_catalog.dart';
import 'plugin_hook_background.dart';
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
    this.background,
  });
  final CloudStore store;
  final SelectedPluginHooks catalog;
  final DockerCodeExecutionService executor;
  final Iterable<String> Function() aliases;
  final void Function(Map<String, Object?>) onEvent;
  final PluginHookBackground? background;
  final _results = <String, (String, PluginHookOutput?)>{};

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
        final saved = _results[cache]!;
        if (saved.$1 != ToolExecution.digest(input))
          throw StateError('生命周期原事件参数已变化');
        result = saved.$2;
      } else {
        onEvent({
          'type': 'tool_started',
          'tool': 'plugin_hook',
          'capability_name': catalog.entries[id]!['plugin_name'],
          'hook_event': event,
        });
        Future<PluginHookOutput?> command() => PluginHookRunner(executor).run(
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
        Future<PluginHookOutput?> execute() => background == null
            ? command()
            : background!.run(
                hook: hook,
                identity: cache,
                requestIdentity: execution.requestIdentity,
                descriptor: {
                  'kind': 'root',
                  'alias': id,
                  'binding': binding,
                  'invocation': invocation,
                  'input': {...input, 'hook_event_name': event},
                  'match': match,
                  'materials': materials,
                },
                execute: command,
                check: checkSource,
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
        _results[cache] = (ToolExecution.digest(input), result);
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

  /// The task Agent exits its tool/work phase before the separate, tool-free
  /// final presentation model runs. A veto continues that same authorized chat.
  Future<List<String>> beforeExit({
    required ToolExecution execution,
    required String eventIdentity,
    required String lastAssistantMessage,
    required CancellationToken cancellation,
    required List<Map<String, dynamic>> materials,
  }) async {
    if (!execution.contract.executesWorkflow || !has('Stop')) return const [];
    execution.check('workspace');
    cancellation.throwIfCancelled();
    final key =
        'private_plugin_lifecycle/${execution.tenantId}/${execution.taskId}/stop/${ToolExecution.digest(execution.requestIdentity)}';
    final event = ToolExecution.digest(eventIdentity);
    bool? active;
    for (var attempt = 0; attempt < 8; attempt++) {
      final saved = store.get(key);
      final events = Map<String, dynamic>.from(
        saved?.value['events'] as Map? ?? const {},
      );
      if (events.containsKey(event)) {
        active = events[event] as bool;
        break;
      }
      if (events.length >= 512) throw StateError('任务结束事件超过资源限制');
      final value = saved?.value['active'] == true;
      events[event] = value;
      try {
        store.put(key, {'active': value, 'events': events}, saved?.revision);
        active = value;
        break;
      } on RevisionConflict {
        continue;
      }
    }
    if (active == null) throw StateError('任务结束事件竞争');
    final results = await dispatch(
      event: 'Stop',
      eventIdentity: eventIdentity,
      execution: execution,
      input: {
        'session_id': execution.taskId,
        'cwd': '/workspace/work',
        'permission_mode': 'default',
        'stop_hook_active': active,
        'last_assistant_message': lastAssistantMessage,
        'host_phase': 'task_execution_exit',
      },
      cancellation: cancellation,
      materials: materials,
    );
    final feedback = <String>[];
    for (final result in results) {
      if (result.stopProcessing)
        throw StateError(result.reason ?? '插件结束检查停止了任务');
      if (result.continueLoop)
        feedback.add(
          result.additionalContext ?? result.reason ?? '插件结束检查要求继续处理当前任务',
        );
    }
    if (feedback.isNotEmpty) {
      noteStopContinuation(execution, cancellation);
    }
    return feedback;
  }

  void noteStopContinuation(
    ToolExecution execution,
    CancellationToken cancellation,
  ) {
    final key =
        'private_plugin_lifecycle/${execution.tenantId}/${execution.taskId}/stop/${ToolExecution.digest(execution.requestIdentity)}';
    for (var attempt = 0; attempt < 8; attempt++) {
      execution.check('workspace');
      cancellation.throwIfCancelled();
      final saved = store.get(key)!;
      if (saved.value['active'] == true) break;
      try {
        store.put(key, {...saved.value, 'active': true}, saved.revision);
        break;
      } on RevisionConflict {
        if (attempt == 7) rethrow;
      }
    }
  }
}
