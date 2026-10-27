import 'package:genkit/genkit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'dart:io';
import 'package:xiaoqi_genkit_server/src/task_model_client.dart';
import 'package:xiaoqi_genkit_server/src/execution_limits.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  late Directory root;
  late CloudStore store;
  final url = Uri.parse('https://fixture.invalid/chat/completions');
  const limits = ExecutionLimits(modelRequests: 2);
  setUp(() {
    root = Directory.systemTemp.createTempSync('task-model-budget-');
    store = CloudStore(root: root.path);
    store.put('task/tenant/task', {'status': 'running'}, null);
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });

  test(
    'failed attempts and rebuilt clients share a durable task budget across steering',
    () async {
      var calls = 0;
      final first = TaskModelClient(
        store,
        'tenant',
        'task',
        limits: limits,
        inner: MockClient((_) async {
          calls++;
          throw http.ClientException('connection lost');
        }),
      );
      await expectLater(first.post(url), throwsA(isA<http.ClientException>()));
      first.close();
      expect(store.get('task/tenant/task')!.value['model_request_runs'], 1);
      ToolExecution(
        store,
        'tenant',
        'task',
        TurnContract(mode: 'answer', imageLimit: 0),
        requestIdentity: 'updated-user-scope',
      ).bind();
      final secondStore = CloudStore(root: root.path);
      final resumed = TaskModelClient(
        secondStore,
        'tenant',
        'task',
        limits: limits,
        inner: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      try {
        await resumed.post(url);
        await expectLater(
          resumed.post(url),
          throwsA(isA<ExecutionBudgetExceeded>()),
        );
        expect(calls, 2);
        expect(
          secondStore.get('task/tenant/task')!.value['model_request_runs'],
          2,
        );
        expect(store.get('task/tenant/task')!.value['model_request_runs'], 2);
      } finally {
        resumed.close();
        secondStore.close();
      }
    },
  );

  test(
    'metadata reads do not consume model attempts; cancellation prevents submission',
    () async {
      var calls = 0;
      final cancellation = CancellationController();
      final client = TaskModelClient(
        store,
        'tenant',
        'task',
        cancellation: cancellation.token,
        limits: limits,
        inner: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      try {
        await client.get(url.resolve('/models'));
        expect(
          store.get('task/tenant/task')!.value['model_request_runs'],
          isNull,
        );
        cancellation.cancel();
        await expectLater(client.post(url), throwsA(anything));
        expect(calls, 1);
        expect(
          store.get('task/tenant/task')!.value['model_request_runs'],
          isNull,
        );
      } finally {
        client.close();
      }
    },
  );

  test(
    'task context covers nested async work and is removed on failure',
    () async {
      expect(TaskModelClient.current, isNull);
      await expectLater(
        TaskModelClient.run<void>(
          store: store,
          tenantId: 'tenant',
          taskId: 'task',
          limits: limits,
          cancellation: CancellationController().token,
          operation: () async {
            expect(TaskModelClient.current, isA<TaskModelClient>());
            await Future<void>.delayed(Duration.zero);
            expect(TaskModelClient.current, isA<TaskModelClient>());
            throw StateError('fixture operation failed');
          },
        ),
        throwsStateError,
      );
      expect(TaskModelClient.current, isNull);
    },
  );

  test('missing and stopped tasks cannot use another task budget', () async {
    var calls = 0;
    final inner = MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    });
    final wrongTenant = TaskModelClient(store, 'other', 'task', inner: inner);
    await expectLater(wrongTenant.post(url), throwsStateError);
    final current = store.get('task/tenant/task')!;
    store.put('task/tenant/task', {
      ...current.value,
      'status': 'stopped',
    }, current.revision);
    final stopped = TaskModelClient(store, 'tenant', 'task', inner: inner);
    await expectLater(stopped.post(url), throwsStateError);
    expect(calls, 0);
    wrongTenant.close();
    stopped.close();
  });

  test(
    'a swallowed model budget refusal still fails the owning task',
    () async {
      final record = store.get('task/tenant/task')!;
      store.put('task/tenant/task', {
        ...record.value,
        'model_request_runs': 2,
      }, record.revision);
      await expectLater(
        TaskModelClient.run<String>(
          store: store,
          tenantId: 'tenant',
          taskId: 'task',
          limits: limits,
          cancellation: CancellationController().token,
          operation: () async {
            try {
              await TaskModelClient.current!.post(url);
            } catch (_) {
              /* Simulate a classifier fallback. */
            }
            return 'not a verified completion';
          },
        ),
        throwsA(isA<ExecutionBudgetExceeded>()),
      );
      expect(TaskModelClient.current, isNull);
    },
  );
}
