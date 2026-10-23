import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'store.dart';
import 'plugin_dependencies.dart';

const skillIconAssets = {
  'research',
  'file-text',
  'book',
  'code',
  'database',
  'presentation',
  'table',
  'folder',
  'chat',
  'plugs',
  'gear',
  'search',
  'mcp',
  'extension',
};

/// Presentation is data, never HTML, executable SVG or a client-supplied URL.
Map<String, dynamic> normalizeSkillPresentation(Object? raw) {
  if (raw == null) return {};
  if (raw is! Map) throw const FormatException('展示资料格式无效');
  String text(String key, int limit) {
    final value = raw[key]?.toString().trim() ?? '';
    if (value.length > limit) throw FormatException('$key 超过长度限制');
    return value;
  }

  String image(Object? raw, {bool icon = false}) {
    final value = raw?.toString() ?? '';
    if (value.isEmpty) return '';
    final match = RegExp(
      r'^data:image/(png|jpeg|webp|svg\+xml);base64,([A-Za-z0-9+/=]+)$',
    ).firstMatch(value);
    if (match == null)
      throw const FormatException('请选择 PNG、JPEG、WebP 或安全 SVG 图片');
    final bytes = base64Decode(match.group(2)!);
    if (bytes.isEmpty || bytes.length > (icon ? 128 : 512) * 1024) {
      throw FormatException(icon ? '图标不能超过 128 KB' : '单张介绍图片不能超过 512 KB');
    }
    final type = match.group(1);
    bool starts(List<int> signature) =>
        bytes.length >= signature.length &&
        List.generate(
          signature.length,
          (i) => bytes[i] == signature[i],
        ).every((v) => v);
    if (type == 'png' && !starts([137, 80, 78, 71, 13, 10, 26, 10]) ||
        type == 'jpeg' && !starts([255, 216, 255]) ||
        type == 'webp' &&
            !(starts([82, 73, 70, 70]) &&
                bytes.length > 12 &&
                ascii.decode(bytes.sublist(8, 12)) == 'WEBP')) {
      throw const FormatException('图片内容与文件类型不一致');
    }
    if (type == 'svg+xml') {
      final svg = utf8.decode(bytes);
      if (!icon ||
          !RegExp(r'<svg\b').hasMatch(svg) ||
          RegExp(
            r'<!|<\?|\bon\w+\s*=|\bhref\s*=|\bstyle\s*=|url\s*\(',
            caseSensitive: false,
          ).hasMatch(svg) ||
          RegExp(r'<\s*/?\s*([\w:-]+)')
              .allMatches(svg)
              .any(
                (m) => !const {
                  'svg',
                  'g',
                  'path',
                  'rect',
                  'circle',
                  'ellipse',
                  'line',
                  'polyline',
                  'polygon',
                  'title',
                  'desc',
                }.contains(m.group(1)),
              )) {
        throw const FormatException('SVG 仅支持不含脚本、外链和嵌入图片的固定图形');
      }
    }
    return value;
  }

  final asset = raw['icon_asset']?.toString() ?? 'research';
  if (!skillIconAssets.contains(asset))
    throw const FormatException('图标不在可选图标库中');
  final gallery = raw['images'] ?? const [];
  if (gallery is! List || gallery.length > 6)
    throw const FormatException('介绍图片最多 6 张');
  return {
    'title': text('title', 128),
    'introduction': text('introduction', 20000),
    'icon_asset': asset,
    'icon_data': image(raw['icon_data'], icon: true),
    'images': [
      for (final item in gallery)
        if (item is Map)
          {
            'data': image(item['data']),
            'caption': (item['caption']?.toString() ?? '').substring(
              0,
              (item['caption']?.toString() ?? '').length.clamp(0, 200),
            ),
          }
        else
          throw const FormatException('介绍图片格式无效'),
    ],
  };
}

class SkillMarket {
  SkillMarket(this.store);
  final CloudStore store;

  static String publicationId(String tenant, String capabilityId) =>
      sha256.convert(utf8.encode('$tenant/$capabilityId')).toString();

