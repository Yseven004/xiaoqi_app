import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:genkit/experimental_client.dart' as genkit_client;
import 'package:http/http.dart' as http;

import '../../../config/api_config.dart';
import 'capability_models.dart';
import 'capability_store.dart';

({String code, String message, String details}) _presentTaskFailure(
  Object? value, {
  Object? fallback,
  bool imageGeneration = false,
}) {
  final raw = (value ?? fallback)?.toString().trim() ?? '';
  final normalized = raw.toLowerCase();
  final isArkFailure =
      normalized.contains('seedream') ||
      normalized.contains('生图服务') ||
      normalized.contains('生图结果') ||
      normalized.contains('ark');
  final isImageGenerationFailure =
      imageGeneration || normalized.contains('generate_image') || isArkFailure;
  final details = raw
      .replaceAll(RegExp(r'Bearer\s+\S+', caseSensitive: false), 'Bearer [已隐藏]')
      .replaceAll(
        RegExp(r'\b(?:ark|sk)-[A-Za-z0-9_-]{12,}\b', caseSensitive: false),
        '[密钥已隐藏]',
      );
  if (RegExp(
    r'(overdue balance|balance.{0,16}overdue|account.{0,24}overdue|past[- ]due|outstanding balance|insufficient balance|账户欠费|账户逾期|余额不足|欠费)',
  ).hasMatch(normalized)) {
    return (
      code: isArkFailure
          ? 'ark_account_overdue'
          : 'text_model_billing_required',
      message: isArkFailure
          ? '图片生成失败：火山引擎 Ark 账户存在逾期欠款，Seedream 已拒绝请求。请在火山引擎控制台结清欠款后重试。'
          : '任务失败：文字模型服务提示账户欠费或余额不足，请在对应服务商控制台处理账单后重试。',
      details: details,
    );
  }
  if (normalized.contains('ark_api_key')) {
    return (
      code: 'ark_not_configured',
      message:
          '图片生成失败：服务端没有配置火山引擎 Ark 密钥（ARK_API_KEY）。请在实际连接的 API 服务器配置密钥并重启服务。',
      details: details,
    );
  }
  if (normalized.contains('create-image') ||
      normalized.contains('所选技能') ||
      normalized.contains('技能不存在') ||
      (imageGeneration && normalized.contains('技能 id 无效'))) {
    return (
      code: 'image_action_not_deployed',
      message:
          '图片生成失败：服务端把“创建图像”当成了普通技能加载；该内置动作没有技能版本 ID（version_id），所以在调用 Seedream 前就失败了。请更新并重启当前连接的 Genkit 服务端，使其支持 create-image 动作。',
      details: details,
    );
  }
  if (normalized.contains('mimo_api_key') ||
      normalized.contains('deepseek_api_key')) {
    return (
      code: 'text_model_not_configured',
      message: '任务失败：服务端缺少所选文字模型的 API Key，请配置后重启服务。',
      details: details,
    );
  }

  final status = RegExp(
    r'(?:http|返回错误)\s*[\(: ]\s*(\d{3})',
    caseSensitive: false,
  ).firstMatch(raw)?.group(1);
  if (status != null) {
    final statusCode = int.tryParse(status);
    if (isImageGenerationFailure &&
        isArkFailure &&
        (statusCode == 401 || statusCode == 403)) {
      return (
        code: 'ark_auth_failed',
        message:
            '图片生成失败：Seedream 拒绝了服务器凭据（HTTP $status）。请检查 Ark API Key 和模型权限。',
        details: details,
      );
    }
    if (isImageGenerationFailure && isArkFailure && statusCode == 429) {
      return (
        code: 'ark_rate_limited',
        message: '图片生成失败：Seedream 当前限流或额度不足（HTTP 429），请查看 Ark 配额。',
        details: details,
      );
    }
    if (isImageGenerationFailure && isArkFailure && statusCode == 400) {
      return (
        code: 'ark_request_rejected',
        message: '图片生成失败：Seedream 拒绝了请求（HTTP 400）。$details',
        details: details,
      );
    }
    if (isImageGenerationFailure &&
        isArkFailure &&
        statusCode != null &&
        statusCode >= 500) {
      return (
        code: 'ark_server_error',
        message: '图片生成失败：Seedream 服务端暂时异常（HTTP $status），请稍后再试。',
        details: details,
      );
    }
    if (statusCode == 401 || statusCode == 403) {
      return (
        code: 'upstream_auth_failed',
        message: isImageGenerationFailure
            ? '图片任务未能启动：文字模型服务鉴权失败（HTTP $status）。'
            : '任务失败：上游模型服务鉴权失败（HTTP $status）。',
        details: details,
      );
    }
    if (statusCode == 429) {
      return (
        code: 'upstream_rate_limited',
        message: '任务失败：上游模型服务限流或额度不足（HTTP 429）。',
        details: details,
      );
    }
    if (statusCode != null && statusCode >= 500) {
      return (
        code: 'upstream_server_error',
        message: '任务失败：上游服务暂时异常（HTTP $status）。',
        details: details,
      );
    }
  }
  if (normalized.contains('timeout') || normalized.contains('超时')) {
    return (
      code: 'task_timeout',
      message:
          isImageGenerationFailure &&
              (normalized.contains('seedream') ||
                  normalized.contains('生图服务') ||
                  normalized.contains('生图结果'))
          ? '图片生成请求超时。服务端没有自动重试；结果可能未知，请确认 Ark 任务状态后再重试。'
          : '任务等待上游服务响应超时。请先确认任务状态，再决定是否重试。',
      details: details,
    );
  }
  if (normalized.contains('socketexception') ||
      normalized.contains('clientexception') ||
      normalized.contains('failed host lookup')) {
    return (
      code: 'task_network_error',
      message: '任务失败：服务端无法连接上游服务，请检查服务器网络和 DNS。',
      details: details,
    );
  }

  final clean = details
      .replaceFirst(RegExp(r'^(Bad state: |Exception: |HttpException: )'), '')
      .trim();
  if (clean.isEmpty ||
      clean == '任务执行失败，请检查服务端配置或稍后重试' ||
      clean == '图片生成失败，请检查服务端配置或稍后重试') {
    return (
      code: 'task_error_details_unavailable',
      message: '服务端只返回了通用失败状态，没有提供具体原因。',
      details: '',
    );
  }
  return (
    code: 'agent_task_failed',
    message: '任务执行失败：$clean',
    details: details,
  );
}

