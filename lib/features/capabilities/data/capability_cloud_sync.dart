import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../../config/api_config.dart';
import 'capability_models.dart';
import 'capability_store.dart';

class CapabilityCloudSync {
  CapabilityCloudSync._();

  static final instance = CapabilityCloudSync._();
  static const _tokenKey = 'xiaoqi.capabilities.device_token.v1';
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final http.Client _client = http.Client();
  Future<void>? _syncing;

  String get _baseUrl =>
      ApiConfig.capabilitiesBaseUrl.replaceFirst(RegExp(r'/$'), '');

  Future<bool> get isPaired async =>
      (await _secureStorage.read(key: _tokenKey))?.isNotEmpty == true;

  Future<void> pair(String code) async {
    final response = await _client
        .post(
          Uri.parse('$_baseUrl/pair'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'code': code.trim()}),
        )
        .timeout(const Duration(seconds: 15));
    final decoded = _decode(response);
    final token = decoded['access_token']?.toString();
    if (response.statusCode != 201 || token == null || token.length < 24) {
      throw StateError(_errorMessage(decoded, '配对失败'));
    }
    await _secureStorage.write(key: _tokenKey, value: token);
    try {
      await syncNow();
    } catch (error) {
      throw StateError('设备已连接，首次同步未完成：$error');
    }
  }

  Future<void> unpair() async {
    final token = await _secureStorage.read(key: _tokenKey);
    if (token != null) {
      final response = await _client
          .delete(Uri.parse('$_baseUrl/devices/me'), headers: _headers(token))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode >= 500 || response.statusCode == 429) {
        throw StateError(_errorMessage(_decode(response), '设备撤销失败'));
      }
      if (response.statusCode != 401 &&
          (response.statusCode < 200 || response.statusCode >= 300)) {
        throw StateError(_errorMessage(_decode(response), '设备撤销失败'));
      }
    }
    await _secureStorage.delete(key: _tokenKey);
  }

  Future<void> syncNow() {
    return _syncing ??= _sync().whenComplete(() => _syncing = null);
  }

  Future<void> _sync() async {
    final token = await _secureStorage.read(key: _tokenKey);
    if (token == null || token.isEmpty) throw StateError('尚未连接云同步');
    final store = CapabilityStore.instance;
    for (final record in await store.list(includeDeleted: true)) {
      if (record.syncState == CapabilitySyncState.synced ||
          record.syncState == CapabilitySyncState.conflict) {
        continue;
      }
      final response = await _client
          .post(
            Uri.parse('$_baseUrl/capabilities/sync'),
            headers: _headers(token),
            body: jsonEncode({
              'record': record.toJson(),
              'expected_revision': record.cloudRevision,
            }),
          )
          .timeout(const Duration(seconds: 25));
      final decoded = _decode(response);
      if (response.statusCode == 409) {
        final remote = decoded['error'] is Map
            ? (decoded['error'] as Map)['current']
            : null;
        if (remote is Map) await _keepConflictCopies(store, record, remote);
        await store.markConflict(record.id);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(_errorMessage(decoded, '技能同步失败'));
      }
      final remote = decoded['record'];
      if (remote is Map) {
        await store.applyRemote(CapabilityRecord.fromJson(remote));
      } else {
        await store.markSynced(
          record.id,
          (decoded['cloud_revision'] as num?)?.toInt() ??
              record.cloudRevision + 1,
        );
      }
    }

    for (final draft in await store.drafts()) {
      final response = await _client
          .put(
            Uri.parse('$_baseUrl/drafts'),
            headers: _headers(token),
            body: jsonEncode({
              'draft': draft.toJson(),
              'expected_revision': draft.cloudRevision,
            }),
          )
          .timeout(const Duration(seconds: 20));
      final decoded = _decode(response);
      if (response.statusCode == 409) {
        final remote = decoded['error'] is Map
            ? (decoded['error'] as Map)['current']
            : null;
        if (remote is Map) {
          await _saveDraftConflict(store, draft, remote);
          await store.discardDraft(draft.id);
        }
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(_errorMessage(decoded, '草稿同步失败'));
      }
      final revision = (decoded['cloud_revision'] as num?)?.toInt();
      if (revision != null) await store.markDraftSynced(draft.id, revision);
    }

    final response = await _client
        .get(Uri.parse('$_baseUrl/capabilities'), headers: _headers(token))
        .timeout(const Duration(seconds: 25));
    final decoded = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_errorMessage(decoded, '读取云端能力失败'));
    }
    final items = decoded['items'];
    if (items is List) {
      for (final raw in items.whereType<Map>()) {
        final remote = CapabilityRecord.fromJson(raw);
        final local = await store.find(remote.id);
        if (local == null ||
            (local.syncState == CapabilitySyncState.synced &&
                remote.cloudRevision > local.cloudRevision)) {
          await store.applyRemote(remote);
        }
      }
    }

    final draftResponse = await _client
        .get(Uri.parse('$_baseUrl/drafts'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final draftDecoded = _decode(draftResponse);
    if (draftResponse.statusCode >= 200 &&
        draftResponse.statusCode < 300 &&
        draftDecoded['items'] is List) {
      final localIds = (await store.drafts()).map((draft) => draft.id).toSet();
      for (final raw in (draftDecoded['items'] as List).whereType<Map>()) {
        if (localIds.contains(raw['id']?.toString())) continue;
        await store.saveDraft(CapabilityDraft.fromJson(raw));
      }
    }
  }

  Future<void> _keepConflictCopies(
    CapabilityStore store,
    CapabilityRecord local,
    Map remoteJson,
  ) async {
    final localVersion = local.currentVersion;
    if (localVersion != null) {
      await store.saveDraft(
        CapabilityDraft(
          id: store.newDraftId(),
          kind: local.kind,
          name: '${local.name}（本机冲突副本）',
          description: local.description,
          content: localVersion.content,
          files: localVersion.files,
          updatedAt: DateTime.now(),
          userSuggestion: '多设备修改冲突，保留本机内容供手动合并。',
        ),
      );
    }
    final remote = CapabilityRecord.fromJson(remoteJson);
    final remoteVersion = remote.currentVersion;
    if (remoteVersion != null) {
      await store.saveDraft(
        CapabilityDraft(
          id: store.newDraftId(),
          kind: remote.kind,
          name: '${remote.name}（云端冲突副本）',
          description: remote.description,
          content: remoteVersion.content,
          files: remoteVersion.files,
          updatedAt: DateTime.now(),
          userSuggestion: '多设备修改冲突，保留云端内容供手动合并。',
        ),
      );
    }
    if (remote.isDeleted) await store.applyRemote(remote);
  }

  Future<void> _saveDraftConflict(
    CapabilityStore store,
    CapabilityDraft local,
    Map remoteJson,
  ) async {
    final remote = CapabilityDraft.fromJson(remoteJson);
    await store.saveDraft(
      CapabilityDraft(
        id: store.newDraftId(),
        kind: local.kind,
        name: '${local.name}（本机草稿冲突副本）',
        description: local.description,
        content: local.content,
        files: local.files,
        updatedAt: DateTime.now(),
        userSuggestion: '多设备草稿冲突，保留本机版本。',
      ),
    );
    await store.saveDraft(
      CapabilityDraft(
        id: store.newDraftId(),
        kind: remote.kind,
        name: '${remote.name}（云端草稿冲突副本）',
        description: remote.description,
        content: remote.content,
        files: remote.files,
        updatedAt: remote.updatedAt,
        userSuggestion: '多设备草稿冲突，保留云端版本。',
      ),
    );
  }

  Future<Map<String, dynamic>> createAgentTask({
    required List<Map<String, Object?>> messages,
    required String modelId,
    required String reasoningLevel,
    required Map<String, Object?>? capability,
    String? taskId,
    List<Map<String, Object?>> materials = const [],
  }) async {
    final token = await _requireToken();
    final requestBody = jsonEncode({
      'task_id': taskId ?? newTaskId(),
      'messages': messages,
      'model_id': modelId,
      'reasoning_level': reasoningLevel,
      if (capability != null)
        'capability': {
          'id': capability['id'],
          'version_id': capability['version_id'],
        },
      'materials': materials,
    });
    late http.Response response;
    try {
      response = await _postAgentTask(token, requestBody);
    } on TimeoutException {
      response = await _postAgentTask(token, requestBody);
    } on http.ClientException {
      response = await _postAgentTask(token, requestBody);
    }
    final decoded = _decode(response);
    if (response.statusCode != 202 && response.statusCode != 200) {
      throw StateError(_errorMessage(decoded, '技能任务无法启动'));
    }
    return decoded;
  }

  Future<http.Response> _postAgentTask(String token, String body) => _client
      .post(
        Uri.parse('$_baseUrl/agent/tasks'),
        headers: _headers(token),
        body: body,
      )
      .timeout(const Duration(seconds: 25));

  Future<Map<String, dynamic>> getTask(String taskId) async {
    final token = await _requireToken();
    final response = await _client.get(
      Uri.parse('$_baseUrl/agent/tasks/$taskId'),
      headers: _headers(token),
    );
    return _checked(response);
  }

  Future<Map<String, dynamic>> getTaskEvents(String taskId, int after) async {
    final token = await _requireToken();
    final response = await _client.get(
      Uri.parse('$_baseUrl/agent/tasks/$taskId/events?after=$after'),
      headers: _headers(token),
    );
    return _checked(response);
  }

  Stream<Map<String, dynamic>> watchTask(String taskId) async* {
    var cursor = -1;
    final started = DateTime.now();
    var completionReceived = false;
    var errorReceived = false;
    while (DateTime.now().difference(started) < const Duration(minutes: 20)) {
      final response = await getTaskEvents(taskId, cursor);
      final events = response['events'];
      if (events is List) {
        for (final raw in events.whereType<Map>()) {
          final event = raw.cast<String, dynamic>();
          cursor = max(cursor, (event['seq'] as num?)?.toInt() ?? cursor);
          if (event['type'] == 'completed') completionReceived = true;
          if (event['type'] == 'error') errorReceived = true;
          yield event;
        }
      }
      final status = response['status']?.toString();
      if (status == 'succeeded' ||
          status == 'failed' ||
          status == 'cancelled') {
        if (!completionReceived && status == 'succeeded') {
          final task = await getTask(taskId);
          yield {
            'type': 'completed',
            'status': status,
            'text': task['result'],
            'draft': task['draft'],
            'artifacts': task['artifacts'] ?? const [],
          };
        } else if (status == 'failed' && !errorReceived) {
          final task = await getTask(taskId);
          if (task['error'] != null) {
            yield {'type': 'error', 'message': task['error']};
          }
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException('技能任务等待超时，可稍后恢复。');
  }

  Future<Uint8List> downloadTaskArtifact(
    String taskId,
    String artifactId,
  ) async {
    final token = await _requireToken();
    final response = await _client.get(
      Uri.parse(
        '$_baseUrl/agent/tasks/${Uri.encodeComponent(taskId)}/artifacts/${Uri.encodeComponent(artifactId)}',
      ),
      headers: _headers(token),
    );
    if (response.statusCode != 200) {
      final decoded = _decode(response);
      throw StateError(_errorMessage(decoded, '文件下载失败'));
    }
    return response.bodyBytes;
  }

  Future<void> cancelTask(String taskId) async {
    final token = await _requireToken();
    final response = await _client.post(
      Uri.parse('$_baseUrl/agent/tasks/$taskId/cancel'),
      headers: _headers(token),
    );
    _checked(response);
  }

  Future<void> authorizeTaskDomains(String taskId, List<String> domains) async {
    final token = await _requireToken();
    final response = await _client.post(
      Uri.parse('$_baseUrl/agent/tasks/$taskId/authorize-network'),
      headers: _headers(token),
      body: jsonEncode({'domains': domains}),
    );
    _checked(response);
  }

  Future<void> resumeTask(String taskId) async {
    final token = await _requireToken();
    final response = await _client.post(
      Uri.parse('$_baseUrl/agent/tasks/$taskId/resume'),
      headers: _headers(token),
    );
    _checked(response);
  }

  Future<String> _requireToken() async {
    final token = await _secureStorage.read(key: _tokenKey);
    if (token == null || token.isEmpty) throw StateError('请先连接云同步');
    return token;
  }

  static String newTaskId() {
    final random = Random.secure();
    final suffix = List<int>.generate(
      24,
      (_) => random.nextInt(16),
    ).map((value) => value.toRadixString(16)).join();
    return 'task-$suffix';
  }

  Map<String, String> _headers(String token) => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  Map<String, dynamic> _checked(http.Response response) {
    final decoded = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_errorMessage(decoded, '云端请求失败'));
    }
    return decoded;
  }

  Map<String, dynamic> _decode(http.Response response) {
    final value = jsonDecode(utf8.decode(response.bodyBytes));
    if (value is! Map) throw StateError('云端返回格式无效');
    return value.cast<String, dynamic>();
  }

  String _errorMessage(Map<String, dynamic> value, String fallback) {
    final error = value['error'];
    return error is Map ? error['message']?.toString() ?? fallback : fallback;
  }
}
