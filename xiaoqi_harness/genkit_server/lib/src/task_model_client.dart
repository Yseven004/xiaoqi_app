import 'dart:convert';
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
    this.prefixContent,
    this.prefixReasoning,
    this.requireDeepSeekPrefix = false,
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
    String? prefixContent,
    String? prefixReasoning,
    bool requireDeepSeekPrefix = false,
    required Future<T> Function() operation,
  }) async {
    cancellation.throwIfCancelled();
    final client = TaskModelClient(
      store,
      tenantId,
      taskId,
      limits: limits,
      cancellation: cancellation,
      prefixContent: prefixContent,
      prefixReasoning: prefixReasoning,
      requireDeepSeekPrefix: requireDeepSeekPrefix,
    );
    try {
      final result = await runZoned(operation, zoneValues: {_zoneKey: client});
      if (client._reservationError != null) throw client._reservationError!;
      client._assertPrefixAccepted();
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
  String? prefixContent;
  String? prefixReasoning;
  final bool requireDeepSeekPrefix;
  final http.Client _inner;
  StateError? _reservationError;
  bool _prefixAccepted = false;

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

  void _assertPrefixAccepted() {
    if (requireDeepSeekPrefix && !_prefixAccepted) {
      throw StateError('当前模型接口没有接受 DeepSeek 前缀续写请求；原回答已保留，没有重新生成。');
    }
  }

  http.Request _prefixRequest(http.Request request, List<int> bytes) {
    if (request.url.host.toLowerCase() != 'api.deepseek.com') {
      throw StateError('当前 DeepSeek 代理不支持官方前缀续写接口；原回答已保留。');
    }
    final path = request.url.path;
    if (!path.endsWith('/chat/completions')) {
      throw StateError('当前 DeepSeek 请求不是聊天补全接口，不能安全续写。');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map || decoded['messages'] is! List) {
      throw StateError('DeepSeek 续写请求缺少标准消息历史。');
    }
    final body = Map<String, dynamic>.from(decoded);
    final rawMessages = body['messages'] as List;
    if (rawMessages.isEmpty || rawMessages.any((message) => message is! Map)) {
      throw StateError('DeepSeek 续写请求的消息历史无效。');
    }
    final messages = rawMessages
        .map((message) => Map<String, dynamic>.from(message as Map))
        .toList();
    if (!messages.any((message) => message['role'] == 'user')) {
      throw StateError('DeepSeek 续写请求缺少原始用户消息。');
    }
    final previous = messages.last;
    final pendingToolCalls = previous['tool_calls'];
    if (previous['role'] == 'assistant' &&
        pendingToolCalls is List &&
        pendingToolCalls.isNotEmpty) {
      throw StateError('原任务停在未完成的工具调用，不能作为回答前缀续写。');
    }
    messages.add({
      'role': 'assistant',
      'content': prefixContent ?? '',
      if ((prefixReasoning ?? '').isNotEmpty)
        'reasoning_content': prefixReasoning,
      'prefix': true,
    });
    body['messages'] = messages;

    final betaPath = path.replaceFirst(
      RegExp(r'(?:/v1)?/chat/completions$'),
      '/beta/chat/completions',
    );
    if (betaPath == path) {
      throw StateError('DeepSeek 前缀续写需要官方 beta 聊天补全接口。');
    }
    final requestHeaders = Map<String, String>.from(request.headers)
      ..removeWhere((key, _) => key.toLowerCase() == 'content-length');
    final outgoing =
        http.Request(request.method, request.url.replace(path: betaPath))
          ..headers.addAll(requestHeaders)
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection
          ..encoding = request.encoding
          ..body = jsonEncode(body);
    return outgoing;
  }

  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'POST') {
      try {
        _claim();
      } on StateError catch (error) {
        _reservationError = error;
        rethrow;
      }
    }
    final hasPrefix =
        (prefixContent?.isNotEmpty ?? false) ||
        (prefixReasoning?.isNotEmpty ?? false);
    if (!hasPrefix) return _inner.send(request);
    if (request is! http.Request) {
      throw StateError('Genkit 生成请求无法通过公开 HTTP 扩展点安全添加续写前缀。');
    }
    final originalBytes = await request.finalize().toBytes();
    final outgoing = _prefixRequest(request, originalBytes);
    final response = await _inner.send(outgoing);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      _prefixAccepted = true;
      prefixContent = null;
      prefixReasoning = null;
    }
    return response;
  }

  @override
  void close() => _inner.close();
}
