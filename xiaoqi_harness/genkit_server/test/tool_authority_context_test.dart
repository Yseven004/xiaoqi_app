import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  late Directory root;
  late CloudStore store;
  late ToolExecution owner;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tool-authority-');
    store = CloudStore(root: root.path);
    store.put('task/tenant/task', {'artifacts': []}, null);
    owner = ToolExecution(
      store,
      'tenant',
      'task',
      TurnContract(mode: 'workflow', imageLimit: 0),
      requestIdentity: 'human',
    )..bind();
  });
  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });

  test(
    'source revocation during an asynchronous wait blocks submission without affecting other tools',
    () async {
      var enabled = true;
      var effects = 0;
      final entered = Completer<void>();
      final release = Completer<void>();
      final pending = ToolExecution.withAuthorityCheck(
        () {
          if (!enabled) throw StateError('source revoked');
        },
        () async {
          owner.check('read');
          entered.complete();
          await release.future;
          owner.check('workspace');
          effects++;
        },
      );
      final failure = expectLater(pending, throwsStateError);
      await entered.future;
      enabled = false;
      // Outside the child's async zone, the same task retains its own authority.
      owner.check('workspace');
      release.complete();
      await failure;
      expect(effects, 0);
      owner.check('workspace');
    },
  );
  test(
    'nested async tools retain all ancestor checks and release them on exit',
    () async {
      var parentEnabled = true;
      var childEnabled = true;
      await ToolExecution.withAuthorityCheck(
        () {
          if (!parentEnabled) throw StateError('parent revoked');
        },
        () async {
          await ToolExecution.withAuthorityCheck(
            () {
              if (!childEnabled) throw StateError('child revoked');
            },
            () async {
              await Future<void>.value();
              owner.check('read');
              parentEnabled = false;
              expect(() => owner.check('workspace'), throwsStateError);
              parentEnabled = true;
              childEnabled = false;
              expect(() => owner.check('workspace'), throwsStateError);
            },
          );
          owner.check('workspace');
        },
      );
      parentEnabled = false;
      owner.check('workspace');
    },
  );
}
