import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'execution_limits.dart';
import 'store.dart';
import 'tool_execution.dart';

/// Persists the ORIGINAL native result before any post-hook is started. The
/// post-hook may change model-visible output, never this confirmed effect.
class PluginHookToolJournal {
  PluginHookToolJournal(this.owner);
  final ToolExecution owner;
  static const maxRetainedBytes = 32 * 1024 * 1024;

  Future<ToolResult> run({
    required String invocation,
    required Map<String, dynamic> arguments,
    required bool resumed,
    required Future<ToolResult> Function() invoke,
  }) async {
    owner.check('read');
    final id = owner.operationIdentity('hook-native-tool', invocation);
    final binding = ToolExecution.digest(_canonical(arguments)!);
    final blob =
        'tenants/${owner.tenantId}/tasks/${owner.taskId}/private_hook_tool_results/$id.json';
    Map? cached;
    _update((task) {
      owner.check('read');
      final entries = Map<String, dynamic>.from(
        task['plugin_hook_tool_calls'] as Map? ?? const {},
      );
      final previous = entries[id];
      if (previous is Map) {
        if (previous['binding'] != binding ||
            previous['request_identity'] != owner.requestIdentity)
          throw StateError('原始 hook 工具事件的参数已变更');
        if (const {'ready', 'result_pending'}.contains(previous['status'])) {
          cached = Map.from(previous);
          return task;
        }
        if (previous['status'] != 'waiting' || !resumed) {
          throw UnconfirmedToolOperation('原始工具结果尚未确认，不能在恢复后重跑目标工具');
        }
      } else {
        if (entries.values.whereType<Map>().any(
          (entry) =>
              entry['request_identity'] == owner.requestIdentity &&
              entry['binding'] == binding &&
              const {'running', 'result_pending'}.contains(entry['status']),
        )) {
          throw UnconfirmedToolOperation('相同目标的原始工具结果尚未确认，不能换事件标识重跑');
        }
        if (entries.length >= owner.limits.toolOperations) {
          throw ExecutionBudgetExceeded('hook 工具事件数量达到本任务上限');
        }
      }
      entries[id] = {
        'binding': binding,
        'status': 'running',
        'blob': blob,
        'request_identity': owner.requestIdentity,
      };
      return {...task, 'plugin_hook_tool_calls': entries};
    });
    if (cached != null) {
      final data = _read(cached!, blob);
      _change(id, binding, {'status': 'ready'});
      owner.check('read');
      return data;
    }
    final result = await invoke();
    if (result is ToolInterruptResult) {
      _change(id, binding, {'status': 'waiting'});
      return result;
    }
    final bytes = utf8.encode(jsonEncode(result.toJson()));
    final hash = sha256.convert(bytes).toString();
    // Reserve size and expected hash before the atomic blob write. A crash
    // after writing but before marking ready can still recover this result.
    _update((task) {
      final entries = Map<String, dynamic>.from(
        task['plugin_hook_tool_calls'] as Map? ?? const {},
      );
      final previous = entries[id] as Map?;
      if (previous?['binding'] != binding || previous?['status'] != 'running') {
        throw StateError('原始工具结果检查点身份不匹配');
      }
      final retained = entries.values.whereType<Map>().fold<int>(
        0,
        (sum, entry) => sum + (entry['bytes'] as int? ?? 0),
      );
      if (retained + bytes.length > maxRetainedBytes) {
        throw ExecutionBudgetExceeded('hook 原始结果保留空间达到 32 MiB，不能自动重放原操作');
      }
      entries[id] = {
        ...previous!,
        'status': 'result_pending',
        'bytes': bytes.length,
        'sha256': hash,
      };
      return {...task, 'plugin_hook_tool_calls': entries};
    });
    owner.store.putTaskBlob(blob, bytes);
    _change(id, binding, {'status': 'ready'});
    return result;
  }

  ToolResult _read(Map entry, String expectedBlob) {
    try {
      if (entry['blob'] != expectedBlob ||
          entry['bytes'] is! int ||
          (entry['bytes'] as int) < 0 ||
          (entry['bytes'] as int) > maxRetainedBytes) {
        throw const FormatException('checkpoint scope mismatch');
      }
      final bytes = owner.store.getObject(expectedBlob);
      if (bytes.length != entry['bytes'] ||
          sha256.convert(bytes).toString() != entry['sha256']) {
        throw const FormatException('checkpoint checksum mismatch');
      }
      final result = jsonDecode(utf8.decode(bytes)) as Map;
      if (!result.containsKey('output') || result.containsKey('interrupt')) {
        throw const FormatException('checkpoint has no native response');
      }
      return ToolResult.response(
        result['output'],
        parts: result['content'] is List
            ? [
                for (final value in result['content'] as List)
                  Part.fromJson(Map<String, dynamic>.from(value as Map)),
              ]
            : null,
        metadata: result['metadata'] is Map
            ? Map<String, dynamic>.from(result['metadata'] as Map)
            : null,
      );
    } on Object {
      throw UnconfirmedToolOperation('原始工具结果检查点不可用，不能重跑目标工具');
    }
  }

  void _change(String id, String binding, Map<String, dynamic> fields) =>
      _update((task) {
        final entries = Map<String, dynamic>.from(
          task['plugin_hook_tool_calls'] as Map? ?? const {},
        );
        final previous = entries[id] as Map?;
        if (previous?['binding'] != binding) throw StateError('hook 工具事件身份失效');
        entries[id] = {...previous!, ...fields};
        return {...task, 'plugin_hook_tool_calls': entries};
      });

  void _update(Map<String, dynamic> Function(Map<String, dynamic>) update) {
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = owner.store.get(owner.key);
      if (current == null) throw StateError('原始任务不存在');
      final value = update(current.value);
      try {
        owner.store.put(owner.key, value, current.revision);
        return;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('hook 工具事件检查点写入冲突');
  }

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
