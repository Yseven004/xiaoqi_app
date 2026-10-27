import 'dart:convert';

import 'package:genkit/genkit.dart';

import 'code_execution_service.dart';
import 'store.dart';
import 'tool_access_policy.dart';
import 'release.dart';

/// The polling API resumes the same interrupted SDK request as streaming.
/// The snapshot belongs to the task and is never accepted from tool arguments.
class NetworkResume {
  NetworkResume(this.store, this.tenant, this.taskId);
  final CloudStore store;
  final String tenant;
  final String taskId;
  String get _key => 'task/$tenant/$taskId';
  String _requestDigest(Map<String, dynamic> request) =>
      ToolAccessPolicy.actionHash(
        connectionId: 'task-resume',
        tool: 'network',
        requestIdentity: 'input',
        authority: request,
      );

  void save({
    required Map<String, dynamic> request,
    required List<Message> messages,
    required ToolRequestPart pending,
  }) {
    final permission = pending.metadata?['interrupt'] as Map;
    final body = utf8.encode(
      jsonEncode({
        'messages': messages.map((message) => message.toJson()).toList(),
        'pending': pending.toJson(),
      }),
    );
    if (body.length > 8 * 1024 * 1024) throw StateError('待确认的任务记录过大，无法安全恢复');
    final hash = permission['approval_hash'].toString();
    final objectKey = 'tenants/$tenant/tasks/$taskId/network-resume/$hash';
    store.putTaskBlob(objectKey, body);
    final current = store.get(_key)!;
    final previous = current.value['network_resume'];
    store.put(_key, {
      ...current.value,
      'network_resume': {
        'request_digest': _requestDigest(request),
        'object_key': objectKey,
        'approval_hash': hash,
        'release_id': releaseId,
        'api_contract_version': apiContractVersion,
      },
    }, current.revision);
    final previousKey = previous is Map
        ? previous['object_key']?.toString()
        : null;
    if (previousKey != null &&
        previousKey != objectKey &&
        previousKey.startsWith(
          'tenants/$tenant/tasks/$taskId/network-resume/',
        )) {
      store.deleteImmutable(previousKey);
    }
  }

  ({List<Message> messages, List<ToolRequestPart> restart})? load(
    Map<String, dynamic> request,
  ) {
    final task = store.get(_key)?.value;
    final saved = task?['network_resume'];
    if (saved is! Map ||
        saved['completed'] == true ||
        saved['request_digest'] != _requestDigest(request))
      return null;
    if (saved['release_id'] != releaseId ||
        saved['api_contract_version'] != apiContractVersion) {
      throw StateError('待确认任务来自旧服务版本，请按当前版本重新开始任务');
    }
    final hash = saved['approval_hash'];
    final decision = (task?['tool_authorizations'] as Map?)?[hash];
    if (decision is! bool) return null;
    final objectKey = saved['object_key']?.toString() ?? '';
    if (objectKey != 'tenants/$tenant/tasks/$taskId/network-resume/$hash') {
      throw StateError('待恢复的联网操作不属于当前任务');
    }
    final body = jsonDecode(utf8.decode(store.getObject(objectKey))) as Map;
    final pending = ToolRequestPart.fromJson(
      Map<String, dynamic>.from(body['pending'] as Map),
    );
    final permission = pending.metadata?['interrupt'] as Map;
    if (permission['approval_hash'] != hash ||
        permission['type'] != 'network_permission') {
      throw StateError('待恢复的联网确认记录不一致');
    }
    return (
      messages: (body['messages'] as List)
          .map(
            (message) =>
                Message.fromJson(Map<String, dynamic>.from(message as Map)),
          )
          .toList(),
      restart: [
        pending.restart({
          'approved': decision,
          'approval_hash': hash,
          'domains': permission['domains'],
        }),
      ],
    );
  }

  NetworkPermissionRequired permission(ToolRequestPart pending) {
    final data = pending.metadata?['interrupt'] as Map;
    return NetworkPermissionRequired(
      (data['domains'] as List).cast<String>(),
      data['purpose'].toString(),
      approvalHash: data['approval_hash'].toString(),
      scopeHash: data['scope_hash'].toString(),
      details: Map<String, dynamic>.from(data['details'] as Map? ?? const {}),
    );
  }

  void complete(Map<String, dynamic> request) {
    final current = store.get(_key);
    final saved = current?.value['network_resume'];
    if (current == null ||
        saved is! Map ||
        saved['request_digest'] != _requestDigest(request))
      return;
    // Retain the last checkpoint as task data until normal task retention
    // cleanup; a later normal retry must not silently restart a completed turn.
    store.put(_key, {
      ...current.value,
      'network_resume': {...saved, 'completed': true},
    }, current.revision);
  }
}
