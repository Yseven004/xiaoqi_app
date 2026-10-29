import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_catalog.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_command.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  final files = <String, List<int>>{
    '.claude-plugin/plugin.json': utf8.encode('{"name":"hook-fixture"}'),
    'commands/healthy.md': utf8.encode(
      '---\ndescription: Healthy command\n---\nDo the task.',
    ),
    'hooks/hooks.json': utf8.encode(
      jsonEncode({
        'hooks': {
          'PreToolUse': [
            {
              'matcher': 'Write',
              'hooks': [
                {'type': 'command', 'command': 'guard'},
                {'type': 'http', 'url': 'https://example.com/guard'},
                {'type': 'command'},
              ],
            },
          ],
          'SessionStart': [
            {
              'hooks': [
                {'type': 'command', 'command': 'initialize'},
              ],
            },
          ],
        },
      }),
    ),
  };
  test(
    'independent hook states keep healthy commands and expose unmapped handlers',
    () {
      final plugin = CapabilityImportService.discover(files, '').single;
      final components = (plugin['components'] as List).whereType<Map>();
      expect(
        components.singleWhere((c) => c['type'] == 'command')['status'],
        'supported',
      );
      final hooks = components.where((c) => c['type'] == 'hook').toList();
      expect(hooks, hasLength(4));
      expect(hooks.where((h) => h['status'] == 'partial'), hasLength(1));
      expect(hooks.where((h) => h['status'] == 'unsupported'), hasLength(3));
      expect(plugin['status'], 'partial');
    },
  );

  test(
    'old installed metadata refresh stays tenant/version/source-bound and disableable',
    () async {
      final directory = await Directory.systemTemp.createTemp('hook-catalog-');
      final store = CloudStore(root: directory.path);
      try {
        store.putImmutable('packages/hooks', files);
        store.put('cap/alice/plugin', {
          'id': 'plugin',
          'kind': 'plugin',
          'enabled': true,
          'name': 'renamable',
          'current_version_id': 'v1',
          'versions': [
            {
              'id': 'v1',
              'artifact_key': 'packages/hooks',
              'components': [
                {
                  'id': 'healthy',
                  'type': 'command',
                  'root': '',
                  'source_path': 'commands/healthy.md',
                  'status': 'supported',
                },
              ],
            },
          ],
        }, null);
        final selection = [
          {'id': 'plugin', 'version_id': 'v1', 'component_id': 'healthy'},
        ];
        final hooks = SelectedPluginHooks(store, 'alice', selection);
        expect(hooks.entries, hasLength(1));
        final alias = hooks.entries.keys.single;
        expect(hooks.hook(alias).event, 'PreToolUse');
        final fingerprint = hooks.fingerprint(alias);
        final record = store.get('cap/alice/plugin')!;
        final version = (record.value['versions'] as List).single as Map;
        expect(
          version['plugin_hook_profile'],
          PluginHookCatalog.profileVersion,
        );
        expect(
          (version['components'] as List).whereType<Map>().where(
            (c) => c['type'] == 'command',
          ),
          hasLength(1),
        );
        store.put('cap/alice/plugin', {
          ...record.value,
          'name': 'changed display name',
        }, record.revision);
        expect(
          SelectedPluginHooks(store, 'alice', selection).fingerprint(alias),
          fingerprint,
        );
        expect(SelectedPluginHooks(store, 'bob', selection).entries, isEmpty);
        expect(
          SelectedPluginHooks(store, 'alice', [
            {'id': 'plugin', 'version_id': 'absent'},
          ]).entries,
          isEmpty,
        );
        final current = store.get('cap/alice/plugin')!;
        store.put('cap/alice/plugin', {
          ...current.value,
          'enabled': false,
        }, current.revision);
        expect(() => hooks.files(alias), throwsStateError);
        expect(SelectedPluginHooks(store, 'alice', selection).entries, isEmpty);
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'literal alternatives match source regexp semantics without API regex execution',
    () {
      expect(PluginHookCommand.trivialMatch('Write|Edit', 'BeforeWrite'), true);
      expect(PluginHookCommand.trivialMatch(r'^Write$', 'Write\n'), isNull);
      expect(
        PluginHookCommand.trivialMatch(r'^Write|Edit$', 'BeforeWrite'),
        false,
      );
      expect(PluginHookCommand.trivialMatch(r'^Write$|^Edit$', 'Write'), true);
      expect(
        PluginHookCommand.trivialMatch(r'^Write$|^Edit$', 'WriteMore'),
        false,
      );
      expect(PluginHookCommand.trivialMatch(r'(a+)+$', 'a' * 10000), isNull);
      expect(
        PluginHookCommand.trivialMatch('mcp__.*', 'mcp__library__read'),
        isNull,
      );
    },
  );
}
