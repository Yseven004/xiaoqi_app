import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';

import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/execution_limits.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';
import 'package:xiaoqi_genkit_server/src/network_call_authorization.dart';

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
    'ordinary tasks cannot request the installer execution budget',
    () async {
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      await expectLater(
        service.execute(
          tenantId: 'personal',
          taskId: 'task-code',
          code: 'pass',
          language: 'python',
          authorizedDomains: [],
          materials: [],
          skillFiles: {},
          cancellation: CancellationController().token,
          profile: SandboxExecutionProfile.dependencyBuild,
        ),
        throwsStateError,
      );
      final task = store.get('task/personal/task-code')!.value;
      expect(task['code_execution_runs'] ?? 0, 0);
      expect(task['artifacts'], isEmpty);
    },
  );

  test(
    'network execution carries private runner token and rechecks after grant',
    () async {
      final captured = File('${directory.path}/network-request.json');
      final token = '123456789.${'a' * 64}';
      worker.writeAsStringSync('''
import json,sys
r=json.loads(sys.stdin.readline())
if r.get('action') == 'network_token':
 assert r['network_revision'] == 4
 print(json.dumps({'type':'result','ok':True,'network_token':'$token'}))
elif r.get('action'):
 print(json.dumps({'type':'result','ok':True}))
else:
 open(${jsonEncode(captured.path)},'w').write(json.dumps(r))
 print(json.dumps({'type':'result','ok':True,'stdout':'done','artifacts':[],'cleanup_pending':False}))
''');
      var checks = 0;
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
        limits: const ExecutionLimits(toolOperations: 1),
      );
      final execution = ToolExecution(
        store,
        'personal',
        'task-code',
        TurnContract(mode: 'workflow', imageLimit: 0),
        requestIdentity: 'network-budget',
        limits: const ExecutionLimits(toolOperations: 1),
      )..bind();
      final task = store.get('task/personal/task-code')!;
      store.put('task/personal/task-code', {
        ...task.value,
        'network_policy_revision': 4,
      }, task.revision);
      final grant = NetworkCallAuthorization(
        execution: execution,
        domains: ['example.com'],
        tool: 'execute_python',
        arguments: {'code': 'pass'},
        authority: {},
      );
      grant.decide(
        resumed: {
          'approved': true,
          'approval_hash': grant.approvalHash,
          'domains': ['example.com'],
        },
      );
      Future<String> invoke() => service.execute(
        tenantId: 'personal',
        taskId: 'task-code',
        code: 'pass',
        language: 'python',
        authorizedDomains: ['example.com'],
        materials: [],
        skillFiles: {},
        cancellation: CancellationController().token,
        beforeSubmit: () {
          checks++;
        },
      );
      final output = await grant.execute(invoke);
      expect(await grant.execute(invoke), output);
      final sent = jsonDecode(captured.readAsStringSync()) as Map;
      expect(sent['network_token'], token);
      expect(sent['network_revision'], 4);
      expect(sent['authorized_domains'], ['example.com']);
      expect(checks, 3);
      expect(
        store.get('task/personal/task-code')!.value['code_execution_runs'],
        1,
      );
      expect(
        taskToolOperationsUsed(store.get('task/personal/task-code')!.value),
        1,
      );
    },
  );
  test(
    'hook protocol profile shares normal deadlines and rejects alternate entrypoints before IO',
    () async {
      expect(
        SandboxExecutionProfile.pluginHook.runSeconds,
        SandboxExecutionProfile.code.runSeconds,
      );
      expect(
        SandboxExecutionProfile.pluginHook.apiDeadline,
        SandboxExecutionProfile.code.apiDeadline,
      );
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      for (final entry in [
        (language: 'python', path: null),
        (language: 'javascript', path: 'scripts/entry.js'),
      ]) {
        await expectLater(
          service.execute(
            tenantId: 'personal',
            taskId: 'task-code',
            code: 'process.exit(0)',
            language: entry.language,
            scriptPath: entry.path,
            authorizedDomains: [],
            materials: [],
            skillFiles: {},
            cancellation: CancellationController().token,
            profile: SandboxExecutionProfile.pluginHook,
          ),
          throwsStateError,
        );
      }
      expect(
        store.get('task/personal/task-code')!.value['code_execution_runs'] ?? 0,
        0,
      );
    },
  );

  test(
    'network permission withdrawn during token lookup never submits execution',
    () async {
      final token = '123456789.${'a' * 64}';
      worker.writeAsStringSync('''
import json,sys
r=json.loads(sys.stdin.readline())
assert r['action'] == 'network_token'
print(json.dumps({'type':'result','ok':True,'network_token':'$token'}))
''');
      var checks = 0;
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      await expectLater(
        service.execute(
          tenantId: 'personal',
          taskId: 'task-code',
          code: 'pass',
          language: 'python',
          authorizedDomains: ['example.com'],
          materials: [],
          skillFiles: {},
          cancellation: CancellationController().token,
          beforeSubmit: () {
            if (++checks > 1) throw StateError('network permission withdrawn');
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('withdrawn'),
          ),
        ),
      );
      expect(
        store.get('task/personal/task-code')!.value['code_execution_runs'],
        isNull,
      );
    },
  );

  test(
    'scope withdrawn during bridge startup never submits the old execution',
    () async {
      final scope = ToolExecution(
        store,
        'personal',
        'task-code',
        TurnContract(mode: 'workflow', imageLimit: 0),
        requestIdentity: 'original',
      )..bind();
      final submitted = File('${directory.path}/submitted.json');
      worker.writeAsStringSync('''
import sys
payload=sys.stdin.readline()
if payload:
 open(${jsonEncode(submitted.path)},'w').write(payload)
''');
      var checks = 0;
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      await expectLater(
        service.execute(
          tenantId: 'personal',
          taskId: 'task-code',
          code: 'print("old operation")',
          language: 'python',
          authorizedDomains: [],
          materials: [],
          skillFiles: {},
          cancellation: CancellationController().token,
          beforeSubmit: () {
            checks++;
            if (checks == 1)
              scheduleMicrotask(() {
                ToolExecution(
                  store,
                  'personal',
                  'task-code',
                  TurnContract(mode: 'workflow', imageLimit: 0),
                  requestIdentity: 'updated',
                ).bind();
              });
            scope.check('workspace');
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'scope failure',
            contains('用户已更新任务'),
          ),
        ),
      );
      expect(checks, 2);
      expect(submitted.existsSync(), false);
      final task = store.get('task/personal/task-code')!.value;
      expect(task['code_execution_runs'], 1);
      expect(task['code_execution_operations'], isNull);
    },
  );

  test(
    'scope rejected before bridge startup does not consume an execution attempt',
    () async {
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      await expectLater(
        service.execute(
          tenantId: 'personal',
          taskId: 'task-code',
          code: 'print("old")',
          language: 'python',
          authorizedDomains: [],
          materials: [],
          skillFiles: {},
          cancellation: CancellationController().token,
          beforeSubmit: () => throw StateError('revoked-before-start'),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'scope failure',
            'revoked-before-start',
          ),
        ),
      );
      expect(
        store.get('task/personal/task-code')!.value['code_execution_runs'] ?? 0,
        0,
      );
    },
  );

  Future<Map<String, List<int>>> prepareArchive(
    Map<String, String> entries,
  ) async {
    final archive = Archive();
    for (final entry in entries.entries) {
      archive.add(ArchiveFile.string(entry.key, entry.value));
    }
    final encoded = base64Encode(ZipEncoder().encode(archive));
    File(
      '${directory.path}/prepare_dependencies.py',
    ).writeAsStringSync('# trusted installer fixture');
    worker.writeAsStringSync('''
import json,sys
request=json.loads(sys.stdin.readline())
if request.get('action') == 'network_token':
 print(json.dumps({'ok':True,'network_token':'123456789.${'a' * 64}'})); sys.exit(0)
if request.get('action'):
 print(json.dumps({'acknowledged':True,'cleanup_pending':False})); sys.exit(0)
assert 'scripts/build.cjs' in request['skill_files']
assert request['execution_profile'] == 'dependency_build'
print(json.dumps({'type':'result','ok':True,'stdout':'','stderr':'','cleanup_pending':False,'artifacts':[{'name':'dependencies.zip','media_type':'application/zip','base64':'$encoded'}]}),flush=True)
''');
    return DockerCodeExecutionService(
      store,
      workerPath: worker.path,
      pythonExecutable: pythonExecutable(),
    ).prepareDependencies('personal', {
      'package.json': utf8.encode(
        '{"scripts":{"build":"node scripts/build.cjs"}}',
      ),
      'scripts/build.cjs': utf8.encode('// package-owned build source'),
    });
  }

  test(
    'prepared build output keeps package paths and source reaches isolated worker',
    () async {
      final prepared = await prepareArchive({
        '.xiaoqi/dependency-lock.json': '{"schema":1}',
        '.xiaoqi/built/dist/index.cjs': 'module.exports=42;',
      });
      expect(utf8.decode(prepared['dist/index.cjs']!), 'module.exports=42;');
      expect(prepared.containsKey('.xiaoqi/built/dist/index.cjs'), false);
      expect(
        store.list('task/personal/').length,
        1,
        reason: 'temporary dependency task must be removed',
      );
    },
  );

  test(
    'dependency installation recovers the original build across restarts without replay',
    () async {
      final archive = Archive()
        ..add(
          ArchiveFile.string('.xiaoqi/dependency-lock.json', '{"schema":1}'),
        )
        ..add(
          ArchiveFile.string(
            '.xiaoqi/built/dist/index.cjs',
            'module.exports=42;',
          ),
        );
      final encoded = base64Encode(ZipEncoder().encode(archive));
      final original = File('${directory.path}/install-original.json');
      final ready = File('${directory.path}/install-ready');
      final ack = File('${directory.path}/install-ack');
      File(
        '${directory.path}/prepare_dependencies.py',
      ).writeAsStringSync('# trusted installer');
      worker.writeAsStringSync('''
import json,pathlib,sys
r=json.loads(sys.stdin.readline())
original=pathlib.Path(${jsonEncode(original.path)})
if r.get('action') == 'network_token':
 print(json.dumps({'ok':True,'network_token':'123456789.${'a' * 64}'}))
elif r.get('action') == 'execution_result':
 first=json.loads(original.read_text())
 assert r['execution_id'] == first['execution_id']
 complete=pathlib.Path(${jsonEncode(ready.path)}).exists()
 failed=complete and pathlib.Path(${jsonEncode(ready.path)}).read_text() == 'fail'
 result={'ok':not failed,'stderr':'original build failure diagnostic' if failed else '', 'execution_id':first['execution_id'],'cleanup_pending':False,'artifacts':[{'name':'dependencies.zip','base64':'$encoded','media_type':'application/zip'}]}
 print(json.dumps({'ok':True,'finished':complete,'completion':result if complete else None}))
elif r.get('action') == 'ack_execution':
 ack=pathlib.Path(${jsonEncode(ack.path)})
 acknowledged=ack.exists()
 ack.write_text('ack')
 print(json.dumps({'ok':acknowledged,'acknowledged':acknowledged,'cleanup_pending':False}))
elif r.get('action'):
 print(json.dumps({'ok':True}))
else:
 assert not original.exists(), 'dependency build was replayed'
 original.write_text(json.dumps(r))
''');
      DockerCodeExecutionService service() => DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      final source = {
        'package.json': utf8.encode('{}'),
        'source.js': utf8.encode('// source'),
      };
      final firstAttempt = expectLater(
        service().prepareDependencies('personal', source),
        throwsA(isA<SandboxExecutionError>()),
      );
      await expectLater(
        service().prepareDependencies('personal', source),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'concurrent preparation',
            contains('正在准备'),
          ),
        ),
      );
      await firstAttempt;
      final pending = store.list('task/personal/install-').single;
      final firstRequest = original.readAsStringSync();
      store.put(pending.$1, {
        ...pending.$2.value,
        'dependency_source_digest': 'different-source',
      }, pending.$2.revision);
      await expectLater(
        service().prepareDependencies('personal', source),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'source binding',
            contains('来源不匹配'),
          ),
        ),
      );
      final rejected = store.get(pending.$1)!;
      expect(rejected.value['dependency_source_digest'], 'different-source');
      store.put(pending.$1, pending.$2.value, rejected.revision);
      store.close();
      store = CloudStore(root: directory.path);
      await expectLater(
        service().prepareDependencies('personal', source),
        throwsStateError,
      );
      expect(store.list('task/personal/install-').single.$1, pending.$1);
      expect(original.readAsStringSync(), firstRequest);
      ready.writeAsStringSync('ready');
      final recovered = await service().prepareDependencies(
        'personal',
        Map.fromEntries(source.entries.toList().reversed),
      );
      expect(utf8.decode(recovered['dist/index.cjs']!), 'module.exports=42;');
      final saved = store.get(pending.$1)!.value;
      expect(saved['code_execution_runs'], 1);
      expect(saved['artifacts'], hasLength(1));
      expect(
        (saved['code_execution_operations'] as Map)
            .values
            .single['ack_pending'],
        true,
      );
      final acknowledged = await service().prepareDependencies(
        'personal',
        source,
      );
      expect(acknowledged.keys, contains('dist/index.cjs'));
      expect(store.get(pending.$1), isNull);
      expect(original.readAsStringSync(), firstRequest);
      original.deleteSync();
      ready.deleteSync();
      ack.deleteSync();
      await expectLater(
        service().prepareDependencies('personal', source),
        throwsA(isA<SandboxExecutionError>()),
      );
      final failedRequest = original.readAsStringSync();
      ready.writeAsStringSync('fail');
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          service().prepareDependencies('personal', source),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'original failure diagnostics',
              contains('original build failure diagnostic'),
            ),
          ),
        );
        expect(original.readAsStringSync(), failedRequest);
        expect(store.get(pending.$1) == null, attempt == 1);
      }
    },
  );

  test(
    'prepared build output cannot overwrite reserved runtime or alias dependencies',
    () async {
      for (final entries in [
        {
          '.xiaoqi/dependency-lock.json': '{}',
          '.xiaoqi/built/.xiaoqi/dependency-lock.json': 'poison',
        },
        {
          '.xiaoqi/dependency-lock.json': '{}',
          'node_modules/pkg/index.js': 'original',
          '.xiaoqi/built/node_modules/pkg/index.js': 'poison',
        },
        {
          '.xiaoqi/dependency-lock.json': '{}',
          '.xiaoqi/built/../escape': 'poison',
        },
        {
          '.xiaoqi/dependency-lock.json': '{}',
          '.xiaoqi/built/C:/escape': 'poison',
        },
      ]) {
        await expectLater(prepareArchive(entries), throwsStateError);
      }
    },
  );

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
    'acknowledged files do not hide an earlier execution cleanup failure',
    () async {
      final clean = jsonEncode('${directory.path}/clean');
      worker.writeAsStringSync('''
import json, pathlib, sys
request = json.loads(sys.stdin.readline())
if request.get('action') == 'ack_execution':
    second_file = pathlib.Path($clean+'-second')
    second_id = second_file.read_text() if second_file.exists() else None
    pending = not pathlib.Path($clean).exists() and request['execution_id'] != second_id
    print(json.dumps({'type':'result','ok':True,'acknowledged':True,'cleanup_pending':pending}), flush=True)
elif request.get('action') == 'execution_result':
    print(json.dumps({'type':'result','ok':True,'finished':True,'cleanup_pending':not pathlib.Path($clean).exists(),'completion':None}), flush=True)
else:
    second = request['code'] == 'second'
    if second:
        pathlib.Path($clean+'-second').write_text(request['execution_id'])
    print(json.dumps({'type':'sandbox_started','sandbox_id':request['execution_id']}), flush=True)
    print(json.dumps({'type':'result','ok':True,'execution_id':request['execution_id'],'cleanup_pending':not second,'sandbox_id':request['execution_id'] if not second else None,'artifacts':[{'name':'second.txt' if second else 'first.txt','media_type':'text/plain','base64':'c2F2ZWQ='}]}), flush=True)
''');
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      Future<String> run(String code) => service.execute(
        tenantId: 'personal',
        taskId: 'task-code',
        code: code,
        language: 'shell',
        authorizedDomains: [],
        materials: [],
        skillFiles: {},
        cancellation: CancellationController().token,
      );
      await run('first');
      await run('second');
      var task = store.get('task/personal/task-code')!.value;
      expect(task['sandbox_cleanup_pending'], true);
      expect((task['artifacts'] as List), hasLength(2));
      File('${directory.path}/clean').writeAsStringSync('clean');
      await service.recoverExecutions(
        tenantId: 'personal',
        taskId: 'task-code',
      );
      task = store.get('task/personal/task-code')!.value;
      expect(task['sandbox_cleanup_pending'], false);
      expect(task['sandbox_id'], null);
      expect(task['code_execution_runs'], 2);
      expect((task['artifacts'] as List), hasLength(2));
    },
  );

  test(
    'a rebuilt service recovers original files once and acknowledges after persistence',
    () async {
      final original = jsonEncode('${directory.path}/original.json');
      final ready = jsonEncode('${directory.path}/ready');
      final ack = jsonEncode('${directory.path}/ack');
      worker.writeAsStringSync('''
import json, pathlib, sys
request = json.loads(sys.stdin.readline())
original = pathlib.Path($original)
if request.get('action') == 'execution_result':
    first = json.loads(original.read_text())
    assert all(request[key] == first[key] for key in ['task_id','execution_id','issued_at'])
    completed = pathlib.Path($ready).exists()
    result = {'type':'result','ok':True,'stdout':'calculation result: 42','execution_id':first['execution_id'],'cleanup_pending':False,'artifacts':[{'name':'recovered.txt','media_type':'text/plain','base64':'cmVjb3ZlcmVk'}]}
    print(json.dumps({'type':'result','ok':True,'finished':completed,'completion':result if completed else None}), flush=True)
elif request.get('action') == 'ack_execution':
    retry = pathlib.Path($ack).exists()
    pathlib.Path($ack).write_text('ack')
    print(json.dumps({'type':'result','ok':retry,'acknowledged':retry}), flush=True)
else:
    assert not original.exists(), 'code was replayed'
    original.write_text(json.dumps(request))
    print(json.dumps({'type':'sandbox_started','sandbox_id':'recovery-sandbox'}), flush=True)
    # Simulates losing the stream while the runner continues independently.
''');
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      await expectLater(
        service.execute(
          tenantId: 'personal',
          taskId: 'task-code',
          code: 'pass',
          language: 'python',
          authorizedDomains: [],
          materials: [],
          skillFiles: {},
          cancellation: CancellationController().token,
        ),
        throwsA(isA<SandboxExecutionError>()),
      );
      expect(File('${directory.path}/ack').existsSync(), false);
      File('${directory.path}/ready').writeAsStringSync('ready');
      store.close();
      store = CloudStore(root: directory.path);
      final resumed = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      await resumed.recoverExecutions(
        tenantId: 'personal',
        taskId: 'task-code',
      );
      expect(
        ((store
                        .get('task/personal/task-code')!
                        .value['code_execution_operations']
                    as Map)
                .values
                .single
            as Map)['ack_pending'],
        true,
      );
      await resumed.recoverExecutions(
        tenantId: 'personal',
        taskId: 'task-code',
      );
      final task = store.get('task/personal/task-code')!.value;
      final artifact = (task['artifacts'] as List).single as Map;
      expect(utf8.decode(store.getObject(artifact['object_key'])), 'recovered');
      expect(
        (task['events'] as List).whereType<Map>().where(
          (event) => event['type'] == 'artifacts_ready',
        ),
        hasLength(1),
      );
      expect(task['sandbox_cleanup_pending'], false);
      expect(File('${directory.path}/ack').existsSync(), true);
      final record =
          (task['code_execution_operations'] as Map).values.single as Map;
      expect(record['status'], 'persisted');
      expect(record['ack_pending'], false);
      expect(task['code_execution_runs'], 1);
      expect(
        jsonEncode(resumed.recoveredExecutionResults('personal', 'task-code')),
        contains('calculation result: 42'),
      );
    },
  );

  test(
    'cleanup failure before a container ID exists remains visible',
    () async {
      worker.writeAsStringSync('''
import json, sys
json.loads(sys.stdin.readline())
print(json.dumps({'type':'result','ok':False,'error':'prepare failed, volume busy','cleanup_pending':True,'artifacts':[]}), flush=True)
''');
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      await expectLater(
        service.execute(
          tenantId: 'personal',
          taskId: 'task-code',
          code: 'pass',
          language: 'python',
          authorizedDomains: [],
          materials: [],
          skillFiles: {},
          cancellation: CancellationController().token,
        ),
        throwsA(isA<SandboxExecutionError>()),
      );
      expect(
        store.get('task/personal/task-code')!.value['sandbox_cleanup_pending'],
        true,
      );
      worker.writeAsStringSync('''
import json, sys
request = json.loads(sys.stdin.readline())
assert request['action'] == 'execution_result'
print(json.dumps({'type':'result','ok':True,'finished':True,'cleanup_pending':False,'completion':None}), flush=True)
''');
      await service.recoverExecutions(
        tenantId: 'personal',
        taskId: 'task-code',
      );
      expect(
        store.get('task/personal/task-code')!.value['sandbox_cleanup_pending'],
        false,
      );
    },
  );

  test(
    'a late broken stream cannot downgrade an already recovered execution',
    () async {
      final originalFile = jsonEncode('${directory.path}/original.json');
      final ackFile = jsonEncode('${directory.path}/ack');
      worker.writeAsStringSync('''
import json, pathlib, sys, time
request = json.loads(sys.stdin.readline())
original = pathlib.Path($originalFile)
ack = pathlib.Path($ackFile)
if request.get('action') == 'execution_result':
    first = json.loads(original.read_text())
    result = {'type':'result','execution_id':first['execution_id'],'ok':True,'cleanup_pending':False,'stdout':'42','artifacts':[{'name':'recovered.txt','base64':'NDI=','media_type':'text/plain'}]}
    print(json.dumps({'type':'result','ok':True,'finished':True,'cleanup_pending':False,'completion':None if ack.exists() else result}), flush=True)
elif request.get('action') == 'ack_execution':
    ack.write_text('ack')
    print(json.dumps({'type':'result','ok':True,'acknowledged':True,'cleanup_pending':False}), flush=True)
else:
    assert not original.exists(), 'execution replayed'
    original.write_text(json.dumps(request))
    print(json.dumps({'type':'sandbox_started','sandbox_id':'late-stream'}), flush=True)
    deadline = time.monotonic() + 10
    while not ack.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert ack.exists()
    # The original result stream ends only after another service recovered it.
''');
      final first = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      final running = first.execute(
        tenantId: 'personal',
        taskId: 'task-code',
        code: 'pass',
        language: 'python',
        authorizedDomains: [],
        materials: [],
        skillFiles: {},
        cancellation: CancellationController().token,
      );
      final done = expectLater(running, throwsA(isA<SandboxExecutionError>()));
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return store.get('task/personal/task-code')!.value['sandbox_id'] !=
            'late-stream';
      }).timeout(const Duration(seconds: 10));
      final resumed = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      await resumed.recoverExecutions(
        tenantId: 'personal',
        taskId: 'task-code',
      );
      await done;
      final task = store.get('task/personal/task-code')!.value;
      final operation =
          (task['code_execution_operations'] as Map).values.single as Map;
      expect(operation['status'], 'persisted');
      expect(operation['ack_pending'], false);
      expect(task['sandbox_cleanup_pending'], false);
      expect(task['code_execution_runs'], 1);
      expect(task['artifacts'] as List, hasLength(1));
      expect(
        jsonEncode(resumed.recoveredExecutionResults('personal', 'task-code')),
        contains('42'),
      );
    },
  );

  test(
    'cancel keeps the result bridge alive until partial files and cleanup persist',
    () async {
      final marker = jsonEncode('${directory.path}/cancel.json');
      final identity = jsonEncode('${directory.path}/execution.json');
      worker.writeAsStringSync('''
import json, pathlib, sys, time
request = json.loads(sys.stdin.readline())
marker = pathlib.Path($marker)
identity = pathlib.Path($identity)
if request.get('action') == 'cancel_execution':
    original = json.loads(identity.read_text())
    assert all(request[key] == original[key] for key in ['task_id', 'execution_id', 'issued_at'])
    marker.write_text('cancel')
    print(json.dumps({'type':'result', 'ok':True}), flush=True)
else:
    identity.write_text(json.dumps(request))
    print(json.dumps({'type':'sandbox_started','sandbox_id':'cancel-sandbox'}), flush=True)
    deadline = time.monotonic() + 10
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert marker.exists(), 'cancel control was not received'
    print(json.dumps({'type':'result','ok':False,'error':'cancelled','artifacts':[{'name':'partial.txt','base64':'cGFydGlhbA==','media_type':'text/plain'}], 'cleanup_pending':False}), flush=True)
''');
      final cancellation = CancellationController();
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      final execution = service.execute(
        tenantId: 'personal',
        taskId: 'task-code',
        code: 'pass',
        language: 'python',
        authorizedDomains: [],
        materials: [],
        skillFiles: {},
        cancellation: cancellation.token,
      );
      // Attach the error observer before triggering cancellation.
      final finished = expectLater(
        execution,
        throwsA(isA<SandboxExecutionError>()),
      );
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return store.get('task/personal/task-code')!.value['sandbox_id'] !=
            'cancel-sandbox';
      }).timeout(const Duration(seconds: 10));
      cancellation.cancel();
      await finished;
      final task = store.get('task/personal/task-code')!.value;
      expect(task['sandbox_cleanup_pending'], false);
      final artifact = (task['artifacts'] as List).single as Map;
      expect(utf8.decode(store.getObject(artifact['object_key'])), 'partial');
      expect(File('${directory.path}/cancel.json').existsSync(), true);
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
assert request['network_revision'] == 7
assert len(request["task_id"]) == 64
print(json.dumps({"type": "result", "ok": True, "network": "off"}), flush=True)
''');
    final service = DockerCodeExecutionService(
      store,
      pythonExecutable: pythonExecutable(),
      workerPath: worker.path,
    );

    await service.disableNetwork(
      tenantId: 'personal',
      taskId: 'task-code',
      networkRevision: 7,
    );
  });
  test(
    'an unrelated scope identity never submits code to the runner',
    () async {
      final submitted = File('${directory.path}/unrelated-submission');
      worker.writeAsStringSync('''
