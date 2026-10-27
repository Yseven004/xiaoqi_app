import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'execution_limits.dart';
import 'store.dart';
import 'turn_contract.dart';

/// Claims scope and budget together in the existing task document.
class ToolExecution {
  ToolExecution(
    this.store,
    this.tenantId,
    this.taskId,
    this.contract, {
    required this.requestIdentity,
    this.steeringSequence = 0,
    this.requestText,
    this.limits = const ExecutionLimits(),
  });

  final CloudStore store;
  final String tenantId;
  final String taskId;
  final TurnContract contract;
  final String requestIdentity;
  final int steeringSequence;
  final String? requestText;
  final ExecutionLimits limits;
  String get key => 'task/$tenantId/$taskId';

  static String digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  bool get hasUncertainNetworkExecution =>
      (store.get(key)?.value['uncertain_network_scopes'] as Map?)?.containsKey(
        requestIdentity,
      ) ==
      true;

  void markUncertainNetworkExecution(String codeHash) {
    _update(
      (value) => {
        ...value,
        'uncertain_network_scopes': {
          ...?(value['uncertain_network_scopes'] as Map?),
          requestIdentity: {'code_hash': codeHash, 'status': 'unknown'},
        },
      },
    );
  }

  void bind() {
    _update((value) {
      final prior = value['turn_scope'] as Map?;
      if (prior?['request_identity'] == requestIdentity) return value;
      return {
        ...value,
        'turn_scope': {
          ...contract.toJson(),
          'request_identity': requestIdentity,
          'steering_sequence': steeringSequence,
          if (requestText != null) 'request_text': requestText,
        },
        // A corrected user request starts a new plan, not a monotonic extension
        // of a withdrawn requirement. Old operation evidence remains intact.
        if (prior != null) 'delivery_evidence': <String, dynamic>{},
        'tool_authorizations': <String, dynamic>{},
        'tool_authorization_denials': <String, dynamic>{},
        'authorized_network_domains': <String>[],
        'requested_network_domains': <String>[],
        'network_purpose': null,
      };
    });
  }

  /// Only the caller handling a matching human resume may record a decision.
  /// Explicit denials remain in force for this request; a changed user request
  /// starts a new scope. Prior exact approvals do not grant changed arguments.
  void recordAuthorization({
    required String actionHash,
    required String scopeHash,
    required bool approved,
  }) {
    _update((value) {
      check('read');
      final decisions = Map<String, dynamic>.from(
        value['tool_authorizations'] as Map? ?? const {},
      );
      final denials = Map<String, dynamic>.from(
        value['tool_authorization_denials'] as Map? ?? const {},
      );
      if (!decisions.containsKey(actionHash) &&
          decisions.length >= limits.toolOperations) {
        throw ExecutionBudgetExceeded('本次任务的操作确认数量已达到上限');
      }
      if (decisions[actionHash] != false) decisions[actionHash] = approved;
      if (!approved) denials[scopeHash] = true;
      return {
        ...value,
        'tool_authorizations': decisions,
        'tool_authorization_denials': denials,
      };
    });
  }

  bool? authorization({required String actionHash, required String scopeHash}) {
    check('read');
    final value = store.get(key)?.value ?? const <String, dynamic>{};
    final exact = (value['tool_authorizations'] as Map?)?[actionHash];
    if (exact is bool) return exact;
    if ((value['tool_authorization_denials'] as Map?)?[scopeHash] == true)
      return false;
    return null;
  }

  void check(String effect) {
    final value = store.get(key)?.value ?? const <String, dynamic>{};
    if (value['cancel_requested'] == true ||
        const {'cancelled', 'stopped'}.contains(value['status'])) {
      throw StateError('任务已停止，不能继续执行操作');
    }
    final scope = value['turn_scope'] as Map?;
    if (scope?['request_identity'] != requestIdentity) {
      throw StateError('用户已更新任务，旧操作已失效');
    }
    if ((value['steering_instructions'] as List? ?? const [])
        .whereType<Map>()
        .any((i) => (i['sequence'] as num? ?? 0) > steeringSequence)) {
      throw StateError('有新的用户指令，请先更新任务范围');
    }
    if (!contract.permitsWorkspace) {
      throw StateError('任务已停止或等待用户澄清，不能执行操作');
    }
    if (effect == 'image' && !contract.permitsImages) {
      throw StateError('本轮没有要求生成图片');
    }
    if (effect == 'workflow' && !contract.executesWorkflow) {
      throw StateError('本轮只需回答或读取结果，不能执行旧工作流');
    }
  }

