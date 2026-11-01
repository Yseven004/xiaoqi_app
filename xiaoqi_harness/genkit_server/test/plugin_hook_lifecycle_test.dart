import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_catalog.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_lifecycle.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

class _Executor extends DockerCodeExecutionService {
  _Executor(super.store);
  final submitted = <String>[];
  bool deny = false;
  Object? failure;
  @override
  Future<String> execute({
    required String tenantId,
    required String taskId,
    required String code,
    required String language,
    required List<String> authorizedDomains,
    required List<Map<String, dynamic>> materials,
    required Map<String, List<int>> skillFiles,
    required CancellationToken cancellation,
    String? scriptPath,
    List<String> arguments = const [],
    List<String>? artifactIds,
    void Function()? beforeSubmit,
    String? scopeOperationId,
    SandboxExecutionProfile profile = SandboxExecutionProfile.code,
  }) async {
    beforeSubmit?.call();
    expect(profile, SandboxExecutionProfile.pluginHook);
    expect(authorizedDomains, isEmpty);
    final line = code.split('\n').first;
    final literal = line.substring(
      'const spec = JSON.parse('.length,
      line.length - 2,
    );
    final spec = jsonDecode(jsonDecode(literal) as String) as Map;
    final input = spec['input'] as Map;
    final event = input['hook_event_name'] as String;
    expect(input['session_id'], 'task');
    if (event == 'UserPromptSubmit') expect(input['prompt'], 'original prompt');
    submitted.add(event);
    if (failure != null) throw failure!;
    return jsonEncode({
      'xiaoqi_hook_command_v1': {
        'matched': true,
        'timed_out': false,
        'exit_code': deny && event == 'UserPromptSubmit' ? 2 : 0,
        'stdout': event == 'SessionStart'
            ? 'STARTUP_CONTEXT'
            : 'PROMPT_CONTEXT',
        'stderr': deny ? 'prompt blocked' : '',
      },
    });
  }
}

void main() {
  late Directory directory;
  late CloudStore store;
  late SelectedPluginHooks catalog;
  late _Executor executor;
  late CancellationController cancellation;
  late ToolExecution owner;
  ToolExecution execution(String identity, {String mode = 'workflow'}) {
    final result = ToolExecution(
      store,
      'alice',
      'task',
      TurnContract(mode: mode, imageLimit: 0),
      requestIdentity: identity,
    );
    result.bind();
    return result;
  }

  PluginHookLifecycle lifecycle() => PluginHookLifecycle(
    store: store,
    catalog: catalog,
    executor: executor,
    aliases: () => catalog.entries.keys,
    onEvent: (_) {},
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hook-lifecycle-');
    store = CloudStore(root: directory.path);
    final files = <String, List<int>>{
      '.claude-plugin/plugin.json': utf8.encode('{"name":"lifecycle-fixture"}'),
      'hooks/hooks.json': utf8.encode(
        jsonEncode({
          'hooks': {
            for (final event in ['SessionStart', 'UserPromptSubmit'])
              event: [
                {
                  'hooks': [
                    {'type': 'command', 'command': 'source-handler'},
                  ],
                },
              ],
          },
        }),
      ),
    };
    store.putImmutable('packages/lifecycle', files);
    store.put('cap/alice/plugin', {
      'id': 'plugin',
      'kind': 'plugin',
      'name': 'Lifecycle fixture',
      'origin': 'upload',
      'enabled': true,
      'current_version_id': 'v1',
      'versions': [
        {
          'id': 'v1',
          'artifact_key': 'packages/lifecycle',
          'plugin_hook_profile': PluginHookCatalog.profileVersion,
          'components': PluginHookCatalog.inspect(files, ''),
        },
      ],
    }, null);
    store.put('task/alice/task', {
      'status': 'running',
      'artifacts': [],
      'events': [],
    }, null);
    catalog = SelectedPluginHooks(store, 'alice', [
      {'id': 'plugin', 'version_id': 'v1'},
    ]);
    executor = _Executor(store);
    cancellation = CancellationController();
    owner = execution('original-turn');
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });
  Future<List<String>> run(PluginHookLifecycle hooks) => hooks.beforeTurn(
    execution: owner,
    prompt: 'original prompt',
    model: 'deepseek-flash',
    cancellation: cancellation.token,
    materials: const [],
  );

  test(
    'startup is session-scoped while each original user turn runs once',
    () async {
      final hooks = lifecycle();
      expect(await run(hooks), ['STARTUP_CONTEXT', 'PROMPT_CONTEXT']);
      expect(await run(hooks), ['STARTUP_CONTEXT', 'PROMPT_CONTEXT']);
      expect(await run(lifecycle()), ['STARTUP_CONTEXT', 'PROMPT_CONTEXT']);
      expect(executor.submitted, ['SessionStart', 'UserPromptSubmit']);
      owner = execution('next-user-turn');
      expect(await run(lifecycle()), ['STARTUP_CONTEXT', 'PROMPT_CONTEXT']);
      expect(executor.submitted, [
        'SessionStart',
        'UserPromptSubmit',
        'UserPromptSubmit',
      ]);
    },
  );
  test(
    'prompt blocking remains a block on original recovery without repeat IO',
    () async {
      executor.deny = true;
      await expectLater(run(lifecycle()), throwsStateError);
      await expectLater(run(lifecycle()), throwsStateError);
      expect(executor.submitted, ['SessionStart', 'UserPromptSubmit']);
    },
  );
  test(
    'withdrawn sources and cancellation prevent startup-context cache reuse',
    () async {
      final hooks = lifecycle();
      await run(hooks);
      final record = store.get('cap/alice/plugin')!;
      store.put('cap/alice/plugin', {
        ...record.value,
        'enabled': false,
      }, record.revision);
      await expectLater(run(hooks), throwsStateError);
      final disabled = store.get('cap/alice/plugin')!;
      store.put('cap/alice/plugin', {
        ...disabled.value,
        'enabled': true,
      }, disabled.revision);
      cancellation.cancel();
      await expectLater(run(hooks), throwsA(anything));
      expect(executor.submitted, hasLength(2));
    },
  );
  test(
    'uncertain startup cannot be replayed by a recreated or later turn',
    () async {
      executor.failure = SandboxExecutionError('submitted, reply lost');
      await expectLater(
        run(lifecycle()),
        throwsA(isA<SandboxExecutionError>()),
      );
      executor.failure = null;
      await expectLater(
        run(lifecycle()),
        throwsA(isA<UnconfirmedToolOperation>()),
      );
      owner = execution('next-user-turn');
      await expectLater(
        run(lifecycle()),
        throwsA(isA<UnconfirmedToolOperation>()),
      );
      expect(executor.submitted, ['SessionStart']);
    },
  );
  test(
    'answer-only contract never launches a workflow lifecycle handler',
    () async {
      owner = execution('answer', mode: 'answer');
      expect(await run(lifecycle()), isEmpty);
      expect(executor.submitted, isEmpty);
    },
  );
}