import json, pathlib, sys
json.loads(sys.stdin.readline())
pathlib.Path(${jsonEncode(submitted.path)}).write_text('submitted')
''');
      final service = DockerCodeExecutionService(
        store,
        workerPath: worker.path,
        pythonExecutable: pythonExecutable(),
      );
      await expectLater(
        service.execute(
          tenantId: 'personal',
          taskId: 'task-code',
          code: 'pass',
          language: 'python',
          authorizedDomains: [],
          materials: [],
          skillFiles: {},
          scopeOperationId: 'f' * 64,
          cancellation: CancellationController().token,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error is SandboxExecutionError,
            'submitted effects',
            false,
          ),
        ),
      );
      expect(submitted.existsSync(), false);
      expect(
        store
            .get('task/personal/task-code')!
            .value['code_execution_operations'],
        isNull,
      );
    },
  );

  for (final scenario in [
    'success',
    'failed',
    'legacy-unknown',
    'other-unknown',
  ]) {
    test(
      'confirmed $scenario result reconciles its original authorized code operation',
      () async {
        final ok = scenario != 'failed';
        final originalPath = '${directory.path}/linked-original.json';
        final readyPath = '${directory.path}/linked-ready';
        worker.writeAsStringSync('''
import json, pathlib, sys
r = json.loads(sys.stdin.readline())
original = pathlib.Path(${jsonEncode(originalPath)})
if r.get('action') == 'network_token':
    print(json.dumps({'type':'result','ok':True,'network_token':'123456789.'+'a'*64}))
