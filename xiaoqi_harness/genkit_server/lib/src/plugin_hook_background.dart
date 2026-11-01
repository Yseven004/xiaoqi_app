import 'dart:async';
import 'plugin_hooks.dart';
import 'plugin_hook_output.dart';
import 'store.dart';
import 'tool_execution.dart';

/// Task-owned background work. Execution still uses the original durable code
/// operation, source checks, cancellation token and cumulative task budget.
class PluginHookBackground {
  PluginHookBackground(this.store, this.tenant, this.task, {this.onEvent});
  final void Function(Map<String, Object?>)? onEvent;
  final CloudStore store;
  final String tenant, task;
  String get _prefix => 'private_background_hooks/$tenant/$task/';
  final _jobs = <String, Future<void>>{};
  final _tails = <String, Future<void>>{};
  final _checks = <String, void Function()>{};
  final _messages = <String>[];
  final _ready = <String>{};
  Object? _failure;
  StackTrace? _stack;

  Future<PluginHookOutput?> run({
    required PluginHook hook,
    required String identity,
    required String requestIdentity,
    required Map<String, dynamic> descriptor,
    required Future<PluginHookOutput?> Function() execute,
    required void Function() check,
  }) async {
    if (hook.config['async'] != true && hook.config['asyncRewake'] != true) {
      return execute();
    }
    check();
    final key = '$_prefix${ToolExecution.digest(identity)}';
    final saved = store.get(key);
    final binding = ToolExecution.digest(descriptor);
    if (saved != null &&
        (saved.value['binding'] != binding ||
            saved.value['request_identity'] != requestIdentity)) {
      throw StateError('后台 hook 原始参数已变化');
    }
    if (!_jobs.containsKey(identity)) {
      if (saved == null) {
        store.put(key, {
          'phase': 'pending',
          'identity': identity,
          'request_identity': requestIdentity,
          'binding': binding,
          'descriptor': descriptor,
          'created_at': DateTime.now().microsecondsSinceEpoch,
        }, null);
      }
      _checks[key] = check;
      final serial = descriptor['serial_key'] as String?;
      final previous = serial == null ? null : _tails[serial];
      // Catch immediately: an operation can fail while the model is running.
      _jobs[identity] = Future<void>(() async {
        try {
          await previous;
          check();
          final current = store.get(key)!;
          final result = current.value['phase'] == 'succeeded'
              ? current.value['result'] == null
                    ? null
                    : PluginHookOutput.restore(current.value['result'] as Map)
              : await execute();
          check();
          final done = store.get(key)!;
          if (done.value['phase'] != 'succeeded') {
            store.put(key, {
              ...done.value,
              'phase': 'succeeded',
              'result': result?.toJson(),
            }, done.revision);
          }
          onEvent?.call({
            'type': result?.error == null ? 'tool_succeeded' : 'tool_failed',
            'tool': 'plugin_hook',
            'hook_event': hook.event,
            'background': true,
            if (result?.error != null) 'message': result!.error,
          });
          if (done.value['delivered'] == true) return;
          if (result?.additionalContext case final String value) {
            _messages.add(value);
            _ready.add(key);
          } else {
            acknowledgeKey(key);
          }
        } catch (error, stack) {
          onEvent?.call({
            'type': 'tool_failed',
            'tool': 'plugin_hook',
            'hook_event': hook.event,
            'background': true,
            'message': '后台 hook 未完成或来源已失效',
          });
          _failure ??= error;
          _stack ??= stack;
        }
      });
      if (serial != null) _tails[serial] = _jobs[identity]!;
    }
    return null;
  }

  Future<void> recover({
    required String requestIdentity,
    required Future<PluginHookOutput?> Function(Map<String, dynamic>) execute,
    required PluginHook Function(Map<String, dynamic>) definition,
  }) async {
    // Per-task code budget bounds submissions; paginate rather than silently
    // dropping pending jobs when old completed turns accumulated records.
    String? after;
    final records = <StoredDocument>[];
    while (true) {
      final page = store.list(_prefix, afterKey: after);
      for (final (_, record) in page) {
        if (record.value['request_identity'] != requestIdentity ||
            record.value['delivered'] == true)
          continue;
        records.add(record);
      }
      if (page.length < 200) break;
      after = page.last.$1;
    }
    records.sort(
      (a, b) => (a.value['created_at'] as int).compareTo(
        b.value['created_at'] as int,
      ),
    );
    for (final record in records) {
      final descriptor = Map<String, dynamic>.from(
        record.value['descriptor'] as Map,
      );
      await run(
        hook: definition(descriptor),
        identity: record.value['identity'] as String,
        requestIdentity: requestIdentity,
        descriptor: descriptor,
        check: () {
          definition(descriptor);
        },
        execute: () => execute(descriptor),
      );
    }
  }

  /// The host joins before completing the turn; no orphaned task or new grant.
  Future<List<String>> drain() async {
    await Future.wait(_jobs.values.toList());
    if (_failure case final Object error) {
      Error.throwWithStackTrace(error, _stack!);
    }
    for (final key in _ready) {
      _checks[key]!();
    }
    final result = List<String>.of(_messages);
    _messages.clear();
    return result;
  }

  Future<void> close() async {
    await Future.wait(_jobs.values.toList());
  }

  void acknowledgeKey(String key) {
    final saved = store.get(key)!;
    if (saved.value['delivered'] != true) {
      store.put(key, {...saved.value, 'delivered': true}, saved.revision);
    }
  }

  void acknowledge() {
    for (final key in _ready) {
      acknowledgeKey(key);
    }
    _ready.clear();
  }
}
