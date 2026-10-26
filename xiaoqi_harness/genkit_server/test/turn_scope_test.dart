import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/history_context.dart';
import 'package:xiaoqi_genkit_server/src/artifact_context.dart';
import 'package:xiaoqi_genkit_server/src/intent_router.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  late Directory directory;
  late CloudStore store;
  test(
    'artifact references use tenant-owned records instead of client paths',
    () {
      store.put('task/personal/prior', {
        'artifacts': [
          {
            'id': 'cat',
            'object_key': 'tenants/personal/tasks/prior/artifacts/cat.png',
            'media_type': 'image/png',
          },
          {
            'id': 'foreign',
            'object_key': 'tenants/other/tasks/prior/artifacts/secret.png',
          },
        ],
      }, null);
      final references = validateArtifactReferences(store, 'personal', [
        {'id': 'prior/cat', 'object_key': 'C:/private.txt'},
        {'id': 'prior/foreign'},
      ]);
      expect(references, hasLength(1));
      expect(
        references.single['object_key'],
        'tenants/personal/tasks/prior/artifacts/cat.png',
      );
      expect(
        validateArtifactReferences(store, 'other', [
          {'id': 'prior/cat'},
        ]),
        isEmpty,
      );
    },
  );
  test(
    'historical skill bodies are inference-only and current reads survive',
    () {
      final messages = [
        Message(
          role: Role.tool,
          content: [
            ToolResponsePart(
              toolResponse: ToolResponse(
                name: 'use_skill',
                ref: 'old',
                output: '必须反复生图',
              ),
            ),
            ToolResponsePart(
              toolResponse: ToolResponse(
                name: 'use_skill',
                ref: 'current',
                output: '当前任务的有效资料',
              ),
            ),
          ],
        ),
      ];
      final inference = withoutHistoricalSkillBodies(messages, {'old'});
      final parts = inference.single.content
          .map((part) => ToolResponsePart.fromJson(part.toJson()))
          .toList();
      expect(parts.first.toolResponse.output, isNot(contains('必须反复生图')));
      expect(parts.last.toolResponse.output, '当前任务的有效资料');
      expect(
        ToolResponsePart.fromJson(
          messages.single.content.first.toJson(),
        ).toolResponse.output,
        '必须反复生图',
      );
    },
  );

  test('corrected scope persists its text and steering revision', () {
    final runner = ToolExecution(
      store,
      'personal',
      'task-1',
      TurnContract(mode: 'inspect', imageLimit: 0),
      requestIdentity: 'corrected',
      requestText: '只解释这张图',
      steeringSequence: 2,
    );
    runner.bind();
    final scope = store.get('task/personal/task-1')!.value['turn_scope'] as Map;
    expect(scope['request_text'], '只解释这张图');
    expect(scope['steering_sequence'], 2);
    expect(() => runner.check('image'), throwsStateError);
  });
  setUp(() {
    directory = Directory.systemTemp.createTempSync('turn-scope-');
    store = CloudStore(root: directory.path);
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });
  ToolExecution execution(
    TurnContract scope, {
    String identity = 'message-1',
  }) => ToolExecution(
    store,
    'personal',
    'task-1',
    scope,
    requestIdentity: identity,
  )..bind();

  test(
    'inspection and explicit prohibitions override a mistaken create proposal',
    () async {
      for (final text in ['这是什么', '我问你这是什么？', '解释这张图', '不要生成图片，只解释']) {
        final contract = await routeTurnIntent(
          text: text,
          skills: const [],
          connections: const [],
          artifacts: const [],
          recentUserMessages: const ['生成一张猫图'],
          generate: (_, _) async => jsonEncode({
            'mode': 'create',
            'image_count': 1,
            'answer_required': false,
            'skill_ids': [],
            'connection_ids': [],
            'target_artifact_id': null,
            'clarification': null,
          }),
        );
        expect(contract.permitsImages, isFalse, reason: text);
        final runner = execution(contract, identity: text);
        var calls = 0;
        await expectLater(
          runner.image(
            slot: '1',
            arguments: const {},
            invoke: (_) async {
              calls++;
              return {};
            },
          ),
          throwsStateError,
        );
        expect(calls, 0);
      }
    },
  );

  test(
    'workspace planning does not authorize images or external workflows',
    () {
      final contract = TurnContract(mode: 'answer', imageLimit: 0);
      expect(
        contract.validatePlan({
          'tools': [
            {'name': 'execute_skill_script'},
          ],
          'artifacts': [
            {'media_type': 'image/png', 'count': 1},
          ],
        }),
        isNotNull,
      );
      expect(() => execution(contract).check('workflow'), throwsStateError);
      expect(() => execution(contract).check('workspace'), returnsNormally);
      expect(
        contract.validatePlan({
          'tools': [
            {'name': 'execute_skill_script', 'count': 1},
          ],
          'artifacts': [
            {'media_type': 'application/pdf', 'count': 1},
          ],
        }),
        isNull,
      );
    },
  );

  test(
    'a completed operation is reused and parameter drift is rejected',
    () async {
      final runner = execution(TurnContract(mode: 'create', imageLimit: 1));
      var calls = 0;
      Future<Map<String, dynamic>> invoke(String _) async {
        calls++;
        return {'result': 'cat'};
      }

      final first = await runner.image(
        slot: '1',
        arguments: {'prompt': 'cat'},
        invoke: invoke,
      );
      final second = await runner.image(
        slot: '1',
        arguments: {'prompt': 'cat'},
        invoke: invoke,
      );
      expect(second, first);
      expect(calls, 1);
      await expectLater(
        runner.image(slot: '1', arguments: {'prompt': 'dog'}, invoke: invoke),
        throwsStateError,
      );
    },
  );

  test('concurrent calls atomically reserve the last image budget', () async {
    final runner = execution(TurnContract(mode: 'create', imageLimit: 1));
    final provider = Completer<Map<String, dynamic>>();
    var calls = 0;
    final first = runner.image(
      slot: '1',
      arguments: {},
      invoke: (_) {
        calls++;
        return provider.future;
      },
    );
    final second = ToolExecution(
      store,
      'personal',
      'task-1',
      runner.contract,
      requestIdentity: runner.requestIdentity,
    );
    await expectLater(
      second.image(
        slot: '2',
        arguments: {},
        invoke: (_) async {
          calls++;
          return {};
        },
      ),
      throwsStateError,
    );
    expect(calls, 1);
    provider.complete({'ok': true});
    await first;
  });

  test('unknown outcomes cannot be automatically replayed', () async {
    final runner = execution(TurnContract(mode: 'create', imageLimit: 1));
    var calls = 0;
    Future<Map<String, dynamic>> invoke(String _) async {
      calls++;
      throw TimeoutException('accepted status unknown');
    }

    await expectLater(
      runner.image(slot: '1', arguments: {}, invoke: invoke),
      throwsA(isA<TimeoutException>()),
    );
    await expectLater(
      runner.image(slot: '1', arguments: {}, invoke: invoke),
      throwsStateError,
    );
    expect(calls, 1);
  });

  test(
    'a correction withdraws the old plan and rejects its running callbacks',
    () {
      final old = execution(TurnContract(mode: 'create', imageLimit: 1));
      final task = store.get('task/personal/task-1')!;
      store.put('task/personal/task-1', {
        ...task.value,
        'delivery_evidence': {
          'plan': {
            'artifacts': ['image'],
          },
        },
      }, task.revision);
      final current = execution(
        TurnContract(mode: 'answer', imageLimit: 0),
        identity: 'correction',
      );
      expect(
        store.get('task/personal/task-1')!.value['delivery_evidence'],
        isEmpty,
      );
      expect(() => old.check('image'), throwsStateError);
      expect(() => current.check('workflow'), throwsStateError);
    },
  );

  test(
    'cancel and newly received steering block calls before the provider',
    () {
      final runner = execution(TurnContract(mode: 'workflow', imageLimit: 1));
      final task = store.get('task/personal/task-1')!;
      store.put('task/personal/task-1', {
        ...task.value,
        'steering_instructions': [
          {'sequence': 1, 'content': '只解释', 'status': 'received'},
        ],
      }, task.revision);
      expect(() => runner.check('image'), throwsStateError);
    },
  );
}