  StoredDocument publish(
    String tenant,
    String id,
    int revision,
    int publishedRevision,
  ) {
    final record = store.get('cap/$tenant/$id');
    if (record == null || record.value['deleted_at'] != null) {
      throw const FormatException('技能不存在');
    }
    if (record.revision != revision) throw const RevisionConflict('skill');
    final value = record.value;
    if (!const {'skill', 'plugin'}.contains(value['kind']) ||
        const {'github', 'upload', 'market'}.contains(value['origin']) ||
        value['owner_tenant'] != tenant) {
      throw const FormatException('只有作者可以发布自己创建的扩展');
    }
    final presentation = normalizeSkillPresentation(value['presentation']);
    if ((presentation['title']?.toString() ?? '').isEmpty ||
        (value['description']?.toString().trim() ?? '').isEmpty) {
      throw const FormatException('请填写展示名称和一句话简介');
    }
    final versionId = value['current_version_id'];
    final versions = (value['versions'] as List? ?? [])
        .whereType<Map>()
        .where((v) => v['id'] == versionId)
        .toList();
    if (versions.length != 1 || versions.single['artifact_key'] == null) {
      throw const FormatException('请先保存完整的技能内容');
    }
    // Verify the immutable package still exists before replacing a public snapshot.
    final package = store.getImmutable(
      versions.single['artifact_key'].toString(),
    );
    if (value['kind'] == 'plugin') {
      // Connection credentials belong to each installer, never a public package.
      void check(Object? config, [String key = '']) {
        if (config is Map) {
          for (final entry in config.entries) {
            check(entry.value, entry.key.toString());
          }
        } else if (config is List) {
          for (final value in config) {
            check(value, key);
          }
        } else if (config is String &&
            RegExp(
              r'authorization|api[_-]?key|token|password|secret',
              caseSensitive: false,
            ).hasMatch(key)) {
          final literal = config
              .replaceAll(RegExp(r'\$\{[A-Za-z_][A-Za-z0-9_]*\}'), '')
              .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '')
              .trim();
          if (literal.isNotEmpty)
            throw const FormatException('发布包不能包含连接凭据，请使用环境变量占位，由安装者单独配置');
        }
      }

      check(PluginDependencies.declarations(package));
    }
    final publicId = publicationId(tenant, id);
    final key = 'skill-market/$publicId';
    final previous = store.get(key);
    if ((previous?.revision ?? 0) != publishedRevision) {
      final published = previous?.value['record'];
      if (published is Map &&
          published['current_version_id'] == versionId &&
          published['name'] == value['name'] &&
          published['description'] == value['description'] &&
          jsonEncode(published['presentation']) == jsonEncode(presentation)) {
        return previous!;
      }
      throw RevisionConflict(key);
    }
    return store.put(key, {
      'id': publicId,
      'owner_tenant': tenant,
      'capability_id': id,
      'author': '小七用户',
      'published_at': DateTime.now().toUtc().toIso8601String(),
      'record': {
        ...value,
        'versions': [Map<String, dynamic>.from(versions.single)],
        'presentation': presentation,
      },
    }, previous?.revision);
  }

  Map<String, dynamic> listing(
    StoredDocument doc,
    String tenant, {
    bool detail = false,
  }) {
    final value = doc.value;
    final record = Map<String, dynamic>.from(value['record'] as Map);
    final presentation = Map<String, dynamic>.from(
      record['presentation'] as Map,
    );
    if (!detail) presentation.remove('images');
    return {
      'id': value['id'],
      'kind': record['kind'],
      'name': record['name'],
      'description': record['description'],
      'author': value['author'],
      'is_owner': value['owner_tenant'] == tenant,
      'publication_revision': doc.revision,
      'presentation': presentation,
      'published_at': value['published_at'],
      'capability_id': value['owner_tenant'] == tenant
          ? value['capability_id']
          : null,
    };
  }

  StoredDocument install(String tenant, String id, int revision) {
    final publication = store.get('skill-market/$id');
    if (publication == null) throw const FormatException('技能未发布或已不可用');
    if (publication.revision != revision)
      throw const RevisionConflict('publication');
    final value = publication.value;
    if (value['owner_tenant'] == tenant) {
      final key = 'cap/$tenant/${value['capability_id']}';
      final own = store.get(key);
      if (own == null) throw const FormatException('作者记录不存在，请从草稿恢复');
      if (own.value['deleted_at'] == null && own.value['enabled'] != false)
        return own;
      return store.put(key, {
        ...own.value,
        'deleted_at': null,
        'enabled': true,
        'show_in_menu': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, own.revision);
    }
    final key = 'cap/$tenant/market-$id';
    final old = store.get(key);
    if (old != null &&
        (old.value['origin'] != 'market' ||
            (old.value['source'] as Map?)?['publication_id'] != id)) {
      throw const FormatException('此安装标识已被其他作品使用，原内容保留');
    }
    final record = Map<String, dynamic>.from(value['record'] as Map)
      ..remove('owner_tenant');
    return store.put(key, {
      ...record,
      'id': 'market-$id',
      'origin': 'market',
      'deleted_at': null,
      'source': {
        'publication_id': id,
        'author': value['author'],
        'publication_revision': revision,
      },
      'enabled': true,
      'show_in_menu': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, old?.revision);
  }
}
