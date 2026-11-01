import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/plugin_command_context.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

class _Executor extends DockerCodeExecutionService {
  _Executor(super.store);
  int submissions = 0;
  void Function()? before, after;
  Object? failure;
  SandboxExecutionProfile expected =
      SandboxExecutionProfile.pluginCommandContext;

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
    before?.call();
    beforeSubmit?.call();
    expect(profile, expected);
    expect(authorizedDomains, isEmpty);
    expect(language, 'javascript');
    expect(scopeOperationId, matches(RegExp(r'^[a-f0-9]{64}$')));
    submissions++;
    if (failure != null) throw failure!;
    after?.call();
    return jsonEncode({
      PluginCommandContext.resultKey: {
        'ok': true,
        'outputs': ['original context'],
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
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('context-authority-');
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
  Future<List<String>> run({
    String invocation = 'original-ref',
    String arguments = '',
    bool readOnly = false,
    ToolExecution? owner,
  }) => PluginCommandContext.expand(
    executor: executor,
    execution: owner ?? execution,
    sourceBinding: 'immutable-version',
    invocation: invocation,
    commands: ['printf original'],
    arguments: arguments,
    argv: arguments.isEmpty ? [] : [arguments],
    sourceFiles: () {
      if (!enabled) throw StateError('source withdrawn');
      return {'commands/context.md': utf8.encode('fixed source')};
    },
    cancellation: cancellation.token,
    materials: const [],
    readOnly: readOnly,
  );

  test(
    'resume keeps one submission and changed args cannot reuse its identity',
    () async {
      expect(await run(), ['original context']);
      expect(await run(), ['original context']);
      await expectLater(run(arguments: 'changed'), throwsStateError);
      expect(executor.submissions, 1);
      await run(invocation: 'new-ref');
      expect(executor.submissions, 2);
    },
  );
  test(
    'read-only context retains its private execution profile on resume',
    () async {
      executor.expected = SandboxExecutionProfile.pluginCommandContextReadOnly;
      await run(readOnly: true);
      await run(readOnly: true);
      expect(executor.submissions, 1);
    },
  );
  test('lost reply never blindly replays a submitted source command', () async {
    executor.failure = SandboxExecutionError('submitted, reply lost');
    await expectLater(run(), throwsA(isA<SandboxExecutionError>()));
    executor.failure = null;
    await expectLater(run(), throwsA(isA<UnconfirmedToolOperation>()));
    expect(executor.submissions, 1);
  });
  test(
    'withdrawal immediately before submission prevents command IO',
    () async {
      executor.before = () => enabled = false;
      await expectLater(run(), throwsStateError);
      expect(executor.submissions, 0);
    },
  );
  test('withdrawal after execution prevents returning the context', () async {
    executor.after = () => enabled = false;
    await expectLater(run(), throwsStateError);
    expect(executor.submissions, 1);
  });
  test(
    'revocation and cancellation also forbid cached context reuse',
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
  test('answer-only contract cannot run command preprocessing', () async {
    final answer = ToolExecution(
      store,
      'alice',
      'task',
      TurnContract(mode: 'answer', imageLimit: 0),
      requestIdentity: 'answer',
    );
    answer.bind();
    await expectLater(run(owner: answer), throwsStateError);
    expect(executor.submissions, 0);
  });
}
