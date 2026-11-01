import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_event_journal.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_output.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  test(
    'session startup context persists across later turns without repeating its effect',
    () async {
      final directory = await Directory.systemTemp.createTemp('hook-startup-');
      var store = CloudStore(root: directory.path);
      const key = 'private_plugin_lifecycle/alice/task/startup/source';
      var calls = 0;
      Future<PluginHookOutput> execute() async {
        calls++;
        return const PluginHookOutput(
          successful: true,
          additionalContext: 'session instructions',
        );
      }

      try {
        await PluginHookEventJournal(store, key).run(
          invocation: 'original-turn',
          inputBinding: 'original-input',
          check: () {},
          execute: execute,
          returnForLaterEvents: true,
        );
        store.close();
        store = CloudStore(root: directory.path);
        final restored = await PluginHookEventJournal(store, key).run(
          invocation: 'later-turn',
          inputBinding: 'later-input',
          check: () {},
          execute: execute,
          returnForLaterEvents: true,
        );
        expect(restored!.additionalContext, 'session instructions');
        expect(calls, 1);
        await expectLater(
          PluginHookEventJournal(store, key).run(
            invocation: 'original-turn',
            inputBinding: 'changed-input',
            check: () {},
            execute: execute,
            returnForLaterEvents: true,
          ),
          throwsStateError,
        );
        await expectLater(
          PluginHookEventJournal(store, key).run(
            invocation: 'later-turn',
            inputBinding: 'later-input',
            check: () => throw StateError('source withdrawn'),
            execute: execute,
            returnForLaterEvents: true,
          ),
          throwsStateError,
        );
        expect(calls, 1);
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
