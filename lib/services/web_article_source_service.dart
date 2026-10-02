import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/xiaoqi_document.dart';
import 'html_article_document_service.dart';

class WebArticleSourceService {
  const WebArticleSourceService({
    this.documentService = const HtmlArticleDocumentService(),
  });

  static const maxResponseBytes = 5 * 1024 * 1024;
  static const maxRedirects = 5;

  final HtmlArticleDocumentService documentService;

  Future<String> saveSnapshot(WebArticleSourceResult result) async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'web_article_sources'));
    await directory.create(recursive: true);
    final path = p.join(directory.path, '${result.contentHash}.html');
    final file = File(path);
    if (!await file.exists()) {
      await file.writeAsString(result.html, flush: true);
    }
    return path;
  }

  Future<WebArticleSourceResult> fetchAndParse(String rawUrl) async {
    var current = _validateUri(rawUrl);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 10)
      ..maxConnectionsPerHost = 2;
    try {
      for (var redirect = 0; redirect <= maxRedirects; redirect++) {
        await _assertPublicDestination(current);
        final request = await client.getUrl(current);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');
        request.headers.set(HttpHeaders.userAgentHeader, 'Xiaoqi/1.0 article-import');
        final response = await request.close();
        if (response.statusCode >= 300 && response.statusCode < 400) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || location.trim().isEmpty) {
            throw const WebArticleSourceException('redirect_blocked', '网页重定向缺少目标');
          }
          if (redirect == maxRedirects) {
            throw const WebArticleSourceException('redirect_blocked', '网页重定向次数过多');
          }
          current = _validateUri(current.resolve(location));
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw WebArticleSourceException(
            'http_error',
            '网页返回状态码 ${response.statusCode}',
          );
        }
        final contentType = response.headers.contentType?.mimeType;
        if (contentType != null &&
            contentType != 'text/html' &&
            contentType != 'application/xhtml+xml') {
          throw WebArticleSourceException('unsupported_content_type', '网页类型为 $contentType');
        }
        final bytes = await _readLimited(response);
        final html = _decode(response, bytes);
        if (looksLikeAccessChallenge(html)) {
          throw const WebArticleSourceException(
            'access_challenge',
            '网页需要完成验证，暂时无法进行 AI 分析。请先在浏览器完成验证后重试。',
          );
        }
        final hash = sha256.convert(bytes).toString();
        final document = documentService.parse(
          html,
          sourceUrl: current.toString(),
          snapshotHash: hash,
        );
        return WebArticleSourceResult(
          inputUrl: rawUrl.trim(),
          finalUrl: current.toString(),
          html: html,
          contentHash: hash,
          fetchedAt: DateTime.now().toUtc(),
          document: document,
        );
      }
      throw const WebArticleSourceException('redirect_blocked', '网页重定向失败');
    } on WebArticleSourceException {
      rethrow;
    } on TimeoutException {
      throw const WebArticleSourceException('network_timeout', '网页获取超时');
    } on SocketException {
      throw const WebArticleSourceException('network_unavailable', '当前网络无法访问网页');
    } finally {
      client.close(force: true);
    }
  }

  static bool looksLikeAccessChallenge(String source) {
    final text = html_parser.parse(source).body?.text ?? source;
    final normalized = text.replaceAll(RegExp(r'\s+'), '');
    final markers = [
      '环境异常',
      '完成验证后即可继续访问',
      '去验证',
    ];
    var matches = 0;
    for (final marker in markers) {
      if (normalized.contains(marker)) matches++;
    }
    return matches >= 2;
  }

  Uri _validateUri(Object raw) {
    final uri = raw is Uri ? raw : Uri.tryParse(raw.toString().trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.port != 0 && uri.port != 80 && uri.port != 443)) {
      throw const WebArticleSourceException('invalid_url', '请输入公开的 HTTP 或 HTTPS 网页地址');
    }
    return uri;
  }

  Future<void> _assertPublicDestination(Uri uri) async {
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) {
      throw const WebArticleSourceException('blocked_destination', '为保护隐私，不能访问本机地址');
    }
    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty || addresses.any(_isBlockedAddress)) {
      throw const WebArticleSourceException('blocked_destination', '为保护隐私，不能访问内网地址');
    }
  }

  bool _isBlockedAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) return true;
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      final a = bytes[0];
      final b = bytes[1];
      return a == 10 ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 169 && b == 254);
    }
    if (bytes.length == 16) {
      final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
      final isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
      return isUniqueLocal || isLinkLocal;
    }
    return false;
  }

  Future<List<int>> _readLimited(
    HttpClientResponse response, {
    int maxBytes = maxResponseBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw const WebArticleSourceException('response_too_large', '网页内容超过 5 MB 限制');
      }
    }
    return builder.takeBytes();
  }

  String _decode(HttpClientResponse response, List<int> bytes) {
    final charset = response.headers.contentType?.parameters['charset'];
    if (charset?.toLowerCase() == 'iso-8859-1') return latin1.decode(bytes);
    return utf8.decode(bytes, allowMalformed: true);
  }
}

class WebArticleSourceResult {
  const WebArticleSourceResult({
    required this.inputUrl,
    required this.finalUrl,
    required this.html,
    required this.contentHash,
    required this.fetchedAt,
    required this.document,
    this.visualHtml = '',
    this.missingResourceCount = 0,
  });

  final String inputUrl;
  final String finalUrl;
  final String html;
  final String contentHash;
  final DateTime fetchedAt;
  final XiaoqiDocument document;
  final String visualHtml;
  final int missingResourceCount;
}

class WebArticleSourceException implements Exception {
  const WebArticleSourceException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}
