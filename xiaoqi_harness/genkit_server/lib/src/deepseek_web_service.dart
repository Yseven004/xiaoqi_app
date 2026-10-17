import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class DeepSeekWebSearchSource {
  const DeepSeekWebSearchSource({
    required this.title,
    required this.url,
    required this.summary,
    this.content = '',
  });

  final String title;
  final String url;
  final String summary;
  final String content;

  Map<String, Object?> toJson() => {
    'title': title,
    'url': url,
    'summary': summary,
  };
}

class DeepSeekWebSearchResult {
  const DeepSeekWebSearchResult({required this.summary, required this.sources});

  final String summary;
  final List<DeepSeekWebSearchSource> sources;

  Map<String, Object?> toJson() => {
    'summary': summary,
    'sources': sources.map((source) => source.toJson()).toList(),
  };
}

class DeepSeekWebFetchResult {
  const DeepSeekWebFetchResult({required this.title, required this.content});

  final String title;
  final String content;

  Map<String, Object?> toJson() => {'title': title, 'content': content};
}

class DeepSeekWebException implements Exception {
  const DeepSeekWebException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class DeepSeekWebSearchService {
  DeepSeekWebSearchService({
    required this.apiKey,
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.timeout = const Duration(seconds: 20),
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  Future<DeepSeekWebSearchResult> search(
    String rawQuery, {
    int count = 3,
    bool needContent = false,
  }) async {
    final query = rawQuery.trim();
    if (query.isEmpty || query.runes.length > 128 || count < 1 || count > 50) {
      throw const FormatException('搜索词必须为 1 到 128 个字符');
    }
    final body = await _post('tools/search', {
      'query': query,
      'count': count,
      'need_content': needContent,
    });
    final rawResults = body['results'];
    if (rawResults is! List) {
      throw const DeepSeekWebException('DeepSeek 联网搜索返回格式异常。');
    }

    final sources = <DeepSeekWebSearchSource>[];
    final seen = <String>{};
    for (final raw in rawResults.whereType<Map>()) {
      final uri = Uri.tryParse(raw['url']?.toString() ?? '');
      if (uri == null ||
          !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
          uri.host.isEmpty ||
          !seen.add(uri.toString())) {
        continue;
      }
      final title = _bounded(raw['title'], 300);
      final summary = _bounded(raw['summary'] ?? raw['snippet'], 1200);
      final content = needContent ? _bounded(raw['content'], 6000) : '';
      sources.add(
        DeepSeekWebSearchSource(
          title: title.isEmpty ? uri.host : title,
          url: uri.toString(),
          summary: summary,
          content: content,
        ),
      );
    }
    if (sources.isEmpty) {
      throw const DeepSeekWebException('DeepSeek 联网搜索没有返回可验证的网页来源。');
    }
    final summary = sources
        .map((source) => '${source.title}\n${source.summary}')
        .where((item) => item.trim().isNotEmpty)
        .join('\n\n');
    return DeepSeekWebSearchResult(
      summary: _bounded(summary, 6000),
      sources: List.unmodifiable(sources),
    );
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> requestBody,
  ) async {
    if (apiKey.trim().isEmpty) {
      throw const DeepSeekWebException(
        '服务端未配置 DEEPSEEK_API_KEY，无法使用 DeepSeek 联网能力。',
      );
    }
    final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final endpoint = Uri.parse(normalizedBaseUrl).resolve(path);
    final http.Response response;
    try {
      response = await _client
          .post(
            endpoint,
            headers: {
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(requestBody),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const DeepSeekWebException('DeepSeek 联网请求超时，请稍后重试。');
    } on http.ClientException {
      throw const DeepSeekWebException('无法连接 DeepSeek 联网服务，请稍后重试。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DeepSeekWebException(
        'DeepSeek 联网请求返回 HTTP ${response.statusCode}。',
        statusCode: response.statusCode,
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) throw const FormatException();
      return Map<String, dynamic>.from(decoded);
    } on DeepSeekWebException {
      rethrow;
    } on Object {
      throw const DeepSeekWebException('DeepSeek 联网服务返回格式异常。');
    }
  }

  static String _bounded(Object? value, int maxLength) {
    final text = value?.toString().trim() ?? '';
    if (text.runes.length <= maxLength) return text;
    return '${String.fromCharCodes(text.runes.take(maxLength))}…';
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

class DeepSeekWebFetchService {
  DeepSeekWebFetchService({
    required this.apiKey,
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.timeout = const Duration(seconds: 30),
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  Future<DeepSeekWebFetchResult> fetch(String rawUrl) async {
    final url = _validateUrl(rawUrl);
    if (apiKey.trim().isEmpty) {
      throw const DeepSeekWebException(
        '服务端未配置 DEEPSEEK_API_KEY，无法使用 DeepSeek 网页抓取。',
      );
    }
    final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final endpoint = Uri.parse(normalizedBaseUrl).resolve('tools/fetch');
    final http.Response response;
    try {
      response = await _client
          .post(
            endpoint,
            headers: {
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'url': url.toString()}),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const DeepSeekWebException('DeepSeek 网页抓取超时，请稍后重试。');
    } on http.ClientException {
      throw const DeepSeekWebException('无法连接 DeepSeek 网页抓取服务，请稍后重试。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DeepSeekWebException(
        'DeepSeek 网页抓取返回 HTTP ${response.statusCode}。',
        statusCode: response.statusCode,
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) throw const FormatException();
      final content = decoded['content']?.toString().trim() ?? '';
      if (content.isEmpty) {
        throw const DeepSeekWebException('DeepSeek 没有返回可读的网页正文。');
      }
      return DeepSeekWebFetchResult(
        title: decoded['title']?.toString().trim() ?? '',
        content: content,
      );
    } on DeepSeekWebException {
      rethrow;
    } on Object {
      throw const DeepSeekWebException('DeepSeek 网页抓取返回格式异常。');
    }
  }

  Uri _validateUrl(String rawUrl) {
    final text = rawUrl.trim();
    final uri = Uri.tryParse(text);
    if (text.length > 8192 ||
        uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('请输入公开的 HTTP 或 HTTPS 网页地址');
    }
    return uri;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
