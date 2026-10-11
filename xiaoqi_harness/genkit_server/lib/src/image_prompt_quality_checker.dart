/// Validates image generation prompt quality before sending to Ark Seedream.
/// Prevents common failure patterns: copyright keywords, task instructions,
/// non-visual descriptions, and empty/too-short prompts.
class ImagePromptQualityChecker {
  const ImagePromptQualityChecker();

  /// Check prompt quality and return validation result.
  /// Returns (isValid: true, ...) if prompt passes all checks.
  /// Returns (isValid: false, reason: ..., suggestion: ...) if rejected.
  ({
    bool isValid,
    String? reason,
    String? suggestion,
    PromptQualityScore? score,
  }) check(String prompt) {
    final trimmed = prompt.trim();

    // 1. Empty or too short
    if (trimmed.isEmpty) {
      return (
        isValid: false,
        reason: 'Prompt 为空',
        suggestion: '请提供图片的视觉描述，例如：温暖的卧室，窗台有三盆绿植',
        score: null,
      );
    }

    if (trimmed.length < 5) {
      return (
        isValid: false,
        reason: 'Prompt 过短（< 5 字符）',
        suggestion: '请补充更详细的视觉描述，如场景、主体、风格、色调等',
        score: null,
      );
    }

    // 2. Copyright-sensitive keywords (celebrities, brand names, theories)
    final copyrightPattern = RegExp(
      r'(马斯克|乔布斯|比尔盖茨|扎克伯格|贝索斯|库克|雷军|马化腾|张一鸣|'
      r'第一性原理|飞轮效应|OKR|SMART|金字塔原理|'
      r'iPhone|特斯拉|Model\s*[3SXY]|MacBook|SpaceX)',
      caseSensitive: false,
    );

    if (copyrightPattern.hasMatch(trimmed)) {
      return (
        isValid: false,
        reason: 'Prompt 包含版权敏感关键词（名人姓名、品牌名或专有理论名称）',
        suggestion: '请只描述视觉元素，不要提及具体人名或品牌。'
            '例如：将"马斯克的第一性原理"改为"抽象概念图，中心是问题核心，周围是层层剥离的表象"',
        score: null,
      );
    }

    // 3. Task instruction keywords (explanation, Q&A intent)
    final taskInstructionPattern = RegExp(
      r'(讲解|介绍|说明|解释|教学|科普|分析|阐述|阐释|'
      r'为什么|怎么做|如何实现|原理是什么|是什么意思|'
      r'帮我理解|给我说说|告诉我)',
      caseSensitive: false,
    );

    if (taskInstructionPattern.hasMatch(trimmed)) {
      return (
        isValid: false,
        reason: 'Prompt 包含任务指令或问答性质的文本',
        suggestion: '图片生成只接受视觉描述。'
            '如果需要配图说明，请先让 AI 输出文字解释，再单独生成图片。',
        score: null,
      );
    }

    // 4. Score the prompt
    final score = _scorePrompt(trimmed);

    // 5. Warn if score is low (but still allow)
    if (score.total < 40) {
      return (
        isValid: true,
        reason: null,
        suggestion: '提示：当前 Prompt 可视化程度较低（评分 ${score.total}/100），'
            '建议补充具体的视觉元素、场景或风格描述以获得更好效果。',
        score: score,
      );
    }

    return (isValid: true, reason: null, suggestion: null, score: score);
  }

  /// Score prompt quality (0-100).
  PromptQualityScore _scorePrompt(String prompt) {
    var visualKeywordScore = 0;
    var detailScore = 0;
    var structureScore = 0;

    // Visual keyword coverage (0-40)
    final visualKeywords = [
      RegExp(r'(颜色|色调|色彩|配色|明暗|光影|阴影|高光)', caseSensitive: false),
      RegExp(r'(场景|环境|背景|前景|远景|近景)', caseSensitive: false),
      RegExp(r'(物体|主体|人物|动物|建筑|植物)', caseSensitive: false),
      RegExp(r'(风格|画风|艺术风格|写实|抽象|卡通|赛博朋克|极简)', caseSensitive: false),
      RegExp(r'(构图|布局|对称|黄金比例|三分法)', caseSensitive: false),
      RegExp(r'(材质|质感|纹理|光滑|粗糙|金属|木质)', caseSensitive: false),
      RegExp(r'(动作|姿态|表情|氛围|情绪)', caseSensitive: false),
      RegExp(r'(细节|装饰|纹样|图案)', caseSensitive: false),
    ];

    for (final pattern in visualKeywords) {
      if (pattern.hasMatch(prompt)) visualKeywordScore += 5;
    }

    // Detail richness (0-30)
    final length = prompt.length;
    if (length >= 200) {
      detailScore = 30;
    } else if (length >= 100) {
      detailScore = 20;
    } else if (length >= 50) {
      detailScore = 15;
    } else if (length >= 20) {
      detailScore = 10;
    }

    // Structure (0-30)
    final hasCommas = prompt.contains('，') || prompt.contains(',');
    final hasPunctuation = RegExp(r'[，。、；：]').allMatches(prompt).length;
    final hasMultipleClauses = hasPunctuation >= 2;

    if (hasMultipleClauses) {
      structureScore = 30;
    } else if (hasCommas) {
      structureScore = 20;
    } else {
      structureScore = 10;
    }

    return PromptQualityScore(
      visualKeywords: visualKeywordScore,
      detail: detailScore,
      structure: structureScore,
      total: visualKeywordScore + detailScore + structureScore,
    );
  }
}

/// Prompt quality score breakdown.
class PromptQualityScore {
  const PromptQualityScore({
    required this.visualKeywords,
    required this.detail,
    required this.structure,
    required this.total,
  });

  /// Visual keyword coverage score (0-40)
  final int visualKeywords;

  /// Detail richness score (0-30)
  final int detail;

  /// Structure score (0-30)
  final int structure;

  /// Total score (0-100)
  final int total;

  Map<String, dynamic> toJson() => {
        'visual_keywords': visualKeywords,
        'detail': detail,
        'structure': structure,
        'total': total,
      };
}
