import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'deepseek_web_service.dart';

/// Public, read-only web access. Provider selection is never a model decision.
class WebService {
  WebService({
    required this.tinyFishKey,
    required String deepSeekKey,
    String deepSeekBaseUrl = 'https://api.deepseek.com/v1',
    http.Client? client,
    this.checkCancelled,
    this.resolveHost = InternetAddress.lookup,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _search = DeepSeekWebSearchService(
         apiKey: deepSeekKey,
         baseUrl: deepSeekBaseUrl,
         client: client,
       ),
       _fetch = DeepSeekWebFetchService(
         apiKey: deepSeekKey,
         baseUrl: deepSeekBaseUrl,
         client: client,
       );

  final String tinyFishKey;
  final http.Client _client;
  final bool _ownsClient;
  final DeepSeekWebSearchService _search;
  final DeepSeekWebFetchService _fetch;
  final void Function()? checkCancelled;
  final Future<List<InternetAddress>> Function(String) resolveHost;

  static bool publicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (b.length == 4) {
      return !(b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          b[0] >= 224 ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && (b[1] == 168 || b[1] == 0)) ||
          (b[0] == 198 && (b[1] == 18 || b[1] == 19)));
    }
    // Only global unicast IPv6, excluding documentation and mapped addresses.
    return b.length == 16 &&
        (b[0] & 0xe0) == 0x20 &&
        !(b[0] == 0x20 && b[1] == 1 && b[2] == 0x0d && b[3] == 0xb8);
  }

