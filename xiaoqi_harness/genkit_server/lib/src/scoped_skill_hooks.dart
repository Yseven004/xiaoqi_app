import 'plugin_hooks.dart';
import 'plugin_hook_output.dart';
import 'store.dart';
import 'tool_execution.dart';

/// Task-owned skill registrations. Private child session IDs never activate a
/// parent's handlers. Only currently authorized, identical sources can reappear.
class ScopedSkillHooks {
  ScopedSkillHooks(this.store, this.tenant, this.task);
  final CloudStore store;
  final String tenant, task;
  static final _running = <String>{};

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
    final runningKey = '${store.root.absolute.path}/$key';
    if (!_running.add(runningKey)) {
      throw UnconfirmedToolOperation('技能 once hook 的原事件仍在执行');
    }
    try {
      var claimed = false;
      for (var attempt = 0; attempt < 8; attempt++) {
        check();
        final saved = store.get(key);
        if (saved?.value['invocation'] == invocation &&
            saved?.value['input_binding'] != inputBinding) {
          throw StateError('技能 once hook 的原事件参数已变化');
        }
        if (saved?.value['phase'] == 'succeeded') {
          if (saved?.value['invocation'] != invocation) return null;
          // Resume must keep the original rewrite/ask/context verdict, while a
          // distinct later event skips this once handler entirely.
          return PluginHookOutput.restore(saved!.value['result'] as Map);
        }
        if (saved?.value['phase'] == 'pending' &&
            saved?.value['invocation'] != invocation) {
          throw UnconfirmedToolOperation('技能 once hook 的原执行结果未确认');
        }
        try {
          store.put(key, {
            'phase': 'pending',
            'invocation': invocation,
            'input_binding': inputBinding,
          }, saved?.revision);
          claimed = true;
          break;
        } on RevisionConflict {
          continue;
        }
      }
      if (!claimed) throw StateError('技能 once hook 事件竞争');
      final result = await execute();
      check();
      final saved = store.get(key)!;
      if (saved.value['invocation'] != invocation ||
          saved.value['phase'] != 'pending') {
        throw StateError('技能 once hook 的原事件已变化');
      }
      store.put(key, {
        'phase': result?.successful == true ? 'succeeded' : 'ready',
        'invocation': invocation,
        'input_binding': inputBinding,
        if (result?.successful == true) 'result': result!.toJson(),
      }, saved.revision);
      return result;
    } finally {
      _running.remove(runningKey);
    }
  }
}