elif r.get('action') == 'execution_result':
    first = json.loads(original.read_text())
    assert all(r[k] == first[k] for k in ['task_id','execution_id','issued_at'])
    done = pathlib.Path(${jsonEncode(readyPath)}).exists()
    result = {'type':'result','ok':${ok ? 'True' : 'False'},'stdout':'original output 42','execution_id':first['execution_id'],'cleanup_pending':False,'artifacts':[{'name':'original.txt','base64':'b3JpZ2luYWwgYnl0ZXM='}],${ok ? '' : "'error':'original script failed',"}}
    print(json.dumps({'type':'result','ok':True,'finished':done,'completion':result if done else None}))
elif r.get('action') == 'ack_execution':
    print(json.dumps({'type':'result','ok':True,'acknowledged':True}))
else:
    assert r['authorized_domains'] == ['example.com']
    assert not original.exists(), 'the original code was replayed'
    original.write_text(json.dumps(r))
    print(json.dumps({'type':'sandbox_started','sandbox_id':'linked-sandbox'}))
''');
        ToolExecution makeExecution() => ToolExecution(
          store,
          'personal',
          'task-code',
          TurnContract(mode: 'workflow', imageLimit: 0),
          requestIdentity: 'linked-user-request',
        )..bind();
        NetworkCallAuthorization makeGrant(ToolExecution execution) =>
            NetworkCallAuthorization(
              execution: execution,
              domains: ['example.com'],
              tool: 'execute_python',
              arguments: {'code': 'pass'},
              authority: {'inputs': 'original-inputs'},
            );
        DockerCodeExecutionService makeService() => DockerCodeExecutionService(
          store,
          workerPath: worker.path,
          pythonExecutable: pythonExecutable(),
        );
        var execution = makeExecution();
        var grant = makeGrant(execution);
        grant.decide(
          resumed: {
            'approved': true,
            'approval_hash': grant.approvalHash,
            'domains': ['example.com'],
          },
        );
        await expectLater(
          grant.execute(
            () => makeService().execute(
              tenantId: 'personal',
              taskId: 'task-code',
              code: 'pass',
              language: 'python',
              authorizedDomains: ['example.com'],
              materials: [],
              skillFiles: {},
              scopeOperationId: grant.operationId,
              cancellation: CancellationController().token,
            ),
          ),
          throwsA(isA<SandboxExecutionError>()),
        );
        execution.markUncertainNetworkExecution(
          'original-code',
          operationId: grant.operationId,
        );
        if (scenario == 'legacy-unknown')
          execution.markUncertainNetworkExecution('older-unlinked-code');
        if (scenario == 'other-unknown')
          execution.markUncertainNetworkExecution(
            'another-pending-call',
            operationId: 'e' * 64,
          );
        expect(execution.hasUncertainNetworkExecution, true);
        final submitted = store.get('task/personal/task-code')!.value;
        final id = (submitted['code_execution_operations'] as Map).keys.single;
        expect(
          (submitted['scope_operations']
              as Map)[grant.operationId]['execution_id'],
          id,
        );
        expect(
          (submitted['scope_operations'] as Map)[grant.operationId]['status'],
          'unknown',
        );
        File(readyPath).writeAsStringSync('ready');
        store.close();
        store = CloudStore(root: directory.path);
        execution = makeExecution();
        grant = makeGrant(execution);
        await makeService().recoverExecutions(
          tenantId: 'personal',
          taskId: 'task-code',
        );
        final recovered = store.get('task/personal/task-code')!.value;
        final parent =
            (recovered['scope_operations'] as Map)[grant.operationId] as Map;
        expect(parent['status'], ok ? 'succeeded' : 'failed');
        expect(parent['result']['output'], contains('original output 42'));
        expect(parent['result']['output'], contains('original.txt'));
        expect(
          execution.hasUncertainNetworkExecution,
          const {'legacy-unknown', 'other-unknown'}.contains(scenario),
        );
        var replays = 0;
        final cached = grant.execute(() async {
          replays++;
          return 'must not rerun';
        });
        if (ok) {
          expect(await cached, contains('original output 42'));
        } else {
          await expectLater(cached, throwsA(isA<StateError>()));
        }
        execution.markUncertainNetworkExecution(
          'late-error',
          operationId: grant.operationId,
        );
        expect(
          execution.hasUncertainNetworkExecution,
          const {'legacy-unknown', 'other-unknown'}.contains(scenario),
        );
        expect(replays, 0);
        expect(recovered['code_execution_runs'], 1);
        expect((recovered['artifacts'] as List), hasLength(1));
      },
    );
  }
}