  Future<Uri> validateUrl(String raw) async {
    final uri = Uri.tryParse(raw.trim());
    if (raw.length > 8192 ||
        uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 80 && uri.port != 443)) {
      throw const FormatException('请输入不含账号信息的公开 HTTP(S) 网页地址');
    }
    final host = uri.host.replaceAll('[', '').replaceAll(']', '').toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        !host.contains('.') && !host.contains(':')) {
      throw const FormatException('不能读取本机、内网或云元数据地址');
    }
    final literal = InternetAddress.tryParse(host);
    final addresses = literal == null
        ? await resolveHost(host).timeout(const Duration(seconds: 5))
        : [literal];
    if (addresses.isEmpty || addresses.any((a) => !publicAddress(a))) {
      throw const FormatException('不能读取本机、内网或云元数据地址');
    }
    return uri;
  }

  Future<Map<String, dynamic>> _tiny(
    String operation,
    Map<String, Object?> args,
  ) async {
    checkCancelled?.call();
    if (tinyFishKey.trim().isEmpty)
      throw const WebProviderException('not_configured');
    final request = http.Request(
      operation == 'search' ? 'GET' : 'POST',
      operation == 'search'
          ? Uri.https(
              'api.search.tinyfish.ai',
              '/',
              args.map((k, v) => MapEntry(k, v.toString())),
            )
          : Uri.https('api.fetch.tinyfish.ai', '/'),
    );
    request.headers.addAll({
      'X-API-Key': tinyFishKey.trim(),
      'Content-Type': 'application/json',
    });
    request.followRedirects = false;
    if (operation != 'search') request.body = jsonEncode(args);
    return (() async {
      final response = await _client.send(request);
      checkCancelled?.call();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw WebProviderException('http_${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        checkCancelled?.call();
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          throw const WebProviderException('response_too_large');
        }
        bytes.addAll(chunk);
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw const WebProviderException('invalid_response');
      }
      if (decoded is! Map) throw const WebProviderException('invalid_response');
      return Map<String, dynamic>.from(decoded);
    })().timeout(Duration(seconds: operation == 'search' ? 20 : 50));
  }

  Future<Map<String, dynamic>> search(
    String query, {
    String? purpose,
    int limit = 5,
  }) async {
    query = query.trim();
    if (query.isEmpty ||
        query.runes.length > 128 ||
        limit < 1 ||
        limit > 10 ||
        (purpose?.runes.length ?? 0) > 300) {
      throw const FormatException(
        'query 需为 1–128 字符，limit 为 1–10，purpose 最多 300 字符',
      );
    }
    String? fallback;
    List<Map<String, Object?>> sources;
    try {
      final body = await _tiny('search', {
        'query': query,
        if (purpose?.trim().isNotEmpty == true) 'purpose': purpose!.trim(),
      });
      if (body['results'] is! List)
        throw const WebProviderException('invalid_response');
      sources = [];
      for (final item in (body['results'] as List).take(50).whereType<Map>()) {
        final url = item['url']?.toString() ?? '';
        try {
          await validateUrl(url);
        } on FormatException {
          continue;
        }
        sources.add({
          'title': _bounded(item['title']?.toString() ?? url, 300),
          'url': url,
          'summary': _bounded(
            (item['snippet'] ?? item['description'] ?? '').toString(),
            1200,
          ),
        });
        if (sources.length == limit) break;
      }
    } on Object catch (error) {
      checkCancelled?.call();
      fallback = error is WebProviderException ? error.code : 'request_failed';
      final result = await _search.search(query, count: limit);
      sources = [];
      for (final source in result.sources) {
        try {
          await validateUrl(source.url);
          sources.add(source.toJson());
        } on FormatException {
          continue;
        }
      }
    }
    checkCancelled?.call();
    return {
      'status': 'ok',
      'provider': fallback == null ? 'tinyfish' : 'deepseek',
      if (fallback != null) 'fallback_reason': fallback,
      'evidence_type': 'search_snippet',
      'fetched_at': DateTime.now().toUtc().toIso8601String(),
      'sources': sources.map((s) => {...s, 'source_id': s['url']}).toList(),
    };
  }

  Future<Map<String, dynamic>> fetch(String rawUrl) async {
    checkCancelled?.call();
    final url = (await validateUrl(rawUrl)).toString();
    String? fallback;
    String title, content;
    try {
      final body = await _tiny('fetch', {
        'urls': [url],
        'format': 'markdown',
        'per_url_timeout_ms': 45000,
      });
      if (body['results'] is! List || (body['results'] as List).isEmpty) {
        final errors = body['errors'];
        final targetStatus =
            errors is List && errors.isNotEmpty && errors.first is Map
            ? (errors.first as Map)['status']
            : null;
        if (const {401, 403, 404, 410}.contains(targetStatus)) {
          throw const FormatException('目标网页不存在或需要访问权限，请提供公开且有效的链接');
        }
        final code = errors is List && errors.isNotEmpty && errors.first is Map
            ? (errors.first as Map)['error']?.toString()
            : 'invalid_response';
        if ({
          'login_required',
          'page_not_found',
          'invalid_url',
          'invalid_redirect_url',
        }.contains(code)) {
          throw FormatException('网页不可读取：$code；请提供公开且有效的链接');
        }
        throw WebProviderException(code ?? 'invalid_response');
      }
      final page = (body['results'] as List).first as Map;
      await validateUrl((page['url'] ?? url).toString());
      if (page['final_url'] != null)
        await validateUrl(page['final_url'].toString());
      title = page['title']?.toString() ?? '';
      content = page['text']?.toString() ?? '';
      if (content.trim().isEmpty)
        throw const WebProviderException('empty_content');
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      checkCancelled?.call();
      fallback = error is WebProviderException ? error.code : 'request_failed';
      final result = await _fetch.fetch(url);
      title = result.title;
      content = result.content;
    }
    checkCancelled?.call();
    final chars = content.runes.toList();
    const cap = 500000;
    return {
      'status': 'ok',
      'provider': fallback == null ? 'tinyfish' : 'deepseek',
      if (fallback != null) 'fallback_reason': fallback,
      'title': title,
      'url': url,
      'source_id': url,
      'evidence_type': 'page_content',
      'fetched_at': DateTime.now().toUtc().toIso8601String(),
      'content': String.fromCharCodes(chars.take(cap)),
      'content_incomplete': chars.length > cap,
    };
  }

  static Map<String, dynamic> page(
    Map<String, dynamic> document, {
    int start = 0,
    int maxChars = 12000,
  }) {
    if (start < 0 || maxChars < 1 || maxChars > 20000) {
      throw const FormatException('start_char 必须非负，max_chars 为 1–20000');
    }
    final chars = document['content'].toString().runes.toList();
    final end = (start + maxChars).clamp(0, chars.length);
    final more = end < chars.length;
    return {
      ...document,
      'content': String.fromCharCodes(chars.skip(start).take(maxChars)),
      'start_char': start,
      'total_chars': chars.length,
      'truncated': more || document['content_incomplete'] == true,
      if (more) 'next_start_char': end,
    };
  }

  static String _bounded(String text, int limit) =>
      String.fromCharCodes(text.runes.take(limit));

  void close() {
    if (_ownsClient) _client.close();
    _search.close();
    _fetch.close();
  }
}

class WebProviderException implements Exception {
  const WebProviderException(this.code);
  final String code;
  @override
  String toString() => '网页服务暂不可用：$code';
}