class CapabilityCloudSync {
  CapabilityCloudSync._();

  static final instance = CapabilityCloudSync._();
  static const _tokenKey = 'xiaoqi.capabilities.device_token.v1';
  static const _authMethodKey = 'xiaoqi.auth.method.v1';
  static const _emailKey = 'xiaoqi.auth.email.v1';
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final http.Client _client = http.Client();
  genkit_client.AgentApi<Map<String, dynamic>>? _remoteAgent;
  Future<void>? _syncing;
  bool _syncAgain = false;

  String get _baseUrl {
    final value = ApiConfig.capabilitiesBaseUrl.trim();
    if (value.isEmpty) {
      throw StateError('小七服务地址尚未配置，请在构建时设置 CAPABILITIES_BASE_URL。');
    }
    return value.replaceFirst(RegExp(r'/$'), '');
  }

  Future<bool> get hasEmailSession => hasLocalEmailSession;

  Future<bool> get hasLocalEmailSession async {
    final method = await _secureStorage.read(key: _authMethodKey);
    final token = await _secureStorage.read(key: _tokenKey);
    return method == 'email' && token?.isNotEmpty == true;
  }

  Future<Map<String, String>> authenticatedHeaders() async {
    final method = await _secureStorage.read(key: _authMethodKey);
    final token = await _secureStorage.read(key: _tokenKey);
    if (method != 'email' || token == null || token.isEmpty) {
      throw StateError('请先登录个人账号');
    }
    return _headers(token);
  }

  Future<String?> get signedInEmail => _secureStorage.read(key: _emailKey);

