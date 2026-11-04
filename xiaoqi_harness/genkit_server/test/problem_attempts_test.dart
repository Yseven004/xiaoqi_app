import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/problem_attempts.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory directory;
  late CloudStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('problem-attempts-');
    store = CloudStore(root: directory.path);
  });

  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  ProblemAttemptBudget budget({
    required String taskId,
    required String stageId,
  }) {
    store.put('task/alice/$taskId', {'status': 'running'}, null);
    return ProblemAttemptBudget(
      store: store,
      tenantId: 'alice',
      taskId: taskId,
      workflowId: 'work-1',
      stageId: stageId,
      issueContext: 'repair the selected document workflow',
      onEvent: (_) {},
    );
  }

  ToolRequestPart request({
    required String tool,
    String path = 'same-document.md',
    String ref = 'call',
  }) => ToolRequestPart(
    toolRequest: ToolRequest(name: tool, ref: ref, input: {'path': path}),
  );

  Future<ToolResult> invoke(
    ProblemAttemptBudget guard,
    ToolRequestPart call,
    Future<ToolResult> Function() native,
  ) => guard.middleware().tool(
    call,
    ActionFnArg<void, dynamic, void>(),
    (_, _) => native(),
  );

  test(
    'same issue stops at five failures and never executes a sixth call',
    () async {
      final guard = budget(taskId: 'task-1', stageId: 'stage-1');
      var nativeCalls = 0;
      for (var attempt = 1; attempt <= 5; attempt++) {
        await invoke(
          guard,
          request(
            tool: attempt == 1 ? 'read_document' : 'search_document',
            ref: 'failure-$attempt',
          ),
          () async {
            nativeCalls++;
            return ToolResult.response({
              'ok': false,
              'error': 'same parse error',
            });
          },
        );
      }

      final limit = store
          .get('task/alice/task-1')!
          .value['problem_attempt_limit'];
      expect(limit, isA<Map>());
      expect((limit as Map)['attempts'], 5);
      expect(nativeCalls, 5);

      await invoke(
        guard,
        request(tool: 'read_document', ref: 'sixth-call'),
        () async {
          nativeCalls++;
          return ToolResult.response({
            'ok': false,
            'error': 'must not execute',
          });
        },
      );
      expect(nativeCalls, 5);
    },
  );

  test(
    'successful and intentionally denied calls do not consume attempts',
    () async {
      final guard = budget(taskId: 'task-2', stageId: 'stage-1');
      await invoke(
        guard,
        request(tool: 'read_document', path: 'other-document.md'),
        () async => ToolResult.response({
          'ok': true,
          'error': 'this is a successful diagnostic result field',
          'content': 'read',
        }),
      );
      await invoke(
        guard,
        request(tool: 'write_document'),
        () async =>
            ToolResult.response({'status': 'denied', 'error': 'user denied'}),
      );

      for (var attempt = 1; attempt <= 4; attempt++) {
        await invoke(
          guard,
          request(tool: 'read_document', ref: 'failure-$attempt'),
          () async => ToolResult.response({'ok': false, 'error': 'same issue'}),
        );
      }
      expect(
        store.get('task/alice/task-2')!.value['problem_attempt_limit'],
        isNull,
      );

      await invoke(
        guard,
        request(tool: 'search_document', ref: 'fifth-failure'),
        () async => ToolResult.response({'ok': false, 'error': 'same issue'}),
      );
      expect(
        (store.get('task/alice/task-2')!.value['problem_attempt_limit']
            as Map)['attempts'],
        5,
      );
    },
  );

  test(
    'parallel failures are serialized and a new explicit stage retains history',
    () async {
      final firstStage = budget(taskId: 'task-3', stageId: 'stage-1');
      var nativeCalls = 0;
      await Future.wait([
        for (var index = 0; index < 6; index++)
          invoke(
            firstStage,
            request(tool: 'read_document', ref: 'parallel-$index'),
            () async {
              nativeCalls++;
              await Future<void>.delayed(const Duration(milliseconds: 2));
              return ToolResult.response({'ok': false, 'error': 'same issue'});
            },
          ),
      ]);
      expect(nativeCalls, 5);

      final secondStage = budget(taskId: 'task-4', stageId: 'stage-2');
      await invoke(
        secondStage,
        request(tool: 'search_document', ref: 'new-stage'),
        () async =>
            ToolResult.response({'ok': false, 'error': 'new direction failed'}),
      );

      final records = store.list('problem-attempt/alice/');
      expect(records, hasLength(1));
      final stages = records.single.$2.value['stages'] as Map;
      expect((stages['stage-1'] as Map)['attempts'], 5);
      expect((stages['stage-2'] as Map)['attempts'], 1);
    },
  );
}
