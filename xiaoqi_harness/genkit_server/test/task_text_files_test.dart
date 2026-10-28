import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/execution_limits.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/task_text_files.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

class PausingStore extends CloudStore {
  PausingStore({required super.root});
  final paused = Completer<void>();
  final release = Completer<void>();
  var pause = true;
  @override
  Stream<List<int>> readObjectChunks(String key) async* {
    await for (final chunk in super.readObjectChunks(key)) yield chunk;
    if (pause) {
      pause = false;
      paused.complete();
      await release.future;
    }
  }
}

void main() {
  late Directory root;
  late CloudStore store;
  ToolExecution owner({
    String scope = 'original',
    ExecutionLimits limits = const ExecutionLimits(),
  }) => ToolExecution(
    store,
    'tenant',
    'task',
    TurnContract(mode: 'workflow', imageLimit: 0),
    requestIdentity: scope,
    limits: limits,
  )..bind();
  setUp(() {
    root = Directory.systemTemp.createTempSync('task-text-files-');
    store = CloudStore(root: root.path);
    store.put('task/tenant/task', {'status': 'running', 'artifacts': []}, null);
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });

  test(
    'task writes preserve nested paths and exact versions without implicit overwrite',
    () async {
      final files = TaskTextFiles(owner());
      final first = (await files.write('草稿/计划.md', 'first'))['artifact'] as Map;
      await expectLater(files.write('草稿/计划.md', 'unbound'), throwsStateError);
      final second =
          (await files.write(
                '草稿/计划.md',
                'second',
                baseArtifactId: first['id'],
              ))['artifact']
              as Map;
      expect(second['id'], isNot(first['id']));
      expect(first.containsKey('object_key'), false);
      expect((await files.read('草稿/计划.md'))['text'], 'second');
      expect(
        (await files.read('草稿/计划.md', artifactId: first['id']))['text'],
        'first',
      );
      await expectLater(
        files.read('草稿/计划.md', artifactId: 'missing'),
        throwsStateError,
      );
      final listing = await files.list(prefix: '草稿');
      expect((listing['files'] as List).single['id'], second['id']);
      expect((listing['files'] as List).single['path'], '草稿/计划.md');
      expect(
        (store.get('task/tenant/task')!.value['artifacts'] as List),
        hasLength(2),
      );
    },
  );

  test(
    'literal edits reject ambiguous, missing and stale source text',
    () async {
      final files = TaskTextFiles(owner());
      final first =
          (await files.write('config.txt', 'one one'))['artifact'] as Map;
      await expectLater(
        files.edit(first['id'], 'one', 'two'),
        throwsStateError,
      );
      await expectLater(
        files.edit(first['id'], 'missing', 'two'),
        throwsStateError,
      );
      final updated =
          (await files.edit(
                first['id'],
                'one',
                'two',
                replaceAll: true,
              ))['artifact']
              as Map;
      expect((await files.read('config.txt'))['text'], 'two two');
      await expectLater(
        files.edit(first['id'], 'one', 'old'),
        throwsStateError,
      );
      expect(
        (await files.read('config.txt', artifactId: updated['id']))['text'],
        'two two',
      );
      expect(
        (store.get('task/tenant/task')!.value['artifacts'] as List),
        hasLength(2),
      );
    },
  );

  test(
    'file paths cannot escape task storage or overwrite reserved runtime files',
    () async {
      final files = TaskTextFiles(owner());
      for (final path in [
        '../secret',
        '/etc/passwd',
        r'C:\secret.txt',
        'a/../../secret',
        'a//b',
        '.xiaoqi/dependency-lock.json',
        'plugin-agent://id/file.md',
      ]) {
        await expectLater(
          Future.sync(() => files.write(path, 'text')),
          throwsFormatException,
        );
      }
      expect(store.summary()['objects'], 0);
      expect(
        (store.get('task/tenant/task')!.value['artifacts'] as List),
        isEmpty,
      );
    },
  );

  test('read checks ownership and bytes before returning any text', () async {
    final files = TaskTextFiles(owner());
    final written = (await files.write('owned.txt', 'safe'))['artifact'] as Map;
    var task = store.get('task/tenant/task')!;
    final owned = (task.value['artifacts'] as List).single as Map;
    const foreignKey = 'tenants/other/tasks/other/artifacts/foreign';
    final foreign = utf8.encode('private other task');
    store.putTaskBlob(foreignKey, foreign);
    store.put('task/tenant/task', {
      ...task.value,
      'artifacts': [
        ...task.value['artifacts'] as List,
        {
          'id': 'foreign',
          'name': 'foreign.txt',
          'size': foreign.length,
          'sha256': sha256.convert(foreign).toString(),
          'object_key': foreignKey,
        },
      ],
    }, task.revision);
    await expectLater(files.read('foreign.txt'), throwsStateError);
    store.putTaskBlob(owned['object_key'], utf8.encode('evil'));
    await expectLater(
      files.read('owned.txt', artifactId: written['id']),
      throwsStateError,
    );
  });

  test(
    'streamed Unicode pages cross UTF-8 chunk boundaries and budgets remain task-owned',
    () async {
      final files = TaskTextFiles(owner());
      await files.write('unicode.txt', '${'a' * 65535}🍀中文');
      final tail = await files.read('unicode.txt', offset: 65534, maxChars: 4);
      expect(tail['text'], 'a🍀中文');
      expect(tail['total_characters'], 65538);
      expect(tail.containsKey('next_offset'), false);
      await files.write('empty.txt', '');
      expect((await files.read('empty.txt'))['text'], '');
      final task = store.get('task/tenant/task')!.value;
      expect(taskToolOperationsUsed(task), 4);
      final current = store.get('task/tenant/task')!;
      store.put('task/tenant/task', {
        ...current.value,
        'cancel_requested': true,
      }, current.revision);
      await expectLater(files.write('stopped.txt', 'no'), throwsStateError);
      expect(taskToolOperationsUsed(store.get('task/tenant/task')!.value), 4);
    },
  );

  test(
    'an edit cannot commit over a newer version created while its source was read',
    () async {
      store.close();
      final paused = PausingStore(root: root.path);
      store = paused;
      final files = TaskTextFiles(owner());
      final first = (await files.write('note.txt', 'one'))['artifact'] as Map;
      final editing = files.edit(first['id'], 'one', 'edited');
      final failed = expectLater(editing, throwsStateError);
      await paused.paused.future;
      await files.write('note.txt', 'newer', baseArtifactId: first['id']);
      paused.release.complete();
      await failed;
      expect((await files.read('note.txt'))['text'], 'newer');
      expect(
        (store.get('task/tenant/task')!.value['artifacts'] as List),
        hasLength(2),
      );
      expect(store.summary()['objects'], 2);
    },
  );
}
