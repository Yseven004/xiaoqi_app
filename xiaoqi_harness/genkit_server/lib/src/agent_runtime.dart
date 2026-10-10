import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genkit/experimental.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:schemantic/schemantic.dart';

import 'image_service.dart';
import 'code_execution_service.dart';
import 'store.dart';

const _maxAgentImageBytes = 5 * 1024 * 1024;

void _logAgentRuntime(
  String event,
  String taskId,
  Map<String, Object?> details,
) {
  try {
    stderr.writeln(
      jsonEncode({
        'component': 'genkit_agent',
        'event': event,
        'task_id': taskId,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        ...details,
      }),
    );
  } on Object {
    // Logging must not change the task result.
  }
}

List<Message> agentMessagesFromRequest(Object? rawMessages) {
  if (rawMessages is! List || rawMessages.isEmpty || rawMessages.length > 64) {
    throw const FormatException('messages 必须包含 1 到 64 条消息');
  }
  final output = <Message>[];
  var totalImageBytes = 0;
  for (final rawMessage in rawMessages) {
    if (rawMessage is! Map) throw const FormatException('消息格式无效');
    final role = switch (rawMessage['role']?.toString()) {
      'system' => Role.system,
      'user' => Role.user,
      'assistant' => Role.model,
      _ => throw const FormatException('消息角色无效'),
    };
    final content = rawMessage['content'];
    final parts = <Part>[];
    if (content is String) {
      if (content.isNotEmpty) parts.add(TextPart(text: content));
    } else if (content is List) {
      for (final rawPart in content) {
        if (rawPart is! Map) throw const FormatException('消息内容无效');
        if (rawPart['type'] == 'text') {
          final text = rawPart['text']?.toString() ?? '';
          if (text.isNotEmpty) parts.add(TextPart(text: text));
        } else if (rawPart['type'] == 'image_url') {
          final image = rawPart['image_url'];
          final url = image is Map ? image['url']?.toString() ?? '' : '';
          final comma = url.indexOf(',');
          if (!url.startsWith('data:') || comma < 0) {
            throw const FormatException('只支持 PNG、JPEG、WEBP 或 GIF 图片');
          }
          final header = url.substring(5, comma);
          if (!header.endsWith(';base64')) {
            throw const FormatException('只支持 PNG、JPEG、WEBP 或 GIF 图片');
          }
          final contentType = header
              .substring(0, header.length - 7)
              .toLowerCase();
          if (!const {
            'image/png',
            'image/jpeg',
            'image/webp',
            'image/gif',
          }.contains(contentType)) {
            throw const FormatException('只支持 PNG、JPEG、WEBP 或 GIF 图片');
          }
          final encoded = url.substring(comma + 1);
          final maxEncodedLength =
              ((_maxAgentImageBytes - totalImageBytes + 2) ~/ 3) * 4;
          if (encoded.isEmpty || encoded.length > maxEncodedLength) {
            throw const FormatException('图片总大小不能超过 5 MB');
          }
          late final List<int> bytes;
          try {
            bytes = base64.decode(encoded);
          } on FormatException {
            throw const FormatException('图片数据格式无效');
          }
          totalImageBytes += bytes.length;
          if (totalImageBytes > _maxAgentImageBytes) {
            throw const FormatException('图片总大小不能超过 5 MB');
          }
          parts.add(
            MediaPart(
              media: Media(contentType: contentType, url: url),
            ),
          );
        } else {
          throw const FormatException('暂不支持这种消息内容类型');
        }
      }
    } else {
      throw const FormatException('消息内容无效');
    }
    if (parts.isNotEmpty) output.add(Message(role: role, content: parts));
  }
  if (output.isEmpty) throw const FormatException('对话内容为空');
  if (output.last.role != Role.user) {
    throw const FormatException('最后一条消息必须来自用户');
  }
  return output;
}

SchemanticType<Map<String, dynamic>> _objectToolSchema(
  Map<String, Object?> properties, {
  required List<String> required,
}) => SchemanticType.from<Map<String, dynamic>>(
  jsonSchema: {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  },
  parse: (json) => Map<String, dynamic>.from(json as Map),
);

final _generateImageSchema = _objectToolSchema(
  const {
    'prompt': {'type': 'string', 'minLength': 1, 'maxLength': 4000},
    'image_url': {'type': 'string'},
    'count': {'type': 'integer', 'minimum': 1, 'maximum': 4},
    'size': {'type': 'string'},
  },
  required: const ['prompt'],
);

final _executePythonSchema = _objectToolSchema(
  const {
    'code': {'type': 'string', 'minLength': 1, 'maxLength': 65536},
    'domains': {
      'type': 'array',
      'items': {'type': 'string'},
      'maxItems': 10,
    },
    'purpose': {'type': 'string', 'maxLength': 300},
  },
  required: const ['code'],
);

final _executeSkillScriptSchema = _objectToolSchema(
  const {
    'script_path': {'type': 'string', 'minLength': 1},
    'language': {
      'type': 'string',
      'enum': ['python', 'javascript', 'typescript'],
    },
    'arguments': {
      'type': 'array',
      'items': {'type': 'string'},
      'maxItems': 32,
    },
    'domains': {
      'type': 'array',
      'items': {'type': 'string'},
      'maxItems': 10,
    },
    'purpose': {'type': 'string', 'maxLength': 300},
  },
  required: const ['script_path', 'language'],
);

