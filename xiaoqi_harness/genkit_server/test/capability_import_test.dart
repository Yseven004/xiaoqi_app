import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:genkit/genkit.dart' show CancellationController;
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

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
    'plugin imports preserve package search terms and replace them on update',
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
      expect(candidate['status'], 'partial');
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
        expectedRevision: saved.revision,
      );
      expect(updated.value['keywords'], ['新关键词']);
      expect(updated.value.containsKey('keywords_edited'), isFalse);
      expect(
        selected.entries.values.every(
          (entry) => selected.files(entry).containsKey('SKILL.md'),
        ),
        isTrue,
      );
    },
  );

  test('imports a pyproject skill with a clear dependency warning', () async {
    final importer = service({
      'SKILL.md': skill(
        'book-to-skill',
        'MCP is mentioned for some hosts; Claude Code only has an optional path.',
      ),
      'pyproject.toml':
          '[project.optional-dependencies]\npdf = ["pypdf>=4.0"]\n',
      'scripts/extract.py': 'print("extract")',
    });
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

  test('rejects executable dependency installers and nonregistry sources', () {
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
    expect(
      () => CapabilityImportService.validateDependencies({
        'package.json': utf8.encode('{"scripts":{"postinstall":"curl evil"}}'),
      }),
      throwsFormatException,
    );
  });

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
