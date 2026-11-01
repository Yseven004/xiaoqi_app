import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hooks.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_output.dart';
import 'package:xiaoqi_genkit_server/src/scoped_skill_hooks.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';

void main() {
  late Directory directory;
  late CloudStore store;
  late ScopedSkillHooks registry;
  final hook = PluginHooks.skill({
    'hooks': {
      'PreToolUse': [
        {
          'matcher': 'Bash',
          'hooks': [
            {'type': 'command', 'command': 'validate', 'once': true},
          ],
        },
      ],
    },
  }).handlers.single;
  test(
    'unmapped skill lifecycle remains visible while healthy tool hooks stay usable',
    () {
      final inspected = CapabilityImportService.inspectSkill({
        'SKILL.md': utf8.encode(
          '---\nname: secure\ndescription: Guard the workflow\nhooks: ${jsonEncode({
            'SessionStart': [
              {
                'hooks': [
                  {'type': 'command', 'command': 'setup'},
                ],
              },
            ],
            'PreToolUse': [
              {
                'hooks': [
                  {'type': 'command', 'command': 'validate', 'once': true},
                ],
              },
            ],
          })}\n---\nFollow the guarded workflow.',
        ),
      }, '');
      expect(inspected['status'], 'partial');
      expect((inspected['warnings'] as List).single, contains('SessionStart'));
      expect(inspected['issues'], isEmpty);
    },
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('skill-hook-scope-');
    store = CloudStore(root: directory.path);
    registry = ScopedSkillHooks(store, 'alice', 'task');
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });
  Future<PluginHookOutput?> run(
    String event,
    Future<PluginHookOutput?> Function() execute, {
    String session = 'parent',
    void Function()? check,
  }) => registry.run(
    session: session,
    binding: 'immutable-source',
    hook: hook,
    invocation: event,
    inputBinding: 'fixed-event-input',
    check: check ?? () {},
    execute: execute,
  );
  test(
    'skill parsing preserves source, handler identity and invalid siblings',
    () {
      expect(hook.sourcePath, 'SKILL.md');
      expect(hook.matcher, 'Bash');
      expect(hook.config['once'], true);
      expect(PluginHooks.skill({'hooks': []}).issues, hasLength(1));
      final parsed = PluginHooks.skill({
        'hooks': {
          'PreToolUse': [
            {
              'hooks': [
                {'type': 'command', 'command': 'good'},
                {'type': 'command'},
              ],
            },
          ],
        },
      });
      expect(parsed.handlers, hasLength(1));
      expect(parsed.issues, hasLength(1));
    },
  );
  test(
    'same successful event restores its original verdict after reopen without rerunning',
    () async {
      var calls = 0;
      Future<PluginHookOutput> execute() async {
        calls++;
        return PluginHookOutput.parse(
          event: 'PreToolUse',
          exitCode: 0,
          stderr: '',
          stdout:
              '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","updatedInput":{"recipient":"changed"}}}',
        );
      }

      await run('approval-event', execute);
      store.close();
      store = CloudStore(root: directory.path);
      registry = ScopedSkillHooks(store, 'alice', 'task');
      final restored = await run('approval-event', execute);
      expect(restored!.permission, 'ask');
      expect(restored.updatedInput, {'recipient': 'changed'});
      expect(calls, 1);
      await expectLater(
        registry.run(
          session: 'parent',
          binding: 'immutable-source',
          hook: hook,
          invocation: 'approval-event',
          inputBinding: 'changed-input',
          check: () {},
          execute: execute,
        ),
        throwsStateError,
      );
      expect(calls, 1);
    },
  );
  test(
    'activation survives reopen but cannot cross session tenant task or version',
    () {
      registry.activate('parent', 'skill-a', 'v1');
      registry.activate('child', 'skill-b', 'v2');
      store.close();
      store = CloudStore(root: directory.path);
      registry = ScopedSkillHooks(store, 'alice', 'task');
      expect(registry.active('parent', {'skill-a': 'v1', 'skill-b': 'v2'}), [
        'skill-a',
      ]);
      expect(registry.active('child', {'skill-a': 'v1', 'skill-b': 'v2'}), [
        'skill-b',
      ]);
      expect(registry.active('parent', {'skill-a': 'changed'}), isEmpty);
      expect(registry.active('parent', {}), isEmpty);
      expect(
        ScopedSkillHooks(
          store,
          'bob',
          'task',
        ).active('parent', {'skill-a': 'v1'}),
        isEmpty,
      );
      expect(
        ScopedSkillHooks(
          store,
          'alice',
          'other',
        ).active('parent', {'skill-a': 'v1'}),
        isEmpty,
      );
    },
  );
  test(
    'only successful completion consumes once; child has an independent once',
    () async {
      var calls = 0;
      Future<PluginHookOutput> verdict(int exit, {bool timeout = false}) async {
        calls++;
        return PluginHookOutput.parse(
          event: hook.event,
          exitCode: exit,
          stdout: '',
          stderr: '',
          timedOut: timeout,
        );
      }

      await run('blocked', () => verdict(2));
      await run('failed', () => verdict(1));
      await run('timeout', () => verdict(0, timeout: true));
      await run('succeeded', () => verdict(0));
      expect(await run('later', () => verdict(0)), isNull);
      await run('child-event', () => verdict(0), session: 'child');
      expect(calls, 5);
      store.close();
      store = CloudStore(root: directory.path);
      registry = ScopedSkillHooks(store, 'alice', 'task');
      expect(await run('after-reopen', () => verdict(0)), isNull);
      expect(calls, 5);
    },
  );
  test(
    'an uncertain original effect survives restart without new-event replay',
    () async {
      var calls = 0;
      await expectLater(
        run('original', () async {
          calls++;
          throw StateError('submitted, reply lost');
        }),
        throwsStateError,
      );
      store.close();
      store = CloudStore(root: directory.path);
      registry = ScopedSkillHooks(store, 'alice', 'task');
      Future<PluginHookOutput> recover() async {
        calls++;
        return const PluginHookOutput(successful: true);
      }

      await expectLater(
        run('new', recover),
        throwsA(isA<UnconfirmedToolOperation>()),
      );
      expect(calls, 1);
      await run('original', recover);
      expect(
        calls,
        2,
      ); // The execution adapter must recover its original result.
      expect(await run('new', recover), isNull);
      expect(calls, 2);
    },
  );
  test(
    'concurrent once cannot duplicate an in-flight effect and cache still rechecks authority',
    () async {
      final started = Completer<void>();
      final finish = Completer<PluginHookOutput>();
      final first = run('first', () {
        started.complete();
        return finish.future;
      });
      await started.future;
      await expectLater(
        run('second', () async => const PluginHookOutput()),
        throwsA(isA<UnconfirmedToolOperation>()),
      );
      finish.complete(const PluginHookOutput(successful: true));
      await first;
      await expectLater(
        run(
          'third',
          () async => const PluginHookOutput(),
          check: () => throw StateError('source withdrawn'),
        ),
        throwsStateError,
      );
    },
  );
}
