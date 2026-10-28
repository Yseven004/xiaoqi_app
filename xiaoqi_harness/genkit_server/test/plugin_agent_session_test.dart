import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:genkit/experimental.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/execution_limits.dart';
import 'package:xiaoqi_genkit_server/src/plugin_agent_session.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/task_model_client.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  late Directory root;
  late CloudStore store;
  late TaskModelClient client;
  var providerCalls = 0;
  final effects = <String, int>{};
  ToolExecution owner([String identity = 'human-request']) => ToolExecution(
    store,
    'tenant',
    'task',
    TurnContract(mode: 'workflow', imageLimit: 0),
    requestIdentity: identity,
  )..bind();

  Agent<dynamic> child({ExecutionLimits limits = const ExecutionLimits()}) {
    client = TaskModelClient(
      store,
      'tenant',
      'task',
      limits: limits,
      inner: MockClient((request) async {
        providerCalls++;
        final body = jsonDecode(request.body) as Map;
        final messages = (body['messages'] as List).whereType<Map>();
        final outputs = messages
            .where((message) => message['role'] == 'tool')
            .length;
        final delta = outputs >= 2
            ? {'role': 'assistant', 'content': 'Child task completed'}
            : {
                'role': 'assistant',
                'tool_calls': [
                  for (var i = 0; i < 2; i++)
                    {
                      'index': i,
                      'id': 'child-${i == 0 ? 'A' : 'B'}',
                      'type': 'function',
                      'function': {
                        'name': 'child_action',
                        'arguments': jsonEncode({'target': i == 0 ? 'A' : 'B'}),
                      },
                    },
                ],
              };
        final frame = {
          'id': 'fixture',
          'object': 'chat.completion.chunk',
          'created': 1,
          'model': 'fixture',
          'choices': [
            {
              'index': 0,
              'delta': delta,
              'finish_reason': outputs >= 2 ? 'stop' : 'tool_calls',
            },
          ],
        };
        return http.Response(
          'data: ${jsonEncode(frame)}\n\ndata: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final ai = Genkit(
      promptDir: null,
      isDevEnv: false,
      plugins: [
        openAI(
          name: 'fixture',
          apiKey: 'fixture-only',
          baseUrl: 'https://fixture.invalid/v1',
          httpClient: client,
          models: [CustomModelDefinition(name: 'fixture')],
        ),
      ],
    );
    ai.defineTool<Map<String, dynamic>, String>(
      name: 'child_action',
      description: 'Execute one original approved fixture action',
      inputSchema: .map(.string(), .dynamicSchema()),
      fn: (input, context) async {
        final target = input['target'].toString();
        if (context.resumed is Map &&
            context.resumed['approval_hash'] == 'approve-$target' &&
            context.resumed['approved'] is bool) {
          if (context.resumed['approved'] == true)
            effects.update(target, (count) => count + 1, ifAbsent: () => 1);
          return .response(
            context.resumed['approved'] == true
                ? jsonEncode({
                    'ok': true,
                    'status': 'completed',
                    'target': target,
                  })
                : jsonEncode({
                    'ok': false,
                    'status': 'denied',
                    'target': target,
                  }),
          );
        }
        return .interrupt({
          'type': 'mcp_tool_approval',
          'approval_hash': 'approve-$target',
          'target': target,
        });
      },
    );
    return ai.defineAgent(
      name: 'fixture_child',
      model: openAI.model('fixture', namespace: 'fixture'),
      system: 'Use child_action for A and B, then report completion.',
      toolNames: ['child_action'],
      maxTurns: 6,
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('plugin-agent-session-');
    store = CloudStore(root: root.path);
    store.put('task/tenant/task', {'status': 'running'}, null);
    providerCalls = 0;
    effects.clear();
  });
  tearDown(() {
    client.close();
    store.close();
    root.deleteSync(recursive: true);
  });

  test(
    'real SDK child resumes two original approvals across database and registry rebuilds',
    () async {
      var agent = child();
      var scope = owner();
      Future<PluginAgentSessionResult> run([Map<String, dynamic>? resumed]) =>
          PluginAgentSessions(store).run(
            agent: agent,
            owner: scope,
            invocation: 'root/original-call',
            definitionBinding: 'immutable-v1',
            task: 'PRIVATE_AGENT_TASK',
            cancellation: CancellationController().token,
            resumed: resumed,
          );
      final first = await run();
      expect(first.interrupt?['approval_hash'], 'approve-A');
      expect(effects, isEmpty);
      expect(providerCalls, 1);
      expect(
        jsonEncode(
          store.get('task/tenant/task')!.value,
        ).contains('PRIVATE_AGENT_TASK'),
        false,
      );
      expect(taskToolOperationsUsed(store.get('task/tenant/task')!.value), 1);
      await expectLater(
        run({'approved': true, 'approval_hash': 'wrong-hash'}),
        throwsStateError,
      );
      expect(providerCalls, 1);
      client.close();
      store.close();
      store = CloudStore(root: root.path);
      agent = child();
      scope = owner();
      final second = await run({
        'approved': true,
        'approval_hash': 'approve-A',
      });
      expect(second.interrupt?['approval_hash'], 'approve-B');
      expect(effects, {'A': 1});
      final completed = await run({
        'approved': true,
        'approval_hash': 'approve-B',
      });
      expect(completed.interrupt, isNull);
      expect(completed.result['ok'], true);
      expect(effects, {'A': 1, 'B': 1});
      expect(
        store.get('task/tenant/task')!.value['model_request_runs'],
        providerCalls,
      );
      expect(taskToolOperationsUsed(store.get('task/tenant/task')!.value), 1);
      final callsBefore = providerCalls;
      expect((await run()).result['ok'], true);
      expect(providerCalls, callsBefore);
      expect(effects, {'A': 1, 'B': 1});
      await expectLater(
        PluginAgentSessions(store).run(
          agent: agent,
          owner: scope,
          invocation: 'root/original-call',
          definitionBinding: 'changed-version',
          task: 'PRIVATE_AGENT_TASK',
          cancellation: CancellationController().token,
        ),
        throwsStateError,
      );
      scope = owner('new-human-request');
      await expectLater(
        run({'approved': true, 'approval_hash': 'approve-A'}),
        throwsStateError,
      );
      expect(providerCalls, callsBefore);
    },
  );

  test(
    'an unconfirmed active child never restarts or double reserves the delegation',
    () async {
      final agent = child();
      final scope = owner();
      final binding = ToolExecution.digest([
        'immutable-v1',
        'task',
        <String, dynamic>{},
      ]);
      scope.beginDelegation('call', binding);
      final key =
          'private_plugin_agent/tenant/task/${ToolExecution.digest([scope.requestIdentity, 'call'])}';
      store.put(key, {'binding': binding, 'phase': 'active'}, null);
      for (var i = 0; i < 2; i++) {
        await expectLater(
          PluginAgentSessions(store).run(
            agent: agent,
            owner: scope,
            invocation: 'call',
            definitionBinding: 'immutable-v1',
            task: 'task',
            cancellation: CancellationController().token,
          ),
          throwsA(isA<UnconfirmedToolOperation>()),
        );
      }
      expect(providerCalls, 0);
      expect(taskToolOperationsUsed(store.get('task/tenant/task')!.value), 1);
      expect(store.get(key)!.value['phase'], 'unknown');
    },
  );

  test(
    'denying a later child action preserves the earlier approved result',
    () async {
      final agent = child();
      final scope = owner();
      Future<PluginAgentSessionResult> run([Map<String, dynamic>? resumed]) =>
          PluginAgentSessions(store).run(
            agent: agent,
            owner: scope,
            invocation: 'call',
            definitionBinding: 'v1',
            task: 'task',
            cancellation: CancellationController().token,
            resumed: resumed,
          );
      await run();
      final partial = await run({
        'approved': true,
        'approval_hash': 'approve-A',
      });
      expect(partial.interrupt?['approval_hash'], 'approve-B');
      final result = await run({
        'approved': false,
        'approval_hash': 'approve-B',
      });
      expect(result.result['ok'], false);
      expect(result.result['tool_failures'], contains('child_action'));
      expect(effects, {'A': 1});
      expect(taskToolOperationsUsed(store.get('task/tenant/task')!.value), 1);
      expect(
        store.get('task/tenant/task')!.value['model_request_runs'],
        providerCalls,
      );
    },
  );

  test(
    'task cancellation blocks a pending child approval without a new provider call',
    () async {
      final agent = child();
      final scope = owner();
      Future<PluginAgentSessionResult> run([Map<String, dynamic>? resumed]) =>
          PluginAgentSessions(store).run(
            agent: agent,
            owner: scope,
            invocation: 'call',
            definitionBinding: 'v1',
            task: 'task',
            cancellation: CancellationController().token,
            resumed: resumed,
          );
      await run();
      final task = store.get('task/tenant/task')!;
      store.put('task/tenant/task', {
        ...task.value,
        'cancel_requested': true,
      }, task.revision);
      await expectLater(
        run({'approved': true, 'approval_hash': 'approve-A'}),
        throwsStateError,
      );
      expect(effects, isEmpty);
      expect(providerCalls, 1);
      expect(taskToolOperationsUsed(store.get('task/tenant/task')!.value), 1);
    },
  );

  test(
    'child resumes share the original durable provider budget and never replay on exhaustion',
    () async {
      final agent = child(limits: const ExecutionLimits(modelRequests: 1));
      final scope = owner();
      Future<PluginAgentSessionResult> run([Map<String, dynamic>? resumed]) =>
          PluginAgentSessions(store).run(
            agent: agent,
            owner: scope,
            invocation: 'call',
            definitionBinding: 'v1',
            task: 'task',
            cancellation: CancellationController().token,
            resumed: resumed,
          );
      await run();
      await run({'approved': true, 'approval_hash': 'approve-A'});
      await expectLater(
        run({'approved': true, 'approval_hash': 'approve-B'}),
        throwsA(isA<AgentError>()),
      );
      expect(effects, {'A': 1, 'B': 1});
      expect(providerCalls, 1);
      expect(store.get('task/tenant/task')!.value['model_request_runs'], 1);
      await expectLater(run(), throwsA(isA<UnconfirmedToolOperation>()));
      expect(effects, {'A': 1, 'B': 1});
      expect(providerCalls, 1);
      expect(taskToolOperationsUsed(store.get('task/tenant/task')!.value), 1);
    },
  );
}
