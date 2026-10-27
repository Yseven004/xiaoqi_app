import 'dart:async';
import 'package:genkit/genkit.dart' show CancellationToken;
import 'package:http/http.dart' as http;
import 'execution_limits.dart';
import 'store.dart';

/// Counts provider POST attempts at their actual HTTP boundary, including
/// SDK retries and format repair. No prompt, response or credential is logged.
class TaskModelClient extends http.BaseClient {
  TaskModelClient(
    this.store,
    this.tenantId,
    this.taskId, {
    this.limits = const ExecutionLimits(),
    this.cancellation,
    http.Client? inner,
  }) : _inner = inner ?? http.Client();

  static final _zoneKey = Object();
  static http.Client? get current => Zone.current[_zoneKey] as TaskModelClient?;

  static Future<T> run<T>({
    required CloudStore store,
    required String tenantId,
    required String taskId,
    required CancellationToken cancellation,
    required ExecutionLimits limits,
    required Future<T> Function() operation,
  }) async {
    cancellation.throwIfCancelled();
    final client = TaskModelClient(
      store,
      tenantId,
      taskId,
      limits: limits,
      cancellation: cancellation,
    );
    try {
      final result = await runZoned(operation, zoneValues: {_zoneKey: client});
      if (client._reservationError != null) throw client._reservationError!;
      return result;
    } catch (_) {
      // SDK/intent fallbacks must not turn a budget refusal into completion.
      if (client._reservationError != null) throw client._reservationError!;
      rethrow;
    } finally {
      client.close();
    }
  }

  final CloudStore store;
  final String tenantId, taskId;
  final ExecutionLimits limits;
  final CancellationToken? cancellation;
  final http.Client _inner;
  StateError? _reservationError;

  void _claim() {
    cancellation?.throwIfCancelled();
    final key = 'task/$tenantId/$taskId';
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = store.get(key);
      if (current == null) throw StateError('任务不存在，不能调用模型');
      final task = current.value;
      if (task['cancel_requested'] == true ||
          const {'cancelled', 'stopped'}.contains(task['status']))
        throw StateError('任务已停止，不能继续调用模型');
      final count = task['model_request_runs'] ?? 0;
      if (count is! int || count < 0) throw StateError('任务模型调用计数无效');
      if (count >= limits.modelRequests)
        throw ExecutionBudgetExceeded('本次任务的模型调用预算已用完，已取得的结果仍保留');
      try {
        store.put(key, {
          ...task,
          'model_request_runs': count + 1,
        }, current.revision);
        return;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('无法锁定任务模型调用预算');
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method == 'POST') {
      try {
        _claim();
      } on StateError catch (error) {
        _reservationError = error;
        rethrow;
      }
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
