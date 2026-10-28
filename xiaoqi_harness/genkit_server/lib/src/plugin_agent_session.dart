import 'package:genkit/genkit.dart';
import 'package:genkit/experimental.dart';

import 'store.dart';
import 'tool_execution.dart';

/// Resumes the exact private child session; no child prompt/state comes from
/// the model or approval payload. The public approval uses the existing card.
class PluginAgentSessionResult {
  PluginAgentSessionResult(this.result, {this.interrupt});
  final Map<String, dynamic> result;
  final Map<String, dynamic>? interrupt;
}

class PluginAgentSessions {
  PluginAgentSessions(this.store);
  final CloudStore store;
  static final _active = <String>{};

  Future<PluginAgentSessionResult> run({
    required Agent<dynamic> agent,
    required ToolExecution owner,
    required String invocation,
    required String definitionBinding,
    required String task,
    required CancellationToken cancellation,
    Map<String, dynamic>? resumed,
  }) async {
    cancellation.throwIfCancelled();
    owner.check('workspace');
    if (invocation.isEmpty || task.trim().isEmpty)
      throw const FormatException('子 Agent 调用身份和任务不能为空');
    final binding = ToolExecution.digest([definitionBinding, task]);
    final key =
        'private_plugin_agent/${owner.tenantId}/${owner.taskId}/${ToolExecution.digest([owner.requestIdentity, invocation])}';
    final activeKey = '${store.root.absolute.path}/$key';
    if (!_active.add(activeKey))
      throw UnconfirmedToolOperation('原子 Agent 仍在执行，不能重复提交');
    final childCancellation = CancellationController();
    final unregister = cancellation.onCancel(
      () => childCancellation.cancel(cancellation.reason),
    );
    String? operation;
    try {
      var saved = store.get(key);
      if (saved != null && saved.value['binding'] != binding)
        throw StateError('子 Agent 的版本、工具或任务绑定已变化，不能恢复原会话');
      if (saved == null && resumed != null)
        throw StateError('原子 Agent 审批会话不存在，不能把审批用于新会话');
      operation = owner.beginDelegation(invocation, binding);
      if (saved?.value['phase'] == 'completed' ||
          saved?.value['phase'] == 'failed') {
        final result = Map<String, dynamic>.from(saved!.value['result'] as Map);
        owner.checkpointDelegation(
          operation,
          result['ok'] == true ? 'succeeded' : 'failed',
        );
        return PluginAgentSessionResult(result);
      }
      if (const {'active', 'unknown'}.contains(saved?.value['phase'])) {
        owner.checkpointDelegation(operation, 'unknown');
        throw UnconfirmedToolOperation('原子 Agent 的执行结果尚未确认，不能从头重跑其任务');
      }
      final pending = (saved?.value['pending'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (part) => ToolRequestPart.fromJson(Map<String, dynamic>.from(part)),
          )
          .toList();
      List<ToolRequestPart>? restarts;
      if (saved?.value['phase'] == 'interrupted') {
        if (pending.isEmpty) throw StateError('原子 Agent 审批请求缺失，不能恢复');
        if (resumed == null) {
          owner.checkpointDelegation(operation, 'interrupted');
          return PluginAgentSessionResult(
            {'ok': false, 'status': 'interrupted'},
            interrupt: Map<String, dynamic>.from(
              pending.first.metadata!['interrupt'] as Map,
            ),
          );
        }
        if (resumed['approved'] is! bool || resumed['approval_hash'] is! String)
          throw StateError('子 Agent 审批响应格式无效');
        final part = pending
            .where(
              (part) =>
                  (part.metadata?['interrupt'] as Map?)?['approval_hash'] ==
                  resumed['approval_hash'],
            )
            .firstOrNull;
        if (part == null) throw StateError('子 Agent 审批不属于原始请求');
        // SDK resume requires every pending request. Only the selected request
        // receives a decision; the others re-enter their existing approval
        // guard with no grant and remain interrupted, without submitting an effect.
        restarts = [
          for (final original in pending)
            original.restart(identical(original, part) ? resumed : const {}),
        ];
      } else if (resumed != null) {
        throw StateError('子 Agent 当前没有待恢复审批');
      }
      if (saved == null) {
        saved = store.put(key, {'binding': binding, 'phase': 'prepared'}, null);
      }
      final state = saved.value['state'];
      final chat = agent.chat(
        state: state is Map
            ? SessionState.fromJson(Map<String, dynamic>.from(state))
            : null,
      );
      owner.check('workspace');
      cancellation.throwIfCancelled();
      saved = store.put(key, {
        ...saved.value,
        'phase': 'active',
      }, saved.revision);
      owner.checkpointDelegation(operation, 'running');
      final context = {'xiaoqi_plugin_agent_invocation': key};
      final turn = restarts == null
          ? chat.sendStream(
              text: task,
              cancel: childCancellation.token,
              context: context,
            )
          : chat.resumeStream(
              restart: restarts,
              cancel: childCancellation.token,
              context: context,
            );
      await for (final _ in turn.stream) {
        cancellation.throwIfCancelled();
        owner.check('read');
      }
      final response = await turn.response;
      final interrupts = response.toolRequests
          // Genkit 1.0.0 preserves an old interrupt marker alongside the
          // completed pendingOutput while another parallel request is paused.
          // Such a completed request must neither be shown nor restarted.
          .where(
            (part) =>
                part.metadata?['interrupt'] is Map &&
                part.metadata?['pendingOutput'] == null,
          )
          .toList();
      final interrupted =
          response.finishReason == AgentFinishReason.interrupted &&
          interrupts.isNotEmpty;
      final completed =
          response.finishReason == AgentFinishReason.stop &&
          response.text.trim().isNotEmpty;
      final result = {
        'ok': completed,
        'status': interrupted
            ? 'interrupted'
            : completed
            ? 'completed'
            : 'failed',
        'finish_reason': response.finishReason.value,
        if (completed) 'text': response.text,
        if (!interrupted && !completed) 'error': '子 Agent 未完成任务，请检查任务执行记录',
      };
      final snapshot =
          response.raw.state ??
          SessionState(messages: chat.messages, artifacts: chat.artifacts);
      final current = store.get(key)!;
      store.put(key, {
        ...current.value,
        'phase': interrupted
            ? 'interrupted'
            : completed
            ? 'completed'
            : 'failed',
        'state': snapshot.toJson(),
        'pending': interrupts.map((part) => part.toJson()).toList(),
        'result': result,
      }, current.revision);
      owner.checkpointDelegation(
        operation,
        interrupted
            ? 'interrupted'
            : completed
            ? 'succeeded'
            : 'failed',
      );
      cancellation.throwIfCancelled();
      owner.check('read');
      return PluginAgentSessionResult(
        result,
        interrupt: interrupted
            ? Map<String, dynamic>.from(
                interrupts.first.metadata!['interrupt'] as Map,
              )
            : null,
      );
    } on Object {
      childCancellation.cancel('child delegation stopped');
      final current = store.get(key);
      if (current?.value['phase'] == 'active') {
        store.put(key, {
          ...current!.value,
          'phase': 'unknown',
        }, current.revision);
        if (operation != null) owner.checkpointDelegation(operation, 'unknown');
      }
      rethrow;
    } finally {
      unregister();
      _active.remove(activeKey);
    }
  }
}
