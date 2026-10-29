import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agents.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agent_skills.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agent_policy.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory root;
  late CloudStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-skill-preload-');
    store = CloudStore(root: root.path);
  });
  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });

  List<Map<String, dynamic>> install(
    String id,
    String declared, {
    bool skill = true,
    bool userOnly = false,
    String? namespace,
    bool twoVersions = false,
  }) {
    Map<String, List<int>> files(String marker) => {
      '.claude-plugin/plugin.json': utf8.encode(
        jsonEncode({'name': namespace ?? id}),
      ),
      'agents/writer.md': utf8.encode(
        '---\nname: writer\ndescription: Test preload\ntools: [Read]\nskills: $declared\n---\nComplete the task.',
      ),
      if (skill)
        'skills/note/SKILL.md': utf8.encode(
          '---\nname: note\ndescription: Note conventions\n${userOnly ? 'disable-model-invocation: true\n' : ''}---\nFULL_$marker',
        ),
      if (skill)
        'skills/note/references/note.md': utf8.encode('RESOURCE_$marker'),
    };
    final first = files('PINNED');
    final components = <Map<String, dynamic>>[
      ...PluginAgentDefinition.inspect(first, '', {}),
      if (skill)
        {
          'id': 'note',
          'root': 'skills/note',
          'name': 'note',
          'description': 'Note conventions',
          'type': 'skill',
          'status': 'supported',
        },
    ];
    store.putImmutable('packages/$id/v1', first);
    if (twoVersions) store.putImmutable('packages/$id/v2', files('CURRENT'));
    store.put('cap/tenant/$id', {
      'id': id,
      'kind': 'plugin',
      'name': 'display-$id',
      'origin': 'upload',
      'enabled': true,
      'current_version_id': twoVersions ? 'v2' : 'v1',
      'versions': [
        for (final version in ['v1', if (twoVersions) 'v2'])
          {
            'id': version,
            'artifact_key': 'packages/$id/$version',
            'components': components,
            'plugin_agent_profile': 1,
          },
      ],
    }, null);
    return components;
  }

  SelectedPluginAgents agents(
    String id,
    List<Map<String, dynamic>> components,
  ) => SelectedPluginAgents(store, 'tenant', [
    {'id': id, 'version_id': 'v1', 'component_id': components.first['id']},
  ]);

  test(
    'selected Agent preloads its pinned sibling without adding an explicit user selection or tools',
    () {
      final components = install('own', '[note]', twoVersions: true);
      final registry = agents('own', components);
      final skills = SelectedSkills(store, 'tenant', [
        {
          'id': 'own',
          'version_id': 'v1',
          'component_id': components.first['id'],
        },
      ]);
      expect(skills.entries, isEmpty);
      final adapter = PluginAgentSkillPreloads(skills, registry);
      final id = registry.entries.keys.single;
      final preload = adapter.forAgent(id);
      expect(preload.instructions, contains('FULL_PINNED'));
      expect(preload.instructions, isNot(contains('FULL_CURRENT')));
      expect(preload.instructions, contains('references/note.md'));
      expect(skills.explicitIds, isEmpty);
      final policy = PluginAgentPolicy.resolve(
        registry.definition(id),
        parentTools: ['read_skill_resource', 'execute_shell'],
        model: 'model',
        skillsPrepared: true,
      );
      expect(policy.issues, isEmpty);
      expect(policy.tools, ['read_skill_resource']);
      expect(
        utf8.decode(
          skills.files(preload.entries.single)['references/note.md']!,
        ),
        'RESOURCE_PINNED',
      );
      expect(
        () => preload.entries.single['version_id'] = 'v2',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'manifest namespace resolves collisions independently of display names',
    () {
      install('one', '[]', namespace: 'stable-one');
      install('two', '[]', namespace: 'stable-two');
      final components = install('caller', '[stable-two:note]', skill: false);
      final registry = agents('caller', components);
      final skills = SelectedSkills(store, 'tenant', [], discover: true);
      final preload = PluginAgentSkillPreloads(
        skills,
        registry,
      ).forAgent(registry.entries.keys.single);
      expect(preload.entries.single['parent_id'], 'two');
    },
  );

  test(
    'ambiguous names are recoverable and do not block unrelated healthy Agents',
    () {
      install('one', '[]');
      install('two', '[]');
      final components = install('caller', '[note]', skill: false);
      final registry = agents('caller', components);
      final skills = SelectedSkills(store, 'tenant', [], discover: true);
      final adapter = PluginAgentSkillPreloads(skills, registry);
      expect(
        () => adapter.forAgent(registry.entries.keys.single),
        throwsStateError,
      );
      final healthy = agents('one', components);
      expect(
        PluginAgentSkillPreloads(
          skills,
          healthy,
        ).forAgent(healthy.entries.keys.single).entries,
        isEmpty,
      );
    },
  );

  test('user-only sibling cannot be automatically preloaded', () {
    final components = install('own', '[note]', userOnly: true);
    final registry = agents('own', components);
    final skills = SelectedSkills(store, 'tenant', []);
    final adapter = PluginAgentSkillPreloads(skills, registry);
    expect(
      () => adapter.forAgent(registry.entries.keys.single),
      throwsStateError,
    );
    expect(skills.entries, isEmpty);
  });

  test(
    'a disabled source invalidates the original preload at effect and resume checkpoints',
    () {
      final components = install('own', '[note]');
      final registry = agents('own', components);
      final skills = SelectedSkills(store, 'tenant', []);
      final preload = PluginAgentSkillPreloads(
        skills,
        registry,
      ).forAgent(registry.entries.keys.single);
      final current = store.get('cap/tenant/own')!;
      store.put('cap/tenant/own', {
        ...current.value,
        'enabled': false,
      }, current.revision);
      expect(preload.validate, throwsStateError);
    },
  );

  test(
    'missing required skill stops the child instead of dropping its declared instructions',
    () {
      final components = install('own', '[missing]', skill: false);
      final registry = agents('own', components);
      final adapter = PluginAgentSkillPreloads(
        SelectedSkills(store, 'tenant', []),
        registry,
      );
      expect(
        () => adapter.forAgent(registry.entries.keys.single),
        throwsStateError,
      );
    },
  );

  test(
    'presentation metadata changes do not invalidate the same immutable skill binding',
    () {
      final components = install('own', '[note]');
      final registry = agents('own', components);
      final original = PluginAgentSkillPreloads(
        SelectedSkills(store, 'tenant', []),
        registry,
      ).forAgent(registry.entries.keys.single);
      final current = store.get('cap/tenant/own')!;
      final versions = (current.value['versions'] as List)
          .whereType<Map>()
          .map(
            (version) => {
              ...version,
              'components': [
                for (final component
                    in (version['components'] as List).whereType<Map>())
                  {
                    ...component,
                    if (component['type'] == 'skill')
                      'name': 'New display label',
                  },
              ],
            },
          )
          .toList();
      store.put('cap/tenant/own', {
        ...current.value,
        'name': 'New plugin label',
        'versions': versions,
      }, current.revision);
      final rebuilt = PluginAgentSkillPreloads(
        SelectedSkills(store, 'tenant', []),
        registry,
      ).forAgent(registry.entries.keys.single);
      expect(rebuilt.binding, original.binding);
      expect(original.validate, returnsNormally);
    },
  );
}
