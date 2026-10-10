import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory directory;

  setUp(
    () => directory = Directory.systemTemp.createTempSync('xiaoqi-store-test-'),
  );
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'opens existing single-server SQLite schema and preserves CAS revisions',
    () {
      final legacy = sqlite3.open(p.join(directory.path, 'xiaoqi.sqlite3'));
      legacy.execute(
        'CREATE TABLE documents (key TEXT PRIMARY KEY, document TEXT NOT NULL, revision INTEGER NOT NULL)',
      );
      legacy.execute(
        'CREATE TABLE objects (key TEXT PRIMARY KEY, updated_at INTEGER NOT NULL)',
      );
      legacy.execute('INSERT INTO documents VALUES (?, ?, ?)', [
        'draft/personal/one',
        jsonEncode({'id': 'one'}),
        7,
      ]);
      legacy.close();

      final store = CloudStore(root: directory.path);
      expect(store.get('draft/personal/one')?.revision, 7);
      expect(store.get('draft/personal/one')?.value['id'], 'one');
      final updated = store.put('draft/personal/one', {
        'id': 'one',
        'text': 'new',
      }, 7);
      expect(updated.revision, 8);
      expect(
        () => store.put('draft/personal/one', {'id': 'one'}, 7),
        throwsA(isA<RevisionConflict>()),
      );
      store.close();
    },
  );

  test('stores immutable skill ZIPs and private task blobs', () {
    final store = CloudStore(root: directory.path);
    store.putImmutable('tenants/personal/capabilities/demo/v1.zip', {
      'SKILL.md': utf8.encode(
        '---\nname: demo\ndescription: test\n---\n# Demo',
      ),
      'scripts/run.py': utf8.encode('print("ok")'),
    });
    expect(
      utf8.decode(
        store.getImmutable(
          'tenants/personal/capabilities/demo/v1.zip',
        )['SKILL.md']!,
      ),
      contains('# Demo'),
    );
    store.putTaskBlob('tenants/personal/tasks/t1/artifacts/a1', [1, 2, 3]);
    expect(store.getObject('tenants/personal/tasks/t1/artifacts/a1'), [
      1,
      2,
      3,
    ]);
    expect(store.summary(), {'documents': 0, 'objects': 2, 'object_files': 2});
    store.close();
  });
}
