import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:genkit/genkit.dart' show CancellationController;
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/selected_skills.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

const instructions =
    '---\nname: clear-reading\ndescription: Read supplied material clearly\n---\nExplain the main question, evidence and limits.\n';
Archive package(Map<String, String> files) {
  final result = Archive();
  for (final file in files.entries) {
    result.add(ArchiveFile.string(file.key, file.value));
  }
  return result;
}

List<int> zipped(Map<String, String> files) =>
    ZipEncoder().encode(package(files));
List<int> tarWithType(String type) {
  final bytes = List<int>.from(
    TarEncoder().encode(package({'SKILL.md': instructions})),
  );
  bytes[156] = type.codeUnitAt(0);
  bytes.fillRange(148, 156, 32);
  final checksum = bytes.take(512).fold(0, (sum, value) => sum + value);
  bytes.setRange(
    148,
    156,
    ascii.encode('${checksum.toRadixString(8).padLeft(6, '0')}\x00 '),
  );
  return gzip.encode(bytes);
}

void main() {
  late Directory root;
  late CloudStore store;
  late CapabilityImportService importer;
  setUp(() {
    root = Directory.systemTemp.createTempSync('xiaoqi-upload-test-');
    store = CloudStore(root: root.path);
    importer = CapabilityImportService(store);
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });

  test(
    'ZIP, SKILL, TGZ, TAR.GZ and Markdown use the same skill inspection',
    () async {
      for (final name in [
        '技能.zip',
        'reading.skill',
        'reading.tgz',
        'reading.tar.gz',
        'SKILL.md',
      ]) {
        final bytes = name.endsWith('.md')
            ? utf8.encode(instructions)
            : name.endsWith('.zip') || name.endsWith('.skill')
            ? zipped({'SKILL.md': instructions})
            : gzip.encode(
                TarEncoder().encode(package({'./SKILL.md': instructions})),
              );
        final checked = await importer.inspectUpload('alice', name, bytes);
        expect(checked['source_type'], 'upload');
        expect(checked['file_name'], name);
        expect(checked.containsKey('artifact_key'), isFalse);
        expect(checked.containsKey('source_url'), isFalse);
        expect((checked['candidates'] as List).single['status'], 'supported');
      }
    },
  );

  test(
    'uploaded plugin is installed, pinned, deduplicated and tenant-scoped',
    () async {
      final checked = await importer.inspectUpload(
        'alice',
        'reader.zip',
        zipped({
          '.claude-plugin/plugin.json':
              '{"name":"reader","description":"Reading tools"}',
          'skills/reading/SKILL.md': instructions,
          'skills/reading/references/资料.md': 'Evidence stays in this package.',
        }),
      );
      final candidate = (checked['candidates'] as List).single;
      expect(candidate['kind'], 'plugin');
      final saved = await importer.install(
        'alice',
        checked['id'],
        candidate['id'],
      );
      expect(saved.value['origin'], 'upload');
      expect(saved.value['source']['file_name'], 'reader.zip');
      expect(saved.value['source'].containsKey('source_url'), isFalse);
      final repeated = await importer.install(
        'alice',
        checked['id'],
        candidate['id'],
      );
      expect(repeated.revision, saved.revision);
      final selection = [
        {
          'id': saved.value['id'],
          'version_id': saved.value['current_version_id'],
        },
      ];
      final skills = SelectedSkills(store, 'alice', selection);
      expect(skills.entries.values.single['name'], 'clear-reading');
      expect(
        utf8.decode(skills.files(skills.entries.values.single)['SKILL.md']!),
        instructions,
      );
      expect(() => SelectedSkills(store, 'bob', selection), throwsStateError);
      expect(
        () => importer.getInspection('bob', checked['id']),
        throwsFormatException,
      );
    },
  );

  test(
    'failed and cancelled uploaded updates keep the installed version',
    () async {
      final checked = await importer.inspectUpload(
        'alice',
        'reading.md',
        utf8.encode(instructions),
      );
      final saved = await importer.install(
        'alice',
        checked['id'],
        (checked['candidates'] as List).single['id'],
      );
      final update = await importer.inspectUpload(
        'alice',
        'reading.zip',
        zipped({
          'SKILL.md': instructions,
          'requirements.txt': 'missing-package==1.0',
        }),
      );
      for (final cancelled in [false, true]) {
        final controller = CancellationController();
        final failing = CapabilityImportService(
          store,
          prepareDependencies: (_, _, {cancellation}) async {
            if (cancelled) {
              controller.cancel();
              cancellation!.throwIfCancelled();
            }
            throw StateError('dependency preparation failed');
          },
        );
        await expectLater(
          failing.install(
            'alice',
            update['id'],
            (update['candidates'] as List).single['id'],
            updateId: saved.value['id'],
            expectedRevision: saved.revision,
            cancellation: controller.token,
          ),
          throwsA(anything),
        );
        expect(
          store
              .get('cap/alice/${saved.value['id']}')!
              .value['current_version_id'],
          saved.value['current_version_id'],
        );
        expect(
          store.get('cap/alice/${saved.value['id']}')!.revision,
          saved.revision,
        );
      }
      final successful = await importer.inspectUpload(
        'alice',
        'updated.md',
        utf8.encode('$instructions\nAdded instructions.'),
      );
      final updated = await importer.install(
        'alice',
        successful['id'],
        (successful['candidates'] as List).single['id'],
        updateId: saved.value['id'],
        expectedRevision: saved.revision,
      );
      expect(updated.value['versions'], hasLength(2));
      expect(updated.revision, saved.revision + 1);
    },
  );

  test('cancelled inspection creates no metadata or package', () async {
    final controller = CancellationController()..cancel();
    await expectLater(
      importer.inspectUpload(
        'alice',
        'SKILL.md',
        utf8.encode(instructions),
        cancellation: controller.token,
      ),
      throwsA(anything),
    );
    expect(store.list('import/alice/'), isEmpty);
    expect(store.objects.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('upload format, name, encoding and byte limits are enforced', () {
    for (final body in [
      {'file_name': '../bad.zip', 'archive_base64': 'YQ=='},
      {'file_name': 'bad.exe', 'archive_base64': 'YQ=='},
      {'file_name': 'safe.zip', 'archive_base64': 'not base64'},
      {'file_name': 'safe.zip', 'archive_base64': ''},
      {'file_name': 'safe.zip', 'archive_base64': 42},
    ]) {
      expect(
        () => CapabilityImportService.readUpload(body),
        throwsFormatException,
      );
    }
    expect(
      () => CapabilityImportService.decodeUpload('bad.zip', [1, 2, 3]),
      throwsFormatException,
    );
    expect(
      () => CapabilityImportService.decodeUpload('bad.md', [0xff]),
      throwsFormatException,
    );
    expect(
      () => CapabilityImportService.decodeUpload(
        'huge.zip',
        Uint8List(CapabilityImportService.maxArchiveBytes + 1),
      ),
      throwsFormatException,
    );
    expect(
      () => CapabilityImportService.decodeUpload(
        'huge.zip',
        zipped({'large.txt': 'x' * (CapabilityImportService.maxFileBytes + 1)}),
      ),
      throwsFormatException,
    );
  });

  test(
    'ZIP/TAR reject traversal, normalized duplicates, links and file-tree conflicts',
    () {
      for (final files in [
        {'../SKILL.md': instructions},
        {'folder/../../SKILL.md': instructions},
        {'SKILL.md': instructions, './SKILL.md': instructions},
        {'a': 'file', 'a-b': 'sort separator', 'a/b.md': 'conflict'},
      ]) {
        expect(
          () => CapabilityImportService.decodeUpload('bad.zip', zipped(files)),
          throwsFormatException,
        );
        expect(
          () => CapabilityImportService.decodeUpload(
            'bad.tgz',
            gzip.encode(TarEncoder().encode(package(files))),
          ),
          throwsFormatException,
        );
      }
      final link = ArchiveFile.string('link', 'target')
        ..mode = 0xa1ff
        ..symbolicLink = 'target';
      expect(
        () => CapabilityImportService.decodeUpload(
          'link.zip',
          ZipEncoder().encode(Archive()..add(link)),
        ),
        throwsFormatException,
      );
      for (final type in ['1', '2', '3', '4', '6', '7']) {
        expect(
          () => CapabilityImportService.decodeUpload(
            'special.tgz',
            tarWithType(type),
          ),
          throwsFormatException,
          reason: 'TAR type $type',
        );
      }
    },
  );

  test(
    'corrupt ZIP CRC, TAR checksums and gzip expansion cannot bypass checks',
    () {
      final zip = List<int>.from(zipped({'SKILL.md': instructions}));
      for (var i = 0; i + 20 < zip.length; i++) {
        if (zip[i] == 0x50 &&
            zip[i + 1] == 0x4b &&
            zip[i + 2] == 1 &&
            zip[i + 3] == 2) {
          zip[i + 16] ^= 1;
          break;
        }
      }
      expect(
        () => CapabilityImportService.decodeUpload('crc.zip', zip),
        throwsFormatException,
      );
      final tar = List<int>.from(
        TarEncoder().encode(package({'SKILL.md': instructions})),
      )..[0] = 88;
      expect(
        () => CapabilityImportService.decodeUpload(
          'corrupt.tgz',
          gzip.encode(tar),
        ),
        throwsFormatException,
      );
      final limit =
          CapabilityImportService.maxExpandedBytes +
          CapabilityImportService.maxFiles * 2048 +
          1024;
      final bomb = gzip.encode(Uint8List(limit + 1));
      expect(
        () => CapabilityImportService.decodeUpload('bomb.tgz', bomb),
        throwsFormatException,
      );
    },
  );

  test('ZIP and TAR enforce the same file-count limit', () {
    final files = {
      for (var i = 0; i <= CapabilityImportService.maxFiles; i++)
        'file-$i.txt': '',
    };
    expect(
      () => CapabilityImportService.decodeUpload('many.zip', zipped(files)),
      throwsFormatException,
    );
    expect(
      () => CapabilityImportService.decodeUpload(
        'many.tgz',
        gzip.encode(TarEncoder().encode(package(files))),
      ),
      throwsFormatException,
    );
  });

  test('TAR extended Unicode paths preserve their real relative filename', () {
    final path = 'references/${'资料' * 60}.md';
    final files = CapabilityImportService.decodeUpload(
      'reading.tgz',
      gzip.encode(
        TarEncoder().encode(
          package({'./SKILL.md': instructions, path: 'A source document.'}),
        ),
      ),
    );
    expect(utf8.decode(files[path]!), 'A source document.');
    expect(files['SKILL.md'], isNotNull);
  });
}
