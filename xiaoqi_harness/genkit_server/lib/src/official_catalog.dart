import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'capability_import_service.dart';
import 'skill_market.dart';
import 'store.dart';

const _catalogUri =
    'https://raw.githubusercontent.com/Yseven004/xiaoqi-capabilities/main/catalog.json';
const _catalogRepository = 'Yseven004/xiaoqi-capabilities';
const _curatedTenant = '_official-curated';
const _packageTitles = {
  'study-notes-studio': 'Study Notes Studio · 学霸笔记图',
  'book-to-skill': 'Book to Skill · 书籍转技能',
  'original-reading-annotations': '原文批注笔记',
  'learning-notes-manager': '学习笔记管家',
};
const _hostTools = {
  'read_skill_resource',
  'execute_skill_script',
  'set_task_deliverables',
  'generate_image',
  'append_learning_notes',
};
const _capabilityClaims = {'image.annotate_original', 'learning_notes.append'};

Map<String, dynamic> _inspection(Map<String, List<int>> files) =>
    files.containsKey('plugin.json')
    ? CapabilityImportService.discover(files, '').single
    : CapabilityImportService.inspectSkill(files, '');

/// Atomically add or update one package after its release archive is verified.
Map<String, dynamic> installOfficialPackage(
  CloudStore store, {
  required String packageId,
  required Map<String, List<int>> files,
  required Map<String, dynamic> release,
}) {
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{1,63}$').hasMatch(packageId) ||
      release['id'] != packageId) {
    throw const FormatException('精选包标识无效');
  }
  _validateReleaseRow(release);
  final inspection = _inspection(files);
  if (inspection['status'] != 'supported' ||
      !files.containsKey('PROVENANCE.json') ||
      !files.keys.any((key) => key.toLowerCase().startsWith('license'))) {
    throw FormatException('精选能力包检查失败：$packageId ${inspection['issues']}');
  }
  _validatePackageMetadata(packageId, files, release);
  final provenance = jsonDecode(utf8.decode(files['PROVENANCE.json']!)) as Map;
  final manifest =
      jsonDecode(utf8.decode(files['xiaoqi-capability.json']!)) as Map;
  final original = provenance['original'] == true;
  final components = files.containsKey('plugin.json')
      ? (inspection['components'] as List)
            .whereType<Map>()
            .map(
              (component) => {
                ...component,
                'type': component['type'] ?? 'skill',
              },
            )
            .toList()
      : [
          {...inspection, 'type': 'skill'},
        ];
  final digest = CapabilityImportService.digestFiles(files);
  final version = 'release-${release['version']}-${digest.substring(0, 16)}';
  final publicId = SkillMarket.publicationId(_curatedTenant, packageId);
  final key = 'skill-market/$publicId';
  final previous = store.get(key);
  if (previous != null && previous.value['owner_tenant'] != _curatedTenant) {
    throw const FormatException('精选能力标识冲突，现有目录保持不变');
  }
  final previousRecord = previous?.value['record'] as Map?;
  final previousRelease = previous?.value['capability_release'];
  if (previousRelease is Map &&
      previousRelease['version'] == release['version'] &&
      !_jsonEqual(previousRelease, release)) {
    throw const FormatException('已发布能力包版本不可变，现有目录保持不变');
  }
  final oldVersions = <String, Map<String, dynamic>>{};
  for (final raw in previousRecord?['versions'] as List? ?? const []) {
    if (raw is Map && raw['id'] is String) {
      oldVersions[raw['id'] as String] = Map<String, dynamic>.from(raw);
    }
  }
  final number = int.parse((release['version'] as String).split('.').first);
  final artifact = 'official-catalog/$packageId/$digest.zip';
  if (previous?.value['capability_release'] is Map &&
      (previous!.value['capability_release'] as Map)['version'] ==
          release['version'] &&
      previousRecord?['current_version_id'] == version &&
      oldVersions[version]?['content_hash'] == digest) {
    return {
      'updated': false,
      'version': release['version'],
      'document_revision': previous.revision,
      'artifact_key': artifact,
    };
  }
  final versionRecord = <String, dynamic>{
    'id': version,
    'number': number,
    'version_label': release['version'],
    'capability_release': release,
    'content': files.containsKey('plugin.json')
        ? ''
        : utf8.decode(files['SKILL.md']!),
    'content_hash': digest,
    'created_at': DateTime.now().toUtc().toIso8601String(),
    'artifact_key': artifact,
    'components': components,
  };
  final priorVersion = oldVersions[version];
  if (priorVersion != null && priorVersion['artifact_key'] != artifact) {
    throw const FormatException('已发布版本的内容发生变化，现有目录保持不变');
  }
  oldVersions[version] = versionRecord;
  store.putImmutable(artifact, files);
  final now = DateTime.now().toUtc().toIso8601String();
  final title = (manifest['display_name'] as String).trim();
  final description = (manifest['description'] as String).trim();
  final presentation = normalizeSkillPresentation({
    'title': title,
    'introduction': original
        ? '第七世界官方原创\n\n${provenance['adaptation']}\n\n${provenance['limitations']}'
        : '第七世界官方精选开源能力\n'
              '原作者：${provenance['author']} · ${provenance['license']}\n'
              '版权署名：${provenance['copyright']}\n'
              '来源：${provenance['repository']}\n'
              '固定版本：${provenance['version']} (${provenance['commit']})\n\n'
              '${provenance['adaptation']}\n\n'
              '按能力包说明使用小七现有工具；需要授权的操作仍由小七检查。',
    'icon_asset': 'book',
  });
  final saved = store.put(key, {
    'id': publicId,
    'owner_tenant': _curatedTenant,
    'capability_id': packageId,
    'author': provenance['author'],
    if (!original) 'curated_by': '第七世界',
    'provenance': provenance,
    'capability_release': release,
    'published_at': previous?.value['published_at'] ?? now,
    'record': {
      'schema_version': 2,
      'id': packageId,
      'kind': manifest['type'],
      'name': packageId,
      'description': description,
      'origin': 'market',
      'enabled': previousRecord?['enabled'] ?? true,
      'show_in_menu': previousRecord?['show_in_menu'] ?? true,
      'installation_state': 'installed',
      'created_at': previousRecord?['created_at'] ?? now,
      'updated_at': now,
      'current_version_id': version,
      'versions': oldVersions.values.toList(),
      'capability_release': release,
      'presentation': presentation,
    },
  }, previous?.revision);
  return {
    'updated': true,
    'version': release['version'],
    'document_revision': saved.revision,
    'artifact_key': artifact,
  };
}

