import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

/// Drops the real HTTP result stream, then reads the original runner execution.
Future<void> verifyExecutionRecovery(
  CloudStore store,
  Directory directory,
  String tenant,
) async {
  final bridge = Platform.environment['SANDBOX_WORKER_PATH'];
  if (bridge == null) throw StateError('Recovery gate needs the real worker');
  final wrapper = File('${directory.path}/disconnect_worker.py');
  await wrapper.writeAsString('''
import json, os, subprocess, sys, urllib.request
request = json.load(sys.stdin)
if request.get('action'):
    result = subprocess.run([sys.executable, ${jsonEncode(bridge)}], input=json.dumps(request), text=True, capture_output=True)
    sys.stdout.write(result.stdout)
    sys.exit(result.returncode)
outgoing = urllib.request.Request(os.environ['SANDBOX_RUNNER_URL'].rstrip('/') + '/v1/execute', data=json.dumps(request).encode(), headers={'Authorization':'Bearer ' + os.environ['SANDBOX_RUNNER_TOKEN'], 'Content-Type':'application/json'})
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(outgoing, timeout=30) as response:
    # Close immediately after startup; no result payload reaches this bridge.
    sys.stdout.write(response.readline().decode())
    sys.stdout.flush()
''');
  const task = 'code-disconnect-recovery';
  final key = 'task/$tenant/$task';
  store.put(key, {'status': 'running', 'artifacts': [], 'events': []}, null);
  final interrupted = DockerCodeExecutionService(
    store,
    workerPath: wrapper.path,
  );
  try {
    await interrupted.execute(
      tenantId: tenant,
      taskId: task,
      code:
          "sleep 1\nprintf 'recovered-from-original' > /workspace/output/recovered.txt",
      language: 'shell',
      authorizedDomains: [],
      materials: [],
      skillFiles: {},
      cancellation: CancellationController().token,
    );
  } on SandboxExecutionError {
    // The original job may still be running after its stream was disconnected.
  }
  final resumed = DockerCodeExecutionService(store);
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    await resumed.recoverExecutions(tenantId: tenant, taskId: task);
    final operation =
        (store.get(key)!.value['code_execution_operations'] as Map)
                .values
                .single
            as Map;
    if (operation['status'] == 'persisted' && operation['ack_pending'] == false)
      break;
    if (DateTime.now().isAfter(deadline))
      throw StateError('Original execution result was not recovered');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await resumed.recoverExecutions(tenantId: tenant, taskId: task);
  final state = store.get(key)!.value;
  final artifact = (state['artifacts'] as List).single as Map;
  if (artifact['name'] != 'recovered.txt' ||
      utf8.decode(store.getObject(artifact['object_key'])) !=
          'recovered-from-original' ||
      state['code_execution_runs'] != 1 ||
      state['sandbox_cleanup_pending'] != false ||
      (state['events'] as List)
              .whereType<Map>()
              .where((event) => event['type'] == 'artifacts_ready')
              .length !=
          1) {
    throw StateError(
      'Disconnected execution lost bytes, duplicated files, or replayed code',
    );
  }
}
