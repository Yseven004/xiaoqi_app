import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agents.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory root;
  late CloudStore store;
  late List<Map<String, dynamic>> components;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-registry-');
    store = CloudStore(root: root.path);
    Map<String, List<int>> files(String marker, List<String> names) => {
      '.claude-plugin/plugin.json': utf8.encode('{"name":"registry-fixture"}'),
      for (final name in names)
        'agents/$name.md': utf8.encode(
          '---\nname: $name\ndescription: Registry test\n---\n$marker',
        ),
    };
    final first = files('PINNED_SOURCE', ['writer', 'helper']);
    final second = files('CURRENT_SOURCE', ['writer', 'new-helper']);
    components = PluginAgentDefinition.inspect(first, '', {});
    store.putImmutable('packages/v1', first);
    store.putImmutable('packages/v2', second);
    store.put('cap/tenant/plugin', {
      'id': 'plugin',
      'kind': 'plugin',
      'name': 'registry-fixture',
      'origin': 'upload',
      'enabled': true,
      'current_version_id': 'v2',
      'versions': [
        {
          'id': 'v1',
          'artifact_key': 'packages/v1',
          'components': components,
          'plugin_agent_profile': 1,
        },
        {
          'id': 'v2',
          'artifact_key': 'packages/v2',
          'components': PluginAgentDefinition.inspect(second, '', {}),
          'plugin_agent_profile': 1,
        },
      ],
    }, null);
  });
  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });
  SelectedPluginAgents selected([String version = 'v1']) =>
      SelectedPluginAgents(store, 'tenant', [
        {
          'id': 'plugin',
          'version_id': version,
          'component_id': components.singleWhere(
            (e) => e['name'] == 'writer',
          )['id'],
        },
      ], discover: true);

  test(
    'sibling discovery keeps the selected immutable version and explicit preference',
    () {
      final registry = selected();
      expect(registry.entries.values.map((e) => e['name']).toSet(), {
        'writer',
        'helper',
      });
      expect(registry.entries.values.map((e) => e['version_id']).toSet(), {
        'v1',
      });
      for (final entry in registry.entries.values) {
        expect(entry['explicit_component'], entry['name'] == 'writer');
        expect(
          registry.definition(entry['id'].toString()).body,
          'PINNED_SOURCE',
        );
      }
      expect(selected('missing-version').entries, isEmpty);
    },
  );
  test(
    'disabling or withdrawing the selected version invalidates already cached sources',
    () {
      final registry = selected();
      final id = registry.entries.keys.first;
      registry.definition(id);
      final source = store.get('cap/tenant/plugin')!;
      store.put('cap/tenant/plugin', {
        ...source.value,
        'enabled': false,
      }, source.revision);
      expect(() => registry.definition(id), throwsStateError);
      expect(selected().entries, isEmpty);
      final disabled = store.get('cap/tenant/plugin')!;
      store.put('cap/tenant/plugin', {
        ...disabled.value,
        'enabled': true,
        'versions': (disabled.value['versions'] as List)
            .where((v) => v['id'] != 'v1')
            .toList(),
      }, disabled.revision);
      expect(() => registry.definition(id), throwsStateError);
      expect(selected().entries, isEmpty);
    },
  );
}