Future<Map<String, dynamic>> refreshOfficialCapability(
  CloudStore store,
  String publicationId,
) async {
  final publication = store.get('skill-market/$publicationId');
  if (publication == null ||
      publication.value['owner_tenant'] != _curatedTenant) {
    throw const FormatException('只有官方维护的能力包支持在线检查更新');
  }
  final packageId = publication.value['capability_id']?.toString() ?? '';
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{1,63}$').hasMatch(packageId)) {
    throw const FormatException('官方能力包标识无效');
  }
  final rows = await _fetchOfficialCatalog();
  final metadata = rows.where((row) => row['id'] == packageId).firstOrNull;
  if (metadata == null) throw const FormatException('官方能力索引中没有此能力包');
  return _refreshPackage(store, metadata);
}

/// Refresh package publications from the maintainer feed. It updates only the
/// server catalog; installations still require a user's explicit action.
Future<Map<String, dynamic>> refreshOfficialCatalog(CloudStore store) async {
  final rows = await _fetchOfficialCatalog();
  var updated = 0;
  final failed = <String>[];
  for (var start = 0; start < rows.length; start += 3) {
    final batch = rows.skip(start).take(3);
    final outcomes = await Future.wait(
      batch.map((row) async {
        try {
          final result = await _refreshPackage(store, row);
          return (
            id: row['id'].toString(),
            updated: result['updated'] == true,
            error: null as Object?,
          );
        } on Object catch (error) {
          return (id: row['id'].toString(), updated: false, error: error);
        }
      }),
    );
    for (final outcome in outcomes) {
      if (outcome.error == null) {
        if (outcome.updated) updated++;
        continue;
      }
      failed.add(outcome.id);
      stderr.writeln(
        'OFFICIAL_CAPABILITY_REFRESH_FAILED package=${outcome.id} error=${outcome.error}',
      );
    }
  }
  return {'updated_count': updated, 'failed_packages': failed};
}

Future<List<Map<String, dynamic>>> _fetchOfficialCatalog() async {
  final catalogBytes = await _getHttpsBytes(
    Uri.parse(_catalogUri),
    maxBytes: 256 * 1024,
    allowedHosts: const {'raw.githubusercontent.com'},
  );
  final catalog = jsonDecode(utf8.decode(catalogBytes));
  return validateOfficialCatalogPayload(catalog);
}

