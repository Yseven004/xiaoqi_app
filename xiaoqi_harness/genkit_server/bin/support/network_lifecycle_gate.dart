import 'dart:async';

import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

/// Exercises the deployed bridge/runner/proxy, using public package metadata.
Future<void> verifyNetworkLifecycle(
  CloudStore store,
  DockerCodeExecutionService executor,
  String tenant,
) async {
  const task = 'network-lifecycle';
  final key = 'task/$tenant/$task';
  store.put(key, {'status': 'running', 'artifacts': [], 'events': []}, null);
  Future<void> run(String code, {CancellationToken? cancellation}) async {
    await executor.execute(
      tenantId: tenant,
      taskId: task,
      code: code,
      language: 'python',
      authorizedDomains: ['registry.npmjs.org'],
      materials: [],
      skillFiles: {},
      cancellation: cancellation ?? CancellationController().token,
    );
  }

  const allowedAndDenied = r'''
import urllib.request
with urllib.request.urlopen('https://registry.npmjs.org/picocolors/1.1.1', timeout=15) as response:
 assert response.status == 200
for url in ['https://pypi.org/simple/', 'http://169.254.169.254/', 'https://registry.npmjs.org:444/']:
 try:
  urllib.request.urlopen(url, timeout=5)
 except (OSError, ValueError):
  pass
 else:
  raise AssertionError('unapproved destination was reachable: ' + url)
''';
  await run(allowedAndDenied);
  // The executor records sandbox_id only once the process has started. Hold
  // the script briefly so the control request revokes this actual live proxy.
  final liveCancellation = CancellationController();
  final live = run(r'''
import time,urllib.request
time.sleep(8)
try:
 urllib.request.urlopen('https://registry.npmjs.org/picocolors/1.1.1', timeout=5)
except OSError:
 pass
else:
 raise AssertionError('revoked live proxy remained reachable')
''', cancellation: liveCancellation.token);
  // Attach the error handler immediately; a startup failure must fail the gate
  // without producing an unhandled asynchronous error while polling readiness.
  Object? failure;
  final observed = live.catchError((Object error) {
    failure = error;
  });
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (store.get(key)?.value['sandbox_id'] == null && failure == null) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Network revocation fixture did not start');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (failure != null) throw failure!;
    final beforeOff = store.get(key)!;
    store.put(key, {
      ...beforeOff.value,
      'network_policy_revision': 1,
    }, beforeOff.revision);
    await executor.disableNetwork(
      tenantId: tenant,
      taskId: task,
      networkRevision: 1,
    );
    await observed;
    if (failure != null) throw failure!;
  } finally {
    liveCancellation.cancel();
    await observed;
  }
  // No sleep or "enable runner" operation: a fresh authorized call must work
  // immediately, while the unit/queue tests prove old tokens stay revoked.
  final beforeOn = store.get(key)!;
  store.put(key, {
    ...beforeOn.value,
    'network_policy_revision': 2,
  }, beforeOn.revision);
  await run(allowedAndDenied);
  // Reproduce delivery reordering against a real running Docker proxy: a
  // previous off reaches the runner after the newly authorized proxy starts.
  final previousSandbox = store.get(key)?.value['sandbox_id'];
  final freshCancellation = CancellationController();
  Object? freshFailure;
  final fresh =
      run(
        'import time\ntime.sleep(5)\n$allowedAndDenied',
        cancellation: freshCancellation.token,
      ).catchError((Object error) {
        freshFailure = error;
      });
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (freshFailure == null) {
      final sandbox = store.get(key)?.value['sandbox_id'];
      if (sandbox != null && sandbox != previousSandbox) break;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Reauthorized network fixture did not start');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (freshFailure != null) throw freshFailure!;
    await executor.disableNetwork(
      tenantId: tenant,
      taskId: task,
      networkRevision: 1,
    );
    await fresh;
    if (freshFailure != null) throw freshFailure!;
  } finally {
    freshCancellation.cancel();
    await fresh;
  }
  if (store.get(key)?.value['sandbox_cleanup_pending'] != false) {
    throw StateError('Network fixture cleanup was not confirmed');
  }
}
