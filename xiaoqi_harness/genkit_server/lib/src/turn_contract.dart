import 'dart:convert';

import 'package:schemantic/schemantic.dart';

/// A server-owned scope for one user request, not a skill's delivery plan.
class TurnContract {
  TurnContract({
    required this.mode,
    required this.imageLimit,
    this.answerRequired = false,
    this.skillIds = const [],
    this.connectionIds = const [],
    this.targetArtifactId,
    this.clarification,
  });

  final String mode;
  final int imageLimit;
  final bool answerRequired;
  final List<String> skillIds;
  final List<String> connectionIds;
  final String? targetArtifactId;
  final String? clarification;

  factory TurnContract.fromJson(Map value) => TurnContract(
    mode: value['mode'] as String,
    imageLimit: value['image_limit'] as int,
    answerRequired: value['answer_required'] == true,
    skillIds: (value['skill_ids'] as List? ?? const []).cast<String>(),
    connectionIds: (value['connection_ids'] as List? ?? const [])
        .cast<String>(),
    targetArtifactId: value['target_artifact_id'] as String?,
    clarification: value['clarification'] as String?,
  );

  bool get executesWorkflow =>
      const {'create', 'revise', 'workflow', 'continue'}.contains(mode);
  bool get readsImage => mode == 'inspect';
  bool get permitsImages => imageLimit > 0 && executesWorkflow;

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'image_limit': imageLimit,
    'answer_required': answerRequired,
    'skill_ids': skillIds,
    'connection_ids': connectionIds,
    if (targetArtifactId != null) 'target_artifact_id': targetArtifactId,
    if (clarification != null) 'clarification': clarification,
  };

  static final proposalSchema = SchemanticType.from<Map<String, dynamic>>(
    jsonSchema: {
      'type': 'object',
      'properties': {
        'mode': {
          'type': 'string',
          'enum': [
            'answer',
            'inspect',
            'create',
            'revise',
            'workflow',
            'continue',
            'cancel',
            'clarify',
          ],
        },
        'image_count': {'type': 'integer', 'minimum': 0, 'maximum': 12},
        'answer_required': {'type': 'boolean'},
        'skill_ids': {
          'type': 'array',
          'items': {'type': 'string'},
          'maxItems': 16,
        },
        'connection_ids': {
          'type': 'array',
          'items': {'type': 'string'},
          'maxItems': 8,
        },
        'target_artifact_id': {
          'type': ['string', 'null'],
        },
        'clarification': {
          'type': ['string', 'null'],
        },
      },
      'required': [
        'mode',
        'image_count',
        'answer_required',
        'skill_ids',
        'connection_ids',
        'target_artifact_id',
        'clarification',
      ],
      'additionalProperties': false,
    },
    parse: (value) => Map<String, dynamic>.from(value as Map),
  );

  static Future<TurnContract> parseProposal(
    String text, {
    required Set<String> skills,
    required Set<String> connections,
  }) async {
    final match = RegExp(r'\{[\s\S]*\}').firstMatch(text);
    final decoded = jsonDecode(match?.group(0) ?? text);
    if ((await proposalSchema.validate(decoded)).isNotEmpty) {
      throw const FormatException('意图结果格式无效');
    }
    final value = proposalSchema.parse(decoded);
    final mode = value['mode'] as String;
    final workflow = const {
      'create',
      'revise',
      'workflow',
      'continue',
    }.contains(mode);
    List<String> allowed(String key, Set<String> ids) => (value[key] as List)
        .cast<String>()
        .where(ids.contains)
        .toSet()
        .toList();
    return TurnContract(
      mode: mode,
      imageLimit: workflow ? value['image_count'] as int : 0,
      answerRequired: value['answer_required'] as bool,
      skillIds: workflow ? allowed('skill_ids', skills) : const [],
      connectionIds: allowed('connection_ids', connections),
      targetArtifactId: value['target_artifact_id'] as String?,
      clarification: value['clarification'] as String?,
    );
  }

  /// Explicit prohibitions constrain even a mistaken model proposal.
  static bool forbidsImages(String text) => RegExp(
    r'(不要|别|停止|不用|不需要|无需|禁止).{0,8}(生图|生成.{0,3}图|画|绘图|图片|配图)|'
    r'(只用|只要|仅用|纯)(文字|文本)|'
    r'\b(do not|don.t|stop|no need to)\b.{0,20}(generate|draw|image)|'
    r'\b(text.only|only explain)\b',
    caseSensitive: false,
  ).hasMatch(text);

  static bool isInspection(String text) {
    if (RegExp(r'(并|再|然后|同时).{0,12}(生成|画|绘制|修改|制作)').hasMatch(text))
      return false;
    return RegExp(
      r'^(?:我(?:是)?问你|请问|请|帮我|给我)?\s*(?:(?:这|那|它|这张图|那张图|图片|图里).{0,12}(是什么|什么|啥|内容|意思)|(?:解释|说明|分析|识别|看看).{0,6}(这张图|这幅图|这张图片|这是什么))',
    ).hasMatch(text.trim());
  }

  TurnContract constrainedBy(String text, Object? budget) => TurnContract(
    mode: isInspection(text) ? 'inspect' : mode,
    answerRequired: isInspection(text) || answerRequired,
    imageLimit: forbidsImages(text) || isInspection(text)
        ? 0
        : (budget is num && budget.toInt() < imageLimit
              ? budget.toInt().clamp(0, 12).toInt()
              : imageLimit),
    skillIds: isInspection(text) ? const [] : skillIds,
    connectionIds: connectionIds,
    targetArtifactId: targetArtifactId,
    clarification: clarification,
  );

  String? validatePlan(Map<String, dynamic> plan) {
    final images = (plan['artifacts'] as List? ?? const [])
        .whereType<Map>()
        .where((a) => a['media_type']?.toString().startsWith('image/') == true)
        .fold<int>(0, (sum, a) => sum + (a['count'] as num).toInt());
    if (images > imageLimit) return '图片交付超出本轮用户要求，不能通过计划扩大范围';
    if (!executesWorkflow) {
      final tools = (plan['tools'] as List? ?? const []).whereType<Map>();
      if (tools.any(
        (t) => const {
          'generate_image',
          'execute_skill_script',
        }.contains(t['name']),
      ))
        return '本轮只需回答或读取结果，不执行旧工作流';
      if ((plan['artifacts'] as List? ?? const []).isNotEmpty) {
        return '本轮没有要求创建新的交付文件';
      }
    }
    return null;
  }
}
