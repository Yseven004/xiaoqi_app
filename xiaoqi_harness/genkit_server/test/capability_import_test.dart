import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:genkit/genkit.dart' show CancellationController;
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/plugin_dependencies.dart';

String skill(String name, [String body = 'Explain the user input clearly.']) =>
    '---\nname: $name\ndescription: Useful independent instructions\n---\n$body\n';
List<int> archive(Map<String, String> files) {
  final value = Archive();
  for (final e in files.entries) {
    value.add(ArchiveFile.string('repo-main/${e.key}', e.value));
  }
  return ZipEncoder().encode(value);
}

void main() {
  late Directory directory;
  late CloudStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('xiaoqi-import-test-');
    store = CloudStore(root: directory.path);
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  CapabilityImportService service(
    Map<String, String> files, {
    String commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    DependencyPreparer? prepare,
  }) => CapabilityImportService(
    store,
    prepareDependencies: prepare,
    download: (uri, _) async {
      if (uri.host == 'codeload.github.com') return archive(files);
      final packet = '$commit HEAD\x00symref=HEAD:refs/heads/main\n';
      final branch = '$commit refs/heads/main\n';
      return utf8.encode(
        '${(packet.length + 4).toRadixString(16).padLeft(4, "0")}$packet${(branch.length + 4).toRadixString(16).padLeft(4, "0")}$branch'
        '0000',
      );
    },
  );

  test(
    'rejects URLs and paths outside public GitHub / repository boundaries',
    () {
      for (final url in [
        'http://github.com/a/b',
        'https://github.com.evil.test/a/b',
        'https://user@github.com/a/b',
        'https://github.com/a/b?token=x',
        'https://github.com/a/b/tree/main/%2e%2e/x',
      ]) {
        expect(
          () => CapabilityImportService.parseUrl(url),
          throwsFormatException,
        );
      }
      for (final path in ['../secret', '/root', 'a/../../b', 'a\\b', 'C:/a']) {
        expect(
          () => CapabilityImportService.safePath(path),
          throwsFormatException,
        );
      }
      expect(
        () => CapabilityImportService.decodeRepository(
          archive({'../secret': 'bad'}),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'Shell requirements and auxiliary script resources remain installable',
    () async {
      final importer = service({
        'SKILL.md':
            '---\nname: shell-notes\ndescription: Process a local file\nallowed-tools: Bash\n---\nRun scripts/process.sh inside the task workspace.\n',
        'scripts/process.sh': 'printf "%s" "\$1"\n',
        'scripts/options.yaml': 'format: text\n',
      });
      final inspected = await importer.inspect(
        'alice',
        'https://github.com/example/shell',
      );
      final candidate = (inspected['candidates'] as List).single as Map;
      expect(candidate['status'], 'supported');
      expect((candidate['components'] as List).single['has_scripts'], isTrue);
      final saved = await importer.install(
        'alice',
        inspected['id'],
        candidate['id'],
      );
      final selected = SelectedSkills(store, 'alice', [
        {
          'id': saved.value['id'],
          'version_id': saved.value['current_version_id'],
        },
      ]);
      final files = selected.files(selected.entries.values.single);
      expect(utf8.decode(files['scripts/process.sh']!), contains('printf'));
      expect(utf8.decode(files['scripts/options.yaml']!), 'format: text\n');
    },
  );

  test(
    'archive executable bits survive repository subtrees and immutable storage',
    () {
      final input = Archive();
      input.add(ArchiveFile.string('repo-main/one/SKILL.md', skill('one')));
      input.add(
        ArchiveFile.string(
          'repo-main/one/scripts/run.sh',
          '#!/bin/sh\nprintf ok\n',
        )..mode = 0x9ed,
      );
      input.add(ArchiveFile.string('repo-main/two/SKILL.md', skill('two')));
      input.add(
        ArchiveFile.string('repo-main/two/scripts/read.py', 'print("text")'),
      );
      final files = CapabilityImportService.decodeRepository(
        ZipEncoder().encode(input),
      );
      final one = CapabilityImportService.subtree(files, 'one');
      final two = CapabilityImportService.subtree(files, 'two');
      final metadata =
          jsonDecode(
                utf8.decode(
                  one[CapabilityImportService.sourceExecutablesPath]!,
                ),
              )
              as Map;
      expect(metadata, {
        'schema': 1,
        'executables': ['scripts/run.sh'],
      });
      expect(
        two.containsKey(CapabilityImportService.sourceExecutablesPath),
        false,
      );
      store.putImmutable('source-mode-roundtrip', one);
      final reopened = store.getImmutable('source-mode-roundtrip');
      expect(
        reopened[CapabilityImportService.sourceExecutablesPath],
        one[CapabilityImportService.sourceExecutablesPath],
      );
      final tarBytes = GZipEncoder().encode(TarEncoder().encode(input));
      final tar = CapabilityImportService.decodeUpload('source.tgz', tarBytes);
      final tarMetadata = jsonDecode(
        utf8.decode(
          CapabilityImportService.subtree(
            tar,
            'repo-main/one',
          )[CapabilityImportService.sourceExecutablesPath]!,
        ),
      );
      expect(tarMetadata, metadata);
    },
  );

  test(
    'exported source execution metadata is rebased and rejects missing or escaping paths',
    () {
      final metadata = CapabilityImportService.sourceExecutablesPath;
      final files = CapabilityImportService.decodeUpload(
        'export.zip',
        archive({
          metadata: jsonEncode({
            'schema': 1,
            'executables': ['scripts/run.sh'],
          }),
          'scripts/run.sh': '#!/bin/sh\nprintf ok\n',
        }),
      );
      final scoped = CapabilityImportService.subtree(files, 'repo-main');
      expect(jsonDecode(utf8.decode(scoped[metadata]!)), {
        'schema': 1,
        'executables': ['scripts/run.sh'],
      });
      for (final path in ['../host', 'C:/host', 'missing.sh']) {
        expect(
          () => CapabilityImportService.decodeUpload(
            'invalid.zip',
            archive({
              metadata: jsonEncode({
                'schema': 1,
                'executables': [path],
              }),
            }),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'stdio plugin installs its declared dependency and resolves an owned immutable command',
    () async {
      var preparations = 0;
      final importer = service(
        {
          '.claude-plugin/plugin.json': '{"name":"stdio-reference"}',
          '.mcp.json': jsonEncode({
            'mcpServers': {
              'reference': {
                'command': 'npx',
                'args': ['-y', '@example/server@2.0.1', '/workspace/output'],
              },
            },
          }),
        },
        prepare: (tenant, files, {cancellation}) async {
          preparations++;
          expect(tenant, 'alice');
          expect(
            (jsonDecode(utf8.decode(files['package.json']!))
                as Map)['dependencies'],
            {'@example/server': '2.0.1'},
          );
          return {
            'node_modules/@example/server/package.json': utf8.encode(
              '{"version":"2.0.1","bin":"dist/index.js"}',
            ),
            'node_modules/@example/server/dist/index.js': utf8.encode(
              '// immutable test dependency',
            ),
            '.xiaoqi/dependency-lock.json': utf8.encode('{"schema":1}'),
          };
        },
      );
      final inspected = await importer.inspect(
        'alice',
        'https://github.com/example/stdio',
      );
      final candidate = (inspected['candidates'] as List).single as Map;
      expect(candidate['status'], 'supported');
      final saved = await importer.install(
        'alice',
        inspected['id'],
        candidate['id'],
      );
      final selection = [
        {
          'id': saved.value['id'],
          'version_id': saved.value['current_version_id'],
        },
      ];
      final resolved = PluginDependencies.resolve(store, 'alice', selection);
      expect(preparations, 1);
      expect(resolved.unavailable, isEmpty);
      expect(resolved.isolatedConnections.single.isolated!.command, [
        'node',
        '/workspace/skill/node_modules/@example/server/dist/index.js',
        '/workspace/output',
      ]);
      store.put('cap/alice/${saved.value['id']}', {
        ...saved.value,
        'versions': [
          ...(saved.value['versions'] as List),
          {
            'id': 'missing-files',
            'artifact_key': 'private-missing-package-path',
          },
        ],
      }, saved.revision);
      final partial = PluginDependencies.resolve(store, 'alice', [
        {'id': saved.value['id'], 'version_id': 'removed-version'},
        {'id': saved.value['id'], 'version_id': 'missing-files'},
        ...selection,
      ]);
      expect(partial.isolatedConnections, hasLength(1));
      expect(partial.unavailable, hasLength(2));
      expect(
        jsonEncode(partial.messages),
        isNot(contains('private-missing-package-path')),
      );
      expect(
        PluginDependencies.resolve(store, 'bob', selection).isolatedConnections,
        isEmpty,
      );
    },
  );

  test(
    'task selection isolates missing versions and corrupt sibling skills without implicit fallback',
    () {
      store.putImmutable('mixed-package', {
        'good/SKILL.md': utf8.encode(skill('healthy-sibling')),
        'bad/SKILL.md': [0xff],
      });
      store.put('cap/alice/mixed', {
        'id': 'mixed',
        'name': 'Mixed plugin',
        'kind': 'plugin',
        'origin': 'upload',
        'enabled': true,
        'current_version_id': 'v1',
        'versions': [
          {
            'id': 'v1',
            'artifact_key': 'mixed-package',
            'components': [
              {
                'id': 'good',
                'type': 'skill',
                'root': 'good',
                'name': 'Healthy sibling',
              },
              {
                'id': 'bad',
                'type': 'skill',
                'root': 'bad',
                'name': 'Corrupt sibling',
              },
            ],
          },
        ],
      }, null);
      store.put('cap/bob/foreign', {
        'name': 'private-other-account-name',
      }, null);
      final selected = SelectedSkills(
        store,
        'alice',
        [
          {'id': 'mixed', 'version_id': 'removed'},
          {'id': 'mixed', 'version_id': 'v1'},
          {'id': 'foreign', 'version_id': 'v1'},
        ],
        discover: true,
        allowUnavailable: true,
      );
      expect(selected.entries, hasLength(1));
      expect(selected.explicitIds, hasLength(1));
      expect(selected.entries.values.single['component_id'], 'good');
      expect(
        utf8.decode(
          selected.files(selected.entries.values.single)['SKILL.md']!,
        ),
        contains('healthy-sibling'),
      );
      expect(selected.unavailableSelections, hasLength(3));
      expect(
        jsonEncode(selected.unavailableSelections),
        isNot(contains('private-other-account-name')),
      );
      final pinnedMissing = SelectedSkills(
        store,
        'alice',
        [
          {'id': 'mixed', 'version_id': 'removed'},
        ],
        discover: true,
        allowUnavailable: true,
      );
      expect(
        pinnedMissing.entries,
        isEmpty,
        reason:
            'A missing explicit version must not silently fall back to current_version_id',
      );
      expect(
        () => SelectedSkills(store, 'alice', [
          {'id': '../invalid', 'version_id': 'v1'},
        ], allowUnavailable: true),
        throwsFormatException,
      );
    },
  );

  test('rejects symbolic links and oversized expanded archives', () {
    final link = ArchiveFile.string('root/link', 'target')
      ..mode = 0xa1ff
      ..symbolicLink = 'target';
    expect(
      () => CapabilityImportService.decodeRepository(
        ZipEncoder().encode(Archive()..add(link)),
      ),
      throwsFormatException,
    );
    expect(
      () => CapabilityImportService.decodeRepository(
        archive({'large': 'a' * (10 * 1024 * 1024 + 1)}),
      ),
      throwsFormatException,
    );
  });

  test(
    'installs text skill atomically; duplicate install keeps revision; tenant isolation',
    () async {
      final importer = service({
        'SKILL.md': skill('clear-writing'),
        'LICENSE': 'MIT',
      });
      final inspected = await importer.inspect(
        'alice',
        'https://github.com/example/skills',
      );
      expect(inspected.containsKey('artifact_key'), isFalse);
      final candidate = (inspected['candidates'] as List).single as Map;
      final saved = await importer.install(
        'alice',
        inspected['id'],
        candidate['id'],
      );
      final again = await importer.install(
        'alice',
        inspected['id'],
        candidate['id'],
      );
      expect(again.revision, saved.revision);
      final refs = [
        {
          'id': saved.value['id'],
          'version_id': saved.value['current_version_id'],
        },
      ];
      final selected = SelectedSkills(store, 'alice', refs);
      expect(
        utf8.decode(
          selected.files(selected.entries.values.single)['SKILL.md']!,
        ),
        contains('clear-writing'),
      );
      expect(() => SelectedSkills(store, 'bob', refs), throwsStateError);
      expect(
        () => importer.getInspection('bob', inspected['id']),
        throwsFormatException,
      );
      expect(
        () => SelectedSkills(
          store,
          'alice',
          null,
        ).resolve({'skill_id': selected.entries.keys.single}),
        throwsStateError,
      );
    },
  );

  test(
    'empty MCP declarations do not downgrade healthy plugin instructions',
    () async {
      final importer = service({
        '.claude-plugin/plugin.json':
            '{"name":"mixed","mcpServers":{},"keywords":["论文总结","文献阅读"]}',
        'skills/good/SKILL.md': skill('same-name'),
        'skills/bad/SKILL.md': skill(
          'requires-mcp',
          'Call MCP tools to retrieve private data.',
        ),
      });
      final inspected = await importer.inspect(
        'alice',
        'https://github.com/example/plugin',
      );
      final candidate = (inspected['candidates'] as List).single as Map;
      expect(candidate['status'], 'supported');
      final saved = await importer.install(
        'alice',
        inspected['id'],
        candidate['id'],
      );
      final selected = SelectedSkills(store, 'alice', [
        {
          'id': saved.value['id'],
          'version_id': saved.value['current_version_id'],
        },
      ]);
      expect(selected.entries.length, 2);
      expect(candidate['keywords'], ['论文总结', '文献阅读']);
      expect(saved.value['keywords'], ['论文总结', '文献阅读']);
      final key = 'cap/alice/${saved.value['id']}';
      final edited = store.put(key, {
        ...saved.value,
        'keywords': <String>[],
        'keywords_edited': true,
      }, saved.revision);
      final newer = service({
        '.claude-plugin/plugin.json': '{"name":"mixed","keywords":["新关键词"]}',
        'skills/good/SKILL.md': skill('same-name'),
      }, commit: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
      final update = await newer.inspect(
        'alice',
        'https://github.com/example/plugin',
      );
      final updated = await newer.install(
        'alice',
        update['id'],
        (update['candidates'] as List).single['id'],
        updateId: saved.value['id'],
        expectedRevision: edited.revision,
      );
      expect(updated.value['keywords'], isEmpty);
      expect(updated.value['keywords_edited'], isTrue);
      expect(
        selected.entries.values.every(
          (entry) => selected.files(entry).containsKey('SKILL.md'),
        ),
        isTrue,
      );
    },
  );

  test('imports a pyproject skill with a clear dependency warning', () async {
    final importer = service(
      {
        'SKILL.md': skill(
          'book-to-skill',
          'MCP is mentioned for some hosts; Claude Code only has an optional path.',
        ),
        'pyproject.toml':
            '[project.optional-dependencies]\npdf = ["pypdf>=4.0"]\n',
        'scripts/extract.py': 'print("extract")',
      },
      prepare: (tenant, files, {cancellation}) async => {
        '.xiaoqi/dependency-lock.json': utf8.encode(
          '{"schema":1,"python_optional_groups":["pdf"]}',
        ),
      },
    );
    final inspected = await importer.inspect(
      'alice',
      'https://github.com/example/book-to-skill',
    );
    final candidate = (inspected['candidates'] as List).single as Map;

    expect(candidate['status'], 'partial');
    expect(candidate['warnings'], isNotEmpty);
    final saved = await importer.install(
      'alice',
      inspected['id'],
      candidate['id'],
    );
    final selected = SelectedSkills(store, 'alice', [
      {
        'id': saved.value['id'],
        'version_id': saved.value['current_version_id'],
      },
    ]);

    expect(selected.entries.length, 1);
    expect(
      selected.files(selected.entries.values.single).keys,
      containsAll(['SKILL.md', 'scripts/extract.py']),
    );
  });

  test(
    'Python packaging entries prepare dependencies and auxiliary Dockerfile does not block them',
    () async {
      for (final entry in ['pyproject.toml', 'setup.py']) {
        var prepared = false;
        final importer = service(
          {
            'SKILL.md': skill('python-build'),
            entry: entry == 'setup.py'
                ? 'from setuptools import setup\nsetup(name="fixture",version="1")'
                : '[project]\nname="fixture"\nversion="1"\n',
            'Dockerfile': 'FROM scratch\n',
            'scripts/use.py': 'print("installed")',
          },
          prepare: (tenant, files, {cancellation}) async {
            expect(files.containsKey(entry), true);
            prepared = true;
            return {
              '.xiaoqi/dependency-lock.json': utf8.encode('{"schema":1}'),
            };
          },
        );
        final inspection = await importer.inspect(
          'alice',
          'https://github.com/example/$entry',
        );
        final candidate = (inspection['candidates'] as List).single as Map;
        expect(candidate['status'], 'supported');
        expect(
          (candidate['components'] as List).single['has_dependencies'],
          true,
        );
        await importer.install('alice', inspection['id'], candidate['id']);
        expect(prepared, true);
      }
    },
  );

  test(
    'cached skill bytes cannot outlive removal of their version or component binding',
    () async {
      final importer = service({
        'SKILL.md': skill('bound-source'),
        'scripts/run.py': 'print("owned")',
      });
      final inspection = await importer.inspect(
        'alice',
        'https://github.com/example/bound-source',
      );
      final candidate = (inspection['candidates'] as List).single as Map;
      final installed = await importer.install(
        'alice',
        inspection['id'],
        candidate['id'],
      );
      final selected = SelectedSkills(store, 'alice', [
        {
          'id': installed.value['id'],
          'version_id': installed.value['current_version_id'],
        },
      ]);
      final entry = selected.entries.values.single;
      expect(selected.files(entry).containsKey('scripts/run.py'), true);
      final key = 'cap/alice/${installed.value['id']}';
      store.put(key, {...installed.value, 'versions': []}, installed.revision);
      expect(() => selected.files(entry), throwsStateError);
      expect(
        () => selected.resolve({'skill_id': entry['id']}),
        throwsStateError,
      );
      final current = store.get(key)!;
      final versions = (installed.value['versions'] as List)
          .whereType<Map>()
          .map(
            (version) => {
              ...version,
              'components': (version['components'] as List)
                  .whereType<Map>()
                  .map((component) => {...component, 'root': 'changed-root'})
                  .toList(),
            },
          )
          .toList();
      store.put(key, {
        ...installed.value,
        'versions': versions,
      }, current.revision);
      expect(
        () => selected.resolve({'skill_id': entry['id']}),
        throwsStateError,
      );
    },
  );

  test('standard plugin and multiple standalone candidates are discovered', () {
    final standalone = CapabilityImportService.discover({
      'a/SKILL.md': utf8.encode(skill('same-name')),
      'b/SKILL.md': utf8.encode(skill('same-name')),
    }, '');
    expect(standalone.length, 2);
    final plugin = CapabilityImportService.discover({
      'plugin.json': utf8.encode(
        '{"name":"standard","\$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"}',
      ),
      'skills/a/SKILL.md': utf8.encode(skill('first')),
    }, '');
    expect(plugin.single['kind'], 'plugin');
  });

  test(
    'failed dependency preparation leaves no install and preserves old update version',
    () async {
      final first = service({'SKILL.md': skill('one')});
      final checked = await first.inspect(
        'alice',
        'https://github.com/example/repo',
      );
      final installed = await first.install(
        'alice',
        checked['id'],
        (checked['candidates'] as List).single['id'],
      );
      final broken = service(
        {'SKILL.md': skill('one'), 'requirements.txt': 'missing-package==1'},
        commit: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        prepare: (_, _, {cancellation}) async =>
            throw StateError('No compatible wheel'),
      );
      final update = await broken.inspect(
        'alice',
        'https://github.com/example/repo',
      );
      await expectLater(
        broken.install(
          'alice',
          update['id'],
          (update['candidates'] as List).single['id'],
          updateId: installed.value['id'],
          expectedRevision: installed.revision,
        ),
        throwsStateError,
      );
      expect(
        store.get('cap/alice/${installed.value['id']}')!.revision,
        installed.revision,
      );
      final fresh = await broken.inspect(
        'bob',
        'https://github.com/example/repo',
      );
      await expectLater(
        broken.install(
          'bob',
          fresh['id'],
          (fresh['candidates'] as List).single['id'],
        ),
        throwsStateError,
      );
      expect(store.list('cap/bob/'), isEmpty);
    },
  );

  test(
    'running selection pins old version across update; disable revokes it',
    () async {
      final importer = service({'SKILL.md': skill('one')});
      final checked = await importer.inspect(
        'alice',
        'https://github.com/example/repo',
      );
      final installed = await importer.install(
        'alice',
        checked['id'],
        (checked['candidates'] as List).single['id'],
      );
      final selected = SelectedSkills(store, 'alice', [
        {
          'id': installed.value['id'],
          'version_id': installed.value['current_version_id'],
        },
      ]);
      final newer = service({
        'SKILL.md': skill('two'),
      }, commit: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
      final update = await newer.inspect(
        'alice',
        'https://github.com/example/repo',
      );
      final saved = await newer.install(
        'alice',
        update['id'],
        (update['candidates'] as List).single['id'],
        updateId: installed.value['id'],
        expectedRevision: installed.revision,
      );
      expect(
        utf8.decode(
          selected.files(selected.entries.values.single)['SKILL.md']!,
        ),
        contains('name: one'),
      );
      store.put('cap/alice/${saved.value['id']}', {
        ...saved.value,
        'enabled': false,
      }, saved.revision);
      expect(() => selected.resolve({}), throwsStateError);
      final disabled = store.get('cap/alice/${saved.value['id']}')!;
      final restored = await importer.install(
        'alice',
        checked['id'],
        (checked['candidates'] as List).single['id'],
        updateId: disabled.value['id'],
        expectedRevision: disabled.revision,
      );
      expect(restored.value['enabled'], false);
      expect(() => selected.resolve({}), throwsStateError);
    },
  );

  test(
    'accepts isolated npm lifecycle declarations but rejects nonregistry sources',
    () {
      for (final requirements in [
        '-r other.txt',
        'https://evil.test/a.whl',
        'pkg @ file:///tmp/a',
      ]) {
        expect(
          () => CapabilityImportService.validateDependencies({
            'requirements.txt': utf8.encode(requirements),
          }),
          throwsFormatException,
        );
      }
      CapabilityImportService.validateDependencies({
        'package.json': utf8.encode(
          '{"scripts":{"postinstall":"node install.cjs","build":"node build.cjs"}}',
        ),
      });
      for (final package in [
        '{"scripts":{"install":42}}',
        '{"devDependencies":{"build-tool":"file:../host"}}',
        '{"dependencies":{"build-tool":"https://example.com/tool.tgz"}}',
      ]) {
        expect(
          () => CapabilityImportService.validateDependencies({
            'package.json': utf8.encode(package),
          }),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'cancel during dependency preparation never activates installation',
    () async {
      final cancel = CancellationController();
      final importer = service(
        {'SKILL.md': skill('cancel-test'), 'requirements.txt': 'example==1'},
        prepare: (_, _, {cancellation}) async {
          cancel.cancel();
          return {};
        },
      );
      final result = await importer.inspect(
        'alice',
        'https://github.com/example/repo',
      );
      await expectLater(
        importer.install(
          'alice',
          result['id'],
          (result['candidates'] as List).single['id'],
          cancellation: cancel.token,
        ),
        throwsA(anything),
      );
      expect(store.list('cap/alice/'), isEmpty);
    },
  );

  test(
    'same-name installed skills have unique aliases; install survives reopening',
    () async {
      final importer = service({
        'a/SKILL.md': skill('same'),
        'b/SKILL.md': skill('same'),
      });
      final inspected = await importer.inspect(
        'alice',
        'https://github.com/example/repo',
      );
      final refs = <Map<String, Object?>>[];
      for (final c in inspected['candidates'] as List) {
        final installed = await importer.install(
          'alice',
          inspected['id'],
          c['id'],
        );
        refs.add({
          'id': installed.value['id'],
          'version_id': installed.value['current_version_id'],
        });
      }
      store.close();
      store = CloudStore(root: directory.path);
      final catalog = SelectedSkills(store, 'alice', refs);
      expect(catalog.entries.keys.toSet().length, 2);
      for (final entry in catalog.entries.values) {
        expect(catalog.files(entry)['SKILL.md'], isNotEmpty);
      }
    },
  );
}
