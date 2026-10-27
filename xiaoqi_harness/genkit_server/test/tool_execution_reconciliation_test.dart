import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  late Directory root;
  late CloudStore store;
  ToolExecution execution(String request) => ToolExecution(
    store,
    'tenant',
    'task',
    TurnContract(mode: 'workflow', imageLimit: 0),
    requestIdentity: request,
  )..bind();
  setUp(() {
    root = Directory.systemTemp.createTempSync('scope-reconciliation-');
    store = CloudStore(root: root.path);
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });

  test(
    'a late transport error preserves the confirmed bound operation result',
    () async {
      final scope = execution('original');
      final entered = Completer<String>();
      final pending = Completer<Map<String, dynamic>>();
      final operation = scope.authorizedCode(
        slot: 'linked',
        arguments: {},
        invoke: (id) {
          entered.complete(id);
          return pending.future;
        },
        effectsPossible: (_) => true,
      );
      final id = await entered.future;
      final record = store.get('task/tenant/task')!;
      final operations = Map<String, dynamic>.from(
        record.value['scope_operations'] as Map,
      );
      operations[id] = {
        ...operations[id] as Map,
        'execution_id': 'f' * 32,
        'status': 'succeeded',
        'result': {'ok': true, 'output': 'confirmed bytes'},
      };
      store.put('task/tenant/task', {
        ...record.value,
        'scope_operations': operations,
      }, record.revision);
      final completed = expectLater(
        operation,
        completion(containsPair('output', 'confirmed bytes')),
      );
      pending.completeError(SandboxExecutionError('late broken stream'));
      await completed;
      var repeated = false;
      final result = await scope.authorizedCode(
        slot: 'linked',
        arguments: {},
        invoke: (_) async {
          repeated = true;
          return {};
        },
        effectsPossible: (_) => true,
      );
      expect(result['output'], 'confirmed bytes');
      expect(repeated, false);
      scope.markUncertainNetworkExecution('late', operationId: id);
      expect(scope.hasUncertainNetworkExecution, false);
    },
  );

  test('multiple unknown operations and legacy uncertainty are retained', () {
    final scope = execution('original');
    scope.markUncertainNetworkExecution('a', operationId: 'a' * 64);
    scope.markUncertainNetworkExecution('b', operationId: 'b' * 64);
    var state =
        (store.get('task/tenant/task')!.value['uncertain_network_scopes']
                as Map)['original']
            as Map;
    expect(state['operation_ids'], ['a' * 64, 'b' * 64]);
    expect(state['unlinked'], false);
    scope.markUncertainNetworkExecution('legacy');
    state =
        (store.get('task/tenant/task')!.value['uncertain_network_scopes']
                as Map)['original']
            as Map;
    expect(state['operation_ids'], hasLength(2));
    expect(state['unlinked'], true);
  });

  test('late uncertainty belongs to the captured original user scope', () {
    final original = execution('original');
    final updated = execution('updated');
    original.markUncertainNetworkExecution('old-call', operationId: 'a' * 64);
    expect(original.hasUncertainNetworkExecution, true);
    expect(updated.hasUncertainNetworkExecution, false);
  });

  test(
    'a confirmed result never revives a withdrawn operation scope',
    () async {
      final scope = execution('original');
      final entered = Completer<String>();
      final pending = Completer<Map<String, dynamic>>();
      final operation = scope.authorizedCode(
        slot: 'linked',
        arguments: {},
        invoke: (id) {
          entered.complete(id);
          return pending.future;
        },
        effectsPossible: (_) => true,
      );
      final id = await entered.future;
      final record = store.get('task/tenant/task')!;
      final operations = Map<String, dynamic>.from(
        record.value['scope_operations'] as Map,
      );
      operations[id] = {
        ...operations[id] as Map,
        'execution_id': 'f' * 32,
        'status': 'succeeded',
        'result': {'ok': true, 'output': 'confirmed bytes'},
      };
      store.put('task/tenant/task', {
        ...record.value,
        'scope_operations': operations,
      }, record.revision);
      execution('updated');
      final stopped = expectLater(
        operation,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'scope',
            contains('旧操作已失效'),
          ),
        ),
      );
      pending.completeError(SandboxExecutionError('late broken stream'));
      await stopped;
      expect(
        (store.get('task/tenant/task')!.value['scope_operations']
            as Map)[id]['status'],
        'succeeded',
      );
    },
  );
}
