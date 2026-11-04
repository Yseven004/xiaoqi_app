import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';

import 'execution_limits.dart';
import 'store.dart';

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
  final Map<String, Future<void>> _problemQueues = {};

  GenerateMiddleware middleware() => _ProblemAttemptMiddleware(this);

  Future<T> serializeProblem<T>(
    String problemId,
    Future<T> Function() operation,
  ) async {
    final key = '$workflowId/$stageId/$problemId';
    final previous = _problemQueues[key] ?? Future<void>.value();
    final release = Completer<void>();
    final queued = previous.then((_) => release.future);
    _problemQueues[key] = queued;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
      if (identical(_problemQueues[key], queued)) _problemQueues.remove(key);
    }
  }

  String get _taskKey => 'task/$tenantId/$taskId';

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
      final attempts = (stage['attempts'] as num? ?? 0).toInt() + 1;
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
    return budget.serializeProblem(problemId, () async {
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
        result = await next(request, ctx);
      } on Object catch (error) {
        if (ctx.cancel?.isCancelled == true ||
            error is ExecutionBudgetExceeded) {
          rethrow;
        }
        final summary = ProblemAttemptBudget._safeSummary(error);
        final attempts = await budget._recordFailure(problemId, name, summary);
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
        final attempts = await budget._recordFailure(problemId, name, summary);
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
    });
  }
}
