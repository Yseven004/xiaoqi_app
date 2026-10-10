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

final _generateImageSchema = _objectToolSchema(
  const {
    'prompt': {
      'type': 'string',
      'minLength': 1,
      'maxLength': 8000,
      'description': '图片主体、场景与视觉风格的简洁描述。',
    },
  },
  required: const ['prompt'],
);

bool _agentRequestsSupplementalImage(String normalized) => RegExp(
  r'(?:再|还|并|同时)?(?:加|附|配)(?:上)?(?:一张|张|一幅|幅)?(?:图片|图像|示意图|插画|配图|图)|'
  r'(?:再|还|并(?:且)?|同时|然后).{0,10}(?:生成|生图|画|绘制|创作|制作|做).{0,8}(?:一张|图片|图像|示意图|插画|图)|'
  r'(?:配图|附图|用图说明|用图片说明|图解|通过图片理解)|'
  r'(?:图片|图像|示意图).{0,12}(?:更直观|直观地理解|理解)',
).hasMatch(normalized);

bool agentImageRequestNeedsTextAnswer(String text) {
  final normalized = text.toLowerCase();
  return _agentRequestsSupplementalImage(normalized) &&
      RegExp(r'(解释|说明|介绍|讲清楚|理解|是什么|什么是|原理|为什么|如何|怎么)').hasMatch(normalized);
}

bool agentShouldGenerateImage(String text) {
  final normalized = text.toLowerCase();
  final requestMarkers = RegExp(r'(帮我|给我|替我|请直接|来一张|做一张|画一张)');
  final specifiesImage = RegExp(r'(一张|一幅|一个|一份|张|幅)').hasMatch(normalized);
  final asksCapabilityOnly = RegExp(
    r'^(?:请问)?(?:你)?(?:能否|能不能|可不可以|是否可以|可以|能|会不会).{0,12}'
    r'(?:生成|生图|绘制|画).{0,8}(?:图片|图像|插画|海报|头像|壁纸|照片|图)?[吗?？]*$',
  ).hasMatch(normalized);
  final asksWhether = RegExp(
    r'(能否|能不能|可不可以|是否|可以吗|会不会|吗[?？]?$)',
  ).hasMatch(normalized);
  final directAction = RegExp(
    r'^(?:(?:请|麻烦|我想|我要|直接)?(?:生成|生图|画|绘制|创作|制作|做|来)|'
    r'(?:帮我|给我|替我|请直接).{0,3}(?:生成|生图|画|绘制|创作|制作|做|来))',
  ).hasMatch(normalized);
  if (asksCapabilityOnly &&
      !requestMarkers.hasMatch(normalized) &&
      !specifiesImage) {
    return false;
  }

  final asksGeneralQuestion = RegExp(
    r'(怎么|如何|为什么|什么意思|是什么|什么是|原理|特点|区别|有什么用)',
  ).hasMatch(normalized);
  final asksSupplementalImage = _agentRequestsSupplementalImage(normalized);
  if (asksGeneralQuestion && !directAction && !asksSupplementalImage) {
    return false;
  }

  return RegExp(
        r'(生成|生图|画|绘制|创作|制作|做|来).{0,12}'
        r'(一张|一幅|一个|一份|张|幅|图片|图像|插画|海报|头像|壁纸|照片|示意图|图)|'
        r'(编辑|修改|修复|修图|改图).{0,8}(图片|图像|照片|插画|海报|头像|壁纸|图)|'
        r'\b(generate|create|draw|make|edit|retouch)\b.{0,20}'
        r'\b(image|picture|photo|illustration|diagram)\b',
      ).hasMatch(normalized) ||
      asksSupplementalImage ||
      (normalized.contains('生图') && (!asksWhether || directAction));
}

String agentImagePrompt(String request) {
  final prompt = request.trim();
  if (prompt.isEmpty) return prompt;
  final hasExplicitFrame = RegExp(
    r'(?:\d+\s*(?:[:：/×xX*]|乘)\s*\d+|正方形|方形|横版|横屏|竖版|竖屏|宽屏|'
    r'portrait|landscape|square|保持原图比例|保持原比例)',
    caseSensitive: false,
  ).hasMatch(prompt);
  const defaultFrame = '\n\n画面比例采用竖版 3:4（宽:高）。';
  if (hasExplicitFrame || prompt.length + defaultFrame.length > 12000) {
    return prompt;
  }
  return '$prompt$defaultFrame';
}

