import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genkit/experimental.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_openai/genkit_openai.dart';

import 'image_service.dart';
import 'code_execution_service.dart';
import 'store.dart';

abstract interface class XiaoqiAgentRuntime {
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String text) onDelta,
    required CancellationToken cancellation,
  });
}

/// Keeps Genkit's experimental Agent API behind one small server-side boundary.
class GenkitXiaoqiAgentRuntime implements XiaoqiAgentRuntime {
  GenkitXiaoqiAgentRuntime(
    this.store,
    this.images, {
    DockerCodeExecutionService? codeExecutor,
  }) : codeExecutor = codeExecutor ?? DockerCodeExecutionService(store);

  final CloudStore store;
  final ImageService images;
  final DockerCodeExecutionService codeExecutor;

  @override
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String text) onDelta,
    required CancellationToken cancellation,
  }) async {
    final requestedModel = request['model_id']?.toString().trim() ?? '';
    final defaultModel =
        Platform.environment['XIAOQI_DEFAULT_TEXT_MODEL']?.trim() ?? '';
    final selection = _modelSelection(
      requestedModel.isNotEmpty ? requestedModel : defaultModel,
    );
    final apiKey = Platform.environment[selection.keyName] ?? '';
    if (apiKey.isEmpty) throw StateError('服务器未配置 ${selection.keyName}');
    final ai = Genkit(
      promptDir: null,
      isDevEnv: false,
      plugins: [
        openAI(
          name: selection.namespace,
          apiKey: apiKey,
          baseUrl: selection.baseUrl,
          models: [CustomModelDefinition(name: selection.modelId)],
        ),
      ],
    );

    NetworkPermissionRequired? pendingPermission;
    ai.defineTool<Map<String, dynamic>, Map<String, dynamic>>(
      name: 'generate_image',
      description: '根据文字生成或编辑图片。只有用户明确要求图片时才调用。',
      fn: (input, context) async {
        final result = await images.generate(
          taskId: taskId,
          tenantId: tenantId,
          prompt: input['prompt']?.toString() ?? '',
          imageUrl: input['image_url']?.toString(),
          count: int.tryParse('${input['count'] ?? 1}') ?? 1,
          size: input['size']?.toString(),
        );
        return ToolResult.response(result);
      },
    );
    ai.defineTool<Map<String, dynamic>, String>(
      name: 'execute_python',
      description:
          '在服务器本机隔离的 Docker 沙箱执行 Python 代码。默认断网。'
          '只有确实需要联网时才在 domains 中列出精确域名，并用 purpose 说明用途；'
          '用户授权后任务会恢复。工作目录为 /home/user/workspace，'
          '资料位于 materials/，技能位于 skill/，文件产物写入 output/。',
      fn: (input, context) async {
        final permission = _networkPermission(
          tenantId,
          taskId,
          input['domains'],
          input['purpose']?.toString() ?? '',
        );
        if (permission != null) {
          pendingPermission = permission;
          return ToolResult.response(
            jsonEncode({
              'status': 'awaiting_network_permission',
              'domains': permission.domains,
              'purpose': permission.purpose,
            }),
          );
        }
        final skillFiles = request['capability'] is Map
            ? _loadSkillFiles(tenantId, request['capability'])
            : <String, List<int>>{};
        return ToolResult.response(
          await codeExecutor.execute(
            tenantId: tenantId,
            taskId: taskId,
            code: input['code']?.toString() ?? '',
            language: 'python',
            authorizedDomains: _authorizedDomains(tenantId, taskId),
            materials: _materials(request['materials']),
            skillFiles: skillFiles,
            cancellation: cancellation,
          ),
        );
      },
    );
    ai.defineTool<Map<String, dynamic>, String>(
      name: 'execute_skill_script',
      description:
          '执行当前技能已同步版本中的脚本。只接受 scripts/ 下真实存在的 .py、.js、.mjs、.cjs、.ts 或 .mts 文件；'
          '每个任务仅允许执行一次。脚本只能访问本次任务资料和当前技能文件，默认断网。',
      fn: (input, context) async {
        final permission = _networkPermission(
          tenantId,
          taskId,
          input['domains'],
          input['purpose']?.toString() ?? '',
        );
        if (permission != null) {
          pendingPermission = permission;
          return ToolResult.response(
            jsonEncode({
              'status': 'awaiting_network_permission',
              'domains': permission.domains,
              'purpose': permission.purpose,
            }),
          );
        }
        final scriptPath = _safeSkillScriptPath(
          input['script_path']?.toString() ?? '',
          input['language']?.toString() ?? '',
        );
        final skillFiles = _loadSkillFiles(tenantId, request['capability']);
        final scriptBytes = skillFiles[scriptPath];
        if (scriptBytes == null) throw StateError('脚本不在当前技能版本中');
        final rawArguments = input['arguments'];
        if (rawArguments != null && rawArguments is! List)
          throw const FormatException('脚本参数必须是列表');
        final arguments = (rawArguments as List? ?? const []).map((value) {
          if (value is! String) throw const FormatException('脚本参数必须是文本');
          return value;
        }).toList();
        if (arguments.length > 32 ||
            arguments.fold<int>(
                  0,
                  (sum, value) => sum + utf8.encode(value).length,
                ) >
                8 * 1024) {
          throw const FormatException('脚本参数不能超过 32 项或 8 KB');
        }
        return ToolResult.response(
          await codeExecutor.execute(
            tenantId: tenantId,
            taskId: taskId,
            code: utf8.decode(scriptBytes),
            language: input['language']?.toString() ?? '',
            authorizedDomains: _authorizedDomains(tenantId, taskId),
            materials: _materials(request['materials']),
            skillFiles: skillFiles,
            cancellation: cancellation,
            scriptPath: scriptPath,
            arguments: arguments,
          ),
        );
      },
    );

    final messages = request['messages'];
    if (messages is! List) throw const FormatException('messages 必须是列表');
    final conversation = messages
        .whereType<Map>()
        .map((message) {
          final role = message['role'] == 'assistant' ? '助手' : '用户';
          return '$role：${_textContent(message['content'])}';
        })
        .where((line) => line.trim().isNotEmpty)
        .join('\n\n');
    if (conversation.isEmpty) throw const FormatException('对话内容为空');

    final skill = _loadSkill(tenantId, request['capability']);
    final materialText = _materialsText(request['materials']);
    final system = StringBuffer(
      '你是小七的 AI 助手。请使用中文回答，遵循用户的最新要求。'
      '不要声称执行了没有执行的操作。',
    );
    if (skill.isNotEmpty) system.write('\n\n当前技能指令：\n$skill');
    if (materialText.isNotEmpty) system.write('\n\n用户提供的资料：\n$materialText');

    final agent = ai.defineAgent(
      name: 'xiaoqi_assistant',
      model: openAI.model(selection.modelId, namespace: selection.namespace),
      system: system.toString(),
      maxTurns: 8,
      toolNames: const [
        'generate_image',
        'execute_python',
        'execute_skill_script',
      ],
      store: InMemorySessionStore(),
    );
    final chat = agent.chat();
    final turn = chat.sendStream(text: conversation, cancel: cancellation);
    final output = StringBuffer();
    await for (final chunk in turn.stream) {
      cancellation.throwIfCancelled();
      final delta = chunk.text;
      if (delta.isNotEmpty) {
        output.write(delta);
        onDelta(delta);
      }
    }
    final response = await turn.response;
    response.assertValid();
    if (pendingPermission != null) throw pendingPermission!;
    final answer = response.text.isNotEmpty ? response.text : output.toString();
    if (answer.isEmpty) throw StateError('模型没有返回文本');
    return answer;
  }

  String _loadSkill(String tenantId, Object? rawCapability) {
    if (rawCapability is! Map) return '';
    final id = rawCapability['id']?.toString() ?? '';
    final versionId = rawCapability['version_id']?.toString() ?? '';
    final saved = store.get('cap/$tenantId/$id');
    if (saved == null || saved.value['deleted_at'] != null) return '';
    final versions = saved.value['versions'];
    if (versions is! List) return '';
    final version = versions.whereType<Map>().firstWhere(
      (value) => value['id'] == versionId,
      orElse: () => const {},
    );
    final artifact = version['artifact_key']?.toString();
    if (artifact == null || artifact.isEmpty) return '';
    final files = store.getImmutable(artifact);
    final content = utf8.decode(files['SKILL.md'] ?? const []);
    final extras = files.keys.where((path) => path != 'SKILL.md').toList()
      ..sort();
    return extras.isEmpty ? content : '$content\n\n技能资源文件：${extras.join('、')}';
  }

  Map<String, List<int>> _loadSkillFiles(
    String tenantId,
    Object? rawCapability,
  ) {
    if (rawCapability is! Map) throw StateError('当前任务没有选择技能');
    final id = rawCapability['id']?.toString() ?? '';
    final versionId = rawCapability['version_id']?.toString() ?? '';
    if (!_safeId.hasMatch(id) || !_safeId.hasMatch(versionId)) {
      throw const FormatException('技能 ID 无效');
    }
    final saved = store.get('cap/$tenantId/$id');
    if (saved == null || saved.value['deleted_at'] != null) {
      throw StateError('技能不存在或已删除');
    }
    final versions = saved.value['versions'];
    if (versions is! List) throw StateError('技能版本不存在');
    final version = versions.whereType<Map>().firstWhere(
      (value) => value['id'] == versionId,
      orElse: () => const {},
    );
    final artifact = version['artifact_key']?.toString();
    if (artifact == null || artifact.isEmpty) throw StateError('技能文件不存在');
    return store.getImmutable(artifact);
  }

  NetworkPermissionRequired? _networkPermission(
    String tenantId,
    String taskId,
    Object? rawDomains,
    String purpose,
  ) {
    final requested = _normalizeDomains(rawDomains);
    if (requested.isEmpty) return null;
    final allowed = _authorizedDomains(tenantId, taskId).toSet();
    final missing = requested
        .where((domain) => !allowed.contains(domain))
        .toList();
    if (missing.isEmpty) return null;
    final normalizedPurpose = purpose.trim();
    return NetworkPermissionRequired(
      missing,
      normalizedPurpose.isEmpty
          ? '工具需要访问这些域名以完成任务'
          : normalizedPurpose.substring(
              0,
              normalizedPurpose.length > 300 ? 300 : normalizedPurpose.length,
            ),
    );
  }

  List<String> _authorizedDomains(String tenantId, String taskId) {
    final task = store.get('task/$tenantId/$taskId');
    return (task?.value['authorized_network_domains'] as List? ?? const [])
        .map((value) => value.toString())
        .toSet()
        .toList()
      ..sort();
  }

  static List<String> _normalizeDomains(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) throw const FormatException('联网域名必须是列表');
    if (raw.length > 10) throw const FormatException('一次最多申请 10 个联网域名');
    final domains =
        raw
            .map(
              (value) => value.toString().trim().toLowerCase().replaceFirst(
                RegExp(r'\.$'),
                '',
              ),
            )
            .toSet()
            .toList()
          ..sort();
    final pattern = RegExp(
      r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
    );
    if (domains.any((domain) => !pattern.hasMatch(domain)))
      throw const FormatException('联网域名格式无效');
    return domains;
  }

  static String _safeSkillScriptPath(String path, String language) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    if (parts.length < 2 ||
        parts.first != 'scripts' ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('技能脚本路径无效');
    }
    final extension = parts.last.split('.').last.toLowerCase();
    final allowed = switch (language) {
      'python' => const {'py'},
      'javascript' => const {'js', 'mjs', 'cjs'},
      'typescript' => const {'ts', 'mts'},
      _ => const <String>{},
    };
    if (!allowed.contains(extension))
      throw const FormatException('脚本扩展名与语言不匹配');
    return normalized;
  }

  static List<Map<String, dynamic>> _materials(Object? raw) => raw is List
      ? raw
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
      : const [];

  static String _materialsText(Object? raw) {
    if (raw is! List) return '';
    return raw
        .whereType<Map>()
        .map((item) {
          final name = item['name']?.toString() ?? '资料';
          final content =
              item['content']?.toString() ?? item['text']?.toString() ?? '';
          return content.isEmpty ? '' : '[$name]\n$content';
        })
        .where((value) => value.isNotEmpty)
        .join('\n\n');
  }

  static String _textContent(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content.map((part) {
        if (part is String) return part;
        if (part is Map) return part['text']?.toString() ?? '';
        return '';
      }).join();
    }
    if (content is Map) return content['text']?.toString() ?? '';
    return '';
  }

  static final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

  static _ModelSelection _modelSelection(String model) {
    if (model.startsWith('mimo')) {
      return _ModelSelection(
        namespace: 'mimo',
        keyName: 'MIMO_API_KEY',
        baseUrl:
            Platform.environment['MIMO_BASE_URL'] ??
            'https://api.xiaomimimo.com/v1',
        modelId: model.isEmpty ? 'mimo-v2.6-flash' : model,
      );
    }
    return _ModelSelection(
      namespace: 'deepseek',
      keyName: 'DEEPSEEK_API_KEY',
      baseUrl: 'https://api.deepseek.com/v1',
      modelId: model.isEmpty ? 'deepseek-flash' : model,
    );
  }
}

class _ModelSelection {
  const _ModelSelection({
    required this.namespace,
    required this.keyName,
    required this.baseUrl,
    required this.modelId,
  });
  final String namespace;
  final String keyName;
  final String baseUrl;
  final String modelId;
}
