import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hooks.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_runner.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

class _Executor extends DockerCodeExecutionService {
  _Executor(super.store);
  int submissions = 0;
  void Function()? onAttempt;
  Object? submissionFailure;
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
    onAttempt?.call();
    beforeSubmit?.call();
    expect(authorizedDomains, isEmpty);
    expect(scopeOperationId, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(language, 'javascript');
    expect(profile, SandboxExecutionProfile.pluginHook);
    submissions++;
    if (submissionFailure != null) throw submissionFailure!;
    return jsonEncode({
      'xiaoqi_hook_command_v1': {
        'matched': true,
        'timed_out': false,
        'exit_code': 2,
        'stdout': '',
        'stderr': 'guard denied',
      },
    });
  }
}

void main() {
  late Directory directory;
  late CloudStore store;
  late ToolExecution execution;
  late _Executor executor;
  late CancellationController cancellation;
  var enabled = true;
  final hook = PluginHooks.parse({}, {
    'hooks': {
      'PreToolUse': [
        {
          'hooks': [
            {'type': 'command', 'command': 'source-guard'},
          ],
        },
      ],
    },
  }, manifestPath: 'plugin.json').handlers.single;
  Map<String, List<int>> source() {
    if (!enabled) throw StateError('source withdrawn');
    return {'guard.py': utf8.encode('# fixed source')};
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hook-runner-');
    store = CloudStore(root: directory.path);
    store.put('task/alice/task', {
      'status': 'running',
      'artifacts': [],
      'events': [],
    }, null);
    execution = ToolExecution(
      store,
      'alice',
      'task',
      TurnContract(mode: 'workflow', imageLimit: 0),
      requestIdentity: 'original',
    );
    execution.bind();
    executor = _Executor(store);
    cancellation = CancellationController();
    enabled = true;
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });
  Future<Object?> run({
    String id = 'original-tool-ref',
    String tool = 'Bash',
    ToolExecution? owner,
  }) => PluginHookRunner(executor).run(
    execution: owner ?? execution,
    hook: hook,
    sourceBinding: 'immutable-version',
    invocation: id,
    input: {'hook_event_name': 'PreToolUse', 'tool_name': tool},
    matchValue: tool,
    sourceFiles: source,
    cancellation: cancellation.token,
  );

  test(
    'same original event resumes its stored verdict, a new event executes',
    () async {
      final first = await run();
      expect(first, isNotNull);
      await run();
      expect(executor.submissions, 1);
      await run(id: 'next-tool-ref');
      expect(executor.submissions, 2);
    },
  );
  test('changed arguments cannot hijack the original event identity', () async {
    await run();
    await expectLater(run(tool: 'Write'), throwsStateError);
    expect(executor.submissions, 1);
  });
  test(
    'unknown original effects are not replayed after a failed bridge',
    () async {
      executor.submissionFailure = SandboxExecutionError(
        'submitted, reply lost',
      );
      await expectLater(run(), throwsA(isA<SandboxExecutionError>()));
      executor.submissionFailure = null;
      await expectLater(run(), throwsA(isA<UnconfirmedToolOperation>()));
      expect(executor.submissions, 1);
    },
  );
  test('source withdrawal immediately before submission prevents IO', () async {
    executor.onAttempt = () => enabled = false;
    await expectLater(run(), throwsStateError);
    expect(executor.submissions, 0);
  });
  test(
    'withdrawal and cancellation also forbid cached verdict reuse',
    () async {
      await run();
      enabled = false;
      await expectLater(run(), throwsStateError);
      enabled = true;
      cancellation.cancel();
      await expectLater(run(), throwsA(anything));
      expect(executor.submissions, 1);
    },
  );
  test('answer-only scope cannot activate workflow hooks', () async {
    final owner = ToolExecution(
      store,
      'alice',
      'task',
      TurnContract(mode: 'answer', imageLimit: 0),
      requestIdentity: 'answer',
    );
    owner.bind();
    await expectLater(run(owner: owner), throwsStateError);
    expect(executor.submissions, 0);
  });
}
