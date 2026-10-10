import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:uuid/uuid.dart';

import 'image_service.dart';
import 'store.dart';

class XiaoqiMcpService {
  XiaoqiMcpService(this.store, this.images);

  final CloudStore store;
  final ImageService images;
  GenkitMcpServer? _server;
  StreamableHttpServerTransport? _transport;

  Future<void> start({int port = 8081}) async {
    final ai = Genkit(promptDir: null, isDevEnv: false);
    ai.definePrompt(
      name: 'xiaoqi-assistant-guidance',
      description: '小七助手的中文回复与工具使用约定。',
      prompt:
          '你是小七的 AI 助手。请优先使用中文回答，遵循用户最新要求；'
          '只有用户明确要求生成或编辑图片时才调用生图工具。'
          '调用工具后如实说明结果，不要声称完成未执行的操作。',
    );
    ai.defineResource(
      name: 'skills',
      uri: 'xiaoqi://skills',
      description: '当前账号已同步到云端的技能清单与版本。',
      fn: (_, _) async {
        final items = <Map<String, dynamic>>[];
        for (final (_, doc) in store.list('cap/personal/', limit: 200)) {
          if (doc.value['deleted_at'] != null) continue;
          final versions = (doc.value['versions'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          items.add({
            'id': doc.value['id'],
            'kind': doc.value['kind'],
            'name': doc.value['name'],
            'description': doc.value['description'],
            'current_version_id': doc.value['current_version_id'],
            'versions': versions
                .map(
                  (version) => {
                    'id': version['id'],
                    'number': version['number'],
                    'content_hash': version['content_hash'],
                  },
                )
                .toList(),
          });
        }
        return ResourceOutput(
          content: [
            TextPart(text: jsonEncode({'items': items})),
          ],
        );
      },
    );
    ai.defineTool<Map<String, dynamic>, Map<String, dynamic>>(
      name: 'list_skills',
      description: '列出云端已同步的技能及当前版本。',
      fn: (input, context) async {
        final items = <Map<String, dynamic>>[];
        for (final (_, doc) in store.list('cap/personal/', limit: 200)) {
          if (doc.value['deleted_at'] != null) continue;
          final versions = (doc.value['versions'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          items.add({
            'id': doc.value['id'],
            'kind': doc.value['kind'],
            'name': doc.value['name'],
            'description': doc.value['description'],
            'current_version_id': doc.value['current_version_id'],
            'versions': versions
                .map(
                  (version) => {
                    'id': version['id'],
                    'number': version['number'],
                    'content_hash': version['content_hash'],
                  },
                )
                .toList(),
          });
        }
        return ToolResult.response({'items': items});
      },
    );
    ai.defineTool<Map<String, dynamic>, String>(
      name: 'read_skill_resource',
      description:
          '读取某个已同步技能版本内的 SKILL.md 或 references/、assets/、scripts/ 文件，可按 offset 分段。',
      fn: (input, context) async => ToolResult.response(
        _readSkillResource(
          input['capability_id']?.toString() ?? '',
          input['version_id']?.toString() ?? '',
          input['path']?.toString() ?? 'SKILL.md',
          int.tryParse('${input['offset'] ?? 0}') ?? 0,
          int.tryParse('${input['limit'] ?? 20000}') ?? 20000,
        ),
      ),
    );
    ai.defineTool<Map<String, dynamic>, String>(
      name: 'read_task_material',
      description: '读取任务附带文字资料，可按字符 offset 分段。',
      fn: (input, context) async => ToolResult.response(
        _readMaterial(
          input['task_id']?.toString() ?? '',
          input['material_id']?.toString() ?? '',
          int.tryParse('${input['offset'] ?? 0}') ?? 0,
          int.tryParse('${input['limit'] ?? 20000}') ?? 20000,
        ),
      ),
    );
    ai.defineTool<Map<String, dynamic>, String>(
      name: 'draft_workspace',
      description:
          '列出、读取或写入一个任务的临时草稿文件。只允许 SKILL.md 与 references/、assets/、scripts/ 目录。',
      fn: (input, context) async => ToolResult.response(_draftWorkspace(input)),
    );
    ai.defineTool<Map<String, dynamic>, Map<String, dynamic>>(
      name: 'generate_image',
      description: '生成或编辑图片。只有用户明确提出图片生成或编辑要求时才调用。',
      fn: (input, context) async {
        final taskId = 'mcp-${const Uuid().v4().replaceAll('-', '')}';
        final taskKey = 'task/personal/$taskId';
        store.put(taskKey, {
          'task_id': taskId,
          'tenant_id': 'personal',
          'status': 'running',
          'events': <Map<String, dynamic>>[],
          'artifacts': <Map<String, dynamic>>[],
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        }, null);
        try {
          final result = await images.generate(
            taskId: taskId,
            prompt: input['prompt']?.toString() ?? '',
            imageUrl: input['image_url']?.toString(),
            count: int.tryParse('${input['count'] ?? 1}') ?? 1,
            size: input['size']?.toString(),
          );
          _finishImageTask(taskKey, result);
          return ToolResult.response({
            ...result,
            'task_id': taskId,
            'artifact_endpoint':
                '/v1/agent/tasks/$taskId/artifacts/{artifact_id}',
          });
        } on Object {
          _failImageTask(taskKey);
          rethrow;
        }
      },
    );

    final server = createMcpServer(
      ai,
      McpServerOptions(name: 'xiaoqi', version: '1.0.0'),
    );
    final transport = await StreamableHttpServerTransport.bind(
      address: InternetAddress.anyIPv4,
      port: port,
      endpointPath: '/mcp',
      enableJsonResponse: true,
      allowedHosts: [
        'app:$port',
        'localhost:$port',
        '127.0.0.1:$port',
        if ((Platform.environment['XIAOQI_PUBLIC_HOST'] ?? '').isNotEmpty)
          Platform.environment['XIAOQI_PUBLIC_HOST']!,
      ],
    );
    await server.start(transport);
    _server = server;
    _transport = transport;
  }

  void _finishImageTask(String key, Map<String, dynamic> result) {
    _updateImageTask(key, (task) {
      final events = (task['events'] as List? ?? const [])
          .whereType<Map>()
          .map((event) => Map<String, dynamic>.from(event))
          .toList();
      events.add({
        'seq': events.length,
        'type': 'completed',
        'text': '图片已生成',
        'draft': null,
        'files': {},
        'artifacts': result['artifacts'] ?? const [],
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
      return {
        ...task,
        'status': 'completed',
        'result': result,
        'events': events,
        'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
    });
  }

  void _failImageTask(String key) {
    _updateImageTask(key, (task) {
      final events = (task['events'] as List? ?? const [])
          .whereType<Map>()
          .map((event) => Map<String, dynamic>.from(event))
          .toList();
      events.add({
        'seq': events.length,
        'type': 'error',
        'message': '图片生成失败，请检查服务端配置或稍后重试',
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
      return {
        ...task,
        'status': 'failed',
        'error': '图片生成失败',
        'events': events,
        'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
    });
  }

  void _updateImageTask(
    String key,
    Map<String, dynamic> Function(Map<String, dynamic>) update,
  ) {
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = store.get(key);
      if (current == null) return;
      try {
        store.put(key, update(current.value), current.revision);
        return;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('图片任务更新冲突过多');
  }

  Future<void> close() async {
    await _server?.close();
    await _transport?.closeListener();
  }

  String _readSkillResource(
    String capabilityId,
    String versionId,
    String path,
    int offset,
    int limit,
  ) {
    final record = store.get('cap/personal/$capabilityId');
    if (record == null || record.value['deleted_at'] != null)
      throw StateError('技能不存在');
    final versions = (record.value['versions'] as List? ?? const [])
        .whereType<Map>();
    final version = versions
        .where((item) => item['id'] == versionId)
        .firstOrNull;
    if (version == null) throw StateError('技能版本不存在');
    final normalizedPath = path.replaceAll('\\', '/');
    final parts = normalizedPath.split('/');
    if (normalizedPath != 'SKILL.md' &&
        (parts.length < 2 ||
            !const {'scripts', 'references', 'assets'}.contains(parts.first)))
      throw const FormatException('资源路径无效');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..'))
      throw const FormatException('资源路径无效');
    final key = version['artifact_key']?.toString() ?? '';
    if (key.isEmpty) throw StateError('技能文件不存在');
    final data = store.getImmutable(key)[normalizedPath];
    if (data == null) throw StateError('技能文件不存在');
    return _slice(utf8.decode(data), offset, limit);
  }

  String _readMaterial(
    String taskId,
    String materialId,
    int offset,
    int limit,
  ) {
    final task = store.get('task/personal/$taskId');
    if (task == null) throw StateError('任务不存在');
    final inputKey = task.value['input_object_key']?.toString() ?? '';
    if (inputKey.isEmpty) throw StateError('任务资料不存在');
    final payload =
        jsonDecode(utf8.decode(store.getImmutable(inputKey)['input.json']!))
            as Map;
    final materials = payload['materials'];
    if (materials is! List) throw StateError('任务资料不存在');
    final material = materials
        .whereType<Map>()
        .where((item) => item['id']?.toString() == materialId)
        .firstOrNull;
    if (material == null) throw StateError('资料 ID 不存在');
    return _slice(material['text']?.toString() ?? '', offset, limit);
  }

  String _draftWorkspace(Map<String, dynamic> input) {
    final taskId = input['task_id']?.toString() ?? '';
    final path = input['path']?.toString() ?? 'SKILL.md';
    final action = input['action']?.toString() ?? 'list';
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    if (normalized != 'SKILL.md' &&
        (parts.length < 2 ||
            !const {'scripts', 'references', 'assets'}.contains(parts.first)))
      throw const FormatException('草稿路径无效');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..'))
      throw const FormatException('草稿路径无效');
    final key = 'task/personal/$taskId';
    final task = store.get(key);
    if (task == null) throw StateError('任务不存在');
    final files = Map<String, dynamic>.from(
      task.value['draft_files'] as Map? ?? const {},
    );
    if (action == 'list')
      return jsonEncode({'files': files.keys.toList()..sort()});
    if (action == 'read')
      return _slice(
        files[normalized]?.toString() ?? '',
        int.tryParse('${input['offset'] ?? 0}') ?? 0,
        int.tryParse('${input['limit'] ?? 20000}') ?? 20000,
      );
    if (action != 'write') throw const FormatException('草稿操作无效');
    final content = input['content']?.toString() ?? '';
    if (utf8.encode(content).length > 2 * 1024 * 1024)
      throw const FormatException('草稿文件超过 2 MB');
    files[normalized] = content;
    store.put(key, {
      ...task.value,
      'draft_files': files,
      'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    }, task.revision);
    return jsonEncode({
      'ok': true,
      'path': normalized,
      'size': utf8.encode(content).length,
    });
  }

  static String _slice(String value, int offset, int limit) {
    if (offset < 0) throw const FormatException('offset 不能小于 0');
    final start = offset.clamp(0, value.length);
    final end = (start + limit.clamp(1, 20000)).clamp(start, value.length);
    return jsonEncode({
      'text': value.substring(start, end),
      'offset': start,
      'next_offset': end < value.length ? end : null,
      'total_chars': value.length,
    });
  }
}
