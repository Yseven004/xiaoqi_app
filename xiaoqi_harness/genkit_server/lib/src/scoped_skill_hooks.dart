import 'plugin_hooks.dart';
import 'plugin_hook_output.dart';
import 'store.dart';
import 'tool_execution.dart';
import 'plugin_hook_event_journal.dart';

/// Task-owned skill registrations. Private child session IDs never activate a
/// parent's handlers. Only currently authorized, identical sources can reappear.
class ScopedSkillHooks {
  ScopedSkillHooks(this.store, this.tenant, this.task);
  final CloudStore store;
  final String tenant, task;

  String _key(String session) =>
      'private_skill_hooks/$tenant/$task/${ToolExecution.digest(session)}';

  void activate(String session, String alias, String binding) {
    if (session.isEmpty || alias.isEmpty || binding.isEmpty) {
      throw StateError('技能 hook 注册缺少会话或不可变来源');
    }
    final key = _key(session);
    for (var attempt = 0; attempt < 8; attempt++) {
      final saved = store.get(key);
      final sources = Map<String, dynamic>.from(
        saved?.value['sources'] as Map? ?? const {},
      );
      if (sources[alias] == binding) return;
      if (!sources.containsKey(alias) && sources.length >= 128) {
        throw StateError('此会话的技能 hook 来源超过 128 个');
      }
      sources[alias] = binding;
      try {
        store.put(key, {'sources': sources}, saved?.revision);
        return;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('技能 hook 注册冲突');
  }

  List<String> active(String session, Map<String, String> currentBindings) {
    final sources =
        store.get(_key(session))?.value['sources'] as Map? ?? const {};
    return [
      for (final entry in sources.entries)
        if (currentBindings[entry.key] == entry.value) entry.key as String,
    ];
  }

  /// A pending once effect survives restart. Only its original invocation can
  /// recover it; a new event cannot blindly rerun an uncertain previous effect.
  Future<PluginHookOutput?> run({
    required String session,
    required String binding,
    required PluginHook hook,
    required String invocation,
    required String inputBinding,
    required void Function() check,
    required Future<PluginHookOutput?> Function() execute,
  }) async {
    check();
    if (hook.config['once'] != true) return execute();
    if (session.isEmpty ||
        binding.isEmpty ||
        invocation.isEmpty ||
        inputBinding.isEmpty) {
      throw StateError('技能 once 缺少原始会话、来源或事件');
    }
    final key =
        '${_key(session)}/once/${ToolExecution.digest([binding, hook.id])}';
    return PluginHookEventJournal(store, key).run(
      invocation: invocation,
      inputBinding: inputBinding,
      check: check,
      execute: execute,
    );
  }
}
