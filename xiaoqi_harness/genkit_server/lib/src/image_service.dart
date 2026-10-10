import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'store.dart';

typedef ArtifactRecorder = Future<void> Function(Map<String, dynamic> artifact);

/// Calls Ark once per image request and stores returned bytes in the protected
/// task object store. Timeouts are deliberately not retried because billing may
/// have succeeded even when the response was lost.
class ImageService {
  ImageService(
    this.store, {
    http.Client? client,
    String? apiKey,
    String? apiUrl,
    String? model,
    Duration apiTimeout = const Duration(minutes: 3),
  }) : _client = client ?? http.Client(),
       _apiKey = apiKey,
       _apiUrl = apiUrl,
       _model = model,
       _apiTimeout = apiTimeout;

  final CloudStore store;
  final http.Client _client;
  final String? _apiKey;
  final String? _apiUrl;
  final String? _model;
  final Duration _apiTimeout;

  Future<Map<String, dynamic>> generate({
    required String taskId,
    required String prompt,
    String? imageUrl,
    int count = 1,
    String? size,
    String? tenantId,
    ArtifactRecorder? recordArtifact,
  }) async {
    final apiKey = _apiKey ?? Platform.environment['ARK_API_KEY'] ?? '';
    if (apiKey.isEmpty) throw StateError('服务器未配置 ARK_API_KEY');
    if (prompt.trim().isEmpty || prompt.length > 12000) {
      throw const FormatException('图片提示词不能为空且不能超过 12000 个字符');
    }
    final imageCount = count.clamp(1, 4);
    final model =
        _model ??
        Platform.environment['ARK_IMAGE_MODEL'] ??
        'doubao-seedream-5-0-260128';
    final body = <String, dynamic>{
      'model': model,
      'prompt': prompt,
      'size': _normalizeSize(size),
      'response_format': 'url',
      'watermark': false,
      if (imageCount > 1) 'sequential_image_generation': 'auto',
      if (imageCount > 1)
        'sequential_image_generation_options': {'max_images': imageCount},
      if (imageUrl != null && imageUrl.isNotEmpty) 'image': imageUrl,
    };
    late final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(
              _apiUrl ??
                  Platform.environment['ARK_IMAGE_API_URL'] ??
                  'https://ark.cn-beijing.volces.com/api/v3/images/generations',
            ),
            headers: {
              HttpHeaders.authorizationHeader: 'Bearer $apiKey',
              HttpHeaders.contentTypeHeader: 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_apiTimeout);
    } on TimeoutException {
      throw TimeoutException('Seedream 图片生成请求超时');
    } on SocketException catch (error) {
      throw HttpException('Seedream 图片生成网络连接失败：${error.message}');
    } on http.ClientException catch (error) {
      throw HttpException('Seedream 图片生成请求失败：${error.message}');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = _providerErrorMessage(response.body);
      throw HttpException(
        '生图服务返回错误 (${response.statusCode})'
        '${detail == null ? '' : ': $detail'}',
      );
    }
    final payload = jsonDecode(response.body);
    final entries = payload is Map && payload['data'] is List
        ? (payload['data'] as List).whereType<Map>().toList()
        : const <Map>[];
    if (entries.isEmpty) throw const FormatException('生图服务没有返回图片');
    final artifacts = <Map<String, dynamic>>[];
    for (final entry in entries.take(imageCount)) {
      final imageBytes = await _imageBytes(entry);
      final id =
          'img-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
      final key =
          'tenants/${tenantId ?? 'personal'}/tasks/$taskId/artifacts/$id';
      store.putTaskBlob(key, imageBytes.bytes);
      final artifact = <String, dynamic>{
        'id': id,
        'name': 'xiaoqi-image-$id.${imageBytes.extension}',
        'media_type': imageBytes.mediaType,
        'size': imageBytes.bytes.length,
        'sha256': sha256.convert(imageBytes.bytes).toString(),
        'object_key': key,
      };
      if (recordArtifact != null) {
        await recordArtifact(artifact);
      } else {
        _recordOnTask(tenantId ?? 'personal', taskId, artifact);
      }
      artifacts.add(artifact);
    }
    return {
      'ok': true,
      'count': artifacts.length,
      'artifacts': [for (final item in artifacts) _publicArtifact(item)],
    };
  }

  Future<_ImageData> _imageBytes(Map entry) async {
    final base64Data = entry['b64_json'];
    if (base64Data is String && base64Data.isNotEmpty) {
      return _ImageData(base64Decode(base64Data), 'image/png', 'png');
    }
    final url = entry['url']?.toString();
    if (url == null || url.isEmpty) throw const FormatException('生图结果地址缺失');
    final parsed = Uri.parse(url);
    if (parsed.scheme != 'https') throw const FormatException('生图结果必须使用 HTTPS');
    late final http.Response response;
    try {
      response = await _client.get(parsed).timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw TimeoutException('Seedream 生图结果下载超时');
    } on SocketException catch (error) {
      throw HttpException('Seedream 生图结果下载网络失败：${error.message}');
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        response.bodyBytes.isEmpty) {
      throw HttpException('无法下载生图结果 (${response.statusCode})');
    }
    final type =
        response.headers['content-type']?.split(';').first.toLowerCase() ?? '';
    final mediaType =
        const {'image/png', 'image/jpeg', 'image/webp'}.contains(type)
        ? type
        : 'image/png';
    final extension = switch (mediaType) {
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => 'png',
    };
    return _ImageData(response.bodyBytes, mediaType, extension);
  }

  static String _normalizeSize(String? requested) {
    const allowed = {'2k', '3k', '4k'};
    final normalized = requested?.trim().toLowerCase();
    return allowed.contains(normalized) ? normalized! : '2k';
  }

  static String? _providerErrorMessage(String body) {
    try {
      final payload = jsonDecode(body);
      if (payload is! Map) return null;
      final error = payload['error'];
      final message = error is Map
          ? error['message'] ?? error['detail']
          : error ?? payload['message'];
      final normalized = message?.toString().trim();
      if (normalized == null || normalized.isEmpty) return null;
      return normalized.length <= 240
          ? normalized
          : '${normalized.substring(0, 240)}…';
    } on FormatException {
      return null;
    }
  }

  static Map<String, dynamic> _publicArtifact(Map<String, dynamic> item) => {
    for (final key in const ['id', 'name', 'media_type', 'size', 'sha256'])
      key: item[key],
  };

  void _recordOnTask(
    String tenantId,
    String taskId,
    Map<String, dynamic> artifact,
  ) {
    final key = 'task/$tenantId/$taskId';
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = store.get(key);
      if (current == null) return;
      final value = current.value;
      final artifacts = (value['artifacts'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (!artifacts.any((item) => item['id'] == artifact['id'])) {
        artifacts.add(artifact);
      }
      final events = (value['events'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      events.add({
        'seq': events.length,
        'type': 'artifacts_ready',
        'artifacts': [_publicArtifact(artifact)],
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
      try {
        store.put(key, {
          ...value,
          'artifacts': artifacts,
          'events': events,
        }, current.revision);
        return;
      } on RevisionConflict {
        continue;
      }
    }
  }
}

class _ImageData {
  const _ImageData(this.bytes, this.mediaType, this.extension);
  final List<int> bytes;
  final String mediaType;
  final String extension;
}
