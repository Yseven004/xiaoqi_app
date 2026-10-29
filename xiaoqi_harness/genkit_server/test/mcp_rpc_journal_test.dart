import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/mcp_rpc_journal.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  late Directory root;
  late CloudStore store;
  late ToolExecution owner;
  late McpRpcJournal journal;
  const call = {
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'tools/call',
    'params': {'name': 'effect'},
  };
  const response = {
    'jsonrpc': '2.0',
    'id': 1,
    'result': {
      'content': [
        {'type': 'text', 'text': 'original'},
      ],
    },
  };
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mcp-rpc-journal-');
    store = CloudStore(root: root.path);
    store.put('task/t/task', {'artifacts': []}, null);
    store.put('private_mcp_lease/t/task/lease', {}, null);
    owner = ToolExecution(
      store,
      't',
      'task',
      TurnContract(mode: 'workflow', imageLimit: 0),
      requestIdentity: 'human',
    )..bind();
    journal = McpRpcJournal(store, 't', 'task', 'lease', limit: 128);
  });
  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });

  test(
    'a durable response survives a lost event-cursor checkpoint and a late transport failure',
    () async {
      final release = Completer<void>();
      final recorded = Completer<void>();
      final pending = owner.authorizedExternal(
        slot: 'effect',
        arguments: {},
        invoke: (_) async {
          journal.beforeSend(call, 1);
          recorded.complete();
          await release.future;
          throw StateError('old transport died');
        },
      );
      await recorded.future;
      store.delete(
        'private_mcp_lease/t/task/lease',
      ); // Fail the cursor checkpoint after response persistence.
      expect(() => journal.recordEvents([response], 1), throwsStateError);
      expect(journal.records.single.$2.value['response'], response);
      journal.reconcile();
      release.complete();
      expect((await pending)['content'], isNotEmpty);
      var replayed = false;
      await owner.authorizedExternal(
        slot: 'effect',
        arguments: {},
        invoke: (_) async {
          replayed = true;
          return {};
        },
      );
      expect(replayed, false);
      expect(
        (store.get('task/t/task')!.value['scope_operations'] as Map),
        hasLength(1),
      );
    },
  );

  test(
    'typed request identity rejects unrelated and changed responses without advancing their cursor',
    () async {
      await expectLater(
        owner.authorizedExternal(
          slot: 'effect',
          arguments: {},
          invoke: (_) async {
            journal.beforeSend(call, 1);
            journal.recordEvents([
              {...response, 'id': '1'},
            ], 1);
            expect(journal.records.single.$2.value['response'], isNull);
            journal.recordEvents([response], 2);
            journal.recordEvents(
              [
                {
                  'result': {
                    'content': [
                      {'text': 'original', 'type': 'text'},
                    ],
                  },
                  'id': 1,
                  'jsonrpc': '2.0',
                },
              ],
              2,
            ); // Runner journal sorts keys when reconstructing the same batch.
            expect(
              () => journal.recordEvents([
                {
                  ...response,
                  'result': {'content': []},
                },
              ], 3),
              throwsStateError,
            );
            expect(
              store
                  .get('private_mcp_lease/t/task/lease')!
                  .value['event_cursor'],
              2,
            );
            throw StateError('API death');
          },
        ),
        throwsStateError,
      );
      journal.reconcile();
      expect(journal.records, isEmpty);
      expect(
        (store.get('task/t/task')!.value['scope_operations'] as Map)
            .values
            .single['status'],
        'succeeded',
      );
    },
  );

  test(
    'expired original calls remain unknown and cannot be replayed with a fresh deadline',
    () async {
      await expectLater(
        owner.authorizedExternal(
          slot: 'effect',
          arguments: {},
          invoke: (_) async {
            journal.beforeSend(call, 1);
            final record = journal.records.single;
            store.put(record.$1, {
              ...record.$2.value,
              'deadline_ms': 1,
            }, record.$2.revision);
            throw StateError('API death');
          },
        ),
        throwsStateError,
      );
      expect(journal.pendingDeadline!.millisecondsSinceEpoch, 1);
      journal.finishUnknown();
      await expectLater(
        owner.authorizedExternal(
          slot: 'effect',
          arguments: {},
          invoke: (_) async => throw StateError('must not submit'),
        ),
        throwsA(isA<UnconfirmedToolOperation>()),
      );
      expect(journal.pendingDeadline!.millisecondsSinceEpoch, 1);
    },
  );
}