/// Validate the publisher index while allowing staged package migration.
/// Existing curated publications remain available when a later package has
/// not been released yet.
List<Map<String, dynamic>> validateOfficialCatalogPayload(Object? catalog) {
  if (catalog is! Map ||
      catalog['schema_version'] != 1 ||
      catalog['repository'] != _catalogRepository ||
      catalog['packages'] is! List) {
    throw const FormatException('官方能力索引格式无效');
  }
  final rawRows = catalog['packages'] as List;
  if (rawRows.length > 100 || rawRows.any((row) => row is! Map)) {
    throw const FormatException('官方能力索引条目无效');
  }
  final rows = rawRows
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList(growable: false);
  final ids = rows.map((row) => row['id']).toSet();
  if (ids.length != rows.length ||
      ids.any(
        (id) =>
            id is! String ||
            !_packageTitles.containsKey(id) ||
            !RegExp(r'^[a-z0-9][a-z0-9-]{1,63}$').hasMatch(id),
      )) {
    throw const FormatException('官方能力索引包含重复或未批准的能力包');
  }
  for (final row in rows) {
    _validateReleaseRow(row);
  }
  return rows;
}

Map<String, dynamic> _validateReleaseRow(Map<String, dynamic> metadata) {
  final packageId = metadata['id']?.toString() ?? '';
  final version = metadata['version']?.toString() ?? '';
  if (!_isSemver(version) ||
      metadata['type'] != 'skill' && metadata['type'] != 'plugin' ||
      metadata['host_api'] != 1 ||
      metadata['required_tools'] is! List ||
      metadata['capabilities'] is! List ||
      metadata['runtime'] is! Map ||
      metadata['mcp'] != null && metadata['mcp'] is! Map ||
      metadata['source_commit'] is! String ||
      !RegExp(
        r'^[a-f0-9]{40}$',
      ).hasMatch(metadata['source_commit'] as String) ||
      metadata['asset_sha256'] is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(metadata['asset_sha256'] as String)) {
    throw const FormatException('官方能力包版本信息无效');
  }
  final expectedUrl =
      'https://github.com/$_catalogRepository/releases/download/$packageId-v$version/$packageId.zip';
  if (metadata['asset_url'] != expectedUrl) {
    throw const FormatException('官方能力包下载地址不符合仓库约定');
  }
  final tools = (metadata['required_tools'] as List)
      .map((value) => value.toString())
      .toSet();
  final capabilities = (metadata['capabilities'] as List)
      .map((value) => value.toString())
      .toSet();
  if (tools.length != (metadata['required_tools'] as List).length ||
      !tools.every(_hostTools.contains) ||
      capabilities.length != (metadata['capabilities'] as List).length ||
      !capabilities.every(_capabilityClaims.contains)) {
    throw const FormatException('官方能力包声明了不受支持的工具或能力');
  }
  return metadata;
}

Future<Map<String, dynamic>> _refreshPackage(
  CloudStore store,
  Map<String, dynamic> metadata,
) async {
  _validateReleaseRow(metadata);
  final packageId = metadata['id'] as String;
  final version = metadata['version'] as String;
  final expectedUrl = metadata['asset_url'] as String;
  final publicationId = SkillMarket.publicationId(_curatedTenant, packageId);
  final publication = store.get('skill-market/$publicationId');
  if (publication != null &&
      publication.value['owner_tenant'] != _curatedTenant) {
    throw const FormatException('精选能力标识冲突，现有目录保持不变');
  }
  final currentVersion = publication?.value['capability_release'] is Map
      ? (publication!.value['capability_release'] as Map)['version']?.toString()
      : null;
  if (currentVersion == version) {
    if (!_jsonEqual(publication!.value['capability_release'], metadata)) {
      throw const FormatException('已发布能力包版本信息发生变化，现有目录保持不变');
    }
    return {'updated': false, 'version': version};
  }
  if (currentVersion != null && _compareSemver(version, currentVersion) < 0) {
    throw const FormatException('官方目录版本低于当前已发布版本，拒绝降级');
  }

  final archive = await _getHttpsBytes(
    Uri.parse(expectedUrl),
    maxBytes: CapabilityImportService.maxArchiveBytes,
    allowedHosts: const {
      'github.com',
      'release-assets.githubusercontent.com',
      'objects.githubusercontent.com',
    },
  );
  if (sha256.convert(archive).toString() != metadata['asset_sha256']) {
    throw const FormatException('官方能力包校验失败，现有安装保持不变');
  }
  final files = CapabilityImportService.decodeCapabilityRelease(
    packageId,
    archive,
  );
  _validatePackageMetadata(packageId, files, metadata);
  installOfficialPackage(
    store,
    packageId: packageId,
    files: files,
    release: metadata,
  );
  return {'updated': true, 'version': version};
}

