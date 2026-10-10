import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory directory;
  late CloudStore store;
  late File worker;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('xiaoqi-code-test-');
    store = CloudStore(root: directory.path);
    store.put('task/personal/task-code', {
      'task_id': 'task-code',
      'status': 'running',
      'events': [],
      'artifacts': [],
      'skill_script_runs': 0,
    }, null);
    worker = File('${directory.path}${Platform.pathSeparator}worker.py');
    worker.writeAsStringSync('''
import base64
import json
import sys
request = json.loads(sys.stdin.readline())
assert "api_key" not in request
print(json.dumps({"type":"sandbox_started","sandbox_id":"sandbox-test"}), flush=True)
print(json.dumps({"type":"result","ok":True,"stdout":"hello","stderr":"","artifacts":[{"name":"report.txt","media_type":"text/plain","base64":"${base64Encode(utf8.encode('saved'))}"}],"cleanup_pending":False}), flush=True)
''');
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'tracks local Docker sandbox lifecycle and stores a private task artifact',
    () async {
      final service = DockerCodeExecutionService(
        store,
        pythonExecutable: Platform.isWindows ? 'python' : 'python3',
        workerPath: worker.path,
      );
      final output = await service.execute(
        tenantId: 'personal',
        taskId: 'task-code',
        code: 'print("hello")',
        language: 'python',
        authorizedDomains: const [],
        materials: const [],
        skillFiles: const {},
        cancellation: CancellationController().token,
      );

      expect(output, contains('hello'));
      expect(output, contains('report.txt'));
      final task = store.get('task/personal/task-code')!.value;
      expect(task['sandbox_id'], isNull);
      expect(task['sandbox_cleanup_pending'], isFalse);
      final artifact = (task['artifacts'] as List).single as Map;
      expect(
        utf8.decode(store.getObject(artifact['object_key'] as String)),
        'saved',
      );
      final events = task['events'] as List;
      expect((events.single as Map)['type'], 'artifacts_ready');
    },
  );

  test('limits a skill script to one execution per task', () async {
    final service = DockerCodeExecutionService(
      store,
      pythonExecutable: Platform.isWindows ? 'python' : 'python3',
      workerPath: worker.path,
    );
    Future<String> runScript() => service.execute(
      tenantId: 'personal',
      taskId: 'task-code',
      code: 'print("skill")',
      language: 'python',
      authorizedDomains: const [],
      materials: const [],
      skillFiles: const {
        'scripts/test.py': [112],
      },
      cancellation: CancellationController().token,
      scriptPath: 'scripts/test.py',
    );

    await runScript();
    await expectLater(runScript(), throwsA(isA<StateError>()));
  });
}
