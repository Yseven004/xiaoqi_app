import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/official_catalog.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/skill_market.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

Map<String, dynamic> _release(
  String id,
  String version, {
  List<String> capabilities = const [],
}) => {
  'id': id,
  'version': version,
  'type': 'skill',
  'display_name': '测试能力',
  'description': '用于能力包目录测试。',
  'host_api': 1,
  'required_tools': ['read_skill_resource'],
  'runtime': <String, dynamic>{},
  'capabilities': capabilities,
  'mcp': null,
  'source_commit': 'a' * 40,
  'asset_sha256': 'b' * 64,
  'asset_url':
      'https://github.com/Yseven004/xiaoqi-capabilities/releases/download/$id-v$version/$id.zip',
};

Map<String, List<int>> _packageFiles(
  String id,
  String version, {
  String content = '测试内容',
  List<String> capabilities = const [],
}) {
  final release = _release(id, version, capabilities: capabilities);
  final manifest = {
    for (final key in [
      'id',
      'version',
      'type',
      'display_name',
      'description',
      'host_api',
      'required_tools',
      'runtime',
      'capabilities',
      'mcp',
    ])
      key: release[key],
  };
  return {
    'PROVENANCE.json': utf8.encode(
      jsonEncode({
        'author': '测试维护者',
        'copyright': '测试材料',
        'license': 'MIT',
        'version': version,
        'original': true,
        'repository': 'https://github.com/Yseven004/xiaoqi-capabilities',
        'adaptation': '仅用于自动化测试。',
        'limitations': '无。',
      }),
    ),
    'LICENSE.md': utf8.encode('MIT'),
    'xiaoqi-capability.json': utf8.encode(jsonEncode(manifest)),
    'SKILL.md': utf8.encode(
      '---\nname: test-capability\ndescription: 用于能力包测试。\n---\n$content\n',
    ),
  };
}

