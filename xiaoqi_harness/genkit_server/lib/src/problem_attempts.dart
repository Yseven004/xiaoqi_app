import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';

import 'execution_limits.dart';
import 'store.dart';

const Object _activeProblemAttemptZoneKey = Object();

final Map<String, _ProblemAttemptGate> _problemAttemptGates = {};

final class _ProblemAttemptGate {
  int inFlight = 0;
  int waiters = 0;
  final Set<String> taskKeys = {};
  Completer<void>? changed;

  void notifyChanged() {
    final signal = changed;
    changed = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }
}

/// Enforces the user's five-failure ceiling at Genkit's shared tool boundary.
///
/// Successful calls and intentional interrupts do not consume attempts. A
/// stage is keyed by the server task ID; the problem record retains prior
/// stages under the conversation so a resume cannot reset the current count.
class ProblemAttemptBudget {
  ProblemAttemptBudget({
    required this.store,
    required this.tenantId,
    required this.taskId,
    required this.workflowId,
    required this.stageId,
    required this.issueContext,
    required this.onEvent,
    this.limit = 5,
  });

  final CloudStore store;
  final String tenantId;
  final String taskId;
  final String workflowId;
  final String stageId;
  final String issueContext;
  final void Function(Map<String, Object?> event) onEvent;
  final int limit;

  GenerateMiddleware middleware() => _ProblemAttemptMiddleware(this);

  String get _taskKey => 'task/$tenantId/$taskId';

  String _attemptGateKey(String problemId) {
    final workflowHash = sha256.convert(utf8.encode(workflowId)).toString();
    final recordKey = 'problem-attempt/$tenantId/$workflowHash/$problemId';
    return '${identityHashCode(store)}/$recordKey/$stageId';
  }

  Future<bool> _reserveAttempt(
    String gateKey,
    String problemId, {
    required bool nested,
    required CancellationToken? cancellation,
  }) async {
    while (true) {
      cancellation?.throwIfCancelled();
      if (taskStopped || attemptsFor(problemId) >= limit) return false;
      final gate = _problemAttemptGates.putIfAbsent(
        gateKey,
        _ProblemAttemptGate.new,
      )..taskKeys.add(_taskKey);
      final attempts = attemptsFor(problemId);
      if (attempts + gate.inFlight < limit) {
        gate.inFlight++;
        return true;
      }
      // A parent Agent may be waiting for this nested call. Waiting for its
      // own permit would deadlock; return a non-failure, retryable state instead.
      if (nested) return false;
      gate.waiters++;
      final signal = gate.changed ??= Completer<void>();
      try {
        if (cancellation == null) {
          await signal.future;
        } else {
          await Future.any([signal.future, cancellation.whenCancelled]);
          cancellation.throwIfCancelled();
        }
      } finally {
        gate.waiters--;
        if (gate.inFlight == 0 &&
            gate.waiters == 0 &&
            identical(_problemAttemptGates[gateKey], gate)) {
          _problemAttemptGates.remove(gateKey);
        }
      }
    }
  }

  void _releaseAttempt(String gateKey) {
    final gate = _problemAttemptGates[gateKey];
    if (gate == null) return;
    if (gate.inFlight > 0) gate.inFlight--;
    gate.notifyChanged();
    if (gate.inFlight == 0 && gate.waiters == 0) {
      _problemAttemptGates.remove(gateKey);
    }
  }

  void _notifyTaskAttemptWaiters() {
    for (final entry in _problemAttemptGates.entries.toList()) {
      if (entry.value.taskKeys.contains(_taskKey)) entry.value.notifyChanged();
    }
  }

