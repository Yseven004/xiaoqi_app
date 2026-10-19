import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'store.dart';

/// Stores complete data separately from the bounded text sent to the model.
class McpToolResultAdapter {
  McpToolResultAdapter(this.store, this.tenant, this.task);
  final CloudStore store;
  final String tenant;
  final String task;

  Map<String, dynamic> normalize(Map<String, dynamic> result) {
    if (result['isError'] == true) {
      return {
        'status': 'failed',
        'isError': true,
        'error': 'MCP 工具返回执行错误',
        'content': _text(result['content']),
      };
    }
    final content = <Map<String, dynamic>>[];
    final artifacts = <Map<String, dynamic>>[];
    var totalBytes = 0;
    void save(List<int> bytes, String mime, String name) {
      totalBytes += bytes.length;
      if (bytes.isEmpty || totalBytes > 32 * 1024 * 1024) {
        throw const FormatException('MCP 产物为空或超过本轮 32 MB 限制');
      }
      final hash = sha256.convert(bytes).toString();
      final id =
          'mcp-${sha256.convert(utf8.encode('$mime:$hash')).toString().substring(0, 28)}';
      final key = 'tenants/$tenant/tasks/$task/artifacts/$id';
      store.putTaskBlob(key, bytes);
      final artifact = <String, dynamic>{
        'id': id,
        'name': name,
        'media_type': mime,
        'size': bytes.length,
        'sha256': hash,
        'object_key': key,
      };
      _record(artifact);
      artifacts.add({
        for (final field in ['id', 'name', 'media_type', 'size', 'sha256'])
          field: artifact[field],
      });
    }

    final blocks = result['content'] ?? result['contents'] ?? const [];
    if (blocks is! List || blocks.length > 256)
      throw const FormatException('MCP 结果结构或内容数量无效');
    for (final block in blocks.whereType<Map>()) {
      final resource = block['resource'] is Map
          ? block['resource'] as Map
          : block;
      final encoded = block['data'] ?? resource['blob'];
      final mime =
          (block['mimeType'] ?? resource['mimeType'])?.toString() ??
          (resource['text'] != null
              ? 'text/plain'
              : 'application/octet-stream');
      if (encoded is String) {
        if (encoded.length > 45 * 1024 * 1024)
          throw const FormatException('MCP 文件超过限制');
        final extension = switch (mime) {
          'image/png' => 'png',
          'image/jpeg' => 'jpg',
          'image/webp' => 'webp',
          'audio/wav' => 'wav',
          'audio/mpeg' => 'mp3',
          'application/pdf' => 'pdf',
          _ => 'bin',
        };
        save(
          base64Decode(encoded),
          mime,
          'MCP-${artifacts.length + 1}.$extension',
        );
      } else if (resource['text'] is String) {
        final text = resource['text'] as String;
        if (block['type'] == 'resource' ||
            block['uri'] != null ||
            text.length > 16000) {
          save(utf8.encode(text), mime, 'MCP-${artifacts.length + 1}.txt');
        }
        content.add({
          'type': 'text',
          'text': text.length <= 16000
              ? text
              : '${text.substring(0, 16000)}\n[完整内容已保存为文件]',
        });
      } else if (block['type'] == 'resource_link') {
        content.add(Map<String, dynamic>.from(block));
      } else {
        throw const FormatException('MCP 返回了尚未支持的内容类型');
      }
    }
    Object? structured = result['structuredContent'];
    if (structured != null && jsonEncode(structured).length > 16000) {
      save(
        utf8.encode(jsonEncode(structured)),
        'application/json',
        'MCP-structured.json',
      );
      structured = {'message': '完整结构化结果已保存为文件'};
    }
    return {
      'status': 'completed',
      'content': content,
      if (structured != null) 'structuredContent': structured,
      'artifacts': artifacts,
    };
  }

  static String _text(Object? raw) {
    final text =
        (raw is List
            ? raw.whereType<Map>().map((part) => part['text'] ?? '').join('\n')
            : raw?.toString()) ??
        '';
    return text.length <= 16000 ? text : text.substring(0, 16000);
  }

  void _record(Map<String, dynamic> artifact) {
    final key = 'task/$tenant/$task';
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = store.get(key);
      if (current == null) throw StateError('产物所属任务不存在');
      final artifacts = (current.value['artifacts'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      if (artifacts.any((item) => item['id'] == artifact['id'])) return;
      try {
        store.put(key, {
          ...current.value,
          'artifacts': [...artifacts, artifact],
        }, current.revision);
        return;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('MCP 产物记录写入冲突，请检查任务结果');
  }
}
