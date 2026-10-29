import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'plugin_agents.dart';
import 'selected_skills.dart';

/// Knowledge loading within the existing turn catalog, never an effect grant.
class PluginAgentSkillPreloads {
  PluginAgentSkillPreloads(this.skills, SelectedPluginAgents agents) {
    final siblingCatalogs = <String, SelectedSkills>{};
    for (final agent in agents.entries.values) {
      final id = agent['id'] as String;
      final added = <String>[];
      try {
        final declared =
            (agents.definition(id).metadata['skills'] as List? ?? const [])
                .cast<String>();
        if (declared.isEmpty) continue;
        if (declared.length > 32) throw StateError('Agent 一次最多预加载 32 个技能');
        final siblings = siblingCatalogs.putIfAbsent(
          jsonEncode([
            agent['parent_id'],
            agent['version_id'],
            agent['artifact_key'],
          ]),
          () => SelectedSkills(skills.store, skills.tenant, [
            {'id': agent['parent_id'], 'version_id': agent['version_id']},
          ], allowUnavailable: true),
        );
        final resolved = <Map<String, String>>[];
        for (final name in declared) {
          List<Map<String, String>> matches(
            SelectedSkills source,
          ) => source.entries.values.where((entry) {
            try {
              final metadata = source.metadata(entry);
              final local = metadata['name']?.toString();
              if (name == entry['id'] || name == local) return true;
              return name.contains(':') &&
                  name == '${source.namespace(entry)}:$local';
            } on Object {
              return false; // An unrelated unavailable skill cannot hide healthy sources.
            }
          }).toList();
          final local = matches(siblings);
          final found = local.isNotEmpty ? local : matches(skills);
          if (found.length != 1)
            throw StateError(
              'Agent 技能 $name ${found.isEmpty ? '不存在或未启用' : '名称重复，请使用插件名称空间限定'}',
            );
          final entry = found.single;
          final source = local.isNotEmpty ? siblings : skills;
          if (source.metadata(entry)['disable-model-invocation'] == true)
            throw StateError('Agent 不能自动预加载仅限用户调用的技能 $name');
          if (!resolved.any((prior) => prior['id'] == entry['id']))
            resolved.add(entry);
        }
        if ({
              ...skills.entries.keys,
              ...resolved.map((entry) => entry['id']!),
            }.length >
            128)
          throw StateError('本轮技能目录已满，无法预加载 Agent 技能');
        // Commit this Agent's complete resolution only after every name matches.
        for (final entry in resolved) {
          if (!skills.entries.containsKey(entry['id'])) {
            skills.entries[entry['id']!] = entry;
            added.add(entry['id']!);
          }
        }
        _loaded[id] = AgentSkillPreload(skills, resolved);
      } on Object catch (error) {
        for (final id in added) {
          skills.entries.remove(id);
        }
        _issues[id] = error is StateError
            ? error.message.toString()
            : 'Agent 所需技能不可用，请检查插件版本和技能名称';
      }
    }
  }

  final SelectedSkills skills;
  final _loaded = <String, AgentSkillPreload>{};
  final _issues = <String, String>{};

  AgentSkillPreload forAgent(String id) {
    final issue = _issues[id];
    if (issue != null) throw StateError(issue);
    final preload = _loaded[id] ?? AgentSkillPreload(skills, const []);
    preload.validate();
    return preload;
  }
}

class AgentSkillPreload {
  static const _identity = [
    'id',
    'parent_id',
    'version_id',
    'component_id',
    'artifact_key',
    'root',
  ];
  AgentSkillPreload(this.skills, List<Map<String, String>> references)
    : entries = List.unmodifiable(
        references.map((entry) => Map<String, String>.unmodifiable(entry)),
      ) {
    final content = StringBuffer();
    final bindings = <Object>[];
    for (final entry in entries) {
      final files = skills.files(entry);
      final bytes = files['SKILL.md'];
      if (bytes == null) throw StateError('Agent 技能正文不存在');
      final text = utf8.decode(bytes);
      if (content.length + text.length > 240000)
        throw StateError('Agent 预加载技能正文超过本轮上下文限制');
      final digest = sha256.convert(bytes).toString();
      _digests[entry['id']!] = digest;
      bindings.add([
        [for (final field in _identity) entry[field]],
        digest,
      ]);
      final paths = files.keys.toList()..sort();
      content.write(
        '\n<agent_skill id="${entry['id']}">\n$text\n'
        '当前绑定技能 ID：${entry['id']}；资源清单：${jsonEncode(paths)}\n</agent_skill>\n',
      );
    }
    instructions = content.toString();
    binding = sha256.convert(utf8.encode(jsonEncode(bindings))).toString();
  }

  final SelectedSkills skills;
  final List<Map<String, String>> entries;
  final _digests = <String, String>{};
  late final String instructions;
  late final String binding;

  void validate() {
    for (final entry in entries) {
      final current = skills.resolve({'skill_id': entry['id']});
      if (_identity.any((field) => current[field] != entry[field]) ||
          skills.metadata(current)['disable-model-invocation'] == true ||
          sha256
                  .convert(skills.files(current)['SKILL.md'] ?? const [])
                  .toString() !=
              _digests[entry['id']])
        throw StateError('Agent 预加载技能源已变化，不能继续原会话');
    }
  }
}