  String _problemId(Object? rawInput) {
    final targets = <String, Object?>{};
    const targetKeys = {
      'attachment_id',
      'material_id',
      'resource_id',
      'artifact_id',
      'target_artifact_id',
      'file_id',
      'file_path',
      'path',
      'filename',
      'target_id',
      'operation_id',
    };
    void collect(Object? value) {
      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString();
          if (targetKeys.contains(key)) {
            final text = entry.value?.toString().trim() ?? '';
            if (text.isNotEmpty && text.length <= 256) targets[key] = text;
          }
          collect(entry.value);
        }
      } else if (value is Iterable) {
        for (final item in value) {
          collect(item);
        }
      }
    }

    collect(rawInput);
    final stableContext = issueContext
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final canonical = jsonEncode({
      'workflow': workflowId,
      'targets': targets,
      'issue_context': stableContext,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  static String? _failureSummary(Object? output) {
    if (output is Map) {
      final status = output['status']?.toString().toLowerCase();
      if (output['cancelled'] == true ||
          const {
            'cancelled',
            'canceled',
            'denied',
            'rejected',
            'pending',
            'interrupted',
            'unknown',
            'uncertain',
            'in_progress',
            'awaiting_user',
            'awaiting_confirmation',
            'awaiting_authorization',
          }.contains(status) ||
          (status?.startsWith('awaiting_') ?? false)) {
        return null;
      }
      if (output['ok'] == false || output['isError'] == true) {
        return _safeSummary(
          output['error'] ?? output['message'] ?? output['status'] ?? '工具返回失败',
        );
      }
      if (output['ok'] == true ||
          const {
            'success',
            'succeeded',
            'complete',
            'completed',
          }.contains(status)) {
        return null;
      }
      if (const {
        'failed',
        'failure',
        'error',
        'invalid',
        'not_found',
        'unavailable',
      }.contains(status)) {
        return _safeSummary(output['error'] ?? output['message'] ?? status);
      }
      if (output['error'] is String && output['error'].toString().isNotEmpty) {
        return _safeSummary(output['error']);
      }
      return null;
    }
    if (output is String &&
        RegExp(
          r'^(?:ERROR:|Tool error:|Execution failed:)',
          caseSensitive: false,
        ).hasMatch(output.trim())) {
      return _safeSummary(output);
    }
    return null;
  }

  static String _safeSummary(Object? value) {
    var text = value?.toString().trim() ?? '工具执行失败';
    text = text
        .replaceAll(
          RegExp(
            r'(authorization\s*[:=]\s*bearer\s+)\S+',
            caseSensitive: false,
          ),
          r'$1[已隐藏]',
        )
        .replaceAll(
          RegExp(r'\b(sk-[A-Za-z0-9_-]{12,})\b', caseSensitive: false),
          '[已隐藏密钥]',
        )
        .replaceAll(
          RegExp(
            r'((?:api[_-]?key|token|secret|password)\s*[:=]\s*)\S+',
            caseSensitive: false,
          ),
          r'$1[已隐藏]',
        );
    if (text.length > 600) text = '${text.substring(0, 600)}…';
    return text.isEmpty ? '工具执行失败' : text;
  }

  Future<int> _recordFailure(
    String problemId,
    String toolName,
    String summary,
  ) async {
    final workflowHash = sha256.convert(utf8.encode(workflowId)).toString();
    final recordKey = 'problem-attempt/$tenantId/$workflowHash/$problemId';
    for (var conflict = 0; conflict < 8; conflict++) {
      final current = store.get(recordKey);
      final allStages = Map<String, dynamic>.from(
        current?.value['stages'] as Map? ?? const {},
      );
      final stage = Map<String, dynamic>.from(
        allStages[stageId] as Map? ?? const {},
      );
      final priorAttempts = (stage['attempts'] as num? ?? 0).toInt();
      if (priorAttempts >= limit) return priorAttempts;
      final attempts = priorAttempts + 1;
      final history = [
        ...(stage['history'] as List? ?? const []),
        {
          'attempt': attempts,
          'tool': toolName,
          'summary': summary,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
      ];
      allStages[stageId] = {
        'attempts': attempts,
        'limit': limit,
        'history': history.length > 20
            ? history.sublist(history.length - 20)
            : history,
        'stopped': attempts >= limit,
      };
      try {
        store.put(recordKey, {
          'workflow_hash': workflowHash,
          'problem_id': problemId,
          'stages': allStages,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, current?.revision);
        return attempts;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('问题尝试记录冲突过多，已停止工具执行');
  }

  bool get taskStopped =>
      store.get(_taskKey)?.value['problem_attempt_limit'] is Map;

  int attemptsFor(String problemId) {
    final workflowHash = sha256.convert(utf8.encode(workflowId)).toString();
    final record = store.get(
      'problem-attempt/$tenantId/$workflowHash/$problemId',
    );
    final stage = record?.value['stages'] is Map
        ? (record!.value['stages'] as Map)[stageId]
        : null;
    return stage is Map ? (stage['attempts'] as num? ?? 0).toInt() : 0;
  }

  Future<void> _stopTask(String problemId, int attempts, String summary) async {
    for (var conflict = 0; conflict < 8; conflict++) {
      final current = store.get(_taskKey);
      if (current == null || current.value['problem_attempt_limit'] is Map) {
        return;
      }
      try {
        store.put(_taskKey, {
          ...current.value,
          'problem_attempt_limit': {
            'problem_id': problemId,
            'stage_id': stageId,
            'attempts': attempts,
            'limit': limit,
            'summary': summary,
            'workflow_id': workflowId,
            'status': 'waiting_for_user',
            'created_at': DateTime.now().toUtc().toIso8601String(),
          },
        }, current.revision);
        onEvent({
          'type': 'problem_attempt_limit_reached',
          'problem_id': problemId,
          'attempts': attempts,
          'limit': limit,
          'summary': summary,
        });
        _notifyTaskAttemptWaiters();
        return;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('无法保存问题尝试上限状态，已停止工具执行');
  }
}

final class _ProblemAttemptMiddleware extends GenerateMiddleware {
  _ProblemAttemptMiddleware(this.budget);

  final ProblemAttemptBudget budget;

  @override
  Future<ModelResponse> model(
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    Future<ModelResponse> Function(
      ModelRequest request,
      ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    )
    next,
  ) {
    if (!budget.taskStopped) return next(request, ctx);
    return next(
      ModelRequest(
        messages: request.messages,
        config: request.config,
        tools: const [],
        toolChoice: ToolChoice.none,
        output: request.output,
        docs: request.docs,
      ),
      ctx,
    );
  }

  @override
  Future<ToolResult> tool(
    ToolRequestPart request,
    ActionFnArg<void, dynamic, void> ctx,
    Future<ToolResult> Function(
      ToolRequestPart request,
      ActionFnArg<void, dynamic, void> ctx,
    )
    next,
  ) async {
    final name = request.toolRequest.name;
    if (budget.taskStopped) {
      return ToolResult.response({
        'ok': false,
        'status': 'stopped',
        'message': '本任务因同一问题已失败五次而停止；请整理已知原因并等待用户指示。',
      });
    }
    final problemId = budget._problemId(request.toolRequest.input);
    final gateKey = budget._attemptGateKey(problemId);
    final activeProblems =
        Zone.current[_activeProblemAttemptZoneKey] as Set<String>? ?? const {};
    final nested = activeProblems.contains(gateKey);
    final Future<ToolResult> Function() run = () async {
      final reserved = await budget._reserveAttempt(
        gateKey,
        problemId,
        nested: nested,
        cancellation: ctx.cancel,
      );
      if (!reserved) {
        final priorAttempts = budget.attemptsFor(problemId);
        if (budget.taskStopped || priorAttempts >= budget.limit) {
          if (priorAttempts >= budget.limit) {
            await budget._stopTask(problemId, priorAttempts, '该问题在当前尝试阶段已达到上限');
          }
          return ToolResult.response({
            'ok': false,
            'status': 'stopped',
            'message': '本任务因同一问题已达到尝试上限而停止；请等待用户指示。',
          });
        }
        return ToolResult.response({
          'ok': false,
          'status': 'in_progress',
          'retryable': true,
          'message': '同一问题已有并行操作占用剩余尝试名额；此嵌套操作未启动，请先等待当前操作结果。',
        });
      }
      try {
        if (budget.taskStopped) {
          return ToolResult.response({
            'ok': false,
            'status': 'stopped',
            'message': '本任务因同一问题达到尝试上限而停止；请等待用户指示。',
          });
        }
        ctx.cancel?.throwIfCancelled();
        final priorAttempts = budget.attemptsFor(problemId);
        if (priorAttempts >= budget.limit) {
          await budget._stopTask(problemId, priorAttempts, '该问题在当前尝试阶段已达到上限');
          return ToolResult.response({
            'ok': false,
            'status': 'stopped',
            'error':
                '同一问题当前阶段已尝试 ${budget.limit} 次，不能自动开始第 ${budget.limit + 1} 次。',
            'problem_attempt': priorAttempts,
            'problem_attempt_limit': budget.limit,
            'recovery_instruction': '保留现有记录，简短说明原因并等待用户明确指示继续排查或提供新条件。',
          });
        }
        late final ToolResult result;
        try {
          result = await runZoned<Future<ToolResult>>(
            () => next(request, ctx),
            zoneValues: {
              _activeProblemAttemptZoneKey: {...activeProblems, gateKey},
            },
          );
        } on Object catch (error) {
          if (ctx.cancel?.isCancelled == true ||
              error is ExecutionBudgetExceeded) {
            rethrow;
          }
          final summary = ProblemAttemptBudget._safeSummary(error);
          final attempts = await budget._recordFailure(
            problemId,
            name,
            summary,
          );
          final stopped = attempts >= budget.limit;
          budget.onEvent({
            'type': 'tool_failed',
            'tool': name,
            'problem_id': problemId,
            'problem_attempt': attempts,
            'problem_attempt_limit': budget.limit,
            'message': summary,
            if (stopped) 'stopped': true,
          });
          if (stopped) await budget._stopTask(problemId, attempts, summary);
          return ToolResult.response({
            'ok': false,
            'status': stopped ? 'stopped' : 'failed',
            'error': summary,
            'problem_attempt': attempts,
            'problem_attempt_limit': budget.limit,
            'recovery_instruction': stopped
                ? '自动执行已停止。简要说明问题和原因，然后等待用户指示。'
                : '先核对错误与已有证据，再选择不同且有依据的修复方法。',
          });
        }
        if (result case ToolResponseResult(
          :final output,
          :final parts,
          :final metadata,
        )) {
          final summary = ProblemAttemptBudget._failureSummary(output);
          if (summary == null) return result;
          final attempts = await budget._recordFailure(
            problemId,
            name,
            summary,
          );
          final stopped = attempts >= budget.limit;
          budget.onEvent({
            'type': 'tool_failed',
            'tool': name,
            'problem_id': problemId,
            'problem_attempt': attempts,
            'problem_attempt_limit': budget.limit,
            'message': summary,
            if (stopped) 'stopped': true,
          });
          if (stopped) await budget._stopTask(problemId, attempts, summary);
          final note = stopped
              ? '同一问题已失败 $attempts 次（上限 ${budget.limit} 次）。本任务后续工具调用已关闭；请立即用简短中文向用户说明卡点、已知原因和需要的指示。'
              : '同一问题第 $attempts/${budget.limit} 次失败。先检查失败证据，再换一种有依据的方法；禁止无变化地重试。';
          return ToolResult.response(
            output,
            parts: [
              ...?parts,
              TextPart(text: note),
            ],
            metadata: metadata,
          );
        }
        return result;
      } finally {
        budget._releaseAttempt(gateKey);
      }
    };
    return run();
  }
}
