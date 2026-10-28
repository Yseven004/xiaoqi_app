import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';
import 'capability_import_service.dart';
import 'plugin_components.dart';
import 'store.dart';

/// Parsed source profile only. Registration/runtime support is decided by the
/// host adapter; declarations never grant tools, networking or permissions.
class PluginAgentDefinition {
  PluginAgentDefinition._(this.path, this.metadata, this.body);
  static const profileVersion = 1;
  final String path;
  final Map<String, dynamic> metadata;
  final String body;
  String get name => metadata['name'] as String;
  String get description => metadata['description'] as String;
  String get model => metadata['model'] as String? ?? 'inherit';
  List<String>? get tools => (metadata['tools'] as List?)?.cast<String>();
  List<String> get disallowedTools =>
      (metadata['disallowedTools'] as List? ?? const []).cast<String>();
  int? get maxTurns => metadata['maxTurns'] as int?;

  static Map refreshVersion(
    CloudStore store,
    String tenant,
    String id,
    Map version,
  ) {
    if (version['plugin_agent_profile'] == profileVersion) return version;
    final key = 'cap/$tenant/$id';
    final initial = store.get(key)?.value;
    if (initial == null) return version;
    final compatibility = initial['compatibility'];
    final knownNoAgents =
        initial['current_version_id'] == version['id'] &&
        compatibility is Map &&
        compatibility['warnings'] is List &&
        !(compatibility['warnings'] as List).any(
          (warning) => warning.toString().startsWith('agents '),
        ) &&
        !(compatibility['components'] as List? ?? const [])
            .whereType<Map>()
            .any((component) => component['type'] == 'agent');
    Map? candidate;
    if (!knownNoAgents) {
      candidate =
          CapabilityImportService.discover(
                store.getImmutable(version['artifact_key'].toString()),
                '',
              )
              .where(
                (candidate) =>
                    candidate['kind'] == 'plugin' && candidate['root'] == '',
              )
              .firstOrNull;
    }
    final agents = (candidate?['components'] as List? ?? const [])
        .whereType<Map>()
        .where(
          (component) =>
              component['type'] == 'agent' &&
              component['status'] != 'unsupported',
        )
        .toList();
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = store.get(key);
      if (current == null ||
          current.value['enabled'] == false ||
          current.value['deleted_at'] != null)
        return version;
      final versions = (current.value['versions'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final bound = versions
          .where(
            (candidate) =>
                candidate['id'] == version['id'] &&
                candidate['artifact_key'] == version['artifact_key'],
          )
          .firstOrNull;
      if (bound == null) return version;
      if (bound['plugin_agent_profile'] == profileVersion) return bound;
      final updated = {
        ...bound,
        'plugin_agent_profile': profileVersion,
        'components': [
          for (final component
              in (bound['components'] as List? ?? const []).whereType<Map>())
            if (component['type'] != 'agent') component,
          ...agents,
        ],
      };
      try {
        store.put(key, {
          ...current.value,
          'versions': [
            for (final candidate in versions)
              if (identical(candidate, bound)) updated else candidate,
          ],
          if (candidate != null &&
              current.value['current_version_id'] == version['id'])
            'compatibility': candidate,
        }, current.revision);
        return updated;
      } on RevisionConflict {
        continue;
      }
    }
    throw StateError('Agent 元数据更新冲突，请重新读取插件');
  }

  static PluginAgentDefinition parse(String path, List<int> bytes) {
    if (bytes.length > 128 * 1024)
      throw const FormatException('Agent 定义超过 128 KB');
    final text = utf8.decode(bytes);
    final header = RegExp(
      r'^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)',
    ).firstMatch(text);
    if (header == null) throw const FormatException('Agent 需要 YAML 元数据');
    final yaml = loadYaml(header.group(1)!);
    if (yaml is! Map) throw const FormatException('Agent YAML 格式无效');
    final metadata = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(yaml)) as Map,
    );
    for (final key in ['name', 'description']) {
      final value = metadata[key];
      if (value is! String || value.trim().isEmpty)
        throw FormatException('Agent $key 必须是非空文本');
    }
    for (final key in [
      'model',
      'permissionMode',
      'color',
      'memory',
      'isolation',
    ]) {
      if (metadata[key] != null &&
          (metadata[key] is! String ||
              (metadata[key] as String).trim().isEmpty))
        throw FormatException('Agent $key 必须是非空文本');
    }
    for (final key in ['tools', 'disallowedTools', 'skills']) {
      final raw = metadata[key];
      if (raw == null) continue;
      final values = raw is String ? raw.split(',') : raw;
      if (values is! List ||
          values.any((value) => value is! String || value.trim().isEmpty))
        throw FormatException('Agent $key 必须为工具名称列表');
      metadata[key] = values
          .map((value) => (value as String).trim())
          .toSet()
          .toList();
    }
    if (metadata['maxTurns'] != null &&
        (metadata['maxTurns'] is! int || (metadata['maxTurns'] as int) < 1))
      throw const FormatException('Agent maxTurns 必须是正整数');
    if (metadata['background'] != null && metadata['background'] is! bool)
      throw const FormatException('Agent background 必须是布尔值');
    final body = text.substring(header.end);
    if (body.trim().isEmpty) throw const FormatException('Agent 正文为空');
    return PluginAgentDefinition._(path, metadata, body);
  }

  String render(String pluginRoot) =>
      body.replaceAll(r'${CLAUDE_PLUGIN_ROOT}', pluginRoot);

  static List<Map<String, dynamic>> inspect(
    Map<String, List<int>> files,
    String root,
    Map manifest,
  ) {
    final scoped = CapabilityImportService.subtree(files, root);
    final locations = <String>['agents'];
    final declared = manifest['agents'];
    if (declared != null) {
      for (final location in declared is List ? declared : [declared]) {
        if (location is! String || !location.startsWith('./'))
          throw const FormatException('Agent 声明需要插件内相对路径');
        final path = CapabilityImportService.safePath(
          location.substring(2).replaceFirst(RegExp(r'/$'), ''),
        );
        if (!scoped.containsKey(path) &&
            !scoped.keys.any((entry) => entry.startsWith('$path/')))
          throw const FormatException('Agent 声明路径不存在');
        locations.add(path);
      }
    }
    final paths = <String>{};
    for (final location in locations) {
      if (scoped.containsKey(location) && location.endsWith('.md'))
        paths.add(location);
      paths.addAll(
        scoped.keys.where(
          (path) => path.startsWith('$location/') && path.endsWith('.md'),
        ),
      );
    }
    return [
      for (final path in paths.toList()..sort()) _inspect(scoped, root, path),
    ];
  }

  static Map<String, dynamic> _inspect(
    Map<String, List<int>> files,
    String root,
    String path,
  ) {
    PluginAgentDefinition? definition;
    String? issue;
    try {
      definition = parse(path, files[path]!);
    } on Object catch (error) {
      issue = error is FormatException
          ? error.message.toString()
          : 'Agent YAML 或文本格式无效';
    }
    return {
      'id':
          'agent-${sha256.convert(utf8.encode(path)).toString().substring(0, 16)}',
      'type': 'agent',
      'root': root,
      'source_path': path,
      'name': definition?.name ?? path,
      'description': definition?.description ?? path,
      'model': definition?.model,
      // This is source-profile compatibility, not evidence of a running host.
      'status': issue == null ? 'supported' : 'unsupported',
      'issues': [if (issue != null) issue],
      'has_scripts': files.keys.any(
        (path) => RegExp(
          r'^scripts/.+\.(?:py|js|mjs|cjs|ts|mts|sh|bash)$',
        ).hasMatch(path),
      ),
      'has_dependencies': [
        'package.json',
        'requirements.txt',
        'pyproject.toml',
        'setup.py',
      ].any(files.containsKey),
    };
  }
}

class SelectedPluginAgents extends SelectedPluginComponents {
  SelectedPluginAgents(
    CloudStore store,
    String tenant,
    Object? selections, {
    bool discover = false,
    Iterable<String> excludedIds = const [],
  }) : super(
         store,
         tenant,
         selections,
         componentType: 'agent',
         refreshVersion: PluginAgentDefinition.refreshVersion,
         discover: discover,
         discoverSiblingComponents: true,
         excludedIds: excludedIds,
       );
  PluginAgentDefinition definition(String alias) {
    final entry = entries[alias];
    if (entry == null) throw StateError('Agent 不在本次可用插件中');
    final bytes = files(alias)[entry['source_path']];
    if (bytes == null) throw StateError('Agent 定义文件缺失');
    return PluginAgentDefinition.parse(entry['source_path'].toString(), bytes);
  }
}
