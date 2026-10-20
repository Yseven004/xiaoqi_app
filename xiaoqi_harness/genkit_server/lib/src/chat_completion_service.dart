import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:shelf/shelf.dart';
import 'model_limits.dart';

typedef ChatCompletionGenerator =
    Future<String> Function(ChatCompletionInput input);

class ChatCompletionInput {
  const ChatCompletionInput({
    required this.modelId,
    required this.namespace,
    required this.baseUrl,
    required this.apiKey,
    required this.messages,
    required this.temperature,
    required this.maxTokens,
  });

  final String modelId;
  final String namespace;
  final String baseUrl;
  final String apiKey;
  final List<Message> messages;
  final double temperature;
  final int maxTokens;
}

/// Preserves the app's OpenAI-compatible helper API while keeping model keys
/// and model-provider requests on the server.
class ChatCompletionService {
  ChatCompletionService({
    ChatCompletionGenerator? generate,
    Map<String, String>? environment,
  }) : _generate = generate ?? _generateWithGenkit,
       _environment = environment ?? Platform.environment;

  static const _maxRequestBytes = 8 * 1024 * 1024;
  static const _maxImageBytes = 5 * 1024 * 1024;

  final ChatCompletionGenerator _generate;
  final Map<String, String> _environment;

  Future<Response> handle(Request request) async {
    Map<String, dynamic> body;
    try {
      body = await _readBody(request);
    } on _PayloadTooLarge {
      return _error(413, '请求内容过大');
    } on FormatException {
      return _error(400, '请求格式无效');
    }

    final selection = _modelSelection(body['model_id'] ?? body['model']);
    if (selection == null) return _error(400, '暂不支持此模型');
    if (selection.apiKey.isEmpty) return _error(503, '服务器尚未配置此模型');

    final List<Message> messages;
    try {
      messages = _messages(body['messages']);
    } on FormatException catch (error) {
      return _error(400, error.message.toString());
    }

    final temperature = _temperature();
    final maxTokens = ModelLimits.forModel(selection.modelId).maxOutputTokens;

    try {
      final content = await _generate(
        ChatCompletionInput(
          modelId: selection.modelId,
          namespace: selection.namespace,
          baseUrl: selection.baseUrl,
          apiKey: selection.apiKey,
          messages: messages,
          temperature: temperature,
          maxTokens: maxTokens,
        ),
      ).timeout(const Duration(seconds: 120));
      return Response.ok(
        jsonEncode({
          'id': 'chatcmpl-${DateTime.now().microsecondsSinceEpoch}',
          'object': 'chat.completion',
          'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'model': selection.modelId,
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': content},
              'finish_reason': 'stop',
            },
          ],
        }),
        headers: _headers,
      );
    } on TimeoutException {
      return _error(504, 'AI处理超时，请稍后重试');
    } on Object {
      return _error(502, 'AI服务暂时不可用，请稍后重试');
    }
  }

  Future<Map<String, dynamic>> _readBody(Request request) async {
    final declaredLength = int.tryParse(
      request.headers['content-length'] ?? '',
    );
    if (declaredLength != null && declaredLength > _maxRequestBytes) {
      throw _PayloadTooLarge();
    }
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      if (bytes.length + chunk.length > _maxRequestBytes) {
        throw _PayloadTooLarge();
      }
      bytes.addAll(chunk);
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) throw const FormatException('请求格式无效');
    return Map<String, dynamic>.from(value);
  }

  _ModelSelection? _modelSelection(Object? rawModel) {
    final modelId =
        (rawModel?.toString().trim().isNotEmpty == true
            ? rawModel.toString().trim()
            : _environment['XIAOQI_DEFAULT_TEXT_MODEL']?.trim()) ??
        '';
    final selectedModel = modelId.isEmpty ? 'mimo-v2.6-flash' : modelId;
    if (!const {'deepseek-flash', 'mimo-v2.6-flash'}.contains(selectedModel)) {
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(selectedModel)) {
      return null;
    }

    if (selectedModel.toLowerCase().startsWith('mimo')) {
      return _ModelSelection(
        modelId: selectedModel,
        namespace: 'mimo',
        apiKey: (_environment['MIMO_API_KEY'] ?? '').trim(),
        baseUrl: _baseUrl(
          _environment['MIMO_BASE_URL'],
          'https://api.xiaomimimo.com/v1',
        ),
      );
    }
    if (selectedModel.toLowerCase().startsWith('deepseek')) {
      return _ModelSelection(
        modelId: selectedModel,
        namespace: 'deepseek',
        apiKey: (_environment['DEEPSEEK_API_KEY'] ?? '').trim(),
        baseUrl: _baseUrl(
          _environment['DEEPSEEK_BASE_URL'],
          'https://api.deepseek.com/v1',
        ),
      );
    }
    return null;
  }

  List<Message> _messages(Object? rawMessages) {
    if (rawMessages is! List ||
        rawMessages.isEmpty ||
        rawMessages.length > 64) {
      throw const FormatException('messages 必须包含 1 到 64 条消息');
    }
    final output = <Message>[];
    var totalImageBytes = 0;
    for (final rawMessage in rawMessages) {
      if (rawMessage is! Map) continue;
      final role = (rawMessage['role']?.toString() ?? 'user').trim();
      final genkitRole = switch (role) {
        'system' => Role.system,
        'user' => Role.user,
        'assistant' => Role.model,
        _ => null,
      };
      if (genkitRole == null) {
        throw const FormatException('消息角色无效');
      }
      final contentParts = <Part>[];
      final content = rawMessage['content'];
      if (content is String) {
        if (content.isNotEmpty) contentParts.add(TextPart(text: content));
        output.add(Message(role: genkitRole, content: contentParts));
        continue;
      }
      if (content is! List) throw const FormatException('消息内容无效');
      for (final rawPart in content) {
        if (rawPart is! Map) continue;
        if (rawPart['type'] == 'text') {
          final text = rawPart['text']?.toString() ?? '';
          if (text.isNotEmpty) contentParts.add(TextPart(text: text));
        } else if (rawPart['type'] == 'image_url') {
          final image = rawPart['image_url'];
          final url = image is Map ? image['url']?.toString() ?? '' : '';
          final match = RegExp(
            r'^data:(image/(?:png|jpeg|webp|gif));base64,([A-Za-z0-9+/]+={0,2})$',
          ).firstMatch(url);
          if (match == null) {
            throw const FormatException('只支持 PNG、JPEG、WEBP 或 GIF 图片');
          }
          try {
            totalImageBytes += base64.decode(match.group(2)!).length;
          } on FormatException {
            throw const FormatException('图片内容无效');
          }
          if (totalImageBytes > _maxImageBytes) {
            throw const FormatException('图片总大小不能超过 5 MB');
          }
          contentParts.add(
            MediaPart(
              media: Media(contentType: match.group(1), url: url),
            ),
          );
        }
      }
      output.add(Message(role: genkitRole, content: contentParts));
    }
    if (output.isEmpty) throw const FormatException('对话内容为空');
    return output;
  }

  double _temperature() {
    final value =
        double.tryParse(_environment['XIAOQI_TEXT_TEMPERATURE'] ?? '') ?? 0.4;
    return value.clamp(0.0, 2.0).toDouble();
  }

  static String _baseUrl(String? configured, String fallback) {
    final value = configured?.trim() ?? '';
    return value.isEmpty ? fallback : value.replaceFirst(RegExp(r'/$'), '');
  }

  static Future<String> _generateWithGenkit(ChatCompletionInput input) async {
    final ai = Genkit(
      promptDir: null,
      isDevEnv: false,
      plugins: [
        openAI(
          name: input.namespace,
          apiKey: input.apiKey,
          baseUrl: input.baseUrl,
          models: [CustomModelDefinition(name: input.modelId)],
        ),
      ],
    );
    final response = await ai.generate(
      model: openAI.model(input.modelId, namespace: input.namespace),
      messages: input.messages,
      config: OpenAIChatOptions(
        temperature: input.temperature,
        maxTokens: input.maxTokens,
      ),
    );
    return response.text;
  }

  static const _headers = {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  };

  static Response _error(int status, String message) => Response(
    status,
    body: jsonEncode({
      'error': {'message': message},
    }),
    headers: _headers,
  );
}

class _ModelSelection {
  const _ModelSelection({
    required this.modelId,
    required this.namespace,
    required this.apiKey,
    required this.baseUrl,
  });

  final String modelId;
  final String namespace;
  final String apiKey;
  final String baseUrl;
}

class _PayloadTooLarge implements Exception {
  const _PayloadTooLarge();
}
