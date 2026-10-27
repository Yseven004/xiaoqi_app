import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/execution_limits.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  test(
    'bounded script errors retain the terminal cause after long progress logs',
    () {
      final error = StateError(
        '${'progress\n' * 1000}FileNotFoundError: python3 -c\nerror: exit 1',
      );
      final message = DockerCodeExecutionService.failureDetails(error);
      expect(message.length, lessThanOrEqualTo(2000));
      expect(message, contains('FileNotFoundError: python3 -c'));
      expect(message, endsWith('error: exit 1'));
    },
  );

  late Directory directory;
  late CloudStore store;
  late File worker;

  String pythonExecutable() =>
      Platform.environment['XIAOQI_TEST_PYTHON'] ??
      (Platform.isWindows ? 'python' : 'python3');

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
    'failed script retains partial files without reopening confirmed cleanup',
    () async {
      worker.writeAsStringSync(
        worker.readAsStringSync().replaceFirst(
          '"ok":True',
          '"ok":False,"error":"exit 7"',
        ),
      );
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      await expectLater(
        service.execute(
          tenantId: 'personal',
          taskId: 'task-code',
          code: 'exit 7',
          language: 'shell',
          authorizedDomains: [],
          materials: [],
          skillFiles: {},
          cancellation: CancellationController().token,
        ),
        throwsA(isA<SandboxExecutionError>()),
      );
      final task = store.get('task/personal/task-code')!.value;
      expect(task['sandbox_cleanup_pending'], false);
      final file = (task['artifacts'] as List).single as Map;
      expect(utf8.decode(store.getObject(file['object_key'])), 'saved');
    },
  );

  test(
    'code and query share one atomic task budget across resume and steering',
    () async {
      const limits = ExecutionLimits(toolOperations: 2);
      final queries = ToolExecution(
        store,
        'personal',
        'task-code',
        TurnContract(mode: 'workflow', imageLimit: 0),
        requestIdentity: 'first',
        limits: limits,
      )..bind();
      await queries.query(
        slot: 'search',
        arguments: {},
        invoke: (_) async => {'ok': true},
      );
      Future<String> runCode() =>
          DockerCodeExecutionService(
            store,
            workerPath: worker.path,
            pythonExecutable: pythonExecutable(),
            limits: limits,
          ).execute(
            tenantId: 'personal',
            taskId: 'task-code',
            code: 'print(1)',
            language: 'python',
            authorizedDomains: [],
            materials: [],
            skillFiles: {},
            cancellation: CancellationController().token,
          );
      await runCode();
      expect(
        taskToolOperationsUsed(store.get('task/personal/task-code')!.value),
        2,
      );
      await expectLater(runCode(), throwsA(isA<ExecutionBudgetExceeded>()));
      var providerCalls = 0;
      final steered = ToolExecution(
        store,
        'personal',
        'task-code',
        TurnContract(mode: 'workflow', imageLimit: 0),
        requestIdentity: 'second',
        limits: limits,
      )..bind();
      await expectLater(
        steered.query(
          slot: 'search',
          arguments: {},
          invoke: (_) async {
            providerCalls++;
            return {};
          },
        ),
        throwsA(isA<ExecutionBudgetExceeded>()),
      );
      expect(providerCalls, 0);
      expect(
        store.get('task/personal/task-code')!.value['code_execution_runs'],
        1,
      );
    },
  );

  test(
    'installed Shell entry uses its immutable file budget rather than inline code limit',
    () async {
      worker.writeAsStringSync(r'''
import base64, json, sys
request = json.loads(sys.stdin.readline())
assert request['script_path'] == 'scripts/large.sh'
assert request['language'] == 'shell'
assert len(request['code'].encode()) < 100
assert len(base64.b64decode(request['skill_files']['scripts/large.sh'])) == 70 * 1024
print(json.dumps({'type':'result','ok':True,'stdout':'file-budget-verified','stderr':'','artifacts':[],'cleanup_pending':False}), flush=True)
''');
      final result =
          await DockerCodeExecutionService(
            store,
            workerPath: worker.path,
            pythonExecutable: pythonExecutable(),
          ).execute(
            tenantId: 'personal',
            taskId: 'task-code',
            code: '',
            language: 'shell',
            authorizedDomains: [],
            materials: [],
            skillFiles: {'scripts/large.sh': List.filled(70 * 1024, 35)},
            scriptPath: 'scripts/large.sh',
            cancellation: CancellationController().token,
          );
      expect(result, 'file-budget-verified');
    },
  );

  test(
    'tracks local Docker sandbox lifecycle and stores a private task artifact',
    () async {
      final service = DockerCodeExecutionService(
        store,
        pythonExecutable: pythonExecutable(),
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

  test(
    'counts actual script attempts and retains the budget on resume',
    () async {
      final service = DockerCodeExecutionService(
        store,
        pythonExecutable: pythonExecutable(),
        workerPath: worker.path,
        limits: const ExecutionLimits(scriptExecutions: 3),
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

      for (var run = 1; run <= 3; run++) {
        await runScript();
        final value = store.get('task/personal/task-code')!.value;
        expect(value['skill_script_runs'], run);
        expect(value['code_execution_runs'], run);
      }
      await expectLater(runScript(), throwsA(isA<StateError>()));
      final resumed = DockerCodeExecutionService(
        store,
        pythonExecutable: pythonExecutable(),
        workerPath: worker.path,
        limits: const ExecutionLimits(scriptExecutions: 3),
      );
      await expectLater(
        resumed.execute(
          tenantId: 'personal',
          taskId: 'task-code',
          code: 'print("skill")',
          language: 'python',
          authorizedDomains: const [],
          materials: const [],
          skillFiles: const {
            'scripts/test.py': [112],
          },
          scriptPath: 'scripts/test.py',
          cancellation: CancellationController().token,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'failed executions consume attempts and cannot reset the budget',
    () async {
      worker.writeAsStringSync('''
import json
print(json.dumps({"type":"result","ok":False,"error":"script failed"}), flush=True)
''');
      final service = DockerCodeExecutionService(
        store,
        pythonExecutable: pythonExecutable(),
        workerPath: worker.path,
        limits: const ExecutionLimits(toolOperations: 2),
      );
      Future<String> run() => service.execute(
        tenantId: 'personal',
        taskId: 'task-code',
        code: 'raise Exception()',
        language: 'python',
        authorizedDomains: const [],
        materials: const [],
        skillFiles: const {},
        cancellation: CancellationController().token,
      );
      for (var attempt = 1; attempt <= 2; attempt++) {
        await expectLater(run(), throwsStateError);
        expect(
          store.get('task/personal/task-code')!.value['code_execution_runs'],
          attempt,
        );
      }
      await expectLater(
        run(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('预算已用完'),
          ),
        ),
      );
      expect(
        store.get('task/personal/task-code')!.value['code_execution_runs'],
        2,
      );
    },
  );

  for (final format in {
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'pdf': 'application/pdf',
    'png': 'image/png',
  }.entries) {
    test('reuses ${format.key} bytes by owned task artifact ID', () async {
      final bytes = [0, 255, 128, 80, 75, 3, 4, 10];
      const id = 'binary-artifact';
      const key = 'tenants/personal/tasks/task-code/artifacts/$id';
      store.putTaskBlob(key, bytes);
      final task = store.get('task/personal/task-code')!;
      store.put('task/personal/task-code', {
        ...task.value,
        'artifacts': [
          {
            'id': id,
            'name': 'report.${format.key}',
            'media_type': format.value,
            'object_key': key,
          },
        ],
      }, task.revision);
      worker.writeAsStringSync('''
import base64, json, sys
request = json.loads(sys.stdin.readline())
material = next(item for item in request["materials"] if item["artifact_id"] == "$id")
assert base64.b64decode(material["base64"]) == bytes([${bytes.join(',')}])
assert material["media_type"] == "${format.value}"
print(json.dumps({"type":"result","ok":True,"stdout":"binary preserved","artifacts":[]}), flush=True)
''');
      final service = DockerCodeExecutionService(
        store,
        pythonExecutable: pythonExecutable(),
        workerPath: worker.path,
      );
      final result = await service.execute(
        tenantId: 'personal',
        taskId: 'task-code',
        code: 'print("read binary")',
        language: 'python',
        authorizedDomains: const [],
        materials: const [],
        skillFiles: const {},
        artifactIds: const [id],
        cancellation: CancellationController().token,
      );
      expect(result, contains('binary preserved'));
    });
  }

  test(
    'cannot inject another task artifact through a forged object key',
    () async {
      const id = 'foreign';
      const key = 'tenants/other/tasks/private/artifacts/$id';
      store.putTaskBlob(key, [1, 2, 3]);
      final task = store.get('task/personal/task-code')!;
      store.put('task/personal/task-code', {
        ...task.value,
        'artifacts': [
          {
            'id': id,
            'name': 'secret.pdf',
            'media_type': 'application/pdf',
            'object_key': key,
          },
        ],
      }, task.revision);
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
      );
      await expectLater(
        service.execute(
          tenantId: 'personal',
          taskId: 'task-code',
          code: 'print("read")',
          language: 'python',
          authorizedDomains: const [],
          materials: const [],
          skillFiles: const {},
          artifactIds: const [id],
          cancellation: CancellationController().token,
        ),
        throwsStateError,
      );
      expect(
        store.get('task/personal/task-code')!.value['code_execution_runs'],
        isNull,
      );
    },
  );

  test(
    'makes text artifacts available to the next isolated script call',
    () async {
      final service = DockerCodeExecutionService(
        store,
        pythonExecutable: pythonExecutable(),
        workerPath: worker.path,
      );
      await service.execute(
        tenantId: 'personal',
        taskId: 'task-code',
        code: 'print("first")',
        language: 'python',
        authorizedDomains: const [],
        materials: const [],
        skillFiles: const {},
        cancellation: CancellationController().token,
      );
      worker.writeAsStringSync('''
import base64
import json
import sys
request = json.loads(sys.stdin.readline())
material = next(item for item in request["materials"] if item["name"] == "report.txt")
assert base64.b64decode(material["base64"]) == b"saved"
print(json.dumps({"type":"result","ok":True,"stdout":"reused","stderr":"","artifacts":[],"cleanup_pending":False}), flush=True)
''');

      final output = await service.execute(
        tenantId: 'personal',
        taskId: 'task-code',
        code: 'print("second")',
        language: 'python',
        authorizedDomains: const [],
        materials: const [],
        skillFiles: const {},
        cancellation: CancellationController().token,
      );

      expect(output, contains('reused'));
    },
  );

  test('asks the runner to revoke an active task network proxy', () async {
    worker.writeAsStringSync('''
import json
import sys
request = json.loads(sys.stdin.readline())
assert request["action"] == "disable_network"
assert len(request["task_id"]) == 64
print(json.dumps({"type": "result", "ok": True, "network": "off"}), flush=True)
''');
    final service = DockerCodeExecutionService(
      store,
      pythonExecutable: pythonExecutable(),
      workerPath: worker.path,
    );

    await service.disableNetwork(tenantId: 'personal', taskId: 'task-code');
  });
}
