import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'capability_import_service.dart';
import 'skill_market.dart';
import 'store.dart';

/// Only deployment-owned files may create curated publications; no HTTP writer.
void seedOfficialCatalog(CloudStore store, {Directory? directory}) {
  final root = directory ?? Directory('official_catalog');
  const titles = {
    'study-notes-studio': 'Study Notes Studio · 学霸笔记图',
    'book-to-skill': 'Book to Skill · 书籍转技能',
  };
  // Validate every package before changing the live catalog.
  final packages = <String, Map<String, List<int>>>{};
  for (final id in titles.keys) {
    final folder = Directory(p.join(root.path, id));
    final files = <String, List<int>>{};
    for (final entity in folder.listSync(recursive: true, followLinks: false)) {
      if (entity is Link) throw FormatException('精选包禁止符号链接：$id');
      if (entity is File) {
        files[p
            .relative(entity.path, from: folder.path)
            .replaceAll('\\', '/')] = entity
            .readAsBytesSync();
      }
    }
    final inspection = CapabilityImportService.inspectSkill(files, '');
    if (inspection['status'] != 'supported' ||
        !files.containsKey('PROVENANCE.json') ||
        !files.keys.any((key) => key.startsWith('LICENSE'))) {
      throw FormatException('精选技能包检查失败：$id ${inspection['issues']}');
    }
    packages[id] = files;
  }
  for (final entry in packages.entries) {
    final id = entry.key;
    final files = entry.value;
    final provenance =
        jsonDecode(utf8.decode(files['PROVENANCE.json']!)) as Map;
    final inspection = CapabilityImportService.inspectSkill(files, '');
    final digest = CapabilityImportService.digestFiles(files);
    final version = 'curated-${digest.substring(0, 24)}';
    final publicId = SkillMarket.publicationId('_official-curated', id);
    final key = 'skill-market/$publicId';
    final previous = store.get(key);
    if ((previous?.value['record'] as Map?)?['current_version_id'] == version) {
      continue;
    }
    final artifact = 'official-catalog/$id/$digest.zip';
    store.putImmutable(artifact, files);
    final now = DateTime.now().toUtc().toIso8601String();
    store.put(key, {
      'id': publicId,
      'owner_tenant': '_official-curated',
      'capability_id': id,
      'author': provenance['author'],
      'curated_by': '第七世界',
      'provenance': provenance,
      'published_at': now,
      'record': {
        'schema_version': 2,
        'id': id,
        'kind': 'skill',
        'name': id,
        'description': inspection['description'],
        'origin': 'market',
        'enabled': true,
        'show_in_menu': true,
        'installation_state': 'installed',
        'created_at': now,
        'updated_at': now,
        'current_version_id': version,
        'versions': [
          {
            'id': version,
            'number': provenance['adaptation_version'],
            'content': utf8.decode(files['SKILL.md']!),
            'content_hash': digest,
            'created_at': now,
            'artifact_key': artifact,
            'components': [
              {...inspection, 'type': 'skill'},
            ],
          },
        ],
        'presentation': normalizeSkillPresentation({
          'title': titles[id],
          'introduction':
              '第七世界官方精选 · 第三方开源技能\n'
              '原作者：${provenance['author']} · ${provenance['license']}\n'
              '来源：${provenance['repository']}\n'
              '固定版本：${provenance['version']} (${provenance['commit']})\n\n'
              '${provenance['adaptation']}\n\n'
              '${id == 'book-to-skill' ? '生成技能以私有文件包交付，需手动导入；不自动上架。MOBI/AZW 需先转换。' : '生成复习笔记图，需要图片生成额度；长文按预算分页续做，不适用于保留原文的原图批注。'}',
          'icon_asset': 'book',
        }),
      },
    }, previous?.revision);
  }
}
