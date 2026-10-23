import 'dart:convert';
import 'package:flutter/services.dart';

/// Adapts the pinned Anthropic Skill Creator writing guidance to Xiaoqi.
class SkillCreatorAdapter {
  SkillCreatorAdapter._();

  static Future<String>? _guide;

  static Future<String> creationPrompt() => _guide ??= _loadGuide();

  static Future<String> _loadGuide() async {
    const root = 'assets/builtin_plugins/skill_creator/';
    final manifest =
        jsonDecode(await rootBundle.loadString('${root}plugin.json')) as Map;
    final skill = (manifest['skills'] as List).whereType<Map>().singleWhere(
      (value) => value['id'] == 'create-skill',
    );
    final entry = skill['entry'].toString();
    if (entry != 'skills/create-skill/SKILL.md')
      throw StateError('内置技能创建插件入口无效');
    final creationGuide = await rootBundle.loadString('$root$entry');
    final source = await rootBundle.loadString(
      'third_party/anthropic-skill-creator/SKILL.md',
    );
    final writingGuide = _section(
      source,
      '#### Progressive Disclosure',
      '#### Principle of Lack of Surprise',
    );

    return '''$creationGuide
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
