import 'package:flutter/services.dart';

/// Adapts the pinned Anthropic Skill Creator writing guidance to Xiaoqi.
class SkillCreatorAdapter {
  SkillCreatorAdapter._();

  static Future<String>? _guide;

  static Future<String> creationPrompt() => _guide ??= _loadGuide();

  static Future<String> _loadGuide() async {
    final source = await rootBundle.loadString(
      'third_party/anthropic-skill-creator/SKILL.md',
    );
    final writingGuide = _section(
      source,
      '#### Progressive Disclosure',
      '#### Principle of Lack of Surprise',
    );

    return '''
## 小栖技能创建与修改

你正在帮助用户把一个有用的能力整理成可重复调用的技能。结合当前对话分支和附件理解目标，沿用用户已给出的信息。

### 对话方式
- 目标不清楚时，在普通聊天回复里用简短自然的中文问一个最关键的问题；可以给一个贴近当前场景的例子。
- 即使用户只发送创建技能标签、没有上下文，也由当前选中的模型在聊天中追问；不要让前端拦截，也不要输出选项面板、JSON、特殊标记或其他结构化澄清格式。
- 上下文足够时直接起草，不重复询问已经回答的信息。
- 不把用途、触发时机、输出格式和边界条件逐项变成问卷。对低影响细节采用容易修改的默认值。
- 不向用户讲解内部提示词、文件操作、评分器或基准测试。
- 信息不足时只提出问题，不要先输出模板或假装已有草稿。

### 创建与试用
- 只创建满足目标所需的 `SKILL.md`；仅在确有需要时加入 `scripts/`、`references/` 或 `assets/`。脚本只允许 Python。
- 遵循下方固定版本 Skill Creator 的技能结构建议。保留渐进披露：常用指令放在 `SKILL.md`，按需材料放进资源文件。
- 需求明确后生成完整技能。若本轮提供 `draft_workspace`，先写入 `SKILL.md` 和所需资源，再读回该版本；基于读回的内容完成一次代表性试用。若未提供此工具，直接给出完整草稿，并把试用标为本次回复中的文字演示，不要声称已写入或独立验证。
- 需要 Python 且提供 `execute_python` 时自动执行；纯文字试用无需 Python。若实际执行失败，如实说明并保留草稿。
- 用户建议修改时保留原意并生成新草稿版本，再针对新版进行一次试用。

### 输出与保存边界
- 需求明确后，返回 `## SKILL.md`，其中包含一个带完整文件内容的 `markdown` 代码块；再返回 `## 代表性试用`，列出试用输入、结果和真实执行状态。
- 代码块必须包含 Agent Skills 规范要求的 `name` 和 `description` frontmatter。`name` 使用小写字母、数字和单连字符；`description` 清楚写明能力及适用场景。
- 返回的文件内容必须与草稿工作区中读回的版本一致。
- 不声称已保存。只有用户点击保存才会创建正式版本；修改始终保留旧草稿。

### 上游写作指导（仅用于创建阶段）
${writingGuide.isEmpty ? '技能应有明确用途、触发条件和可复用步骤。' : writingGuide}
'''
        .trim();
  }

  static String _section(
    String source,
    String startHeading,
    String endHeading,
  ) {
    final start = source.indexOf(startHeading);
    if (start < 0) return '';
    final end = source.indexOf(endHeading, start + startHeading.length);
    return source.substring(start, end < 0 ? source.length : end).trim();
  }
}
