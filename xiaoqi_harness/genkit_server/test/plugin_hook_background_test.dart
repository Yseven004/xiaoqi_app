import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_background.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hooks.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_output.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory directory;
  late CloudStore store;
  final hook = PluginHooks.parse({}, {
    'hooks': {
      'PostToolUse': [
        {
          'hooks': [
            {'type': 'command', 'command': 'review', 'asyncRewake': true},
          ],
        },
      ],
    },
  }, manifestPath: 'plugin.json').handlers.single;
  PluginHookBackground queue() => PluginHookBackground(store, 'alice', 'task');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('background-hooks-');
    store = CloudStore(root: directory.path);
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });
  test(
    'background returns before work completes and joins the same task',
    () async {
      final gate = Completer<PluginHookOutput?>();
      final jobs = queue();
      expect(
        await jobs.run(
          hook: hook,
          identity: 'event',
          requestIdentity: 'turn',
          descriptor: {'original': 1},
          check: () {},
          execute: () => gate.future,
        ),
        isNull,
      );
      expect(
        store
            .list('private_background_hooks/alice/task/')
            .single
            .$2
            .value['phase'],
        'pending',
      );
      gate.complete(
        const PluginHookOutput(additionalContext: 'review finding'),
      );
      expect(await jobs.drain(), ['review finding']);
      jobs.acknowledge();
      var executions = 0;
      final resumed = queue();
      await resumed.recover(
        requestIdentity: 'turn',
        definition: (_) => hook,
        execute: (_) async {
          executions++;
          return null;
        },
      );
      expect(await resumed.drain(), isEmpty);
      expect(executions, 0);
    },
  );
  test(
    'completed undelivered output survives API restart without replay',
    () async {
      final jobs = queue();
      await jobs.run(
        hook: hook,
        identity: 'event',
        requestIdentity: 'turn',
        descriptor: {'original': 1},
        check: () {},
        execute: () async =>
            const PluginHookOutput(additionalContext: 'finding'),
      );
      await jobs.close();
      store.close();
      store = CloudStore(root: directory.path);
      final resumed = queue();
      await resumed.recover(
        requestIdentity: 'different-turn',
        definition: (_) => hook,
        execute: (_) async => throw StateError('wrong turn'),
      );
      expect(await resumed.drain(), isEmpty);
      await resumed.recover(
        requestIdentity: 'turn',
        definition: (_) => hook,
        execute: (_) async => throw StateError('must reuse result'),
      );
      expect(await resumed.drain(), ['finding']);
      resumed.acknowledge();
    },
  );
  test('changed original arguments cannot claim a background record', () async {
    final jobs = queue();
    await jobs.run(
      hook: hook,
      identity: 'event',
      requestIdentity: 'turn',
      descriptor: {'original': 1},
      check: () {},
      execute: () async => null,
    );
    await jobs.close();
    await expectLater(
      queue().run(
        hook: hook,
        identity: 'event',
        requestIdentity: 'turn',
        descriptor: {'original': 2},
        check: () {},
        execute: () async => null,
      ),
      throwsStateError,
    );
  });
  test(
    'source withdrawal failures surface at join, never grant permission',
    () async {
      final jobs = queue();
      await jobs.run(
        hook: hook,
        identity: 'event',
        requestIdentity: 'turn',
        descriptor: {},
        check: () {},
        execute: () async => throw StateError('source withdrawn'),
      );
      await expectLater(jobs.drain(), throwsStateError);
      await jobs.close();
      expect(
        store
            .list('private_background_hooks/alice/task/')
            .single
            .$2
            .value['phase'],
        'pending',
      );
    },
  );
  test(
    'same skill once group waits for its original effect without blocking the tool',
    () async {
      final jobs = queue();
      final gate = Completer<PluginHookOutput?>();
      final order = <int>[];
      await jobs.run(
        hook: hook,
        identity: 'first',
        requestIdentity: 'turn',
        descriptor: {'serial_key': 'skill'},
        check: () {},
        execute: () {
          order.add(1);
          return gate.future;
        },
      );
      await jobs.run(
        hook: hook,
        identity: 'second',
        requestIdentity: 'turn',
        descriptor: {'serial_key': 'skill'},
        check: () {},
        execute: () async {
          order.add(2);
          return null;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(order, [1]);
      gate.complete(null);
      await jobs.close();
      expect(order, [1, 2]);
    },
  );
  test(
    'withdrawal after completion prevents pending feedback and cached reuse',
    () async {
      final jobs = queue();
      var enabled = true;
      void check() {
        if (!enabled) throw StateError('withdrawn');
      }

      await jobs.run(
        hook: hook,
        identity: 'event',
        requestIdentity: 'turn',
        descriptor: {},
        check: check,
        execute: () async =>
            const PluginHookOutput(additionalContext: 'private result'),
      );
      await jobs.close();
      enabled = false;
      await expectLater(jobs.drain(), throwsStateError);
      await expectLater(
        queue().recover(
          requestIdentity: 'turn',
          definition: (_) {
            check();
            return hook;
          },
          execute: (_) async => throw StateError('no replay'),
        ),
        throwsStateError,
      );
    },
  );
}