List<String> agentToolNamesForRequest({
  required String latestUserText,
  bool capabilitySelected = false,
  bool skillHasScripts = false,
}) {
  final text = latestUserText.toLowerCase();
  final isInquiry = RegExp(
    r'(怎么|如何|能否|能不能|是否|什么意思|是什么|原理|特点|区别|有什么用|吗[?？]?$)',
  ).hasMatch(text);
  final wantsImage =
      !isInquiry &&
      RegExp(
        r'(生成|画|绘制|创作|制作).{0,8}(一张|一个|个|幅|图片|图像|插画|海报|头像|壁纸|照片|图)|'
        r'(编辑|修改|修复|修图|改图).{0,8}(图片|图像|照片|插画|海报|头像|壁纸|图)|'
        r'\b(generate|create|draw|edit|retouch)\b.{0,20}\b(image|picture|photo|illustration)\b',
      ).hasMatch(text);
  final wantsCode =
      capabilitySelected ||
      RegExp(
        r'(运行|执行).{0,12}(代码|脚本|python|javascript|typescript|sql)|'
        r'(代码|脚本|python|javascript|typescript|sql).{0,8}(运行|执行)|'
        r'(处理|转换|统计|批量).{0,8}(文件|附件|数据)|'
        r'(文件|附件|数据).{0,8}(处理|转换|统计|批量)|'
        r'(保存|导出|生成|写入).{0,8}(文件|csv|xlsx)',
      ).hasMatch(text);
  return [
    if (wantsImage) 'generate_image',
    if (wantsCode) 'execute_python',
    if (capabilitySelected && skillHasScripts) 'execute_skill_script',
  ];
}

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
    _logAgentRuntime('model_selected', taskId, {
      'provider': selection.namespace,
      'model_id': selection.modelId,
    });
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
      inputSchema: _generateImageSchema,
      fn: (input, context) async {
        _logAgentRuntime('tool_called', taskId, {
          'tool_name': 'generate_image',
          'input_fields': input.keys.toList()..sort(),
          'prompt_characters': input['prompt']?.toString().length ?? 0,
          'has_source_image': input['image_url'] != null,
        });
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
          '在服务器隔离的 Docker 沙箱执行 Python 代码。仅用于用户明确要求执行代码、'
          '处理文件或对资料做程序化操作时。默认断网。'
          '只有确实需要联网时才在 domains 中列出精确域名，并用 purpose 说明用途；'
          '用户授权后任务会恢复。工作目录为 /workspace，'
          '资料位于 materials/，技能位于 skill/，文件产物写入 output/。',
      inputSchema: _executePythonSchema,
      fn: (input, context) async {
        _logAgentRuntime('tool_called', taskId, {
          'tool_name': 'execute_python',
          'input_fields': input.keys.toList()..sort(),
          'code_bytes': utf8.encode(input['code']?.toString() ?? '').length,
          'domain_count': (input['domains'] as List? ?? const []).length,
        });
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
      inputSchema: _executeSkillScriptSchema,
      fn: (input, context) async {
        _logAgentRuntime('tool_called', taskId, {
          'tool_name': 'execute_skill_script',
          'input_fields': input.keys.toList()..sort(),
          'language': input['language'],
          'argument_count': (input['arguments'] as List? ?? const []).length,
          'domain_count': (input['domains'] as List? ?? const []).length,
        });
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

    final messages = agentMessagesFromRequest(request['messages']);
    _logAgentRuntime('messages_prepared', taskId, {
      'message_count': messages.length,
      'image_count': messages
          .expand((message) => message.content)
          .where((part) => part.isMedia)
          .length,
    });
    final latestUserText = _textContent(
      (request['messages'] as List).whereType<Map>().lastWhere(
        (message) => message['role'] == 'user',
        orElse: () => const {},
      )['content'],
    ).toLowerCase();
    final selectedCapability = request['capability'] is Map;
    final skillFiles = selectedCapability
        ? _loadSkillFiles(tenantId, request['capability'])
        : const <String, List<int>>{};
    final hasSkillScripts = skillFiles.keys.any(
      (path) => path.replaceAll('\\', '/').startsWith('scripts/'),
    );
    final toolNames = agentToolNamesForRequest(
      latestUserText: latestUserText,
      capabilitySelected: selectedCapability,
      skillHasScripts: hasSkillScripts,
    );

    final skill = _loadSkill(tenantId, request['capability']);
    final materialText = _materialsText(request['materials']);
    final system = StringBuffer(
      '你是小七的 AI 助手。请使用中文回答，遵循用户的最新要求。'
      '普通问候、问答、解释和写作直接回答，不要调用技能、代码或文件工具。'
      '只有用户明确要求相应操作，并且对应工具已提供时才调用工具。'
      '不要声称执行了没有执行的操作。',
    );
    if (skill.isNotEmpty) system.write('\n\n当前技能指令：\n$skill');
    if (materialText.isNotEmpty) system.write('\n\n用户提供的资料：\n$materialText');

    final agent = ai.defineAgent(
      name: 'xiaoqi_assistant',
      model: openAI.model(selection.modelId, namespace: selection.namespace),
      system: system.toString(),
      maxTurns: 8,
      toolNames: toolNames,
    );
    final priorMessages = messages.take(messages.length - 1).toList();
    final chat = agent.chat(state: SessionState(messages: priorMessages));
    final turn = chat.sendStream(message: messages.last, cancel: cancellation);
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
