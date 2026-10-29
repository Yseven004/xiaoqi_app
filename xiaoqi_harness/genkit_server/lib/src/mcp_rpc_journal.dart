import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'mcp_tool_result.dart';
import 'store.dart';
import 'tool_execution.dart';

/// Private response correlation, never a source of execution authority.
class McpRpcJournal {
  McpRpcJournal(
    this.store,
    this.tenant,
    this.task,
    this.lease, {
    required this.limit,
  });
  final CloudStore store;
  final String tenant, task, lease;
  final int limit;
  String get prefix => 'private_mcp_rpc/$tenant/$task/$lease/';
  String get leaseKey => 'private_mcp_lease/$tenant/$task/$lease';
  String get taskKey => 'task/$tenant/$task';
  List<(String, StoredDocument)> get records =>
      store.list(prefix, limit: limit + 1).toList();
  String? _key(Object? id) => id is int || (id is String && id.length <= 128)
      ? '$prefix${sha256.convert(utf8.encode(jsonEncode(id)))}'
      : null;

  void beforeSend(Map<String, dynamic> message, int sequence) {
    if (message['method'] != 'tools/call') return;
    final operation = ToolExecution.currentOperationId;
    if (operation == null) return; // SDK probes without an effect reservation.
    final key = _key(message['id']);
    if (key == null) throw const FormatException('Invalid MCP tool request ID');
    final bound =
        (store.get(taskKey)?.value['scope_operations'] as Map?)?[operation];
    if (bound is! Map || bound['status'] != 'running')
      throw StateError('MCP request has no current operation reservation');
    _prune();
    final existing = store.get(key);
    final hash = ToolExecution.digest(message);
    if (existing != null) {
      if (existing.value['request_hash'] != hash ||
          existing.value['operation_id'] != operation)
        throw StateError('Original MCP request binding changed');
      return;
    }
    if (records.length >= limit)
      throw StateError('MCP response journal capacity reached');
    store.put(key, {
      'operation_id': operation,
      'arguments_hash': bound['arguments_hash'],
      'request_identity': bound['request_identity'],
      'request_hash': hash,
      'sequence': sequence,
      'deadline_ms': DateTime.now()
          .add(const Duration(seconds: 60))
          .millisecondsSinceEpoch,
    }, null);
  }

  void recordEvents(List<Map<String, dynamic>> messages, int cursor) {
    _prune();
    var bytes = records.fold<int>(
      0,
      (n, r) => n + utf8.encode(jsonEncode(r.$2.value)).length,
    );
    for (final message in messages) {
      if (message.containsKey('method') ||
          (!message.containsKey('result') && !message.containsKey('error')))
        continue;
      final key = _key(message['id']);
      final previous = key == null ? null : store.get(key);
      if (previous == null) continue;
      final hash = ToolExecution.digest(message);
      if (previous.value['response_hash'] != null) {
        if (previous.value['response_hash'] != hash)
          throw StateError('Original MCP response changed');
        continue;
      }
      bytes += utf8.encode(jsonEncode(message)).length;
      if (bytes > 32 * 1024 * 1024)
        throw StateError('MCP response journal byte budget reached');
      store.put(key!, {
        ...previous.value,
        'response': message,
        'response_hash': hash,
      }, previous.revision);
    }
    if (store.get(leaseKey)?.value['event_cursor'] != cursor) {
      _update(leaseKey, (value) => {...value, 'event_cursor': cursor});
    }
  }

  DateTime? get pendingDeadline {
    DateTime? deadline;
    for (final (_, record) in records) {
      if (record.value['response'] != null) continue;
      final ms = record.value['deadline_ms'];
      if (ms is! int) throw StateError('Original MCP call deadline is missing');
      final next = DateTime.fromMillisecondsSinceEpoch(ms);
      if (deadline == null || next.isAfter(deadline)) deadline = next;
    }
    return deadline;
  }

  void reconcile() {
    for (final (_, record) in records) {
      final value = record.value;
      final response = value['response'];
      if (response is! Map) continue;
      final id = value['operation_id'];
      final current =
          (store.get(taskKey)?.value['scope_operations'] as Map?)?[id];
      if (current is! Map ||
          current['arguments_hash'] != value['arguments_hash'] ||
          current['request_identity'] != value['request_identity'])
        throw StateError('Original MCP operation binding changed');
      if (current['status'] == 'succeeded' && current['result'] is Map)
        continue;
      final raw = response['result'];
      final normalized = McpToolResultAdapter(store, tenant, task).normalize(
        raw is Map<String, dynamic>
            ? raw
            : {
                'isError': true,
                'content': [
                  {
                    'type': 'text',
                    'text': 'Original MCP request returned a protocol error',
                  },
                ],
              },
      );
      _update(taskKey, (taskValue) {
        final operations = Map<String, dynamic>.from(
          taskValue['scope_operations'] as Map? ?? {},
        );
        final bound = operations[id];
        if (bound is! Map ||
            bound['arguments_hash'] != value['arguments_hash'] ||
            bound['request_identity'] != value['request_identity'])
          throw StateError('Original MCP operation binding changed');
        if (bound['status'] == 'succeeded' && bound['result'] is Map)
          return taskValue;
        operations[id] = {
          ...bound,
          'status': 'succeeded',
          'result': normalized,
          'mcp_response_id': '$lease:${value['response_hash']}',
        };
        return {...taskValue, 'scope_operations': operations};
      });
    }
    _prune();
  }

  void _prune() {
    final operations =
        store.get(taskKey)?.value['scope_operations'] as Map? ?? {};
    for (final (key, record) in records) {
      final value = record.value;
      final op = operations[value['operation_id']];
      if (op is Map &&
          op['status'] == 'succeeded' &&
          op['result'] is Map &&
          op['arguments_hash'] == value['arguments_hash'] &&
          op['request_identity'] == value['request_identity'])
        store.delete(key);
    }
  }

  void finishUnknown() {
    _update(taskKey, (value) {
      final operations = Map<String, dynamic>.from(
        value['scope_operations'] as Map? ?? {},
      );
      for (final (_, record) in records) {
        final op = operations[record.value['operation_id']];
        if (record.value['response'] == null &&
            op is Map &&
            op['status'] == 'running' &&
            op['arguments_hash'] == record.value['arguments_hash'] &&
            op['request_identity'] == record.value['request_identity']) {
          operations[record.value['operation_id']] = {
            ...op,
            'status': 'unknown',
          };
        }
      }
      return {...value, 'scope_operations': operations};
    });
  }

  void _update(
    String key,
    Map<String, dynamic> Function(Map<String, dynamic>) mutate,
  ) {
    for (var i = 0; i < 8; i++) {
      final record = store.get(key);
      if (record == null)
        throw StateError('Original MCP journal owner is missing');
      try {
        store.put(key, mutate(record.value), record.revision);
        return;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('Original MCP journal update conflicted');
  }
}
