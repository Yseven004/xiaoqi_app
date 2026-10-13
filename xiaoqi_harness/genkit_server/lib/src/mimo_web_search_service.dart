import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class MimoWebSearchSource {
  const MimoWebSearchSource({
    required this.title,
    required this.url,
    required this.summary,
  });

  final String title;
  final String url;
  final String summary;

  Map<String, Object?> toJson() => {
    'title': title,
    'url': url,
    'summary': summary,
  };
}

class MimoWebSearchResult {
  const MimoWebSearchResult({required this.summary, required this.sources});

  final String summary;
  final List<MimoWebSearchSource> sources;

  Map<String, Object?> toJson() => {
    'summary': summary,
    'sources': sources.map((source) => source.toJson()).toList(),
  };
}

class MimoWebSearchException implements Exception {
  const MimoWebSearchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Small adapter for MiMo's documented OpenAI-compatible Web Search API.
/// Only the user-provided search query is sent to MiMo.
class MimoWebSearchService {
  MimoWebSearchService({
    required this.apiKey,
    required this.model,
    this.baseUrl = 'https://api.xiaomimimo.com/v1',
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const supportedModels = {
    'mimo-v2.6-flash',
    'mimo-v2.6-pro',
    'mimo-v2.6-pro-ultraspeed',
    'mimo-v2.5-pro',
    'mimo-v2.5',
  };

  final String apiKey;
  final String model;
  final String baseUrl;
  final http.Client _client;
  final bool _ownsClient;

  Future<MimoWebSearchResult> search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty || query.length > 2000) {
      throw const FormatException('搜索词必须为 1 到 2000 个字符');
    }
    if (apiKey.trim().isEmpty) {
      throw const MimoWebSearchException(
        '服务端未配置 MiMo 搜索账号。请在 MiMo 开放平台「控制台 → 插件管理」开通 Web Search，并配置服务端 MIMO_API_KEY。',
      );
    }
    if (!supportedModels.contains(model)) {
      throw MimoWebSearchException('MiMo Web Search 不支持当前搜索模型：$model');
    }
    final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final endpoint = Uri.parse(normalizedBaseUrl).resolve('chat/completions');
    final http.Response response;
    try {
      response = await _client
          .post(
            endpoint,
            headers: {
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': model,
              'messages': [
                {'role': 'system', 'content': '只检索用户给出的查询词，返回简洁、可核验的实时公开网页结果。'},
                {'role': 'user', 'content': query},
              ],
              'max_completion_tokens': 500,
              'stream': false,
              'thinking': {'type': 'disabled'},
              'tools': [
                {
                  'type': 'web_search',
                  'max_keyword': 1,
                  'force_search': true,
                  'limit': 3,
                },
              ],
              'tool_choice': 'auto',
            }),
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const MimoWebSearchException('联网搜索超时，请稍后重试。');
    } on Object {
      throw const MimoWebSearchException('无法连接 MiMo 联网搜索服务，请稍后重试。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MimoWebSearchException(
        'MiMo 联网搜索返回 HTTP ${response.statusCode}。请确认 Web Search 插件已在 MiMo 控制台开通且账号额度可用。',
      );
    }
    final Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw const FormatException();
      body = Map<String, dynamic>.from(decoded);
    } on Object {
      throw const MimoWebSearchException('MiMo 联网搜索返回了无法识别的数据。');
    }
    final choices = body['choices'];
    final message =
        choices is List && choices.isNotEmpty && choices.first is Map
        ? (choices.first as Map)['message']
        : null;
    if (message is! Map) {
      throw const MimoWebSearchException('MiMo 联网搜索没有返回结果。');
    }
    final rawSources = message['annotations'];
    final sources = <MimoWebSearchSource>[];
    if (rawSources is List) {
      final seen = <String>{};
      for (final raw in rawSources.whereType<Map>()) {
        if (raw['type'] != 'url_citation') continue;
        final uri = Uri.tryParse(raw['url']?.toString() ?? '');
        if (uri == null ||
            !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
            uri.host.isEmpty ||
            !seen.add(uri.toString())) {
          continue;
        }
        sources.add(
          MimoWebSearchSource(
            title: _bounded(raw['title'], 300),
            url: uri.toString(),
            summary: _bounded(raw['summary'], 1200),
          ),
        );
      }
    }
    if (sources.isEmpty) {
      throw const MimoWebSearchException('MiMo 没有返回可验证的网页来源，不能把模型知识作为搜索结果。');
    }
    return MimoWebSearchResult(
      summary: _bounded(message['content'], 6000),
      sources: List.unmodifiable(sources.take(3)),
    );
  }

  static String _bounded(Object? value, int maxLength) {
    final text = value?.toString().trim() ?? '';
    return text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
