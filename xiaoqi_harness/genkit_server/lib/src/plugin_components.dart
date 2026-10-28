import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'capability_import_service.dart';
import 'store.dart';

class SelectedPluginComponents {
  SelectedPluginComponents(
    this.store,
    this.tenant,
    Object? selections, {
    required this.componentType,
    required Map Function(CloudStore, String, String, Map) refreshVersion,
    bool discover = false,
    bool discoverSiblingComponents = false,
    Iterable<String> excludedIds = const [],
  }) {
    final references = (selections is List ? selections : const [])
        .whereType<Map>()
        .toList();
    if (discover && discoverSiblingComponents) {
      references.addAll([
        for (final reference in [...references])
          if (reference['component_id'] != null)
            {'id': reference['id'], 'version_id': reference['version_id']},
      ]);
    }
    final selected = references.map((r) => r['id']).toSet();
    if (discover) {
      for (final (_, document) in store.list('cap/$tenant/', limit: 500)) {
        final value = document.value;
        if (value['kind'] != 'plugin' ||
            selected.contains(value['id']) ||
            excludedIds.contains(value['id']) ||
            value['enabled'] == false ||
            value['deleted_at'] != null)
          continue;
        references.add({
          'id': value['id'],
          'version_id': value['current_version_id'],
        });
      }
    }
    for (final selection in references) {
      final id = selection['id']?.toString() ?? '';
      final record = store.get('cap/$tenant/$id')?.value;
      if (record == null ||
          record['kind'] != 'plugin' ||
          record['enabled'] == false ||
          record['deleted_at'] != null)
        continue;
      var version =
          (record['versions'] is List ? record['versions'] as List : const [])
              .whereType<Map>()
              .where((v) => v['id'] == selection['version_id'])
              .firstOrNull;
      if (version == null)
        continue; // Existing selection failure reporting owns this.
      try {
        version = refreshVersion(store, tenant, id, version);
      } on Object {
        continue;
      } // One unavailable package must not hide healthy plugins.
      for (final component
          in (version['components'] is List
                  ? version['components'] as List
                  : const [])
              .whereType<Map>()) {
        if (component['type'] != componentType ||
            component['status'] == 'unsupported' ||
            (selection['component_id'] != null &&
                selection['component_id'] != component['id']))
          continue;
        final alias =
            '$componentType-${sha256.convert(utf8.encode('$id/${version['id']}/${component['id']}')).toString().substring(0, 24)}';
        entries[alias] = {
          'id': alias,
          'parent_id': id,
          'version_id': version['id'],
          'component_id': component['id'],
          'root': component['root'],
          'source_path': component['source_path'],
          'artifact_key': version['artifact_key'],
          'name': component['name'],
          'description': component['description'],
          'plugin_name': record['name'],
          'user_only': component['user_only'] == true,
          'has_scripts': component['has_scripts'] == true,
          'explicit_component':
              entries[alias]?['explicit_component'] == true ||
              selection['component_id'] == component['id'],
        };
      }
    }
  }
  final String componentType;
  final CloudStore store;
  final String tenant;
  final entries = <String, Map<String, dynamic>>{};
  final _packages = <String, Map<String, List<int>>>{};

  String fingerprint(String alias) {
    final entry = entries[alias];
    if (entry == null) throw StateError('命令不在本次选择的插件中');
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              for (final key in [
                'parent_id',
                'version_id',
                'component_id',
                'root',
                'source_path',
                'artifact_key',
              ])
                key: entry[key],
            }),
          ),
        )
        .toString();
  }

  String namespace(String alias) {
    final package = files(alias);
    // Same manifest order as installation; display-name edits never rename a
    // declared command namespace. Manually created records may lack a manifest.
    for (final path in [
      'plugin.json',
      '.claude-plugin/plugin.json',
      '.codex-plugin/plugin.json',
    ]) {
      final bytes = package[path];
      if (bytes == null) continue;
      final manifest = jsonDecode(utf8.decode(bytes));
      if (manifest is! Map ||
          manifest['name'] is! String ||
          (manifest['name'] as String).trim().isEmpty) {
        throw const FormatException('插件命令名称空间声明无效');
      }
      return manifest['name'] as String;
    }
    return entries[alias]!['plugin_name'].toString();
  }

  Map<String, List<int>> files(String alias) {
    final entry = entries[alias];
    if (entry == null) throw StateError('命令不在本次选择的插件中');
    final record = store.get('cap/$tenant/${entry['parent_id']}')?.value;
    final version = (record?['versions'] as List? ?? const [])
        .whereType<Map>()
        .where(
          (v) =>
              v['id'] == entry['version_id'] &&
              v['artifact_key'] == entry['artifact_key'],
        )
        .firstOrNull;
    if (record == null ||
        record['enabled'] == false ||
        record['deleted_at'] != null ||
        version == null ||
        !(version['components'] as List? ?? const []).whereType<Map>().any(
          (c) =>
              c['id'] == entry['component_id'] &&
              c['type'] == componentType &&
              c['root'] == entry['root'] &&
              c['source_path'] == entry['source_path'] &&
              c['status'] != 'unsupported',
        )) {
      throw StateError('插件命令或绑定版本已失效，请重新选择');
    }
    return CapabilityImportService.subtree(
      _packages.putIfAbsent(
        entry['artifact_key'].toString(),
        () => store.getImmutable(entry['artifact_key'].toString()),
      ),
      entry['root'].toString(),
    );
  }
}