  Future<void> requestEmailLoginCode(String email) async {
    final response = await _client
        .post(
          Uri.parse('$_baseUrl/auth/email/start'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email.trim()}),
        )
        .timeout(const Duration(seconds: 20));
    final decoded = _decode(response);
    if (response.statusCode != 202) {
      throw StateError(_errorMessage(decoded, '验证码暂时发送失败，请稍后重试'));
    }
  }

  Future<String> signInWithEmailCode({
    required String email,
    required String code,
  }) async {
    final previousToken = await _secureStorage.read(key: _tokenKey);
    final response = await _client
        .post(
          Uri.parse('$_baseUrl/auth/email/verify'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email.trim(), 'code': code.trim()}),
        )
        .timeout(const Duration(seconds: 20));
    final decoded = _decode(response);
    final token = decoded['access_token']?.toString();
    if (response.statusCode != 201 || token == null || token.length < 24) {
      throw StateError(_errorMessage(decoded, '验证码无效或已过期'));
    }

    await _secureStorage.write(key: _tokenKey, value: token);
    await _secureStorage.write(key: _authMethodKey, value: 'email');
    await _secureStorage.write(
      key: _emailKey,
      value: decoded['email']?.toString() ?? email.trim(),
    );

    if (previousToken != null &&
        previousToken.isNotEmpty &&
        previousToken != token) {
      try {
        await _client
            .delete(
              Uri.parse('$_baseUrl/devices/me'),
              headers: _headers(previousToken),
            )
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        // The email session is already valid; cleanup of an older paired token
        // must not block sign-in or the user's local content.
      }
    }
    return decoded['email']?.toString() ?? email.trim();
  }

  Future<bool> validateEmailSession() async {
    if (!await hasLocalEmailSession) return false;
    final token = await _secureStorage.read(key: _tokenKey);
    if (token == null || token.isEmpty) return false;
    final response = await _client
        .get(Uri.parse('$_baseUrl/auth/me'), headers: _headers(token))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 200) return true;
    if (response.statusCode == 401) {
      await _clearLocalSession();
      return false;
    }
    final decoded = _decode(response);
    throw StateError(_errorMessage(decoded, '登录状态暂时无法验证'));
  }

  Future<void> signOut() async {
    final token = await _secureStorage.read(key: _tokenKey);
    if (token != null && token.isNotEmpty) {
      final response = await _client
          .delete(Uri.parse('$_baseUrl/auth/session'), headers: _headers(token))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 401) {
        await _clearLocalSession();
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(_errorMessage(_decode(response), '退出登录失败'));
      }
    }
    await _clearLocalSession();
  }

  Future<void> _clearLocalSession() async {
    await _secureStorage.delete(key: _tokenKey);
    await _secureStorage.delete(key: _authMethodKey);
    await _secureStorage.delete(key: _emailKey);
  }

  Future<void> syncNow() {
    final active = _syncing;
    if (active != null) {
      _syncAgain = true;
      return active;
    }
    final operation = _syncPendingRequests();
    _syncing = operation.whenComplete(() => _syncing = null);
    return _syncing!;
  }

  Future<void> _syncPendingRequests() async {
    do {
      _syncAgain = false;
      await _sync();
    } while (_syncAgain);
  }

  Future<void> _sync() async {
    final token = await _secureStorage.read(key: _tokenKey);
    if (token == null || token.isEmpty) throw StateError('请先登录个人账号');
    final store = CapabilityStore.instance;
    final accountEmail = (await signedInEmail)?.trim().toLowerCase() ?? '';
    for (final deletion in await store.pendingDraftDeletions()) {
      final ownerEmail = deletion['account_email']?.toString() ?? '';
      if (ownerEmail.isNotEmpty && ownerEmail != accountEmail) continue;
      final id = deletion['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final response = await _client
          .delete(
            Uri.parse('$_baseUrl/drafts/${Uri.encodeComponent(id)}'),
            headers: _headers(token),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(_errorMessage(_decode(response), '草稿删除同步失败'));
      }
      await store.completeDraftDeletion(id, ownerEmail);
    }

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
      if (draft.cloudOwnerEmail != null &&
          draft.cloudOwnerEmail!.trim().toLowerCase() != accountEmail) {
        continue;
      }
      final response = await _client
          .put(
            Uri.parse('$_baseUrl/drafts'),
            headers: _headers(token),
            body: jsonEncode({
              'draft': draft.toJson(includeLocalMetadata: false),
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
          if (remote['deleted_at'] != null) {
            await store.rememberRemoteDraftDeletion(
              draft.id,
              accountEmail: accountEmail,
            );
            continue;
          }
          await _saveDraftConflict(store, draft, remote);
          await store.discardDraft(draft.id);
        }
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          _errorMessage(decoded, '草稿同步失败', statusCode: response.statusCode),
        );
      }
      final revision = (decoded['cloud_revision'] as num?)?.toInt();
      if (revision != null) {
        await store.markDraftSynced(
          draft.id,
          revision,
          accountEmail: accountEmail.isEmpty ? null : accountEmail,
        );
      }
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
        final id = raw['id']?.toString();
        if (id == null || id.isEmpty) continue;
        if (raw['deleted_at'] != null) {
          await store.rememberRemoteDraftDeletion(
            id,
            accountEmail: accountEmail,
          );
          continue;
        }
        if (await store.isDraftDeleted(id)) continue;
        if (localIds.contains(id)) continue;
        await store.saveDraft(
          CapabilityDraft.fromJson(raw).copyWith(
            cloudOwnerEmail: accountEmail.isEmpty ? null : accountEmail,
          ),
        );
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
          if (capability['type'] != null) 'type': capability['type'],
          'id': capability['id'],
          if (capability['version_id'] != null)
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

  genkit_client.AgentApi<Map<String, dynamic>> createRemoteAgent() =>
      _remoteAgent ??= genkit_client.remoteAgent<Map<String, dynamic>>(
        url: '$_baseUrl/v1/agent/chat',
        headers: () async => _headers(await _requireToken()),
      );

  Future<http.Response> _postAgentTask(String token, String body) => _client
      .post(
        Uri.parse('$_baseUrl/agent/tasks'),
        headers: _headers(token),
        body: body,
      )
      .timeout(const Duration(seconds: 25));

  Future<Map<String, dynamic>> getTask(String taskId) async {
    final token = await _requireToken();
    final response = await _client
        .get(
          Uri.parse('$_baseUrl/agent/tasks/$taskId'),
          headers: _headers(token),
        )
        .timeout(const Duration(seconds: 20));
    return _checked(response);
  }

  Future<Map<String, dynamic>> getTaskEvents(String taskId, int after) async {
    final token = await _requireToken();
    final response = await _client
        .get(
          Uri.parse('$_baseUrl/agent/tasks/$taskId/events?after=$after'),
          headers: _headers(token),
        )
        .timeout(const Duration(seconds: 20));
    return _checked(response);
  }

  Stream<Map<String, dynamic>> watchTask(
    String taskId, {
    bool imageGeneration = false,
  }) async* {
    var cursor = -1;
    final started = DateTime.now();
    var completionReceived = false;
    var errorReceived = false;
    var consecutiveNetworkFailures = 0;
    while (DateTime.now().difference(started) < const Duration(minutes: 20)) {
      late final Map<String, dynamic> response;
      try {
        response = await getTaskEvents(taskId, cursor);
        consecutiveNetworkFailures = 0;
      } on TimeoutException {
        consecutiveNetworkFailures++;
        if (consecutiveNetworkFailures >= 3) {
          throw TimeoutException('连接云端任务超时，可重新打开会话恢复。');
        }
        await Future<void>.delayed(
          Duration(seconds: consecutiveNetworkFailures),
        );
        continue;
      } on http.ClientException {
        consecutiveNetworkFailures++;
        if (consecutiveNetworkFailures >= 3) {
          throw http.ClientException('连接云端任务失败，可重新打开会话恢复。');
        }
        await Future<void>.delayed(
          Duration(seconds: consecutiveNetworkFailures),
        );
        continue;
      }
      final events = response['events'];
      if (events is List) {
        for (final raw in events.whereType<Map>()) {
          var event = raw.cast<String, dynamic>();
          cursor = max(cursor, (event['seq'] as num?)?.toInt() ?? cursor);
          if (event['type'] == 'completed') completionReceived = true;
          if (event['type'] == 'error') {
            errorReceived = true;
            event = await _detailedTaskErrorEvent(
              taskId,
              event['message'],
              event,
              imageGeneration,
            );
          }
          yield event;
          if (event['type'] == 'completed' || event['type'] == 'error') {
            return;
          }
        }
      }
      if (response['content_expired'] == true) return;
      final status = response['status']?.toString();
      final cleanupPending = response['sandbox_cleanup_pending'] == true;
      if (!cleanupPending &&
          (status == 'completed' ||
              status == 'succeeded' ||
              status == 'failed' ||
              status == 'cancelled')) {
        if (!completionReceived &&
            (status == 'completed' || status == 'succeeded')) {
          final task = await getTask(taskId);
          yield {
            'type': 'completed',
            'status': status,
            'text': task['result'],
            'draft': task['draft'],
            'files': task['files'],
            'artifacts': task['artifacts'] ?? const [],
          };
        } else if (status == 'failed' && !errorReceived) {
          final task = await getTask(taskId);
          if (task['error'] != null) {
            yield await _detailedTaskErrorEvent(
              taskId,
              task['error'],
              task,
              imageGeneration,
            );
          }
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException('技能任务等待超时，可稍后恢复。');
  }

  Future<Map<String, dynamic>> _detailedTaskErrorEvent(
    String taskId,
    Object? reportedMessage,
    Map<String, dynamic> reported,
    bool imageGeneration,
  ) async {
    final message = reportedMessage?.toString().trim() ?? '';
    final generic =
        message == '任务执行失败，请检查服务端配置或稍后重试' || message == '图片生成失败，请检查服务端配置或稍后重试';
    Map<String, dynamic> task = reported;
    if (generic || message.isEmpty) {
      try {
        task = await getTask(taskId);
      } on Object {
        // Preserve the original event when the follow-up detail request fails.
      }
    }
    final storedDetails = task['error_details'] ?? task['error'];
    if (!generic && message.isNotEmpty) {
      return {
        ...reported,
        'type': 'error',
        'message': message,
        'error_code': ?task['error_code'],
        'details': ?storedDetails,
      };
    }
    final failure = _presentTaskFailure(
      storedDetails,
      fallback: message.isEmpty ? reportedMessage : message,
      imageGeneration: imageGeneration,
    );
    return {
      ...reported,
      'type': 'error',
      'message': failure.message,
      'error_code': task['error_code'] ?? failure.code,
      if (failure.details.isNotEmpty) 'details': failure.details,
    };
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

  Future<String?> cancelTask(String taskId) async {
    final token = await _requireToken();
    final response = await _client
        .post(
          Uri.parse('$_baseUrl/agent/tasks/$taskId/cancel'),
          headers: _headers(token),
        )
        .timeout(const Duration(seconds: 20));
    final decoded = _decode(response);
    final accepted =
        (response.statusCode >= 200 && response.statusCode < 300) ||
        decoded['cancel_requested'] == true;
    if (!accepted) {
      throw StateError(_errorMessage(decoded, '云端任务停止失败'));
    }

    var cursor = -1;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var status = decoded['status']?.toString();
    var cleanupPending = decoded['sandbox_cleanup_pending'] == true;
    bool isTerminal(String? value) =>
        value == 'cancelled' ||
        value == 'completed' ||
        value == 'succeeded' ||
        value == 'failed';
    while ((!isTerminal(status) || cleanupPending) &&
        DateTime.now().isBefore(deadline)) {
      final state = await getTaskEvents(
        taskId,
        cursor,
      ).timeout(const Duration(seconds: 20));
      final events = state['events'];
      if (events is List) {
        for (final raw in events.whereType<Map>()) {
          cursor = max(cursor, (raw['seq'] as num?)?.toInt() ?? cursor);
        }
      }
      status = state['status']?.toString();
      cleanupPending = state['sandbox_cleanup_pending'] == true;
      if (!isTerminal(status) || cleanupPending) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return isTerminal(status) && !cleanupPending ? status : null;
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
    if (token == null || token.isEmpty) throw StateError('请先登录个人账号');
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

  String _errorMessage(
    Map<String, dynamic> value,
    String fallback, {
    int? statusCode,
  }) {
    final error = value['error'];
    String? message;
    if (error is Map) {
      message = error['message']?.toString();
    } else if (error is String) {
      message = error;
    } else {
      message = value['message']?.toString() ?? value['Message']?.toString();
    }
    if (message != null && message.trim().isNotEmpty) return message.trim();
    return statusCode == null ? fallback : '$fallback（HTTP $statusCode）';
  }
}
