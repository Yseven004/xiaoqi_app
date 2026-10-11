import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:genkit/experimental.dart'
    show
        Agent,
        AgentFinishReason,
        AgentFnOptions,
        AgentResult,
        AgentStreamChunk,
        Artifact,
        GenkitAgents,
        SessionRunner,
        TurnResult;
import 'package:genkit/experimental_io.dart' show GenkitRouterAgents;
import 'package:genkit/genkit.dart'
    show
        CancellationController,
        Genkit,
        GenkitException,
        Message,
        ModelResponseChunk,
        Role,
        StatusCode,
        TextPart;
import 'package:genkit/io.dart' show GenkitRouter, RequestData;
import 'package:genkit_shelf/genkit_shelf.dart' show GenkitRouterShelf;
import 'package:mailer/mailer.dart' hide Message;
import 'package:mailer/mailer.dart' as mailer;
import 'package:mailer/smtp_server.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import 'agent_runtime.dart';
import 'chat_completion_service.dart';
import 'code_execution_service.dart';
import 'store.dart';

const _remoteAgentTurnMetadataKey = 'xiaoqi_agent_turn';

String _networkMode(Object? value) => switch (value?.toString()) {
  'on' => 'on',
  _ => 'off',
};

({String code, String message, String details}) _taskFailurePresentation(
  Object error, {
  required bool imageGeneration,
}) {
  final details = _redactTaskError(error.toString());
  final normalized = details.toLowerCase();
  final isArkFailure =
      normalized.contains('seedream') ||
      normalized.contains('生图服务') ||
      normalized.contains('生图结果') ||
      normalized.contains('ark');
  final accountOverdue = RegExp(
    r'(overdue balance|balance.{0,16}overdue|account.{0,24}overdue|past[- ]due|outstanding balance|insufficient balance|账户欠费|账户逾期|余额不足|欠费)',
  ).hasMatch(normalized);

  if (accountOverdue && isArkFailure) {
    return (
      code: 'ark_account_overdue',
      message: '图片生成失败：火山引擎 Ark 账户存在逾期欠款，Seedream 已拒绝请求。请在火山引擎控制台结清欠款后重试。',
      details: details,
    );
  }
  if (accountOverdue) {
    return (
      code: 'text_model_billing_required',
      message: '任务失败：文字模型服务提示账户欠费或余额不足，请在对应服务商控制台处理账单后重试。',
      details: details,
    );
  }

  if (imageGeneration && normalized.contains('ark_api_key')) {
    return (
      code: 'ark_not_configured',
      message:
          '图片生成失败：服务端没有配置火山引擎 Ark 密钥（ARK_API_KEY）。'
          '请在实际连接的 API 服务器配置密钥并重启服务。',
      details: details,
    );
  }
  if (imageGeneration &&
      (normalized.contains('create-image') ||
          normalized.contains('所选技能') ||
          normalized.contains('技能不存在') ||
          normalized.contains('技能 id 无效'))) {
    return (
      code: 'image_action_not_deployed',
      message:
          '图片生成失败：服务端把“创建图像”当成了普通技能加载；该内置动作没有技能版本 ID（version_id），'
          '所以在调用 Seedream 前就失败了。请更新并重启当前连接的 Genkit 服务端，使其支持 create-image 动作。',
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
  ).firstMatch(details)?.group(1);
  final statusCode = status == null ? null : int.tryParse(status);
  if (imageGeneration && status != null && isArkFailure) {
    final providerDetail = RegExp(
      r'生图服务返回错误\s*\(\d{3}\)\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(details)?.group(1);
    if (statusCode == 401 || statusCode == 403) {
      return (
        code: 'ark_auth_failed',
        message:
            '图片生成失败：Seedream 拒绝了服务器凭据（HTTP $status）。'
            '请检查 Ark API Key、模型权限和服务端配置。',
        details: details,
      );
    }
    if (statusCode == 429) {
      return (
        code: 'ark_rate_limited',
        message: '图片生成失败：Seedream 当前限流或额度不足（HTTP 429），请稍后查看 Ark 配额。',
        details: details,
      );
    }
    if (statusCode == 400) {
      return (
        code: 'ark_request_rejected',
        message:
            '图片生成失败：Seedream 拒绝了请求（HTTP 400）。'
            '${providerDetail == null ? '' : '\n原因：$providerDetail'}',
        details: details,
      );
    }
    if (statusCode != null && statusCode >= 500) {
      return (
        code: 'ark_server_error',
        message: '图片生成失败：Seedream 服务端暂时异常（HTTP $status），请稍后再试。',
        details: details,
      );
    }
  }
  if (imageGeneration && statusCode != null) {
    if (statusCode == 401 || statusCode == 403) {
      return (
        code: 'text_model_auth_failed',
        message: '图片任务未能启动：负责理解描述的文字模型鉴权失败（HTTP $statusCode）。',
        details: details,
      );
    }
    if (statusCode == 429) {
      return (
        code: 'text_model_rate_limited',
        message: '图片任务未能启动：负责理解描述的文字模型限流或额度不足（HTTP 429）。',
        details: details,
      );
    }
    if (statusCode == 400) {
      return (
        code: 'text_model_request_rejected',
        message: '图片任务未能启动：负责理解描述的文字模型拒绝了请求（HTTP 400）。',
        details: details,
      );
    }
    if (statusCode >= 500) {
      return (
        code: 'upstream_server_error',
        message: '图片任务失败：上游模型服务暂时异常（HTTP $statusCode）。',
        details: details,
      );
    }
  }
  if (!imageGeneration && statusCode != null) {
    if (statusCode == 401 || statusCode == 403) {
      return (
        code: 'text_model_auth_failed',
        message: '任务失败：文字模型服务拒绝了服务器凭据或当前模型权限（HTTP $statusCode）。',
        details: details,
      );
    }
    if (statusCode == 429) {
      return (
        code: 'text_model_rate_limited',
        message: '任务失败：文字模型服务当前限流或额度不足（HTTP 429）。',
        details: details,
      );
    }
    if (statusCode >= 500) {
      return (
        code: 'text_model_server_error',
        message: '任务失败：文字模型服务暂时异常（HTTP $statusCode）。',
        details: details,
      );
    }
  }
  if (normalized.contains('timeout') || normalized.contains('超时')) {
    final isArkFailure =
        normalized.contains('seedream') ||
        normalized.contains('生图服务') ||
        normalized.contains('生图结果') ||
        normalized.contains('ark');
    return (
      code: imageGeneration ? 'image_generation_timeout' : 'task_timeout',
      message: imageGeneration && isArkFailure
          ? '图片生成请求超时。服务端没有自动重试；结果可能未知，请确认 Ark 任务状态后再重试。'
          : imageGeneration
          ? '图片任务等待文字模型响应超时。请检查文字模型服务状态后再试。'
          : '任务等待超时，请检查服务端任务状态后再重试。',
      details: details,
    );
  }
  if (normalized.contains('socketexception') ||
      normalized.contains('clientexception') ||
      normalized.contains('failed host lookup')) {
    final isArkFailure =
        normalized.contains('seedream') ||
        normalized.contains('生图服务') ||
        normalized.contains('生图结果') ||
        normalized.contains('ark');
    return (
      code: imageGeneration ? 'ark_network_error' : 'task_network_error',
      message: imageGeneration && isArkFailure
          ? '图片生成失败：服务端无法连接 Seedream。请检查服务器出网、DNS 和 Ark API 地址。'
          : imageGeneration
          ? '图片任务未能启动：服务端无法连接负责理解描述的文字模型。请检查模型地址和服务器网络。'
          : '任务失败：服务端无法连接上游服务，请检查网络连接。',
      details: details,
    );
  }

  final summary = details.isEmpty ? '服务端没有提供错误详情。' : details;
  return (
    code: imageGeneration ? 'image_generation_failed' : 'agent_task_failed',
    message: imageGeneration ? '图片生成失败：$summary' : '任务执行失败：$summary',
    details: details,
  );
}

String _redactTaskError(String value) {
  var safe = value.replaceAll(
    RegExp(r'Bearer\s+\S+', caseSensitive: false),
    'Bearer [已隐藏]',
  );
  for (final entry in Platform.environment.entries) {
    if (entry.key.contains('KEY') ||
        entry.key.contains('TOKEN') ||
        entry.key.contains('PASSWORD') ||
        entry.key.contains('PEPPER')) {
      final secret = entry.value;
      if (secret.length >= 8) safe = safe.replaceAll(secret, '[已隐藏]');
    }
  }
  safe = safe.replaceAll(
    RegExp(r'\b(?:ark|sk)-[A-Za-z0-9_-]{12,}\b', caseSensitive: false),
    '[密钥已隐藏]',
  );
  return safe.length <= 320 ? safe : '${safe.substring(0, 320)}…';
}

class XiaoqiApi {
  XiaoqiApi(this.store, this.runtime, {ChatCompletionService? chatCompletions})
    : chatCompletions = chatCompletions ?? ChatCompletionService() {
    _agentRouter = GenkitRouter();
    final genkit = Genkit();
    _remoteAgent = genkit.defineCustomAgent<Map<String, dynamic>>(
      name: 'xiaoqi_chat_agent',
      store: CloudSessionStore(store),
      fn: _runRemoteAgent,
    );
    _agentRouter.addAgent(
      _remoteAgent,
      path: '/v1/agent/chat',
      contextProvider: _agentRequestContext,
    );
  }

  final CloudStore store;
  final XiaoqiAgentRuntime runtime;
  final ChatCompletionService chatCompletions;
  late final GenkitRouter _agentRouter;
  late final Agent<Map<String, dynamic>> _remoteAgent;
  final _controllers = <String, CancellationController>{};
  static const _uuid = Uuid();
  static const _maxJsonBytes = 22 * 1024 * 1024;
  static const _maxCapabilityBytes = 2 * 1024 * 1024;

  Router get router {
    final router = Router()
      ..get('/health', (Request request) => _json({'status': 'ok'}))
      ..post('/v1/auth/email/start', _startEmail)
      ..post('/v1/auth/email/verify', _verifyEmail)
      ..get(
        '/v1/auth/me',
        (request) =>
            _authenticated(request, (device) => _authMe(request, device)),
      )
      ..delete(
        '/v1/auth/session',
        (request) =>
            _authenticated(request, (device) => _revokeDevice(request, device)),
      )
      ..delete(
        '/v1/devices/me',
        (request) =>
            _authenticated(request, (device) => _revokeDevice(request, device)),
      )
      ..get(
        '/v1/capabilities',
        (request) => _authenticated(
          request,
          (device) => _listCapabilities(request, device),
        ),
      )
      ..post(
        '/v1/capabilities/sync',
        (request) => _authenticated(
          request,
          (device) => _syncCapability(request, device),
        ),
      )
      ..patch(
        '/v1/capabilities/<id>/visibility',
        (request, id) => _authenticated(
          request,
          (device) => _setVisibility(request, device, id),
        ),
      )
      ..delete(
        '/v1/capabilities/<id>',
        (request, id) => _authenticated(
          request,
          (device) => _deleteCapability(request, device, id),
        ),
      )
      ..get(
        '/v1/drafts',
        (request) =>
            _authenticated(request, (device) => _drafts(request, device)),
      )
      ..put(
        '/v1/drafts',
        (request) =>
            _authenticated(request, (device) => _drafts(request, device)),
      )
      ..delete(
        '/v1/drafts/<id>',
        (request, id) =>
            _authenticated(request, (device) => _deleteDraft(device, id)),
      )
      ..post(
        '/v1/agent/tasks',
        (request) =>
            _authenticated(request, (device) => _createTask(request, device)),
      )
      ..post(
        '/v1/chat/completions',
        (request) =>
            _authenticated(request, (_) => chatCompletions.handle(request)),
      )
      ..get(
        '/v1/agent/tasks/<id>',
        (request, id) =>
            _authenticated(request, (device) => _getTask(device, id)),
      )
      ..get(
        '/v1/agent/tasks/<id>/events',
        (request, id) => _authenticated(
          request,
          (device) => _getEvents(request, device, id),
        ),
      )
      ..post(
        '/v1/agent/tasks/<id>/cancel',
        (request, id) =>
            _authenticated(request, (device) => _cancelTask(device, id)),
      )
      ..post(
        '/v1/agent/tasks/<id>/authorize-network',
        (request, id) => _authenticated(
          request,
          (device) => _authorizeNetwork(request, device, id),
        ),
      )
      ..post(
        '/v1/agent/tasks/<id>/network-mode',
        (request, id) => _authenticated(
          request,
          (device) => _setAgentTaskNetworkMode(request, device, id),
        ),
      )
      ..post(
        '/v1/agent/tasks/<id>/instructions',
        (request, id) => _authenticated(
          request,
          (device) => _sendAgentTaskInstruction(request, device, id),
        ),
      )
      ..post(
        '/v1/agent/tasks/<id>/resume',
        (request, id) =>
            _authenticated(request, (device) => _resumeTask(device, id)),
      )
      ..get(
        '/v1/agent/tasks/<task>/artifacts/<artifact>',
        (request, task, artifact) => _authenticated(
          request,
          (device) => _downloadArtifact(device, task, artifact),
        ),
      );
    return router;
  }

  Handler get handler => const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(
        Cascade().add(router.call).add(_agentRouter.asShelfHandler()).handler,
      );

  Map<String, dynamic> _agentRequestContext(RequestData request) {
    final header = request.headers['authorization'] ?? '';
    if (!header.startsWith('Bearer ')) {
      throw GenkitException(
        '登录状态已失效，请重新登录',
        status: StatusCode.unauthenticated,
      );
    }
    final token = header.substring(7).trim();
    if (token.isEmpty || token.length > 512) {
      throw GenkitException(
        '登录状态已失效，请重新登录',
        status: StatusCode.unauthenticated,
      );
    }
    final key = 'device/${sha256.convert(utf8.encode(token))}';
    final record = store.get(key);
    if (record == null || record.value['revoked_at'] != null) {
      throw GenkitException(
        '登录状态已失效，请重新登录',
        status: StatusCode.unauthenticated,
      );
    }
    final device = _Device(key, record.value);
    return {'tenant_id': device.tenant, 'device_id': device.value['device_id']};
  }

  Future<AgentResult> _runRemoteAgent(
    SessionRunner<Map<String, dynamic>> session,
    AgentFnOptions options,
  ) async {
    await session.run((input, turnContext) async {
      final context = options.context ?? const <String, dynamic>{};
      final tenantId = context['tenant_id']?.toString() ?? '';
      if (tenantId.isEmpty) {
        throw GenkitException(
          '登录状态已失效，请重新登录',
          status: StatusCode.unauthenticated,
        );
      }
      var messages = session.getMessages();
      var currentUserIndex = messages.lastIndexWhere(
        (message) => message.role == Role.user,
      );
      if (currentUserIndex < 0) {
        throw const FormatException('Genkit Agent 当前回合缺少用户消息');
      }
      var currentUser = messages[currentUserIndex];
      final rawConfig = currentUser.metadata?[_remoteAgentTurnMetadataKey];
      if (rawConfig is! Map) {
        throw const FormatException('Genkit Agent 回合参数缺失');
      }
      final config = Map<String, dynamic>.from(rawConfig);
      final taskId = _safeId(config['task_id'], '任务 ID');

      final rawLegacyHistory = config['legacy_history'];
      if (messages.length == 1 && rawLegacyHistory is List) {
        final seeded = agentMessagesFromRequest([
          ...rawLegacyHistory,
          _legacyMessageFor(currentUser),
        ]);
        messages = [...seeded.take(seeded.length - 1), currentUser];
      }
      final cleanConfig = Map<String, dynamic>.from(config)
        ..remove('legacy_history');
      currentUserIndex = messages.lastIndexWhere(
        (message) => message.role == Role.user,
      );
      final latestUser = messages[currentUserIndex];
      messages[currentUserIndex] = Message(
        role: latestUser.role,
        content: latestUser.content,
        metadata: {
          ...?latestUser.metadata,
          _remoteAgentTurnMetadataKey: cleanConfig,
        },
      );
      currentUser = messages[currentUserIndex];
      session.setMessages(messages);

      final request = Map<String, dynamic>.from(cleanConfig)
        ..['remote_agent'] = true;
      _ensureRemoteAgentTask(
        tenantId,
        taskId,
        context['device_id'],
        request['network_mode'],
      );
      session.updateCustom((_) => {'agent_process': <Map<String, dynamic>>[]});

      void addProcessEvent(Map<String, Object?> rawEvent) {
        final event = <String, dynamic>{
          ...rawEvent,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        };
        session.updateCustom((current) {
          final custom = current == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(current);
          final events = (custom['agent_process'] as List? ?? const [])
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
          events.add(event);
          if (events.length > 48) events.removeRange(0, events.length - 48);
          return {
            ...custom,
            'agent_process': events,
            'current_step': _agentProcessLabel(event),
          };
        });
      }

      final modelMessages = messages.map(_withoutTurnMetadata).toList();
      late final XiaoqiAgentTurnResult result;
      try {
        final activeRuntime = runtime;
        if (activeRuntime is XiaoqiStreamingAgentRuntime) {
          result = await (activeRuntime as XiaoqiStreamingAgentRuntime)
              .runAgentTurn(
                tenantId: tenantId,
                taskId: taskId,
                request: {
                  ...request,
                  'messages': [
                    for (final message in modelMessages)
                      _legacyMessageFor(message),
                  ],
                },
                messages: modelMessages,
                respond: input.resume?.respond,
                restart: input.resume?.restart,
                onChunk: options.sendChunk,
                onProcessEvent: addProcessEvent,
                cancellation: options.cancel ?? CancellationController().token,
                onImageGenerationStarted: () => addProcessEvent({
                  'type': 'image_generation_started',
                  'tool': 'generate_image',
                }),
              );
        } else {
          final output = StringBuffer();
          final text = await activeRuntime.run(
            tenantId: tenantId,
            taskId: taskId,
            request: {
              ...request,
              'messages': [
                for (final message in modelMessages) _legacyMessageFor(message),
              ],
            },
            cancellation: options.cancel ?? CancellationController().token,
            onDelta: (delta) {
              output.write(delta);
              options.sendChunk(
                AgentStreamChunk(
                  modelChunk: ModelResponseChunk(
                    role: Role.model,
                    content: [TextPart(text: delta)],
                  ),
                ),
              );
            },
            onImageGenerationStarted: () => addProcessEvent({
              'type': 'image_generation_started',
              'tool': 'generate_image',
            }),
          );
          final reply = text.isEmpty ? output.toString() : text;
          result = XiaoqiAgentTurnResult(
            text: reply,
            messages: [
              ...modelMessages,
              Message(
                role: Role.model,
                content: [TextPart(text: reply)],
              ),
            ],
          );
        }
        _setRemoteAgentTaskStatus(
          tenantId,
          taskId,
          result.finishReason == AgentFinishReason.interrupted
              ? 'awaiting_network_permission'
              : 'completed',
        );
      } on Object {
        _setRemoteAgentTaskStatus(
          tenantId,
          taskId,
          options.cancel?.isCancelled == true ? 'cancelled' : 'failed',
        );
        rethrow;
      }

      final resultMessages = result.messages.toList();
      final webSources =
          (store.get('task/$tenantId/$taskId')?.value['web_sources'] as List? ??
                  const [])
              .whereType<Map>()
              .map((source) => Map<String, Object?>.from(source))
              .where(
                (source) =>
                    source['url'] is String && source['title'] is String,
              )
              .toList(growable: false);
      if (webSources.isNotEmpty &&
          result.finishReason != AgentFinishReason.interrupted) {
        final lastModelIndex = resultMessages.lastIndexWhere(
          (message) => message.role == Role.model,
        );
        if (lastModelIndex >= 0) {
          final lastModel = resultMessages[lastModelIndex];
          final citations = webSources
              .map((source) {
                final title = (source['title']?.toString() ?? '网页来源')
                    .replaceAll(RegExp(r'[\[\]()]'), ' ')
                    .replaceAll('\n', ' ');
                final url = source['url']!.toString();
                return '- [$title](<$url>)';
              })
              .join('\n');
          resultMessages[lastModelIndex] = Message(
            role: lastModel.role,
            content: [
              ...lastModel.content,
              TextPart(text: '\n\n参考来源：\n$citations'),
            ],
            metadata: lastModel.metadata,
          );
        }
      }
      final latestResultUserIndex = resultMessages.lastIndexWhere(
        (message) => message.role == Role.user,
      );
      if (latestResultUserIndex >= 0) {
        final resultUser = resultMessages[latestResultUserIndex];
        resultMessages[latestResultUserIndex] = Message(
          role: resultUser.role,
          content: resultUser.content,
          metadata: {
            ...?resultUser.metadata,
            _remoteAgentTurnMetadataKey: cleanConfig,
          },
        );
      }
      session.setMessages(resultMessages);

      final artifacts = _remoteAgentArtifacts(tenantId, taskId);
      if (artifacts.isNotEmpty) {
        session.addArtifacts(artifacts);
        for (final artifact in artifacts) {
          options.sendChunk(AgentStreamChunk(artifact: artifact));
        }
      }
      return TurnResult(finishReason: result.finishReason);
    });

    final messages = session.getMessages();
    final lastMessage = messages.isNotEmpty ? messages.last : null;
    return AgentResult(
      message: lastMessage?.role == Role.model ? lastMessage : null,
      artifacts: session.getArtifacts(),
      finishReason: session.lastTurnFinishReason,
    );
  }

  void _ensureRemoteAgentTask(
    String tenantId,
    String taskId,
    Object? deviceId,
    Object? rawNetworkMode,
  ) {
    final key = 'task/$tenantId/$taskId';
    final current = store.get(key);
    if (current != null) {
      if (current.value['remote_agent_turn'] != true) {
        throw StateError('任务 ID 已用于其他任务');
      }
      return;
    }
    store.put(key, {
      'task_id': taskId,
      'tenant_id': tenantId,
      'device_id': deviceId,
      'remote_agent_turn': true,
      'status': 'running',
      'network_mode': _networkMode(rawNetworkMode),
      'authorized_network_domains': <String>[],
      'requested_network_domains': <String>[],
      'steering_instructions': <Map<String, dynamic>>[],
      'artifacts': <Map<String, dynamic>>[],
      'created_at': _now(),
      'updated_at': _now(),
    }, null);
  }

  void _setRemoteAgentTaskStatus(
    String tenantId,
    String taskId,
    String status,
  ) {
    _mutateTask(
      'task/$tenantId/$taskId',
      (value) => {...value, 'status': status, 'updated_at': _now()},
    );
  }

  List<Artifact> _remoteAgentArtifacts(String tenantId, String taskId) {
    final raw = store.get('task/$tenantId/$taskId')?.value['artifacts'];
    if (raw is! List || raw.isEmpty) return const [];
    final artifacts = raw
        .whereType<Map>()
        .map((item) => _publicArtifact(Map<String, dynamic>.from(item), taskId))
        .toList();
    if (artifacts.isEmpty) return const [];
    return [
      Artifact(
        name: 'xiaoqi-artifacts-$taskId',
        parts: const [],
        metadata: {'task_id': taskId, 'artifacts': artifacts},
      ),
    ];
  }

  static Map<String, Object?> _legacyMessageFor(Message message) => {
    'role': switch (message.role) {
      Role.system => 'system',
      Role.user => 'user',
      Role.model => 'assistant',
      _ => 'assistant',
    },
    'content': [
      for (final part in message.content)
        if (part.toJson()['text'] is String)
          {'type': 'text', 'text': part.toJson()['text']}
        else if (part.toJson()['media'] is Map)
          {
            'type': 'image_url',
            'image_url': {'url': (part.toJson()['media'] as Map)['url']},
          },
    ],
  };

  static Message _withoutTurnMetadata(Message message) {
    final metadata = Map<String, dynamic>.from(message.metadata ?? const {})
      ..remove(_remoteAgentTurnMetadataKey);
    return Message(
      role: message.role,
      content: message.content,
      metadata: metadata.isEmpty ? null : metadata,
    );
  }

  static String _agentProcessLabel(Map<String, dynamic> event) =>
      switch (event['type']?.toString()) {
        'tool_started' when event['temporary_network'] == true =>
          '正在为${event['capability_name'] ?? '技能'}临时联网',
        'tool_started' => '正在使用 ${event['tool'] ?? '工具'}',
        'tool_succeeded' => '${event['tool'] ?? '工具'}已完成',
        'tool_failed' => '${event['tool'] ?? '工具'}遇到问题',
        'image_generation_started' => '正在生成图片',
        'steering_applied' => '正在应用补充指令',
        _ => '正在处理',
      };

  Future<Response> _startEmail(Request request) async {
    try {
      final body = await _body(request, 1024);
      final email = _email(body['email']);
      final config = _emailConfig();
      if (!_constantTimeEquals(email, config.ownerEmail))
        return _genericCodeResponse();
      final now = _now();
      final key = 'auth-code/${sha256.convert(utf8.encode(email))}';
      final current = store.get(key);
      final sent = (current?.value['send_times'] as List? ?? const [])
          .whereType<num>()
          .map((value) => value.toInt())
          .where((value) => now - value < 3600)
          .toList();
      if (current != null &&
          (now - (current.value['sent_at'] as num).toInt() < 60 ||
              sent.length >= 5)) {
        return _genericCodeResponse();
      }
      final code = Random.secure().nextInt(1000000).toString().padLeft(6, '0');
      final challenge = <String, dynamic>{
        'email': email,
        'code_hash': _codeDigest(email, code, config.pepper),
        'expires_at': now + 600,
        'sent_at': now,
        'send_times': [...sent, now],
        'attempts': 0,
        'consumed': false,
      };
      final saved = store.put(key, challenge, current?.revision);
      try {
        final smtp = SmtpServer(
          config.smtpHost,
          port: config.smtpPort,
          username: config.smtpUsername,
          password: config.smtpPassword,
          ssl: config.smtpPort == 465,
        );
        final message = mailer.Message()
          ..from = Address(config.smtpUsername, '小七')
          ..recipients.add(email)
          ..subject = '小七登录验证码'
          ..text = '你的小七登录验证码是：$code\n验证码 10 分钟内有效，请勿转发给他人。';
        await send(message, smtp).timeout(const Duration(seconds: 15));
      } on Object {
        try {
          store.put(key, {...challenge, 'consumed': true}, saved.revision);
        } on Object {}
        return _genericCodeResponse();
      }
      return _genericCodeResponse();
    } on FormatException catch (error) {
      return _error(error.message, 400);
    } on _ConfigurationException {
      return _error('登录服务暂不可用', 503);
    } on RevisionConflict {
      return _genericCodeResponse();
    } on Object {
      return _error('登录服务暂不可用', 503);
    }
  }

  Future<Response> _verifyEmail(Request request) async {
    String? token;
    String? tokenHash;
    try {
      final body = await _body(request, 1024);
      final email = _email(body['email']);
      final code = body['code']?.toString().trim() ?? '';
      final config = _emailConfig();
      if (!_constantTimeEquals(email, config.ownerEmail) ||
          !RegExp(r'^\d{6}$').hasMatch(code)) {
        return _error('验证码无效或已过期', 401);
      }
      final key = 'auth-code/${sha256.convert(utf8.encode(email))}';
      final challenge = store.get(key);
      final now = _now();
      final valid =
          challenge != null &&
          challenge.value['consumed'] != true &&
          (challenge.value['expires_at'] as num? ?? 0) >= now &&
          (challenge.value['attempts'] as num? ?? 0) < 5 &&
          _constantTimeEquals(
            challenge.value['code_hash']?.toString() ?? '',
            _codeDigest(email, code, config.pepper),
          );
      if (!valid) {
        if (challenge != null && challenge.value['consumed'] != true) {
          final attempts =
              (challenge.value['attempts'] as num? ?? 0).toInt() + 1;
          try {
            store.put(key, {
              ...challenge.value,
              'attempts': attempts,
              'consumed': attempts >= 5,
            }, challenge.revision);
          } on Object {}
        }
        return _error('验证码无效或已过期', 401);
      }
      token = _token();
      tokenHash = sha256.convert(utf8.encode(token)).toString();
      final deviceId = 'device-${_uuid.v4().replaceAll('-', '')}';
      store.put('device/$tokenHash', {
        'tenant_id': 'personal',
        'device_id': deviceId,
        'auth_method': 'email',
        'account_email': email,
        'created_at': now,
        'revoked_at': null,
      }, null);
      try {
        store.put(key, {
          ...challenge.value,
          'consumed': true,
          'consumed_at': now,
        }, challenge.revision);
      } on RevisionConflict {
        final issued = store.get('device/$tokenHash');
        if (issued != null)
          store.put('device/$tokenHash', {
            ...issued.value,
            'revoked_at': now,
          }, issued.revision);
        return _error('验证码已使用，请重新获取', 409);
      }
      return _json({
        'access_token': token,
        'device_id': deviceId,
        'email': email,
      }, 201);
    } on FormatException catch (error) {
      return _error(error.message, 400);
    } on _ConfigurationException {
      return _error('登录服务暂不可用', 503);
    } on Object {
      if (tokenHash != null) {
        final issued = store.get('device/$tokenHash');
        if (issued != null) {
          try {
            store.put('device/$tokenHash', {
              ...issued.value,
              'revoked_at': _now(),
            }, issued.revision);
          } on Object {}
        }
      }
      return _error('登录失败，请重新获取验证码', 503);
    }
  }

  Future<Response> _authMe(Request request, _Device device) async {
    if (device.value['auth_method'] != 'email')
      return _error('请先使用个人邮箱登录', 401);
    return _json({
      'authenticated': true,
      'email': device.value['account_email'] ?? '',
      'tenant_id': device.tenant,
    });
  }

  Future<Response> _revokeDevice(Request request, _Device device) async {
    final current = store.get(device.key);
    if (current != null)
      store.put(device.key, {
        ...current.value,
        'revoked_at': _now(),
      }, current.revision);
    return _json({'ok': true});
  }

  Future<Response> _listCapabilities(Request request, _Device device) async {
    try {
      final records = <Map<String, dynamic>>[];
      for (final (_, doc) in store.list('cap/${device.tenant}/', limit: 200)) {
        records.add(_publicCapability(doc.value, doc.revision, true));
      }
      return _json({'items': records});
    } on Object {
      return _error('读取云端能力失败', 503);
    }
  }

  Future<Response> _syncCapability(Request request, _Device device) async {
    try {
      final body = await _body(request, _maxJsonBytes);
      final record = await _normalizeCapability(device.tenant, body['record']);
      final key = 'cap/${device.tenant}/${record['id']}';
      final current = store.get(key);
      final expected = _asInt(body['expected_revision']);
      if (current == null && expected != null && expected != 0)
        return _error('云端版本已变化', 409);
      if (current != null && expected != current.revision) {
        return _json({
          'error': {
            'message': '云端版本已变化',
            'current': _publicCapability(current.value, current.revision, true),
            'cloud_revision': current.revision,
          },
        }, 409);
      }
      record['cloud_revision'] = (current?.revision ?? 0) + 1;
      final saved = store.put(key, record, current?.revision);
      return _json({
        'record': _publicCapability(saved.value, saved.revision, true),
        'cloud_revision': saved.revision,
      });
    } on FormatException catch (error) {
      return _error(error.message, 400);
    } on RevisionConflict {
      return _error('云端版本已变化', 409);
    } on Object {
      return _error('同步能力失败', 503);
    }
  }

  Future<Response> _setVisibility(
    Request request,
    _Device device,
    String id,
  ) async {
    try {
      final safeId = _safeId(id, '能力 ID');
      final body = await _body(request, 1024);
      final key = 'cap/${device.tenant}/$safeId';
      final current = store.get(key);
      if (current == null || current.value['deleted_at'] != null)
        return _error('能力不存在', 404);
      if (_asInt(body['expected_revision']) != current.revision)
        return _json({
          'error': {
            'message': '云端版本已变化',
            'current': _publicCapability(current.value, current.revision, true),
            'cloud_revision': current.revision,
          },
        }, 409);
      final updated = {
        ...current.value,
        'show_in_menu': body['show_in_menu'] == true,
        'updated_at':
            body['updated_at']?.toString() ?? DateTime.now().toIso8601String(),
        'cloud_revision': current.revision + 1,
      };
      final saved = store.put(key, updated, current.revision);
      return _json({
        'record': _publicCapability(saved.value, saved.revision, false),
        'cloud_revision': saved.revision,
      });
    } on Object {
      return _error('更新展示偏好失败', 503);
    }
  }

  Future<Response> _deleteCapability(
    Request request,
    _Device device,
    String id,
  ) async {
    try {
      final safeId = _safeId(id, '能力 ID');
      final expected =
          int.tryParse(
            request.url.queryParameters['expected_revision'] ?? '',
          ) ??
          -1;
      final key = 'cap/${device.tenant}/$safeId';
      final current = store.get(key);
      if (current == null) return _json({'ok': true});
      if (expected != current.revision)
        return _json({
          'error': {
            'message': '云端版本已变化',
            'current': _publicCapability(current.value, current.revision, true),
            'cloud_revision': current.revision,
          },
        }, 409);
      final now = DateTime.now().toIso8601String();
      final saved = store.put(key, {
        ...current.value,
        'deleted_at': now,
        'updated_at': now,
        'cloud_revision': current.revision + 1,
      }, current.revision);
      return _json({'ok': true, 'cloud_revision': saved.revision});
    } on Object {
      return _error('同步删除标记失败', 503);
    }
  }

  Future<Response> _drafts(Request request, _Device device) async {
    final prefix = 'draft/${device.tenant}/';
    if (request.method == 'GET') {
      return _json({
        'items': [
          for (final (_, item) in store.list(prefix, limit: 200))
            {...item.value, 'cloud_revision': item.revision},
        ],
      });
    }
    try {
      final body = await _body(request, _maxCapabilityBytes * 2);
      final draft = body['draft'];
      if (draft is! Map) return _error('草稿格式无效', 400);
      final draftValue = Map<String, dynamic>.from(draft);
      final id = _safeId(draftValue['id'], '草稿 ID');
      final key = prefix + id;
      final current = store.get(key);
      final expected = _asInt(body['expected_revision']);
      if (current != null && current.value['deleted_at'] != null)
        return _json({
          'error': {
            'message': '云端草稿已删除',
            'current': {...current.value, 'cloud_revision': current.revision},
            'cloud_revision': current.revision,
          },
        }, 409);
      if (current == null && expected != null && expected != 0)
        return _error('云端草稿已变化', 409);
      if (current != null && expected != current.revision)
        return _json({
          'error': {
            'message': '云端草稿已变化',
            'current': {...current.value, 'cloud_revision': current.revision},
            'cloud_revision': current.revision,
          },
        }, 409);
      draftValue['cloud_revision'] = (current?.revision ?? 0) + 1;
      Map<String, dynamic>? currentWithoutRevision;
      if (current != null) {
        currentWithoutRevision = {...current.value};
        currentWithoutRevision.remove('cloud_revision');
      }
      final draftWithoutRevision = {...draftValue}..remove('cloud_revision');
      if (current != null &&
          _canonical(currentWithoutRevision) ==
              _canonical(draftWithoutRevision)) {
        return _json({
          'draft': current.value,
          'cloud_revision': current.revision,
        });
      }
      final saved = store.put(key, draftValue, current?.revision);
      return _json({'draft': saved.value, 'cloud_revision': saved.revision});
    } on FormatException catch (error) {
      return _error(error.message, 400);
    } on Object {
      return _error('同步草稿失败', 503);
    }
  }

  Future<Response> _deleteDraft(_Device device, String id) async {
    try {
      final safeId = _safeId(id, '草稿 ID');
      final key = 'draft/${device.tenant}/$safeId';
      final current = store.get(key);
      if (current != null && current.value['deleted_at'] != null)
        return _json({'ok': true, 'cloud_revision': current.revision});
      final deletedAt = DateTime.now().toIso8601String();
      final saved = store.put(key, {
        'id': safeId,
        'deleted_at': deletedAt,
        'updated_at': deletedAt,
        'cloud_revision': (current?.revision ?? 0) + 1,
      }, current?.revision);
      return _json({'ok': true, 'cloud_revision': saved.revision});
    } on Object {
      return _error('删除云端草稿失败', 503);
    }
  }

  Future<Response> _createTask(Request request, _Device device) async {
    try {
      final body = await _body(request, _maxJsonBytes);
      final taskId = _safeId(body['task_id'] ?? 'task-${_uuid.v4()}', '任务 ID');
      if (body['messages'] is! List) return _error('messages 必须是列表', 400);
      final key = 'task/${device.tenant}/$taskId';
      final requestHash = sha256
          .convert(utf8.encode(_canonical(body)))
          .toString();
      final existing = store.get(key);
      if (existing != null) {
        if (existing.value['request_hash'] != requestHash)
          return _error('任务 ID 已用于另一份请求', 409);
        return _json({
          'task_id': taskId,
          'status': _publicTaskStatus(existing.value['status']),
          'deduplicated': true,
        });
      }
      final now = _now();
      final task = <String, dynamic>{
        'task_id': taskId,
        'request_hash': requestHash,
        'tenant_id': device.tenant,
        'device_id': device.value['device_id'],
        'status': 'queued',
        'attempt': 1,
        'events': [
          {'seq': 0, 'type': 'status', 'status': 'queued', 'created_at': now},
        ],
        'draft_files': <String, String>{},
        'artifacts': <Map<String, dynamic>>[],
        'cancel_requested': false,
        'authorized_network_domains': <String>[],
        'requested_network_domains': <String>[],
        'created_at': now,
        'updated_at': now,
      };
      final inputKey = 'tenants/${device.tenant}/tasks/$taskId/input.json';
      store.putImmutable(inputKey, {
        'input.json': utf8.encode(jsonEncode(body)),
      });
      task['input_object_key'] = inputKey;
      store.put(key, task, null);
      unawaited(_runTask(device.tenant, taskId, body));
      return _json({'task_id': taskId, 'status': 'queued'}, 202);
    } on FormatException catch (error) {
      return _error(error.message, 400);
    } on Object {
      return _error('创建后台任务失败', 503);
    }
  }

  Future<void> _runTask(
    String tenant,
    String taskId,
    Map<String, dynamic> body,
  ) async {
    final key = 'task/$tenant/$taskId';
    final cancellation = CancellationController();
    final startedAt = DateTime.now();
    final messages = (body['messages'] as List? ?? const [])
        .whereType<Map>()
        .toList(growable: false);
    final imageCount = messages.fold<int>(0, (count, message) {
      final content = message['content'];
      return count +
          (content is List
              ? content
                    .whereType<Map>()
                    .where((part) => part['type'] == 'image_url')
                    .length
              : 0);
    });
    _logTaskEvent('started', taskId, {
      'model_id': body['model_id'],
      'message_count': messages.length,
      'roles': messages
          .map((message) => message['role']?.toString())
          .toSet()
          .toList(),
      'image_count': imageCount,
      'capability_selected': body['capability'] is Map,
    });
    _controllers[key] = cancellation;
    try {
      _mutateTask(
        key,
        (value) => {...value, 'status': 'running', 'updated_at': _now()},
      );
      _appendEvent(key, {'type': 'status', 'status': 'running'});
      final answer = await runtime.run(
        tenantId: tenant,
        taskId: taskId,
        request: body,
        cancellation: cancellation.token,
        onDelta: (text) =>
            _appendEvent(key, {'type': 'assistant_delta', 'text': text}),
        onImageGenerationStarted: () =>
            _appendEvent(key, {'type': 'image_generation_started'}),
      );
      final current = store.get(key);
      if (current == null) return;
      if (cancellation.isCancelled ||
          current.value['cancel_requested'] == true) {
        _mutateTask(
          key,
          (value) => {...value, 'status': 'cancelled', 'updated_at': _now()},
        );
        _appendEvent(key, {'type': 'status', 'status': 'cancelled'});
        _logTaskEvent('finished', taskId, {
          'status': 'cancelled',
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
        });
      } else {
        _mutateTask(
          key,
          (value) => {
            ...value,
            'status': 'completed',
            'result': answer,
            'updated_at': _now(),
          },
        );
        final artifacts = (current.value['artifacts'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) =>
                  _publicArtifact(Map<String, dynamic>.from(item), taskId),
            )
            .toList();
        _appendEvent(key, {
          'type': 'completed',
          'text': answer,
          'draft': null,
          'files': {},
          'artifacts': artifacts,
        });
        _logTaskEvent('finished', taskId, {
          'status': 'completed',
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
        });
      }
    } on NetworkPermissionRequired catch (required) {
      final current = store.get(key);
      if (current != null) {
        if (cancellation.isCancelled ||
            current.value['cancel_requested'] == true) {
          _mutateTask(
            key,
            (value) => {...value, 'status': 'cancelled', 'updated_at': _now()},
          );
          _appendEvent(key, {'type': 'status', 'status': 'cancelled'});
        } else {
          _mutateTask(
            key,
            (value) => {
              ...value,
              'status': 'awaiting_network_permission',
              'requested_network_domains': required.domains,
              'network_purpose': required.purpose,
              'updated_at': _now(),
            },
          );
          _appendEvent(key, {
            'type': 'network_permission_required',
            'domains': required.domains,
            'purpose': required.purpose,
          });
          _logTaskEvent('awaiting_network_permission', taskId, {
            'domain_count': required.domains.length,
            'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          });
        }
      }
    } on Object catch (error) {
      final current = store.get(key);
      if (current != null) {
        final cancelled =
            cancellation.isCancelled ||
            current.value['cancel_requested'] == true;
        final capability = body['capability'];
        final normalizedError = error.toString().toLowerCase();
        final imageGeneration =
            (capability is Map &&
                capability['type'] == 'action' &&
                capability['id'] == 'create-image') ||
            normalizedError.contains('generate_image') ||
            normalizedError.contains('seedream') ||
            normalizedError.contains('生图服务');
        final failure = _taskFailurePresentation(
          error,
          imageGeneration: imageGeneration,
        );
        _mutateTask(
          key,
          (value) => {
            ...value,
            'status': cancelled ? 'cancelled' : 'failed',
            if (!cancelled) 'error': failure.message,
            if (!cancelled) 'error_code': failure.code,
            if (!cancelled) 'error_details': failure.details,
            'updated_at': _now(),
          },
        );
        _appendEvent(
          key,
          cancelled
              ? {'type': 'status', 'status': 'cancelled'}
              : {
                  'type': 'error',
                  'message': failure.message,
                  'error_code': failure.code,
                  'details': failure.details,
                },
        );
        _logTaskEvent('finished', taskId, {
          'status': cancelled ? 'cancelled' : 'failed',
          'error_type': error.runtimeType.toString(),
          if (!cancelled) 'error_code': failure.code,
          if (!cancelled) 'error_summary': failure.details,
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
        });
      }
    } finally {
      _controllers.remove(key);
    }
  }

  void _logTaskEvent(
    String event,
    String taskId,
    Map<String, Object?> details,
  ) {
    try {
      stderr.writeln(
        jsonEncode({
          'component': 'agent_task',
          'event': event,
          'task_id': taskId,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          ...details,
        }),
      );
    } on Object {
      // Logging must not change the task result.
    }
  }

  Future<Response> _getTask(_Device device, String id) async {
    try {
      final taskId = _safeId(id, '任务 ID');
      final doc = store.get('task/${device.tenant}/$taskId');
      if (doc == null) return _error('任务不存在', 404);
      final value = doc.value;
      final files = Map<String, dynamic>.from(
        value['draft_files'] as Map? ?? const {},
      );
      final encoded = {
        for (final entry in files.entries)
          entry.key: base64Encode(utf8.encode(entry.value.toString())),
      };
      return _json({
        'task_id': taskId,
        'status': _publicTaskStatus(value['status']),
        'attempt': value['attempt'] ?? 1,
        'error': value['error'],
        'error_code': value['error_code'],
        'error_details': value['error_details'],
        'result': value['result'],
        'draft': files['SKILL.md'],
        'files': encoded,
        'artifacts': [
          for (final item in (value['artifacts'] as List? ?? const []))
            if (item is Map)
              _publicArtifact(Map<String, dynamic>.from(item), taskId),
        ],
        'requested_network_domains': value['requested_network_domains'] ?? [],
        'network_purpose': value['network_purpose'],
        'cloud_revision': doc.revision,
      });
    } on FormatException catch (error) {
      return _error(error.message, 400);
    } on Object {
      return _error('读取任务失败', 503);
    }
  }

  Future<Response> _getEvents(
    Request request,
    _Device device,
    String id,
  ) async {
    try {
      final taskId = _safeId(id, '任务 ID');
      final after =
          int.tryParse(request.url.queryParameters['after'] ?? '-1') ?? -1;
      final doc = store.get('task/${device.tenant}/$taskId');
      if (doc == null) return _error('任务不存在', 404);
      final events = (doc.value['events'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .where((item) => (item['seq'] as num? ?? 0) > after)
          .map((item) => _publicEvent(item, taskId))
          .toList();
      return _json({
        'events': events,
        'status': _publicTaskStatus(doc.value['status']),
        'sandbox_cleanup_pending': false,
      });
    } on FormatException catch (error) {
      return _error(error.message, 400);
    } on Object {
      return _error('读取任务事件失败', 503);
    }
  }

  Future<Response> _cancelTask(_Device device, String id) async {
    try {
      final key = 'task/${device.tenant}/${_safeId(id, '任务 ID')}';
      final current = store.get(key);
      if (current == null) return _error('任务不存在', 404);
      if (const {
        'queued',
        'running',
        'awaiting_network_permission',
      }.contains(current.value['status'])) {
        _mutateTask(
          key,
          (value) => {
            ...value,
            'cancel_requested': true,
            'status': 'cancelled',
            'updated_at': _now(),
          },
        );
        _controllers[key]?.cancel('用户取消任务');
        _appendEvent(key, {'type': 'status', 'status': 'cancelled'});
      }
      return _json({'ok': true});
    } on Object {
      return _error('取消任务失败', 503);
    }
  }

  Future<Response> _authorizeNetwork(
    Request request,
    _Device device,
    String id,
  ) async {
    try {
      final body = await _body(request, 2048);
      final domains = body['domains'];
      if (domains is! List || domains.isEmpty)
        return _error('需要明确授权至少一个域名', 400);
      final requested =
          domains
              .map(
                (item) => item.toString().trim().toLowerCase().replaceFirst(
                  RegExp(r'\.$'),
                  '',
                ),
              )
              .toSet()
              .toList()
            ..sort();
      final domainPattern = RegExp(
        r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
      );
      if (requested.any((domain) => !domainPattern.hasMatch(domain)))
        return _error('域名格式无效', 400);
      final key = 'task/${device.tenant}/${_safeId(id, '任务 ID')}';
      final doc = store.get(key);
      if (doc == null) return _error('任务不存在', 404);
      if (doc.value['status'] != 'awaiting_network_permission')
        return _error('任务当前没有待确认的联网请求', 409);
      final asked =
          (doc.value['requested_network_domains'] as List? ?? const [])
              .map((item) => item.toString())
              .toSet();
      if (!requested.toSet().difference(asked).isEmpty)
        return _error('只能授权本次任务已说明的域名', 400);
      final inputKey = doc.value['input_object_key']?.toString();
      if (inputKey == null || inputKey.isEmpty) {
        return _error('任务输入已过期', 410);
      }
      final savedInput =
          jsonDecode(utf8.decode(store.getImmutable(inputKey)['input.json']!))
              as Map<String, dynamic>;
      _mutateTask(
        key,
        (value) => {
          ...value,
          'authorized_network_domains': {
            ...(value['authorized_network_domains'] as List? ?? const []).map(
              (item) => item.toString(),
            ),
            ...requested,
          }.toList()..sort(),
          'requested_network_domains': [],
          'status': 'queued',
          'attempt': (value['attempt'] as num? ?? 1).toInt() + 1,
          'updated_at': _now(),
        },
      );
      unawaited(_runTask(device.tenant, id, savedInput));
      return _json({'ok': true, 'status': 'queued'});
    } on FormatException catch (error) {
      return _error(error.message, 400);
    } on Object {
      return _error('授权联网失败', 503);
    }
  }

  Future<Response> _setAgentTaskNetworkMode(
    Request request,
    _Device device,
    String id,
  ) async {
    try {
      final body = await _body(request, 1024);
      final rawMode = body['mode']?.toString();
      if (!const {'auto', 'on', 'off'}.contains(rawMode)) {
        return _error('联网模式无效', 400);
      }
      final mode = _networkMode(rawMode);
      final taskId = _safeId(id, '任务 ID');
      final key = 'task/${device.tenant}/$taskId';
      final current = store.get(key);
      if (current == null || current.value['remote_agent_turn'] != true) {
        return _error('Agent 任务不存在', 404);
      }
      if (!const {'queued', 'running'}.contains(current.value['status'])) {
        return _error('任务已结束，无法修改联网模式', 409);
      }
      _mutateTask(
        key,
        (value) => {...value, 'network_mode': mode, 'updated_at': _now()},
      );
      _appendEvent(key, {'type': 'network_mode', 'mode': mode});
      if (mode == 'off') {
        final controller = runtime;
        if (controller is! XiaoqiTaskNetworkController) {
          _appendEvent(key, {
            'type': 'network_revocation_failed',
            'reason': 'runtime_control_unavailable',
          });
          return _json({
            'ok': false,
            'mode': mode,
            'network_revoked': false,
            'error': '联网模式已关闭，但服务不支持撤销运行中脚本的公网代理',
          }, 503);
        }
        try {
          await (controller as XiaoqiTaskNetworkController).disableTaskNetwork(
            tenantId: device.tenant,
            taskId: taskId,
          );
        } on Object {
          _appendEvent(key, {
            'type': 'network_revocation_failed',
            'reason': 'sandbox_control_failed',
          });
          return _json({
            'ok': false,
            'mode': mode,
            'network_revoked': false,
            'error': '联网模式已关闭，但运行中脚本的公网代理未能撤销',
          }, 503);
        }
        _appendEvent(key, {
          'type': 'network_revoked',
          'mode': mode,
          'scope': 'running_script_proxy',
        });
      }
      return _json({
        'ok': true,
        'mode': mode,
        if (mode == 'off') 'network_revoked': true,
      });
    } on FormatException catch (error) {
      return _error(error.message, 400);
    } on Object {
      return _error('更新任务联网模式失败', 503);
    }
  }

  Future<Response> _sendAgentTaskInstruction(
    Request request,
    _Device device,
    String id,
  ) async {
    try {
      final body = await _body(request, 8192);
      final taskId = _safeId(id, '任务 ID');
      final messageId = _safeId(body['message_id'], '消息 ID');
      final sequence = body['sequence'] is num
          ? (body['sequence'] as num).toInt()
          : 0;
      final content = body['content']?.toString().trim() ?? '';
      if (sequence < 1 || content.isEmpty || content.length > 4000) {
        return _error('补充指令无效或超过 4000 字', 400);
      }
      final key = 'task/${device.tenant}/$taskId';
      final current = store.get(key);
      if (current == null || current.value['remote_agent_turn'] != true) {
        return _error('Agent 任务不存在', 404);
      }
      if (!const {'queued', 'running'}.contains(current.value['status'])) {
        return _error('任务已结束；请将补充内容作为下一条消息发送', 409);
      }
      final instructions =
          (current.value['steering_instructions'] as List? ?? const [])
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
      final duplicate = instructions
          .where((item) => item['message_id'] == messageId)
          .firstOrNull;
      if (duplicate != null) {
        if (duplicate['content'] != content ||
            duplicate['sequence'] != sequence) {
          return _error('消息 ID 已用于其他补充指令', 409);
        }
        return _json({
          'ok': true,
          'status': duplicate['status'] ?? 'received',
          'sequence': sequence,
          'duplicate': true,
        });
      }
      final latestSequence = instructions.fold<int>(
        0,
        (latest, item) => max(
          latest,
          item['sequence'] is num ? (item['sequence'] as num).toInt() : 0,
        ),
      );
      if (sequence != latestSequence + 1) {
        return _error('补充指令顺序已变化，请重试', 409);
      }
      final instruction = <String, dynamic>{
        'message_id': messageId,
        'sequence': sequence,
        'content': content,
        'status': 'received',
        'created_at': _now(),
      };
      _mutateTask(
        key,
        (value) => {
          ...value,
          'steering_instructions': [...instructions, instruction],
          'updated_at': _now(),
        },
      );
      _appendEvent(key, {
        'type': 'steering_received',
        'message_id': messageId,
        'sequence': sequence,
      });
      return _json({'ok': true, 'status': 'received', 'sequence': sequence});
    } on FormatException catch (error) {
      return _error(error.message, 400);
    } on Object {
      return _error('发送补充指令失败', 503);
    }
  }

  Future<Response> _resumeTask(_Device device, String id) async {
    try {
      final taskId = _safeId(id, '任务 ID');
      final key = 'task/${device.tenant}/$taskId';
      final task = store.get(key);
      if (task == null) return _error('任务不存在', 404);
      if (!const {
        'failed',
        'awaiting_network_permission',
      }.contains(task.value['status']))
        return _error('任务当前无法恢复', 409);
      final inputKey = task.value['input_object_key']?.toString();
      if (inputKey == null) return _error('任务输入已过期', 410);
      final requestMap =
          jsonDecode(utf8.decode(store.getImmutable(inputKey)['input.json']!))
              as Map<String, dynamic>;
      _mutateTask(
        key,
        (value) => {
          ...value,
          'status': 'queued',
          'cancel_requested': false,
          'attempt': (value['attempt'] as num? ?? 1).toInt() + 1,
          'updated_at': _now(),
        },
      );
      unawaited(_runTask(device.tenant, taskId, requestMap));
      return _json({'ok': true, 'status': 'queued'});
    } on Object {
      return _error('恢复任务失败', 503);
    }
  }

  Future<Response> _downloadArtifact(
    _Device device,
    String taskId,
    String artifactId,
  ) async {
    try {
      final safeTask = _safeId(taskId, '任务 ID');
      final safeArtifact = _safeId(artifactId, '产物 ID');
      final doc = store.get('task/${device.tenant}/$safeTask');
      if (doc == null) return _error('任务不存在', 404);
      final artifact = (doc.value['artifacts'] as List? ?? const [])
          .whereType<Map>()
          .cast<Map<String, dynamic>>()
          .where((item) => item['id'] == safeArtifact)
          .firstOrNull;
      if (artifact == null) return _error('产物不存在', 404);
      final bytes = store.getObject(artifact['object_key'].toString());
      return Response.ok(
        bytes,
        headers: {
          HttpHeaders.contentTypeHeader:
              artifact['media_type'] ?? 'application/octet-stream',
          HttpHeaders.contentLengthHeader: '${bytes.length}',
          'content-disposition': 'attachment; filename="${artifact['name']}"',
          'Cache-Control': 'private, no-store',
        },
      );
    } on Object {
      return _error('下载产物失败', 404);
    }
  }

  Future<Response> _authenticated(
    Request request,
    Future<Response> Function(_Device) action,
  ) async {
    final header = request.headers[HttpHeaders.authorizationHeader] ?? '';
    if (!header.startsWith('Bearer ')) return _error('登录状态已失效，请重新登录', 401);
    final token = header.substring(7).trim();
    if (token.isEmpty || token.length > 512)
      return _error('登录状态已失效，请重新登录', 401);
    final key = 'device/${sha256.convert(utf8.encode(token))}';
    final record = store.get(key);
    if (record == null || record.value['revoked_at'] != null)
      return _error('登录状态已失效，请重新登录', 401);
    return action(_Device(key, record.value));
  }

  Future<Map<String, dynamic>> _normalizeCapability(
    String tenant,
    Object? raw,
  ) async {
    if (raw is! Map) throw const FormatException('技能记录格式无效');
    final id = _safeId(raw['id'], '能力 ID');
    final kind = raw['kind'] ?? 'skill';
    if (kind != 'skill' && kind != 'plugin')
      throw const FormatException('能力类型无效');
    final name = raw['name']?.toString().trim() ?? '';
    final description = raw['description']?.toString().trim() ?? '';
    if (name.isEmpty || name.length > 128 || description.length > 2048)
      throw const FormatException('技能名称或用途说明不符合长度限制');
    final versions = raw['versions'];
    if (versions is! List || versions.length > 100)
      throw const FormatException('技能版本列表无效');
    final normalized = <Map<String, dynamic>>[];
    for (final rawVersion in versions) {
      if (rawVersion is! Map) throw const FormatException('技能版本格式无效');
      final versionId = _safeId(rawVersion['id'], '版本 ID');
      final content = rawVersion['content']?.toString() ?? '';
      final contentBytes = utf8.encode(content);
      if (contentBytes.length > _maxCapabilityBytes)
        throw const FormatException('技能版本超过 2 MB');
      final fm = RegExp(
        r'^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)',
      ).firstMatch(content);
      if (fm == null)
        throw const FormatException('SKILL.md 必须以 YAML frontmatter 开始');
      final header = fm.group(1)!;
      final skillName = RegExp(
        r'(?m)^name:\s*([a-z0-9]+(?:-[a-z0-9]+)*)\s*$',
      ).firstMatch(header)?.group(1);
      var skillDescription = RegExp(
        r'(?m)^description:\s*(.*?)\s*$',
      ).firstMatch(header)?.group(1)?.trim();
      if (skillDescription != null &&
          skillDescription.length >= 2 &&
          ((skillDescription.startsWith('"') &&
                  skillDescription.endsWith('"')) ||
              (skillDescription.startsWith("'") &&
                  skillDescription.endsWith("'")))) {
        skillDescription = skillDescription
            .substring(1, skillDescription.length - 1)
            .trim();
      }
      if (skillName == null || skillName.length > 64)
        throw const FormatException('技能 name 必须是 1-64 位小写字母、数字或连字符');
      if (skillDescription == null ||
          skillDescription.isEmpty ||
          skillDescription.length > 1024)
        throw const FormatException('SKILL.md 必须包含有效 description');
      if (content.substring(fm.end).trim().isEmpty)
        throw const FormatException('SKILL.md 必须包含 Markdown 技能指令');
      final files = <String, List<int>>{'SKILL.md': contentBytes};
      final extra = rawVersion['files'];
      if (extra is Map) {
        for (final entry in extra.entries) {
          final path = entry.key.toString().replaceAll('\\', '/');
          final parts = path.split('/');
          if (path.startsWith('/') ||
              parts.any(
                (part) => part.isEmpty || part == '.' || part == '..',
              ) ||
              !RegExp(r'^[A-Za-z0-9._/-]{1,240}$').hasMatch(path) ||
              !const {
                'scripts',
                'references',
                'assets',
              }.contains(parts.first) ||
              (parts.first == 'scripts' &&
                  !RegExp(
                    r'\.(py|js|mjs|cjs|ts|mts)$',
                    caseSensitive: false,
                  ).hasMatch(path))) {
            throw const FormatException('技能资源路径无效');
          }
          try {
            files[path] = base64Decode(entry.value.toString());
          } on Object {
            throw const FormatException('技能资源编码无效');
          }
        }
      } else if (extra != null) {
        throw const FormatException('技能资源格式无效');
      }
      if (files.values.fold<int>(0, (sum, file) => sum + file.length) >
          _maxCapabilityBytes)
        throw const FormatException('技能包超过 2 MB');
      final digestInput = files.length == 1
          ? utf8.encode(content)
          : utf8.encode(
              _canonical({
                for (final path in files.keys) path: base64Encode(files[path]!),
              }),
            );
      final digest = sha256.convert(digestInput).toString();
      final suppliedHash = rawVersion['content_hash']?.toString() ?? '';
      if (suppliedHash.isNotEmpty && suppliedHash != digest)
        throw const FormatException('技能版本校验值不匹配');
      final artifactKey =
          'tenants/$tenant/capabilities/$id/versions/$versionId-$digest.zip';
      store.putImmutable(artifactKey, files);
      normalized.add({
        'id': versionId,
        'number': _asInt(rawVersion['number']) ?? normalized.length + 1,
        'content_hash': digest,
        'created_at': rawVersion['created_at']?.toString() ?? '',
        'parent_version_id': rawVersion['parent_version_id'],
        'artifact_key': artifactKey,
      });
    }
    final currentVersionId = versions.isEmpty
        ? ''
        : _safeId(raw['current_version_id'], '当前版本 ID');
    if (versions.isNotEmpty &&
        !normalized.any((version) => version['id'] == currentVersionId))
      throw const FormatException('当前版本不在技能版本列表中');
    return {
      'schema_version': 1,
      'id': id,
      'kind': kind,
      'name': name,
      'description': description,
      'versions': normalized,
      'current_version_id': currentVersionId,
      'created_at': raw['created_at']?.toString() ?? '',
      'updated_at': raw['updated_at']?.toString() ?? '',
      'show_in_menu': raw['show_in_menu'] != false,
      'deleted_at': raw['deleted_at'],
    };
  }

  Map<String, dynamic> _publicCapability(
    Map<String, dynamic> document,
    int revision,
    bool includeContent,
  ) {
    final result = {...document, 'cloud_revision': revision};
    result['versions'] = (document['versions'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final version = Map<String, dynamic>.from(raw);
          final artifactKey = version.remove('artifact_key')?.toString() ?? '';
          if (includeContent && artifactKey.isNotEmpty) {
            final files = store.getImmutable(artifactKey);
            version['content'] = utf8.decode(files['SKILL.md'] ?? const []);
            version['files'] = {
              for (final entry in files.entries)
                if (entry.key != 'SKILL.md')
                  entry.key: base64Encode(entry.value),
            };
          }
          return version;
        })
        .toList();
    return result;
  }

  void _appendEvent(String key, Map<String, dynamic> event) {
    _mutateTask(key, (value) {
      final events = (value['events'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      events.add({'seq': events.length, ...event, 'created_at': _now()});
      return {...value, 'events': events, 'updated_at': _now()};
    });
  }

  StoredDocument? _mutateTask(
    String key,
    Map<String, dynamic> Function(Map<String, dynamic>) transform,
  ) {
    for (var attempt = 0; attempt < 10; attempt++) {
      final current = store.get(key);
      if (current == null) return null;
      try {
        return store.put(key, transform(current.value), current.revision);
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('任务更新冲突过多');
  }

  Map<String, dynamic> _publicArtifact(
    Map<String, dynamic> item,
    String taskId,
  ) => {
    'task_id': taskId,
    for (final field in const ['id', 'name', 'media_type', 'size', 'sha256'])
      if (item.containsKey(field)) field: item[field],
  };

  Map<String, dynamic> _publicEvent(Map<String, dynamic> item, String taskId) {
    final result = {...item};
    if (result['artifacts'] is List) {
      result['artifacts'] = (result['artifacts'] as List)
          .whereType<Map>()
          .map((raw) => _publicArtifact(Map<String, dynamic>.from(raw), taskId))
          .toList();
    }
    return result;
  }

  static Future<Map<String, dynamic>> _body(Request request, int limit) async {
    final raw = await request.read().toList();
    final size = raw.fold<int>(0, (sum, part) => sum + part.length);
    if (size > limit) throw const FormatException('请求内容过大');
    final decoded = jsonDecode(
      utf8.decode(raw.expand((part) => part).toList()),
    );
    if (decoded is! Map) throw const FormatException('请求格式无效');
    return Map<String, dynamic>.from(decoded);
  }

  _EmailConfig _emailConfig() {
    final env = Platform.environment;
    final email = (env['CAPABILITY_OWNER_EMAIL'] ?? '').trim().toLowerCase();
    final host = (env['CAPABILITY_SMTP_HOST'] ?? 'smtp.qq.com').trim();
    final username = (env['CAPABILITY_SMTP_USERNAME'] ?? '').trim();
    final password = env['CAPABILITY_SMTP_PASSWORD'] ?? '';
    final pepper = env['CAPABILITY_AUTH_CODE_PEPPER'] ?? '';
    final port = int.tryParse(env['CAPABILITY_SMTP_PORT'] ?? '465') ?? 0;
    if (!_validEmail(email) ||
        host.isEmpty ||
        username.isEmpty ||
        password.isEmpty ||
        pepper.length < 32 ||
        port < 1 ||
        port > 65535)
      throw const _ConfigurationException();
    return _EmailConfig(email, host, username, password, pepper, port);
  }

  static String _email(Object? value) {
    final email = value?.toString().trim().toLowerCase() ?? '';
    if (!_validEmail(email)) throw const FormatException('邮箱地址格式无效');
    return email;
  }

  static bool _validEmail(String email) =>
      email.length <= 254 &&
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email);
  static String _codeDigest(String email, String code, String pepper) => Hmac(
    sha256,
    utf8.encode(pepper),
  ).convert(utf8.encode('$email:$code')).toString();
  static bool _constantTimeEquals(String a, String b) {
    final left = utf8.encode(a), right = utf8.encode(b);
    var difference = left.length ^ right.length;
    final size = max(left.length, right.length);
    for (var i = 0; i < size; i++)
      difference |=
          (i < left.length ? left[i] : 0) ^ (i < right.length ? right[i] : 0);
    return difference == 0;
  }

  static String _token() => base64Url
      .encode(List<int>.generate(48, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  static String _safeId(Object? value, String label) {
    final id = value?.toString() ?? '';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id))
      throw FormatException('$label无效');
    return id;
  }

  static int? _asInt(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
  static Object _publicTaskStatus(Object? status) =>
      status == 'completed' ? 'succeeded' : status ?? 'unknown';
  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  static String _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return '{${keys.map((key) => '${jsonEncode(key)}:${_canonical(value[key])}').join(',')}}';
    }
    if (value is List) return '[${value.map(_canonical).join(',')}]';
    return jsonEncode(value);
  }

  static Response _json(Object? value, [int status = 200]) => Response(
    status,
    body: jsonEncode(value),
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  );
  static Response _error(String message, int status) => _json({
    'error': {'message': message},
  }, status);
  static Response _genericCodeResponse() =>
      _json({'ok': true, 'message': '如果该邮箱已获准登录，验证码会发送到邮箱'}, 202);
}

class _Device {
  const _Device(this.key, this.value);
  final String key;
  final Map<String, dynamic> value;
  String get tenant => value['tenant_id']?.toString() ?? 'personal';
}

class _EmailConfig {
  const _EmailConfig(
    this.ownerEmail,
    this.smtpHost,
    this.smtpUsername,
    this.smtpPassword,
    this.pepper,
    this.smtpPort,
  );
  final String ownerEmail, smtpHost, smtpUsername, smtpPassword, pepper;
  final int smtpPort;
}

class _ConfigurationException implements Exception {
  const _ConfigurationException();
}
