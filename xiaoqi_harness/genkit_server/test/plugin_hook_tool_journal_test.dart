import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_tool_journal.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  late Directory directory;
  late CloudStore store;
  late ToolExecution owner;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hook-native-journal-');
    store = CloudStore(root: directory.path);
    store.put('task/alice/task', {'status': 'running', 'artifacts': []}, null);
    owner = ToolExecution(
      store,
      'alice',
      'task',
      TurnContract(mode: 'workflow', imageLimit: 0),
      requestIdentity: 'request',
    );
    owner.bind();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });
  Future<ToolResult> run(
    Future<ToolResult> Function() effect, {
    String id = 'original',
    Map<String, dynamic> arguments = const {'path': 'a'},
    bool resumed = false,
  }) => PluginHookToolJournal(
    owner,
  ).run(invocation: id, arguments: arguments, resumed: resumed, invoke: effect);

  test(
    'stored response survives database reopening with original parts and metadata',
    () async {
      var effects = 0;
      Future<ToolResult> effect() async {
        effects++;
        return ToolResult.response(
          'original',
          parts: [TextPart(text: '中文原始结果')],
          metadata: {'proof': 'original'},
        );
      }

      await run(effect);
      store.close();
      store = CloudStore(root: directory.path);
      owner = ToolExecution(
        store,
        'alice',
        'task',
        TurnContract(mode: 'workflow', imageLimit: 0),
        requestIdentity: 'request',
      );
      final result = await run(effect) as ToolResponseResult;
      expect(effects, 1);
      expect(result.output, 'original');
      expect(result.parts!.single.toJson(), TextPart(text: '中文原始结果').toJson());
      expect(result.metadata, {'proof': 'original'});
      expect(store.get(owner.key)!.value['artifacts'], isEmpty);
    },
  );
  test(
    'unknown native outcome cannot replay through the same or a fresh SDK reference',
    () async {
      var effects = 0;
      Future<ToolResult> effect() async {
        effects++;
        throw StateError('reply lost');
      }

      await expectLater(run(effect), throwsStateError);
      await expectLater(run(effect), throwsA(isA<UnconfirmedToolOperation>()));
      await expectLater(
        run(effect, id: 'replacement'),
        throwsA(isA<UnconfirmedToolOperation>()),
      );
      expect(effects, 1);
    },
  );
  test(
    'original permission interrupt can restart only with resumed metadata',
    () async {
      var attempts = 0;
      Future<ToolResult> effect() async {
        attempts++;
        return attempts == 1
            ? ToolResult.interrupt({'approval_hash': 'exact'})
            : ToolResult.response('approved original effect');
      }

      expect(await run(effect), isA<ToolInterruptResult>());
      await expectLater(run(effect), throwsA(isA<UnconfirmedToolOperation>()));
      expect(
        (await run(effect, resumed: true)).output,
        'approved original effect',
      );
      expect(attempts, 2);
    },
  );
  test(
    'changed input rejects reuse while JSON key order preserves the original binding',
    () async {
      var effects = 0;
      Future<ToolResult> effect() async {
        effects++;
        return ToolResult.response('original');
      }

      await run(
        effect,
        arguments: {
          'a': 1,
          'nested': {'x': 'value', 'y': true},
        },
      );
      await run(
        effect,
        arguments: {
          'nested': {'y': true, 'x': 'value'},
          'a': 1,
        },
      );
      await expectLater(run(effect, arguments: {'a': 2}), throwsStateError);
      expect(effects, 1);
    },
  );
  test(
    'atomic blob written before ready marker can recover; corruption cannot trigger IO',
    () async {
      var effects = 0;
      Future<ToolResult> effect() async {
        effects++;
        return ToolResult.response('original');
      }

      await run(effect);
      var task = store.get(owner.key)!;
      final entries = Map<String, dynamic>.from(
        task.value['plugin_hook_tool_calls'] as Map,
      );
      final id = entries.keys.single;
      entries[id] = {...entries[id] as Map, 'status': 'result_pending'};
      store.put(owner.key, {
        ...task.value,
        'plugin_hook_tool_calls': entries,
      }, task.revision);
      expect((await run(effect)).output, 'original');
      task = store.get(owner.key)!;
      final entry = (task.value['plugin_hook_tool_calls'] as Map)[id] as Map;
      store.putTaskBlob(entry['blob'] as String, utf8.encode('corrupt'));
      await expectLater(run(effect), throwsA(isA<UnconfirmedToolOperation>()));
      expect(effects, 1);
    },
  );
  test(
    'forged checkpoint pointer cannot read another tenant even with a matching checksum',
    () async {
      var effects = 0;
      Future<ToolResult> effect() async {
        effects++;
        return ToolResult.response('owned');
      }

      await run(effect);
      const foreign =
          'tenants/bob/tasks/other/private_hook_tool_results/foreign.json';
      final bytes = utf8.encode(jsonEncode({'output': 'foreign secret'}));
      store.putTaskBlob(foreign, bytes);
      final task = store.get(owner.key)!;
      final entries = Map<String, dynamic>.from(
        task.value['plugin_hook_tool_calls'] as Map,
      );
      final id = entries.keys.single;
      entries[id] = {
        ...entries[id] as Map,
        'blob': foreign,
        'bytes': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      };
      store.put(owner.key, {
        ...task.value,
        'plugin_hook_tool_calls': entries,
      }, task.revision);
      await expectLater(run(effect), throwsA(isA<UnconfirmedToolOperation>()));
      expect(effects, 1);
    },
  );
}
