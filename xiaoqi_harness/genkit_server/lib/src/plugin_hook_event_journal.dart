import 'plugin_hook_output.dart';
import 'store.dart';
import 'tool_execution.dart';

/// A host-owned one-time lifecycle event or skill once handler. Keys and event
/// identities come from the runtime, never plugin output or model arguments.
class PluginHookEventJournal {
  PluginHookEventJournal(this.store, this.key);
  final CloudStore store;
  final String key;
  static final _running = <String>{};

  Future<PluginHookOutput?> run({
    required String invocation,
    required String inputBinding,
    required void Function() check,
    required Future<PluginHookOutput?> Function() execute,
    bool returnForLaterEvents = false,
  }) async {
    check();
    if (key.isEmpty || invocation.isEmpty || inputBinding.isEmpty) {
      throw StateError('hook 事件缺少宿主来源、原始身份或参数');
    }
    final runningKey = '${store.root.absolute.path}/$key';
    if (!_running.add(runningKey)) {
      throw UnconfirmedToolOperation('hook 的原事件仍在执行');
    }
    try {
      var claimed = false;
      for (var attempt = 0; attempt < 8; attempt++) {
        check();
        final saved = store.get(key);
        if (saved?.value['invocation'] == invocation &&
            saved?.value['input_binding'] != inputBinding) {
          throw StateError('hook 的原事件参数已变化');
        }
        if (saved?.value['phase'] == 'succeeded') {
          if (!returnForLaterEvents && saved?.value['invocation'] != invocation)
            return null;
          return PluginHookOutput.restore(saved!.value['result'] as Map);
        }
        if (saved?.value['phase'] == 'pending' &&
            saved?.value['invocation'] != invocation) {
          throw UnconfirmedToolOperation('hook 的原执行结果未确认');
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
      if (!claimed) throw StateError('hook 原事件竞争');
      final result = await execute();
      check();
      final saved = store.get(key)!;
      if (saved.value['invocation'] != invocation ||
          saved.value['phase'] != 'pending') {
        throw StateError('hook 的原事件已变化');
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
