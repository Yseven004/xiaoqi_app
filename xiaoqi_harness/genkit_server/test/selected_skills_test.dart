import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory root;
  late CloudStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('xiaoqi-selected-skills-');
    store = CloudStore(root: root.path);
    store.putImmutable('artifacts/older', {
      'skills/example/SKILL.md': utf8.encode('older exact version'),
    });
    store.putImmutable('artifacts/current', {
      'skills/example/SKILL.md': utf8.encode('current version'),
    });
    store.put('cap/tenant-a/example-skill', {
      'id': 'example-skill',
      'name': 'Example skill',
      'enabled': true,
      'origin': 'github',
      'current_version_id': 'v-current',
      'versions': [
        {
          'id': 'v-old',
          'artifact_key': 'artifacts/older',
          'components': [
            {
              'id': 'example-component',
              'root': 'skills/example',
              'name': 'Example component',
              'description': '',
            },
          ],
        },
        {
          'id': 'v-current',
          'artifact_key': 'artifacts/current',
          'components': [
            {
              'id': 'example-component',
              'root': 'skills/example',
              'name': 'Example component',
              'description': '',
            },
          ],
        },
      ],
    }, null);
  });

  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });

  test('loads the exact selected plugin component version from the server', () {
    final selected = SelectedSkills(store, 'tenant-a', [
      {
        'id': 'example-skill',
        'component_id': 'example-component',
        'version_id': 'v-old',
      },
    ]);
    final alias = selected.entries.keys.single;
    final binding = selected.resolve({
      'skill_id': alias,
      'version_id': 'v-old',
    });

    expect(binding['version_id'], 'v-old');
    expect(
      utf8.decode(selected.files(binding)['SKILL.md']!),
      'older exact version',
    );
  });
}
