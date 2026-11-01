import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/plugin_commands.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  test(
    'legacy root commands reindex preserves ids and restores fork siblings',
    () async {
      final directory = await Directory.systemTemp.createTemp('legacy-fork-');
      final store = CloudStore(root: directory.path);
      try {
        final files = {
          'commands/plain.md': utf8.encode('Plain task'),
          'commands/fork.md': utf8.encode('---\ncontext: fork\n---\nFork task'),
        };
        store.putImmutable('legacy-commands', files);
        final components = PluginCommand.inspect(files, '', {});
        final plain = components.singleWhere((c) => c['name'] == 'plain');
        final fork = components.singleWhere((c) => c['name'] == 'fork');
        store.put('cap/alice/legacy', {
          'id': 'legacy',
          'kind': 'plugin',
          'enabled': true,
          'current_version_id': 'v1',
          'compatibility': {
            'warnings': ['commands 组件暂不支持'],
          },
          'versions': [
            {
              'id': 'v1',
              'artifact_key': 'legacy-commands',
              'plugin_command_profile': 1,
              'components': [
                {...plain, 'id': 'preserved-plain'},
                {...fork, 'id': 'preserved-fork', 'status': 'unsupported'},
              ],
            },
          ],
        }, null);
        final selected = SelectedPluginCommands(store, 'alice', [
          {'id': 'legacy', 'version_id': 'v1'},
        ]);
        expect(
          selected.entries.values.map((c) => c['component_id']),
          unorderedEquals(['preserved-plain', 'preserved-fork']),
        );
        final current = store.get('cap/alice/legacy')!.value;
        expect((current['compatibility'] as Map)['warnings'], isEmpty);
        expect(store.getImmutable('legacy-commands'), files);
        expect(
          (current['versions'] as List).single['artifact_key'],
          'legacy-commands',
        );
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'command arguments preserve quotes and never recursively expand inserted text',
    () {
      final command = PluginCommand.parse(
        'commands/check.md',
        utf8.encode(
          r'Args=$ARGUMENTS; first=$0; second=$ARGUMENTS[1]; root=${CLAUDE_PLUGIN_ROOT}',
        ),
      );
      expect(
        command.render(
          '"hello world" \'\$ARGUMENTS\'',
          pluginRoot: 'plugin-command://id',
        ),
        r'''Args="hello world" '$ARGUMENTS'; first=hello world; second=$ARGUMENTS; root=plugin-command://id''',
      );
      expect(() => command.render('"unclosed'), throwsFormatException);
      expect(command.render('"" last'), contains('first=; second=last'));
      expect(
        command.render(r'"C:\Users\Ada" ""'),
        contains(r'first=C:\Users\Ada; second=;'),
      );
    },
  );
  test('dynamic shell remains source data until its context is executed', () {
    final files = <String, List<int>>{
      'commands/healthy.md': utf8.encode('Explain \$ARGUMENTS'),
      'commands/dynamic.md': utf8.encode('!`touch marker`'),
      'commands/agent.md': utf8.encode('---\ncontext: fork\n---\nRun agent'),
    };
    final inspected = PluginCommand.inspect(files, '', {});
    expect(
      inspected.where((c) => c['status'] == 'supported').map((c) => c['name']),
      unorderedEquals(['healthy', 'agent', 'dynamic']),
    );
    expect(inspected.where((c) => c['status'] == 'unsupported'), isEmpty);
    final command = PluginCommand.parse(
      'commands/dynamic.md',
      files['commands/dynamic.md']!,
    );
    expect(command.contextCommands, ['touch marker']);
    expect(() => command.render(''), throwsStateError);
    expect(
      command.render('unused', contextOutputs: [r'!`never run` $ARGUMENTS']),
      r'!`never run` $ARGUMENTS',
    );
  });
  test(
    'fork context validates agent and preserves standalone task arguments',
    () {
      final command = PluginCommand.parse(
        'commands/work.md',
        utf8.encode(
          '---\ncontext: fork\nagent: Explore\nbackground: false\n---\nRead \$ARGUMENTS',
        ),
      );
      expect(command.fork, isTrue);
      expect(command.agent, 'Explore');
      expect(
        command.render('literal; \$(no-shell)'),
        'Read literal; \$(no-shell)',
      );
      for (final header in [
        'context: other',
        'agent: Explore',
        'context: fork\nagent: 7',
        'context: fork\nbackground: yes',
      ]) {
        expect(
          () => PluginCommand.parse(
            'commands/work.md',
            utf8.encode('---\n$header\n---\nTask'),
          ),
          throwsFormatException,
        );
      }
    },
  );
  test('custom command locations stay inside the immutable plugin package', () {
    final files = {'custom/nested.md': utf8.encode('Command')};
    expect(
      PluginCommand.inspect(files, '', {
        'commands': './custom',
      }).single['source_path'],
      'custom/nested.md',
    );
    for (final path in ['./../other', './missing', '/absolute']) {
      expect(
        () => PluginCommand.inspect(files, '', {'commands': path}),
        throwsFormatException,
      );
    }
    final large = {
      for (var i = 0; i < 160; i++)
        'commands/c$i.md': utf8.encode('Command $i'),
    };
    expect(PluginCommand.inspect(large, '', {}), hasLength(160));
  });
  test(
    'actual import/install exposes tenant-bound versioned commands and resources',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'plugin-command-install-',
      );
      final store = CloudStore(root: directory.path);
      try {
        final archive = Archive();
        for (final entry in {
          '.claude-plugin/plugin.json':
              '{"name":"example","description":"Prompt commands"}',
          'commands/greet.md':
              '---\ndescription: Greet a user\n---\nRead references/greeting.md for \$ARGUMENTS',
          'references/greeting.md': 'Greeting reference',
          'LICENSE': 'MIT (synthetic test fixture)',
        }.entries)
          archive.add(
            ArchiveFile.string('repo-main/${entry.key}', entry.value),
          );
        final zip = ZipEncoder().encode(archive);
        final importer = CapabilityImportService(
          store,
          download: (uri, _) async {
            if (uri.host == 'codeload.github.com') return zip;
            final commit = 'a' * 40;
            final packet = '$commit HEAD\x00symref=HEAD:refs/heads/main\n';
            final branch = '$commit refs/heads/main\n';
            return utf8.encode(
              '${(packet.length + 4).toRadixString(16).padLeft(4, "0")}$packet'
              '${(branch.length + 4).toRadixString(16).padLeft(4, "0")}$branch'
              '0000',
            );
          },
        );
        final inspection = await importer.inspect(
          'alice',
          'https://github.com/example/commands',
        );
        final candidate = (inspection['candidates'] as List).single as Map;
        expect(candidate['status'], 'supported');
        final installed = await importer.install(
          'alice',
          inspection['id'],
          candidate['id'],
        );
        final id = installed.value['id'];
        final version = installed.value['current_version_id'];
        final refs = [
          {'id': id, 'version_id': version},
        ];
        final old = store.get('cap/alice/$id')!;
        final oldVersion =
            Map<String, dynamic>.from(
                (old.value['versions'] as List).single as Map,
              )
              ..remove('plugin_command_profile')
              ..['components'] = [];
        final originalArtifact = oldVersion['artifact_key'];
        store.put('cap/alice/$id', {
          ...old.value,
          'versions': [oldVersion],
          'compatibility': {
            ...old.value['compatibility'] as Map,
            'warnings': ['commands 组件暂不支持'],
          },
        }, old.revision);
        final selected = SelectedPluginCommands(store, 'alice', refs);
        final alias = selected.entries.keys.single;
        final migrated =
            (store.get('cap/alice/$id')!.value['versions'] as List).single
                as Map;
        expect(migrated['artifact_key'], originalArtifact);
        expect(migrated['id'], version);
        expect(
          migrated['plugin_command_profile'],
          PluginCommand.profileVersion,
        );
        expect(selected.command(alias).render('Ada'), contains('for Ada'));
        final binding = selected.fingerprint(alias);
        final named = store.get('cap/alice/$id')!;
        store.put('cap/alice/$id', {
          ...named.value,
          'name': 'Renamed display label',
          'description': 'Updated description',
        }, named.revision);
        final renamed = SelectedPluginCommands(store, 'alice', refs);
        expect(renamed.entries.keys.single, alias);
        expect(renamed.fingerprint(alias), binding);
        expect(renamed.namespace(alias), 'example');
        final discovered = SelectedPluginCommands(
          store,
          'alice',
          [],
          discover: true,
        );
        expect(discovered.fingerprint(alias), binding);
        expect(discovered.namespace(alias), 'example');
        expect(
          utf8.decode(selected.files(alias)['references/greeting.md']!),
          'Greeting reference',
        );
        expect(SelectedPluginCommands(store, 'bob', refs).entries, isEmpty);
        expect(
          () => SelectedPluginCommands(store, 'bob', []).files(alias),
          throwsStateError,
        );
        expect(
          SelectedPluginCommands(store, 'alice', [], discover: true).entries,
          hasLength(1),
        );
        expect(
          SelectedPluginCommands(
            store,
            'alice',
            [],
            discover: true,
            excludedIds: [id],
          ).entries,
          isEmpty,
        );
        expect(
          SelectedPluginCommands(store, 'alice', [
            {'id': id, 'version_id': 'missing'},
          ], discover: true).entries,
          isEmpty,
        );
        final current = store.get('cap/alice/$id')!;
        store.put('cap/alice/$id', {
          ...current.value,
          'enabled': false,
        }, current.revision);
        expect(() => selected.files(alias), throwsStateError);
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
