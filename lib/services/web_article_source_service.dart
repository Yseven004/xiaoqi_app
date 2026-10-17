import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/api_config.dart';
import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/xiaoqi_document.dart';
import 'html_article_document_service.dart';

class WebArticleSourceService {
  const WebArticleSourceService({
    this.documentService = const HtmlArticleDocumentService(),
  });

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
    final uri = _validateUri(rawUrl);
    final client = http.Client();
    try {
      final response = await client
          .post(
            Uri.parse(ApiConfig.webFetchEndpoint),
            headers: await CapabilityCloudSync.instance.authenticatedHeaders(),
            body: jsonEncode({'url': uri.toString()}),
          )
          .timeout(const Duration(seconds: 35));
      final decoded = _decodeResponse(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw WebArticleSourceException(
          'fetch_error',
          _errorMessage(decoded, '网页抓取暂时不可用'),
        );
      }
      final title = decoded['title']?.toString().trim() ?? '';
      final markdown = decoded['content']?.toString().trim() ?? '';
      if (markdown.isEmpty) {
        throw const WebArticleSourceException('empty_content', '网页没有返回可读正文');
      }
      final html = _markdownSnapshot(
        title.isEmpty ? uri.host : title,
        markdown,
      );
      final hash = sha256.convert(utf8.encode(html)).toString();
      final document = documentService.parse(
        html,
        sourceUrl: uri.toString(),
        snapshotHash: hash,
      );
      return WebArticleSourceResult(
        inputUrl: rawUrl.trim(),
        finalUrl: uri.toString(),
        html: html,
        contentHash: hash,
        fetchedAt: DateTime.now().toUtc(),
        document: document,
      );
    } on WebArticleSourceException {
      rethrow;
    } on TimeoutException {
      throw const WebArticleSourceException('network_timeout', '网页抓取超时');
    } on StateError catch (error) {
      throw WebArticleSourceException(
        'auth_required',
        error.message.toString(),
      );
    } on Object {
      throw const WebArticleSourceException(
        'network_unavailable',
        '当前网络无法访问网页',
      );
    } finally {
      client.close();
    }
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) throw const FormatException();
      return Map<String, dynamic>.from(decoded);
    } on Object {
      throw const WebArticleSourceException('invalid_response', '网页抓取返回格式异常');
    }
  }

  String _errorMessage(Map<String, dynamic> body, String fallback) {
    final error = body['error'];
    return error is Map && error['message'] != null
        ? error['message'].toString()
        : fallback;
  }

  String _markdownSnapshot(String title, String markdown) {
    return '<!doctype html><html><head><meta charset="utf-8"><title>'
        '${_escapeHtml(title)}</title></head><body><article><h1>'
        '${_escapeHtml(title)}</h1><pre>${_escapeHtml(markdown)}</pre>'
        '</article></body></html>';
  }

  String _escapeHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  static bool looksLikeAccessChallenge(String source) {
    final text = html_parser.parse(source).body?.text ?? source;
    final normalized = text.replaceAll(RegExp(r'\s+'), '');
    final markers = ['环境异常', '完成验证后即可继续访问', '去验证'];
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
      throw const WebArticleSourceException(
        'invalid_url',
        '请输入公开的 HTTP 或 HTTPS 网页地址',
      );
    }
    return uri;
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
