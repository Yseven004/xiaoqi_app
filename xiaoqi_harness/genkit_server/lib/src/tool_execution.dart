import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'execution_limits.dart';
import 'store.dart';
import 'turn_contract.dart';
import 'user_action_authorization.dart';

/// A previous effect has no confirmed outcome; changing aliases cannot replay it.
class UnconfirmedToolOperation extends StateError {
  UnconfirmedToolOperation(super.message);
}

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

  String operationIdentity(String effect, String slot) =>
      digest([requestIdentity, effect, slot]);

  void markUncertainNetworkExecution(String codeHash, {String? operationId}) {
    _update((value) {
      final parent = (value['scope_operations'] as Map?)?[operationId];
      if (operationId != null &&
          parent is Map &&
          parent['execution_id'] is String &&
          const {'succeeded', 'failed'}.contains(parent['status']) &&
          parent['result'] is Map)
        return value;
      final scopes = Map<String, dynamic>.from(
        value['uncertain_network_scopes'] as Map? ?? const {},
      );
      final prior = scopes[requestIdentity] as Map?;
      scopes[requestIdentity] = {
        'code_hash': codeHash,
        'status': 'unknown',
        'operation_ids': {
          for (final id in prior?['operation_ids'] as List? ?? const []) id,
          if (operationId != null) operationId,
        }.toList(),
        'unlinked':
            operationId == null ||
            (prior != null &&
                (prior['operation_ids'] is! List || prior['unlinked'] == true)),
      };
      return {...value, 'uncertain_network_scopes': scopes};
    });
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
        'user_action_intents': <String, dynamic>{},
        'tool_authorization_sources': <String, dynamic>{},
        'loaded_plugin_commands': <String, dynamic>{},
        'authorized_network_domains': <String>[],
        'requested_network_domains': <String>[],
        'network_purpose': null,
        'network_details': null,
        'requested_network_action_hash': null,
        'requested_network_scope_hash': null,
        'network_resume': null,
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

  Map<String, dynamic> get loadedPluginCommandBindings {
    final value = store.get(key)?.value ?? const <String, dynamic>{};
    if ((value['steering_instructions'] as List? ?? const [])
        .whereType<Map>()
        .any((i) => (i['sequence'] as num? ?? 0) > steeringSequence)) {
      // Restore no old load permission while a correction awaits the steering
      // middleware. This metadata read must not prevent that middleware running.
      return const {};
    }
    check('read');
    return Map<String, dynamic>.from(
      store.get(key)?.value['loaded_plugin_commands'] as Map? ?? const {},
    );
  }

  void recordLoadedPluginCommand(String alias, String fingerprint) {
    _update((value) {
      check('read');
      final loaded = Map<String, dynamic>.from(
        value['loaded_plugin_commands'] as Map? ?? const {},
      );
      if (!loaded.containsKey(alias) &&
          loaded.length >= limits.toolOperations) {
        throw ExecutionBudgetExceeded('本次任务的插件命令加载数量达到上限');
      }
      loaded[alias] = fingerprint;
      return {...value, 'loaded_plugin_commands': loaded};
    });
  }

  String? userActionIntent(String intentKey) {
    check('read');
    return (store.get(key)?.value['user_action_intents'] as Map?)?[intentKey]
        as String?;
  }

  String saveUserActionIntent(String intentKey, String response) {
    String? saved;
    _update((value) {
      check('read');
      final intents = Map<String, dynamic>.from(
        value['user_action_intents'] as Map? ?? const {},
      );
      if (!intents.containsKey(intentKey) &&
          intents.length >= limits.toolOperations * 2) {
        throw ExecutionBudgetExceeded('本次任务的操作授权识别数量已达到上限');
      }
      saved = (intents.putIfAbsent(intentKey, () => response)) as String;
      return {...value, 'user_action_intents': intents};
    });
    return saved!;
  }

  /// Called only after independent original-request inference and exact matching.
  /// A user's denial always wins over inferred intent, including concurrent ones.
  void recordOriginalUserAuthorization({
    required UserActionIntent intent,
    required Map<String, dynamic> arguments,
    required String actionHash,
    required String scopeHash,
    required String ruleFingerprint,
  }) {
    if (requestText == null ||
        !intent.isForRequest(requestText!) ||
        !intent.matches(arguments))
      return;
    _update((value) {
      check('read');
      final decisions = Map<String, dynamic>.from(
        value['tool_authorizations'] as Map? ?? const {},
      );
      if (decisions[actionHash] == false ||
          (value['tool_authorization_denials'] as Map?)?[scopeHash] == true)
        return value;
      if (!decisions.containsKey(actionHash) &&
          decisions.length >= limits.toolOperations) {
        throw ExecutionBudgetExceeded('本次任务的操作确认数量已达到上限');
      }
      decisions[actionHash] = true;
      return {
        ...value,
        'tool_authorizations': decisions,
        'tool_authorization_sources': {
          ...(value['tool_authorization_sources'] as Map? ?? const {}),
          actionHash: {
            'source': 'original_user_request',
            'request_identity': requestIdentity,
            'request_digest': digest(requestText!),
            'rule_fingerprint': ruleFingerprint,
          },
        },
      };
    });
  }

  bool isAuthorizationScopeDenied(String scopeHash) {
    check('read');
    return (store.get(key)?.value['tool_authorization_denials']
            as Map?)?[scopeHash] ==
        true;
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
    List<String> legacySlots = const [],
    List<String> uncertainLegacySlots = const [],
  }) => _operation(
    effect: 'external',
    slot: slot,
    arguments: arguments,
    limit: limits.toolOperations,
    invoke: invoke,
    legacySlots: legacySlots,
    uncertainLegacySlots: uncertainLegacySlots,
  );

  /// One reservation per original SDK delegation request, including resumes.
  /// Actual child tool calls and model requests keep their existing budgets.
  String beginDelegation(String invocation, String binding) {
    check('workspace');
    final id = operationIdentity('delegation', invocation);
    _update((value) {
      check('workspace');
      final operations = Map<String, dynamic>.from(
        value['scope_operations'] as Map? ?? const {},
      );
      final prior = operations[id];
      if (prior is Map) {
        if (prior['arguments_hash'] != binding)
          throw StateError('子 Agent 调用绑定已变化，不能恢复原调用');
        return value;
      }
      if (taskToolOperationsUsed(value) >= limits.toolOperations)
        throw ExecutionBudgetExceeded('本次任务的操作数量预算已用完');
      operations[id] = {
        'request_identity': requestIdentity,
        'effect': 'delegation',
        'arguments_hash': binding,
        'status': 'not_submitted',
      };
      return {...value, 'scope_operations': operations};
    });
    return id;
  }

  void checkpointDelegation(String id, String status) =>
      _finish(id, status, {'phase': status});

  /// Code attempts reserve their budget in DockerCodeExecutionService. This
  /// entry supplies effect identity/result reuse without charging twice.
  Future<Map<String, dynamic>> authorizedCode({
    required String slot,
    required Map<String, dynamic> arguments,
    required Future<Map<String, dynamic>> Function(String id) invoke,
    required bool Function(Object error) effectsPossible,
  }) => _operation(
    effect: 'external',
    slot: slot,
    arguments: arguments,
    limit: limits.toolOperations,
    invoke: invoke,
    codeBudget: true,
    effectsPossible: effectsPossible,
  );

  Future<Map<String, dynamic>> _operation({
    required String effect,
    required String slot,
    required Map<String, dynamic> arguments,
    required int limit,
    required Future<Map<String, dynamic>> Function(String) invoke,
    bool codeBudget = false,
    bool Function(Object error)? effectsPossible,
    List<String> legacySlots = const [],
    List<String> uncertainLegacySlots = const [],
  }) async {
    check(effect);
    final operationId = operationIdentity(effect, slot);
    final hash = digest(arguments);
    Map<String, dynamic>? cached;
    _update((value) {
      check(effect);
      final operations = Map<String, dynamic>.from(
        value['scope_operations'] as Map? ?? const {},
      );
      final previous = operations[operationId] as Map?;
      // Exact legacy slots are derived by trusted callers from the same
      // canonical action/authority binding. Keep their original journal and
      // budget charge; changing an alias must not replay an unknown effect.
      if (previous == null && legacySlots.isNotEmpty) {
        final legacy = [
          for (final legacySlot in legacySlots)
            if (operations[operationIdentity(effect, legacySlot)] is Map)
              operations[operationIdentity(effect, legacySlot)] as Map,
        ];
        if (legacy.any(
          (record) =>
              !const {'succeeded', 'not_submitted'}.contains(record['status']),
        )) {
          throw UnconfirmedToolOperation('原入口操作正在处理或结果未知，不能通过其他入口重复提交');
        }
        final completed = legacy
            .where(
              (record) =>
                  record['status'] == 'succeeded' && record['result'] is Map,
            )
            .firstOrNull;
        if (completed != null) {
          cached = Map<String, dynamic>.from(completed['result'] as Map);
          return value;
        }
      }
      if (previous != null) {
        if (previous['arguments_hash'] != hash)
          throw StateError('同一操作的参数已经变化，请明确重新生成');
        if ((previous['status'] == 'succeeded' ||
                (codeBudget && previous['status'] == 'failed')) &&
            previous['result'] is Map) {
          cached = Map<String, dynamic>.from(previous['result'] as Map);
          return value;
        }
        if (previous['status'] != 'not_submitted') {
          throw UnconfirmedToolOperation('操作正在处理或结果未知，不能重复提交');
        }
      }
      if (uncertainLegacySlots.any((legacySlot) {
        final record = operations[operationIdentity(effect, legacySlot)];
        return record is Map &&
            !const {'succeeded', 'not_submitted'}.contains(record['status']);
      })) {
        // Old journals kept only parameter hashes. If a connector's old
        // uncertain action cannot be matched exactly, do not infer that a
        // changed schema or reordered input makes it a new external effect.
        throw UnconfirmedToolOperation(
          '此连接的原操作结果未知，旧记录无法确认是否为独立操作；请先查询原结果或明确更新任务，不能换入口重跑',
        );
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
        if (codeBudget) 'budget_owner': 'code',
        'arguments_hash': hash,
        'status': 'running',
      };
      return {...value, 'scope_operations': operations};
    });
    if (cached != null) return cached!;
    try {
      final result = await invoke(operationId);
      final confirmed = _finish(operationId, 'succeeded', result);
      if (codeBudget && confirmed != null) {
        check(effect);
        return confirmed;
      }
      return result;
    } catch (error) {
      // A failed HTTP await does not prove the provider rejected the request.
      final confirmed = _finish(
        operationId,
        codeBudget && effectsPossible?.call(error) == false
            ? 'not_submitted'
            : 'unknown',
        null,
      );
      if (codeBudget && confirmed != null) {
        check(effect);
        return confirmed;
      }
      rethrow;
    }
  }

  Map<String, dynamic>? _finish(
    String id,
    String status,
    Map<String, dynamic>? result,
  ) {
    Map<String, dynamic>? confirmed;
    _update((value) {
      final operations = Map<String, dynamic>.from(
        value['scope_operations'] as Map? ?? const {},
      );
      final previous = Map<String, dynamic>.from(operations[id] as Map);
      if (previous['execution_id'] is String &&
          const {'succeeded', 'failed'}.contains(previous['status']) &&
          previous['result'] is Map) {
        confirmed = Map<String, dynamic>.from(previous['result'] as Map);
        return value; // A late transport failure cannot downgrade a confirmed runner result.
      }
      operations[id] = {
        ...previous,
        'status': status,
        if (result != null) 'result': result,
      };
      return {...value, 'scope_operations': operations};
    });
    return confirmed;
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