List<String> agentToolNamesForRequest({
  required String latestUserText,
  bool capabilitySelected = false,
  bool skillHasScripts = false,
  bool imageGenerationRequested = false,
}) {
  final text = latestUserText.toLowerCase();
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
    if (imageGenerationRequested) 'generate_image',
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
    void Function()? onImageGenerationStarted,
  });
}

abstract interface class XiaoqiStreamingAgentRuntime {
  Future<XiaoqiAgentTurnResult> runAgentTurn({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required List<Message> messages,
    List<ToolResponsePart>? respond,
    List<ToolRequestPart>? restart,
    required void Function(AgentStreamChunk chunk) onChunk,
    required void Function(Map<String, Object?> event) onProcessEvent,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
  });
}

class XiaoqiAgentTurnResult {
  const XiaoqiAgentTurnResult({
    required this.text,
    required this.messages,
    this.finishReason,
  });

  final String text;
  final List<Message> messages;
  final AgentFinishReason? finishReason;
}

/// Keeps Genkit's experimental Agent API behind one small server-side boundary.
class GenkitXiaoqiAgentRuntime
    implements XiaoqiAgentRuntime, XiaoqiStreamingAgentRuntime {
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
    void Function()? onImageGenerationStarted,
  }) async => (await runAgentTurn(
    tenantId: tenantId,
    taskId: taskId,
    request: request,
    messages: agentMessagesFromRequest(request['messages']),
    onChunk: (_) {},
    onProcessEvent: (_) {},
    cancellation: cancellation,
    onImageGenerationStarted: onImageGenerationStarted,
    onLegacyDelta: onDelta,
  )).text;

  @override
  Future<XiaoqiAgentTurnResult> runAgentTurn({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required List<Message> messages,
    List<ToolResponsePart>? respond,
    List<ToolRequestPart>? restart,
    required void Function(AgentStreamChunk chunk) onChunk,
    required void Function(Map<String, Object?> event) onProcessEvent,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
    void Function(String text)? onLegacyDelta,
  }) async {
    cancellation.throwIfCancelled();
    final rawCapability = request['capability'];
    final imageGenerationSelected =
        rawCapability is Map &&
        rawCapability['type'] == 'action' &&
        rawCapability['id'] == 'create-image';
    final legacyMessages = _legacyMessagesFor(messages);
    final latestUserText = _latestUserText(legacyMessages);
    if (imageGenerationSelected && latestUserText.trim().isEmpty) {
      const answer = '你想生成什么内容的图片？可以描述一下主体、风格或用途。';
      onLegacyDelta?.call(answer);
      return XiaoqiAgentTurnResult(
        text: answer,
        messages: [
          ...messages,
          Message(
            role: Role.model,
            content: [TextPart(text: answer)],
          ),
        ],
      );
    }
    final shouldGenerateImage =
        imageGenerationSelected || agentShouldGenerateImage(latestUserText);
    final answerBeforeImage =
        !imageGenerationSelected &&
        agentImageRequestNeedsTextAnswer(latestUserText);
    final imageToolAvailable = shouldGenerateImage && answerBeforeImage;
    _logAgentRuntime('image_intent_classified', taskId, {
      'requested': shouldGenerateImage,
      'answer_before_image': answerBeforeImage,
      'agent_tool_available': imageToolAvailable,
    });
    if (shouldGenerateImage && !answerBeforeImage) {
      // Image generation has billing side effects; explicit requests should not depend on model-emitted tool markup.
      cancellation.throwIfCancelled();
      _logAgentRuntime('tool_called', taskId, {
        'tool_name': 'generate_image',
        'source': imageGenerationSelected ? 'selected_action' : 'intent_router',
      });
      onProcessEvent({'type': 'tool_started', 'tool': 'generate_image'});
      onImageGenerationStarted?.call();
      final imageResult = await images.generate(
        taskId: taskId,
        tenantId: tenantId,
        prompt: agentImagePrompt(latestUserText),
        count: 1,
        imageUrl: _latestUserImageUrl(legacyMessages),
      );
      cancellation.throwIfCancelled();
      const answer = '图片已生成。';
      onLegacyDelta?.call(answer);
      onProcessEvent({
        'type': 'tool_succeeded',
        'tool': 'generate_image',
        'artifacts': imageResult['artifacts'],
      });
      return XiaoqiAgentTurnResult(
        text: answer,
        messages: [
          ...messages,
          Message(
            role: Role.model,
            content: [TextPart(text: answer)],
          ),
        ],
      );
    }

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
    var imageToolCalled = false;
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
        onProcessEvent({'type': 'tool_started', 'tool': 'execute_python'});
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
          final approvedDomains = request['remote_agent'] == true
              ? _resumedAuthorizedDomains(context.resumed, permission)
              : null;
          if (request['remote_agent'] == true && approvedDomains == null) {
            return ToolResult.interrupt({
              'type': 'network_permission',
              'tool': 'execute_python',
              'domains': permission.domains,
              'purpose': permission.purpose,
            });
          }
          if (approvedDomains == null) {
            pendingPermission = permission;
            return ToolResult.response(
              jsonEncode({
                'status': 'awaiting_network_permission',
                'domains': permission.domains,
                'purpose': permission.purpose,
              }),
            );
          }
          _authorizeAgentTaskDomains(tenantId, taskId, approvedDomains);
        }
        final skillFiles = request['capability'] is Map
            ? _loadSkillFiles(tenantId, request['capability'])
            : <String, List<int>>{};
        try {
          final result = await codeExecutor.execute(
            tenantId: tenantId,
            taskId: taskId,
            code: input['code']?.toString() ?? '',
            language: 'python',
            authorizedDomains: {
              ..._authorizedDomains(tenantId, taskId),
              ...?_resumedAuthorizedDomains(context.resumed, permission),
            }.toList()..sort(),
            materials: _materials(request['materials']),
            skillFiles: skillFiles,
            cancellation: cancellation,
          );
          onProcessEvent({'type': 'tool_succeeded', 'tool': 'execute_python'});
          return ToolResult.response(result);
        } on Object catch (error) {
          onProcessEvent({
            'type': 'tool_failed',
            'tool': 'execute_python',
            'message': _briefToolError(error),
          });
          rethrow;
        }
      },
    );
    if (imageToolAvailable) {
      ai.defineTool<Map<String, dynamic>, String>(
        name: 'generate_image',
        description:
            '为当前用户明确要求的图片生成真实图片。必须使用此工具完成生图，不要用 SVG、HTML、代码或文字描述代替图片。'
            'prompt 只写图片画面内容和风格；用户同时要求解释时仍须完整回答解释。',
        inputSchema: _generateImageSchema,
        fn: (input, context) async {
          onProcessEvent({'type': 'tool_started', 'tool': 'generate_image'});
          cancellation.throwIfCancelled();
          if (imageToolCalled) {
            return ToolResult.response(
              jsonEncode({'ok': false, 'message': '本任务已经生成过图片'}),
            );
          }
          imageToolCalled = true;
          _logAgentRuntime('tool_called', taskId, {
            'tool_name': 'generate_image',
            'source': 'genkit_agent',
          });
          onImageGenerationStarted?.call();
          final requestedPrompt = input['prompt']?.toString().trim() ?? '';
          final combinedPrompt = requestedPrompt.isEmpty
              ? latestUserText
              : '$requestedPrompt\n\n用户原始要求：$latestUserText';
          try {
            final result = await images.generate(
              taskId: taskId,
              tenantId: tenantId,
              prompt: agentImagePrompt(combinedPrompt),
              count: 1,
              imageUrl: _latestUserImageUrl(legacyMessages),
            );
            cancellation.throwIfCancelled();
            onProcessEvent({
              'type': 'tool_succeeded',
              'tool': 'generate_image',
            });
            return ToolResult.response(jsonEncode(result));
          } on Object catch (error) {
            onProcessEvent({
              'type': 'tool_failed',
              'tool': 'generate_image',
              'message': _briefToolError(error),
            });
            rethrow;
          }
        },
      );
    }
    ai.defineTool<Map<String, dynamic>, String>(
      name: 'execute_skill_script',
      description:
          '执行当前技能已同步版本中的脚本。只接受 scripts/ 下真实存在的 .py、.js、.mjs、.cjs、.ts 或 .mts 文件；'
          '每个任务仅允许执行一次。脚本只能访问本次任务资料和当前技能文件，默认断网。',
      inputSchema: _executeSkillScriptSchema,
      fn: (input, context) async {
        onProcessEvent({
          'type': 'tool_started',
          'tool': 'execute_skill_script',
        });
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
          final approvedDomains = request['remote_agent'] == true
              ? _resumedAuthorizedDomains(context.resumed, permission)
              : null;
          if (request['remote_agent'] == true && approvedDomains == null) {
            return ToolResult.interrupt({
              'type': 'network_permission',
              'tool': 'execute_skill_script',
              'domains': permission.domains,
              'purpose': permission.purpose,
            });
          }
          if (approvedDomains == null) {
            pendingPermission = permission;
            return ToolResult.response(
              jsonEncode({
                'status': 'awaiting_network_permission',
                'domains': permission.domains,
                'purpose': permission.purpose,
              }),
            );
          }
          _authorizeAgentTaskDomains(tenantId, taskId, approvedDomains);
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
        try {
          final result = await codeExecutor.execute(
            tenantId: tenantId,
            taskId: taskId,
            code: utf8.decode(scriptBytes),
            language: input['language']?.toString() ?? '',
            authorizedDomains: {
              ..._authorizedDomains(tenantId, taskId),
              ...?_resumedAuthorizedDomains(context.resumed, permission),
            }.toList()..sort(),
            materials: _materials(request['materials']),
            skillFiles: skillFiles,
            cancellation: cancellation,
            scriptPath: scriptPath,
            arguments: arguments,
          );
          onProcessEvent({
            'type': 'tool_succeeded',
            'tool': 'execute_skill_script',
          });
          return ToolResult.response(result);
        } on Object catch (error) {
          onProcessEvent({
            'type': 'tool_failed',
            'tool': 'execute_skill_script',
            'message': _briefToolError(error),
          });
          rethrow;
        }
      },
    );

    _logAgentRuntime('messages_prepared', taskId, {
      'message_count': messages.length,
      'image_count': messages
          .expand((message) => message.content)
          .where((part) => part.isMedia)
          .length,
    });
    final selectedCapability = request['capability'] is Map;
    final skillSelected = selectedCapability && !imageGenerationSelected;
    final skillFiles = skillSelected
        ? _loadSkillFiles(tenantId, request['capability'])
        : const <String, List<int>>{};
    final hasSkillScripts = skillFiles.keys.any(
      (path) => path.replaceAll('\\', '/').startsWith('scripts/'),
    );
    final toolNames = agentToolNamesForRequest(
      latestUserText: latestUserText.toLowerCase(),
      capabilitySelected: skillSelected,
      skillHasScripts: hasSkillScripts,
      imageGenerationRequested: imageToolAvailable,
    );

    final skill = skillSelected
        ? _loadSkill(tenantId, request['capability'])
        : '';
    final materialText = _materialsText(request['materials']);
    final system = StringBuffer(
      '你是小七的 AI 助手。请使用中文回答，遵循用户的最新要求。'
      '普通问候、问答、解释和写作直接回答，不要调用技能、代码或文件工具。'
      '只有用户明确要求相应操作，并且对应工具已提供时才调用工具。'
      '不要声称执行了没有执行的操作。',
    );
    if (skill.isNotEmpty) system.write('\n\n当前技能指令：\n$skill');
    if (materialText.isNotEmpty) system.write('\n\n用户提供的资料：\n$materialText');
    if (imageToolAvailable) {
      system.write(
        '\n\n当前用户明确要求生成图片。必须调用 generate_image 工具生成真实图片；'
        '不要输出 SVG、HTML、代码或图片提示词来代替图片。若同时要求知识解释，也要完整回答文字部分。',
      );
    }

    final agent = ai.defineAgent(
      name: 'xiaoqi_assistant',
      model: openAI.model(selection.modelId, namespace: selection.namespace),
      system: system.toString(),
      maxTurns: 8,
      toolNames: toolNames,
    );
    final isResume = respond?.isNotEmpty == true || restart?.isNotEmpty == true;
    final priorMessages = isResume
        ? messages
        : messages.take(messages.length - 1).toList();
    final chat = agent.chat(state: SessionState(messages: priorMessages));
    final turn = isResume
        ? chat.resumeStream(
            respond: respond,
            restart: restart,
            cancel: cancellation,
          )
        : chat.sendStream(message: messages.last, cancel: cancellation);
    final output = StringBuffer();
    await for (final chunk in turn.stream) {
      cancellation.throwIfCancelled();
      onChunk(chunk.raw);
      final delta = chunk.text;
      if (delta.isNotEmpty) {
        output.write(delta);
        onLegacyDelta?.call(delta);
      }
    }
    final response = await turn.response;
    response.assertValid();
    if (pendingPermission != null) throw pendingPermission!;
    final answer = response.text.isNotEmpty ? response.text : output.toString();
    if (answer.isEmpty &&
        response.finishReason != AgentFinishReason.interrupted) {
      throw StateError('模型没有返回文本');
    }
    if (imageToolAvailable && !imageToolCalled) {
      cancellation.throwIfCancelled();
      _logAgentRuntime('tool_called', taskId, {
        'tool_name': 'generate_image',
        'source': 'intent_router_fallback',
      });
      onImageGenerationStarted?.call();
      onProcessEvent({'type': 'tool_started', 'tool': 'generate_image'});
      await images.generate(
        taskId: taskId,
        tenantId: tenantId,
        prompt: agentImagePrompt(latestUserText),
        count: 1,
        imageUrl: _latestUserImageUrl(legacyMessages),
      );
      cancellation.throwIfCancelled();
      onProcessEvent({'type': 'tool_succeeded', 'tool': 'generate_image'});
    }
    return XiaoqiAgentTurnResult(
      text: answer,
      messages: List<Message>.unmodifiable(chat.messages),
      finishReason: response.finishReason,
    );
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

  void _authorizeAgentTaskDomains(
    String tenantId,
    String taskId,
    List<String> domains,
  ) {
    final key = 'task/$tenantId/$taskId';
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = store.get(key);
      if (current == null)
        throw StateError('Agent turn is no longer available.');
      final authorized = {
        ...(current.value['authorized_network_domains'] as List? ?? const [])
            .map((value) => value.toString()),
        ...domains,
      }.toList()..sort();
      try {
        store.put(key, {
          ...current.value,
          'authorized_network_domains': authorized,
        }, current.revision);
        return;
      } on RevisionConflict {
        if (attempt == 7) rethrow;
      }
    }
  }

  static List<String>? _resumedAuthorizedDomains(
    Object? resumed,
    NetworkPermissionRequired? permission,
  ) {
    if (resumed is! Map || resumed['approved'] != true || permission == null) {
      return null;
    }
    final provided = (resumed['domains'] as List? ?? const [])
        .map((value) => value.toString())
        .toSet();
    final requested = permission.domains.toSet();
    if (provided.length != requested.length ||
        !provided.containsAll(requested)) {
      return null;
    }
    return requested.toList()..sort();
  }

  static String _briefToolError(Object error) {
    final value = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return value.length <= 240 ? value : '${value.substring(0, 240)}…';
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

  static String _latestUserText(Object? rawMessages) {
    if (rawMessages is! List) return '';
    for (final rawMessage in rawMessages.reversed) {
      if (rawMessage is Map && rawMessage['role'] == 'user') {
        return _textContent(rawMessage['content']);
      }
    }
    return '';
  }

  static List<Map<String, Object?>> _legacyMessagesFor(
    List<Message> messages,
  ) => [
    for (final message in messages)
      {
        'role': switch (message.role) {
          Role.system => 'system',
          Role.user => 'user',
          Role.model => 'assistant',
          _ => 'assistant',
        },
        'content': [
          for (final part in message.content)
            if (part.toJson()['text'] is String)
              {'type': 'text', 'text': part.toJson()['text']}
            else if (part.toJson()['media'] is Map)
              {
                'type': 'image_url',
                'image_url': {'url': (part.toJson()['media'] as Map)['url']},
              },
        ],
      },
  ];

  static String? _latestUserImageUrl(Object? rawMessages) {
    if (rawMessages is! List) return null;
    for (final rawMessage in rawMessages.reversed) {
      if (rawMessage is! Map || rawMessage['role'] != 'user') continue;
      final content = rawMessage['content'];
      if (content is! List) return null;
      for (final rawPart in content) {
        if (rawPart is! Map || rawPart['type'] != 'image_url') continue;
        final image = rawPart['image_url'];
        if (image is Map) return image['url']?.toString();
      }
      return null;
    }
    return null;
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
