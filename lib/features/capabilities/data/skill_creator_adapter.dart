import 'package:flutter/services.dart';

/// Adapts the pinned Anthropic Skill Creator guidance to Xiaoqi's chat flow.
class SkillCreatorAdapter {
  SkillCreatorAdapter._();

  static Future<String>? _guide;

  static Future<String> creationPrompt() => _guide ??= _loadGuide();

  static Future<String> _loadGuide() async {
    final files = await Future.wait([
      rootBundle.loadString('third_party/anthropic-skill-creator/SKILL.md'),
      rootBundle.loadString(
        'third_party/anthropic-skill-creator/agents/grader.md',
      ),
    ]);
    final authoringGuide = _authoringWorkflow(
      _withoutPlatformSections(files[0]),
    );
    return '''
${_adaptedAuthoringGuide(authoringGuide)}

## Xiaoqi adapter

Use the selected model and the current conversation as the creator context.
The Xiaoqi adapter provides the conversation history, task attachments, and a
private draft workspace. Do not assume Claude tools, subagents, or a Claude
filesystem. Python execution is performed by the server sandbox when needed;
do not ask the user for permission to run Python. Do not request network access
unless a separate domain-scoped authorization is part of the task.

Ask only for missing details that materially change the skill: its purpose,
trigger situations, expected result, and important edge cases. Use details
already present in the conversation or attachments. Keep instructions concise,
prefer progressive disclosure, and do not add files or scripts without a clear
need. A Python script is allowed only when the described capability requires
deterministic computation or file transformation.

Return exactly these sections when the skill is ready:
1. `## SKILL.md` followed by one fenced `markdown` block containing the complete
   Agent Skills compliant file. Its frontmatter must include a lowercase
   kebab-case `name` and a useful `description`.
2. `## 代表性试用` followed by a realistic user request and the result produced
   by applying the just-written skill. Judge the result against the supplied
   grader guidance; state concrete gaps instead of claiming the test passed.

Never claim that the draft was saved. Saving is a separate user action.

## Pinned upstream review resources

### Grader guidance
${files[1]}
''';
  }

  static String _authoringWorkflow(String source) {
    final start = source.indexOf('## Creating a skill');
    final end = source.indexOf('## Description Optimization');
    if (start < 0) return source;
    return source.substring(start, end < 0 ? source.length : end).trim();
  }

  static String _withoutPlatformSections(String source) {
    final lines = source.split('\n');
    final kept = <String>[];
    var skipping = false;
    for (final line in lines) {
      if (line.startsWith('## ')) {
        skipping =
            line == '## Claude.ai-specific instructions' ||
            line == '## Cowork-Specific Instructions';
      }
      if (!skipping) kept.add(line);
    }
    return kept.join('\n').trim();
  }

  static String _adaptedAuthoringGuide(String source) => source
      .replaceAll('Claude', 'the selected assistant')
      .replaceAll('claude.ai', 'Xiaoqi');
}
