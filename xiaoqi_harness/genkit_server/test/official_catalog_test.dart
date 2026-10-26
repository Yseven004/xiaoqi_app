import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/official_catalog.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/skill_market.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

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

  test(
    'curated packages install, resolve all runtime resources and seed once',
    () {
      seedOfficialCatalog(store);
      final market = SkillMarket(store);
      final publications = store.list('skill-market/');
      expect(publications, hasLength(2));
      for (final (_, publication) in publications) {
        final listing = market.listing(publication, 'alice', detail: true);
        expect(listing['curated_by'], '第七世界');
        expect(listing['author'], isNot('第七世界'));
        expect((listing['provenance'] as Map)['license'], 'MIT');
        final installed = market.install(
          'alice',
          listing['id'],
          publication.revision,
        );
        final selected = SelectedSkills(store, 'alice', [
          {
            'id': installed.value['id'],
            'version_id': installed.value['current_version_id'],
          },
        ]);
        final files = selected.files(selected.entries.values.single);
        expect(files['UPSTREAM-SKILL.md'], isNotEmpty);
        expect(
          GenkitXiaoqiAgentRuntime.safeSkillResourcePath('UPSTREAM-SKILL.md'),
          'UPSTREAM-SKILL.md',
        );
        expect(files.keys.any((key) => key.startsWith('LICENSE')), isTrue);
        if (installed.value['name'] == 'book-to-skill') {
          expect(files['scripts/extract.py'], isNotEmpty);
          expect(files['book_to_skill/cli.py'], isNotEmpty);
          expect(
            utf8.decode(files['SKILL.md']!),
            contains('scripts/xiaoqi_extract.py'),
          );
        } else {
          expect(
            GenkitXiaoqiAgentRuntime.safeSkillResourcePath(
              'handbook/coverage-audit.md',
            ),
            'handbook/coverage-audit.md',
          );
          expect(files['handbook/coverage-audit.md'], isNotEmpty);
          expect(utf8.decode(files['SKILL.md']!), contains('generate_image'));
        }
        expect((installed.value['source'] as Map)['curated_by'], '第七世界');
        expect(
          () => market.publish(
            'alice',
            installed.value['id'],
            installed.revision,
            0,
          ),
          throwsFormatException,
        );
      }
      seedOfficialCatalog(store);
      expect(
        store.list('skill-market/').map((e) => e.$2.revision),
        everyElement(1),
      );
    },
  );

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
    expect((publication.value['record'] as Map)['curated_by'], isNull);
    expect(market.listing(publication, 'bob')['curated_by'], isNull);
    final installed = market.install('bob', publication.value['id'], 1);
    expect((installed.value['source'] as Map)['curated_by'], isNull);
    expect((installed.value['source'] as Map)['official'], isNull);
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