void _validatePackageMetadata(
  String packageId,
  Map<String, List<int>> files,
  Map<String, dynamic> release,
) {
  final bytes = files['xiaoqi-capability.json'];
  if (bytes == null) throw const FormatException('能力包缺少小七安装清单');
  final manifest = jsonDecode(utf8.decode(bytes));
  if (manifest is! Map ||
      manifest['id'] != packageId ||
      manifest['version'] != release['version'] ||
      manifest['type'] != release['type'] ||
      manifest['host_api'] != release['host_api'] ||
      manifest['display_name'] is! String ||
      (manifest['display_name'] as String).trim().isEmpty ||
      manifest['description'] is! String ||
      (manifest['description'] as String).trim().isEmpty) {
    throw const FormatException('能力包内容与官方索引不匹配');
  }
  final rawManifestTools = manifest['required_tools'];
  final manifestTools =
      (rawManifestTools is List ? rawManifestTools : const <Object?>[])
          .map((value) => value.toString())
          .toSet();
  final releaseTools = (release['required_tools'] as List? ?? const [])
      .map((value) => value.toString())
      .toSet();
  if (rawManifestTools is! List ||
      rawManifestTools.any((value) => value is! String) ||
      manifestTools.length != rawManifestTools.length ||
      manifestTools.length != releaseTools.length ||
      !manifestTools.containsAll(releaseTools) ||
      !manifestTools.every(_hostTools.contains)) {
    throw const FormatException('能力包声明了不受支持的小七工具');
  }
  final rawManifestCapabilities = manifest['capabilities'];
  final manifestCapabilities =
      (rawManifestCapabilities is List
              ? rawManifestCapabilities
              : const <Object?>[])
          .map((value) => value.toString())
          .toSet();
  final releaseCapabilities = (release['capabilities'] as List? ?? const [])
      .map((value) => value.toString())
      .toSet();
  if (rawManifestCapabilities is! List ||
      rawManifestCapabilities.any((value) => value is! String) ||
      manifestCapabilities.length != rawManifestCapabilities.length ||
      manifestCapabilities.length != releaseCapabilities.length ||
      !manifestCapabilities.containsAll(releaseCapabilities) ||
      !manifestCapabilities.every(_capabilityClaims.contains)) {
    throw const FormatException('能力包声明了不受支持的小七能力');
  }
  if (jsonEncode(manifest['runtime'] ?? {}) !=
          jsonEncode(release['runtime'] ?? {}) ||
      jsonEncode(manifest['mcp']) != jsonEncode(release['mcp'])) {
    throw const FormatException('能力包运行要求与官方索引不匹配');
  }
}

Future<List<int>> _getHttpsBytes(
  Uri uri, {
  required int maxBytes,
  required Set<String> allowedHosts,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    for (var redirects = 0; redirects <= 4; redirects++) {
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          !allowedHosts.contains(uri.host)) {
        throw const FormatException('官方能力下载地址不安全');
      }
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Xiaoqi-Capability-Client',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || redirects == 4) {
          throw const FormatException('官方能力下载重定向无效');
        }
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok ||
          response.contentLength > maxBytes) {
        await response.drain<void>();
        throw const FormatException('官方能力源暂不可用或文件过大');
      }
      Future<List<int>> readBody() async {
        final output = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (output.length + chunk.length > maxBytes) {
            throw const FormatException('官方能力文件超过大小限制');
          }
          output.add(chunk);
        }
        return output.takeBytes();
      }

      return await readBody().timeout(const Duration(seconds: 60));
    }
    throw const FormatException('官方能力下载重定向过多');
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException('连接官方能力仓库失败；当前已安装版本保持不变');
  } finally {
    client.close(force: true);
  }
}

bool _isSemver(String value) =>
    RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$').hasMatch(value);

int _compareSemver(String left, String right) {
  final a = left.split('.').map(int.parse).toList();
  final b = right.split('.').map(int.parse).toList();
  for (var index = 0; index < 3; index++) {
    final compared = a[index].compareTo(b[index]);
    if (compared != 0) return compared;
  }
  return 0;
}

bool _jsonEqual(Object? left, Object? right) =>
    jsonEncode(_canonicalJson(left)) == jsonEncode(_canonicalJson(right));

Object? _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonicalJson(value[key])};
  }
  if (value is List) return value.map(_canonicalJson).toList();
  return value;
}