void main() {
  late Directory directory;
  late CloudStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('official-catalog-');
    store = CloudStore(root: directory.path);
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  test('official package index permits the staged first release', () {
    final catalog = {
      'schema_version': 1,
      'repository': 'Yseven004/xiaoqi-capabilities',
      'packages': [_release('study-notes-studio', '1.0.0')],
    };
    final rows = validateOfficialCatalogPayload(catalog);
    expect(rows, hasLength(1));
    expect(rows.single['id'], 'study-notes-studio');
    expect(
      validateOfficialCatalogPayload({...catalog, 'packages': []}),
      isEmpty,
    );
    expect(
      () => validateOfficialCatalogPayload({
        ...catalog,
        'packages': [_release('unapproved-package', '1.0.0')],
      }),
      throwsFormatException,
    );
  });

  test('verified package release is installed as a curated version', () {
    final release = _release('study-notes-studio', '1.0.0');
    final files = _packageFiles('study-notes-studio', '1.0.0');
    final change = installOfficialPackage(
      store,
      packageId: 'study-notes-studio',
      files: files,
      release: release,
    );
    expect(change['updated'], isTrue);
    final publicId = SkillMarket.publicationId(
      '_official-curated',
      'study-notes-studio',
    );
    final publication = store.get('skill-market/$publicId')!;
    expect(publication.value['owner_tenant'], '_official-curated');
    expect(
      SkillMarket(store).listing(publication, 'alice')['curated_capability_id'],
      'study-notes-studio',
    );
    expect(
      (publication.value['record'] as Map)['current_version_id'],
      startsWith('release-1.0.0-'),
    );
    expect(
      installOfficialPackage(
        store,
        packageId: 'study-notes-studio',
        files: files,
        release: release,
      )['updated'],
      isFalse,
    );
    expect(store.get('skill-market/$publicId')!.revision, publication.revision);
    final installed = SkillMarket(
      store,
    ).install('alice', publicId, publication.revision);
    expect(installed.value['curated_capability_id'], 'study-notes-studio');
    final selected = SelectedSkills(store, 'alice', [
      {
        'id': installed.value['id'],
        'version_id': installed.value['current_version_id'],
      },
    ]);
    expect(
      utf8.decode(selected.files(selected.entries.values.single)['SKILL.md']!),
      contains('测试内容'),
    );
  });

  test('ordinary publication cannot impersonate curated source', () {
    store.putImmutable('test/package.zip', {'SKILL.md': utf8.encode('test')});
    store.put('cap/alice/test', {
      'id': 'test',
      'kind': 'skill',
      'origin': 'local',
      'owner_tenant': 'alice',
      'description': 'Test',
      'name': 'test',
      'current_version_id': 'v1',
      'source': {'official': true, 'curated_by': '第七世界'},
      'curated_by': '第七世界',
      'provenance': {'author': 'forged'},
      'presentation': {'title': 'Test'},
      'versions': [
        {'id': 'v1', 'artifact_key': 'test/package.zip'},
      ],
    }, null);
    final market = SkillMarket(store);
    final publication = market.publish('alice', 'test', 1, 0);
    final forged = SelectedSkills(store, 'alice', [
      {'id': 'test', 'version_id': 'v1'},
    ]);
    expect(forged.permitsGeneratedCode(forged.entries.keys), isFalse);
    expect((publication.value['record'] as Map)['curated_by'], isNull);
    expect(market.listing(publication, 'bob')['curated_by'], isNull);
    expect(market.listing(publication, 'bob')['curated_capability_id'], isNull);
    final installed = market.install('bob', publication.value['id'], 1);
    expect((installed.value['source'] as Map)['curated_by'], isNull);
    expect((installed.value['source'] as Map)['official'], isNull);
    expect(installed.value['curated_capability_id'], isNull);
  });

  test(
    'market upgrades keep prior package versions and installation choices',
    () {
      final first = <String, dynamic>{
        'id': 'published-skill',
        'kind': 'skill',
        'name': 'Published skill',
        'description': 'Example',
        'origin': 'market',
        'enabled': true,
        'show_in_menu': true,
        'current_version_id': 'version-a',
        'versions': [
          {
            'id': 'version-a',
            'number': 1,
            'artifact_key': 'package-v1.zip',
            'content_hash': 'a' * 64,
          },
        ],
      };
      final firstVersion = Map<String, dynamic>.from(
        (first['versions'] as List).first as Map,
      );
      store.put('skill-market/publication', {
        'id': 'publication',
        'owner_tenant': 'alice',
        'capability_id': 'published-skill',
        'author': 'alice',
        'record': first,
      }, null);
      final market = SkillMarket(store);
      final installed = market.install('bob', 'publication', 1);
      final custom = Map<String, dynamic>.from(installed.value)
        ..['enabled'] = false
        ..['show_in_menu'] = false;
      final saved = store.put(
        'cap/bob/market-publication',
        custom,
        installed.revision,
      );

      final secondVersion = {
        ...firstVersion,
        'id': 'version-b',
        'number': 2,
        'artifact_key': 'package-v2.zip',
      };
      final second = {
        ...first,
        'current_version_id': 'version-b',
        'versions': [firstVersion, secondVersion],
      };
      final updatedPublication = store.put('skill-market/publication', {
        'id': 'publication',
        'owner_tenant': 'alice',
        'capability_id': 'published-skill',
        'author': 'alice',
        'record': second,
      }, 1);
      final upgraded = market.install(
        'bob',
        'publication',
        updatedPublication.revision,
      );

      expect(upgraded.value['current_version_id'], 'version-b');
      expect(
        (upgraded.value['versions'] as List).map((v) => v['id']),
        containsAll(['version-a', 'version-b']),
      );
      expect(upgraded.value['enabled'], isFalse);
      expect(upgraded.value['show_in_menu'], isFalse);
      expect(upgraded.revision, saved.revision + 1);
    },
  );

  test(
    'an independently released package adds a version without auto-updating users',
    () {
      installOfficialPackage(
        store,
        packageId: 'study-notes-studio',
        files: _packageFiles('study-notes-studio', '1.0.0'),
        release: _release('study-notes-studio', '1.0.0'),
      );
      final id = SkillMarket.publicationId(
        '_official-curated',
        'study-notes-studio',
      );
      final firstPublication = store.get('skill-market/$id')!;
      final market = SkillMarket(store);
      final installed = market.install('alice', id, firstPublication.revision);
      final disabled = store.put('cap/alice/market-$id', {
        ...installed.value,
        'enabled': false,
        'show_in_menu': false,
      }, installed.revision);

      final metadata = _release('study-notes-studio', '1.0.1');
      final files = _packageFiles(
        'study-notes-studio',
        '1.0.1',
        content: '新版本内容',
      );
      installOfficialPackage(
        store,
        packageId: 'study-notes-studio',
        files: files,
        release: metadata,
      );

      final afterPublish = store.get('skill-market/$id')!;
      expect(afterPublish.revision, firstPublication.revision + 1);
      expect((afterPublish.value['record'] as Map)['versions'], hasLength(2));
      expect(
        store.get('cap/alice/market-$id')!.value['current_version_id'],
        installed.value['current_version_id'],
      );
      final updated = market.install('alice', id, afterPublish.revision);
      expect(updated.value['current_version_id'], startsWith('release-1.0.1-'));
      expect(
        (updated.value['versions'] as List).map((version) => version['id']),
        contains(installed.value['current_version_id']),
      );
      expect(updated.value['enabled'], isFalse);
      expect(updated.value['show_in_menu'], isFalse);
      expect(updated.revision, disabled.revision + 1);

      final futurePackage = 'future-study-capability';
      final futureFiles = _packageFiles(futurePackage, '1.0.0');
      final futureMetadata = _release(futurePackage, '1.0.0');
      installOfficialPackage(
        store,
        packageId: futurePackage,
        files: futureFiles,
        release: futureMetadata,
      );
      final futureId = SkillMarket.publicationId(
        '_official-curated',
        futurePackage,
      );
      expect(
        store.get('skill-market/$futureId')!.value['capability_id'],
        futurePackage,
      );
    },
  );

  test('host claims belong to a trusted package version and are immutable', () {
    final firstRelease = _release(
      'future-capability',
      '1.0.0',
      capabilities: ['learning_notes.append'],
    );
    final firstFiles = _packageFiles(
      'future-capability',
      '1.0.0',
      content: '旧版说明',
      capabilities: ['learning_notes.append'],
    );
    installOfficialPackage(
      store,
      packageId: 'future-capability',
      files: firstFiles,
      release: firstRelease,
    );
    final publicationId = SkillMarket.publicationId(
      '_official-curated',
      'future-capability',
    );
    var publication = store.get('skill-market/$publicationId')!;
    var installed = SkillMarket(
      store,
    ).install('alice', publicationId, publication.revision);
    final oldVersion = installed.value['current_version_id'] as String;
    final oldWork = SelectedSkills(store, 'alice', [
      {'id': installed.value['id'], 'version_id': oldVersion},
    ]);
    expect(
      oldWork.hasCapabilityClaim('learning_notes.append', oldWork.entries.keys),
      isTrue,
    );

    installOfficialPackage(
      store,
      packageId: 'future-capability',
      files: _packageFiles('future-capability', '1.1.0', content: '新版说明'),
      release: _release('future-capability', '1.1.0'),
    );
    publication = store.get('skill-market/$publicationId')!;
    installed = SkillMarket(
      store,
    ).install('alice', publicationId, publication.revision);
    final newVersion = installed.value['current_version_id'] as String;
    final newWork = SelectedSkills(store, 'alice', [
      {'id': installed.value['id'], 'version_id': newVersion},
    ]);
    expect(
      newWork.hasCapabilityClaim('learning_notes.append', newWork.entries.keys),
      isFalse,
    );
    expect(
      oldWork.hasCapabilityClaim('learning_notes.append', oldWork.entries.keys),
      isTrue,
    );

    final revision = store.get('skill-market/$publicationId')!.revision;
    expect(
      () => installOfficialPackage(
        store,
        packageId: 'future-capability',
        files: _packageFiles(
          'future-capability',
          '1.1.0',
          content: '新版说明',
          capabilities: ['learning_notes.append'],
        ),
        release: _release(
          'future-capability',
          '1.1.0',
          capabilities: ['learning_notes.append'],
        ),
      ),
      throwsFormatException,
    );
    expect(store.get('skill-market/$publicationId')!.revision, revision);
  });

  test('documentation access still refuses traversal and root scripts', () {
    for (final path in [
      '../SKILL.md',
      '/etc/passwd',
      'handbook/../SKILL.md',
      'scripts/extract.py',
      'extract.py',
      'C:\\private\\SKILL.md',
      'handbook//rules.md',
      './UPSTREAM-SKILL.md',
    ]) {
      expect(
        () => GenkitXiaoqiAgentRuntime.safeSkillResourcePath(path),
        throwsFormatException,
      );
    }
  });
}