  Future<Map<String, dynamic>> image({
    required String slot,
    required Map<String, dynamic> arguments,
    required Future<Map<String, dynamic>> Function(String idempotencyKey)
    invoke,
  }) => _operation(
    effect: 'image',
    slot: slot,
    arguments: arguments,
    limit: contract.imageLimit,
    invoke: invoke,
  );

  Future<Map<String, dynamic>> workflow({
    required String slot,
    required Map<String, dynamic> arguments,
    required Future<Map<String, dynamic>> Function(String id) invoke,
  }) => _operation(
    effect: 'workflow',
    slot: slot,
    arguments: arguments,
    limit: limits.toolOperations,
    invoke: invoke,
  );

  /// Read attempts are fresh (polling must not reuse a stale successful read).
  /// They still share the task's operation budget and cancellation checks.
  Future<Map<String, dynamic>> query({
    required String slot,
    required Map<String, dynamic> arguments,
    required Future<Map<String, dynamic>> Function(String id) invoke,
  }) => _operation(
    effect: 'read',
    slot: '$slot:${const Uuid().v4()}',
    arguments: arguments,
    limit: limits.toolOperations,
    invoke: invoke,
  );

  /// Isolated workspace calls are fresh; prior writes must not stale later reads.
  Future<Map<String, dynamic>> workspace({
    required String slot,
    required Map<String, dynamic> arguments,
    required Future<Map<String, dynamic>> Function(String id) invoke,
  }) => _operation(
    effect: 'workspace',
    slot: '$slot:${const Uuid().v4()}',
    arguments: arguments,
    limit: limits.toolOperations,
    invoke: invoke,
  );

  /// Caller must validate a grant for these exact external operation arguments.
  /// Intent routing alone neither grants nor revokes an explicit user approval.
  Future<Map<String, dynamic>> authorizedExternal({
    required String slot,
    required Map<String, dynamic> arguments,
    required Future<Map<String, dynamic>> Function(String id) invoke,
  }) => _operation(
    effect: 'external',
    slot: slot,
    arguments: arguments,
    limit: limits.toolOperations,
    invoke: invoke,
  );

  Future<Map<String, dynamic>> _operation({
    required String effect,
    required String slot,
    required Map<String, dynamic> arguments,
    required int limit,
    required Future<Map<String, dynamic>> Function(String) invoke,
  }) async {
    check(effect);
    final operationId = digest([requestIdentity, effect, slot]);
    final hash = digest(arguments);
    Map<String, dynamic>? cached;
    _update((value) {
      check(effect);
      final operations = Map<String, dynamic>.from(
        value['scope_operations'] as Map? ?? const {},
      );
      final previous = operations[operationId] as Map?;
      if (previous != null) {
        if (previous['arguments_hash'] != hash)
          throw StateError('同一操作的参数已经变化，请明确重新生成');
        if (previous['status'] == 'succeeded' && previous['result'] is Map) {
          cached = Map<String, dynamic>.from(previous['result'] as Map);
          return value;
        }
        throw StateError('操作正在处理或结果未知，不能重复提交');
      }
      final reserved = effect != 'image'
          ? taskToolOperationsUsed(value)
          : operations.values
                .whereType<Map>()
                .where(
                  (op) =>
                      op['request_identity'] == requestIdentity &&
                      op['effect'] == 'image',
                )
                .length;
      if (reserved >= limit) throw ExecutionBudgetExceeded('已达到本轮操作数量上限');
      operations[operationId] = {
        'request_identity': requestIdentity,
        'effect': effect,
        'arguments_hash': hash,
        'status': 'running',
      };
      return {...value, 'scope_operations': operations};
    });
    if (cached != null) return cached!;
    try {
      final result = await invoke(operationId);
      _finish(operationId, 'succeeded', result);
      return result;
    } catch (_) {
      // A failed HTTP await does not prove the provider rejected the request.
      _finish(operationId, 'unknown', null);
      rethrow;
    }
  }

  void _finish(String id, String status, Map<String, dynamic>? result) {
    _update((value) {
      final operations = Map<String, dynamic>.from(
        value['scope_operations'] as Map? ?? const {},
      );
      final previous = Map<String, dynamic>.from(operations[id] as Map);
      operations[id] = {
        ...previous,
        'status': status,
        if (result != null) 'result': result,
      };
      return {...value, 'scope_operations': operations};
    });
  }

  void _update(Map<String, dynamic> Function(Map<String, dynamic>) mutate) {
    for (var attempt = 0; attempt < 8; attempt++) {
      final previous = store.get(key);
      final value = mutate(previous?.value ?? <String, dynamic>{});
      try {
        store.put(key, value, previous?.revision);
        return;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('任务状态写入冲突，请重试读取结果');
  }
}
