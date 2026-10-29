import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_middleware.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

Future<void> main(List<String> args) async {
  final store = CloudStore(root: args[0]);
  final counter = File('${args[0]}/native-effect-count');
  final starting = args[1] == 'start';
  if (starting) store.put('task/alice/task', {'status': 'running'}, null);
  final owner = ToolExecution(
    store,
    'alice',
    'task',
    TurnContract(mode: 'workflow', imageLimit: 0),
    requestIdentity: 'original',
  );
  owner.bind();
  final hooks = PluginHookMiddleware(
    execution: () => owner,
    control: PluginHookControl(),
    checkSources: (_) {},
    hasHooks: (_) => true,
    describe: PluginHookTool.native,
    validateInput: (_, _) async => true,
    dispatch: (event, _, _) async {
      if (starting && event == 'PostToolUse') {
        // The parent kills this process here, after the real file effect and
        // result checkpoint, before a post-hook or SDK response can finish.
        stdout.writeln('NATIVE_CHECKPOINT_READY');
        await stdout.flush();
        Timer.periodic(const Duration(seconds: 10), (_) {});
        await Completer<void>().future;
      }
      return [];
    },
  );
  try {
    final result = await hooks.tool(
      ToolRequestPart(
        toolRequest: ToolRequest(
          name: 'write_task_text_file',
          ref: 'original-sdk-ref',
          input: {'path': 'report.txt', 'text': 'original payload'},
        ),
      ),
      ActionFnArg(),
      (_, _) async {
        final count = counter.existsSync()
            ? int.parse(counter.readAsStringSync())
            : 0;
        counter.writeAsStringSync('${count + 1}', flush: true);
        return ToolResult.response(
          'original native result',
          parts: [TextPart(text: '原始结果')],
          metadata: {'proof': 'original'},
        );
      },
    );
    stdout.writeln(
      'RESULT:${jsonEncode({'effects': int.parse(counter.readAsStringSync()), 'response': result.toJson()})}',
    );
  } finally {
    store.close();
  }
}
