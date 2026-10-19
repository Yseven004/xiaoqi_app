/// A declared plan is a requirement, never evidence that a tool ran.
class TaskDelivery {
  TaskDelivery({Map<String, dynamic>? restored}) {
    final savedPlan = restored?['plan'];
    if (savedPlan is Map) plan = Map<String, dynamic>.from(savedPlan);
    final counts = restored?['succeeded'];
    if (counts is Map) {
      for (final entry in counts.entries) {
        if (entry.value is num)
          succeeded[entry.key.toString()] = (entry.value as num).toInt();
      }
    }
  }
  Map<String, dynamic>? plan;
  final succeeded = <String, int>{};
  Map<String, dynamic> toJson() => {'plan': plan, 'succeeded': succeeded};

  void observe(Map<String, Object?> event) {
    if (event['type'] == 'tool_succeeded') {
      final name = event['tool']?.toString() ?? '';
      succeeded.update(name, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  void declare(Map<String, dynamic> input) {
    if (plan != null) {
      final nextSkills = (input['skill_ids'] as List? ?? const []).toSet();
      if (!(plan!['skill_ids'] as List? ?? const []).every(
        nextSkills.contains,
      )) {
        throw StateError('交付计划不能移除已经绑定的技能');
      }
      for (final kind in ['tools', 'artifacts']) {
        final key = kind == 'tools' ? 'name' : 'media_type';
        for (final previous
            in (plan![kind] as List? ?? const []).whereType<Map>()) {
          final next = (input[kind] as List? ?? const [])
              .whereType<Map>()
              .where((entry) => entry[key] == previous[key])
              .firstOrNull;
          if (next == null ||
              (next['count'] as num) < (previous['count'] as num)) {
            throw StateError('交付计划不能降低已经绑定的工具或产物要求');
          }
        }
      }
    }
    plan = input;
  }

  List<String> missing({
    required bool planRequired,
    required Iterable<String> loadedSkills,
    required Iterable<Map> artifacts,
  }) {
    if (plan == null) return planRequired ? ['尚未声明任务步骤与交付要求'] : [];
    final result = <String>[];
    for (final skill in (plan!['skill_ids'] as List? ?? const [])) {
      if (!loadedSkills.contains(skill)) result.add('相关技能尚未成功加载');
    }
    for (final raw in (plan!['tools'] as List? ?? const []).whereType<Map>()) {
      final tool = raw['name']?.toString() ?? '';
      final count = (raw['count'] as num?)?.toInt() ?? 1;
      if ((succeeded[tool] ?? 0) < count) result.add('必要工具尚未成功执行：$tool');
    }
    for (final raw
        in (plan!['artifacts'] as List? ?? const []).whereType<Map>()) {
      final type = raw['media_type']?.toString() ?? '';
      final count = (raw['count'] as num?)?.toInt() ?? 1;
      final actual = artifacts.where((artifact) {
        final actualType = artifact['media_type']?.toString() ?? '';
        return type.endsWith('/*')
            ? actualType.startsWith(type.substring(0, type.length - 1))
            : actualType == type;
      }).length;
      if (actual < count) result.add('缺少要求的交付文件：$type（$actual/$count）');
    }
    return result;
  }
}
