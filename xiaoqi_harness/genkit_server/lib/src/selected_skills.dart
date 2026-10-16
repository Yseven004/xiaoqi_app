import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'capability_import_service.dart';
import 'store.dart';

/// A turn-local allow-list. A model-provided ID can only address this list,
/// never another installation, tenant, or version.
class SelectedSkills {
  SelectedSkills(this.store, this.tenant, Object? selections) {
    if (selections == null) return;
    if (selections is! List || selections.length > 16) {
      throw const FormatException('一次最多选择 16 个技能或插件');
    }
    for (final raw in selections) {
      if (raw is! Map) throw const FormatException('扩展引用格式无效');
      final id = _id(raw['id']);
      final versionId = _id(raw['version_id']);
      final record = _record(id);
      final version = (record['versions'] as List)
          .whereType<Map>()
          .where((v) => v['id'] == versionId)
          .firstOrNull;
      if (version == null) throw StateError('扩展版本不存在，请刷新后重新选择');
      final components = record['origin'] == 'github'
          ? (version['components'] as List).whereType<Map>().toList()
          : <Map>[
              {
                'id': 'legacy',
                'root': '',
                'name': record['name'],
                'description': record['description'],
              },
            ];
      final componentId = raw['component_id'];
      if (componentId != null &&
          !components.any((c) => c['id'] == componentId)) {
        throw StateError('插件组件不存在或暂不支持');
      }
      for (final component in components) {
        if (componentId != null && component['id'] != componentId) continue;
        final alias =
            'skill-${sha256.convert(utf8.encode('$id/$versionId/${component['id']}')).toString().substring(0, 24)}';
        entries[alias] = {
          'id': alias,
          'parent_id': id,
          'version_id': versionId,
          'component_id': component['id'].toString(),
          'root': component['root'].toString(),
          'name': component['name']?.toString() ?? record['name'].toString(),
          'description': component['description']?.toString() ?? '',
          'artifact_key': version['artifact_key'].toString(),
        };
      }
    }
    if (entries.length > 32)
      throw const FormatException('本次选择包含超过 32 个技能，请分次选择');
  }

  final CloudStore store;
  final String tenant;
  final entries = <String, Map<String, String>>{};
  static String _id(Object? value) {
    final id = value?.toString() ?? '';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id)) {
      throw const FormatException('扩展 ID 或版本 ID 无效');
    }
    return id;
  }

  Map<String, dynamic> _record(String id) {
    final record = store.get('cap/$tenant/$id')?.value;
    if (record == null ||
        record['deleted_at'] != null ||
        record['enabled'] == false) {
      throw StateError('扩展不存在、已卸载或已停用');
    }
    return record;
  }

  Map<String, String> resolve(Map<String, dynamic> input) {
    final alias = input['skill_id']?.toString() ?? '';
    final entry =
        entries[alias] ??
        (alias.isEmpty && entries.length == 1 ? entries.values.single : null);
    if (entry == null) throw StateError('只能使用本次选中的技能，请使用目录中的技能 ID');
    _record(entry['parent_id']!);
    if (input['version_id'] != null &&
        input['version_id'] != entry['version_id']) {
      throw StateError('技能版本与本次绑定版本不一致');
    }
    return entry;
  }

  Map<String, List<int>> files(Map entry) {
    final bound = entries[entry['id']];
    if (bound == null) throw StateError('技能未获本次任务授权');
    _record(bound['parent_id']!);
    return CapabilityImportService.subtree(
      store.getImmutable(bound['artifact_key']!),
      bound['root']!,
    );
  }
}
