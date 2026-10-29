import 'dart:io';
import 'dart:convert';
import '../bin/support/plugin_hook_gate.dart';
import '../bin/support/plugin_hook_fixtures.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hooks.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_command.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_output.dart';

/// Native development probe for checked-in, trusted fixtures only. Actual
/// imported plugins run through DockerCodeExecutionService, never this CLI.
Future<void> main() async {
  final shell = Platform.isWindows
      ? 'C:/Program Files/Git/bin/bash.exe'
      : '/bin/bash';
  final program = hookCommandProbe(shellExecutable: shell);
  if (utf8.encode(program).length > 64 * 1024) {
    throw StateError('hook probe exceeds normal code budget');
  }
  final run = await Process.start('node', ['-']);
  final output = run.stdout.transform(utf8.decoder).join();
  final errors = run.stderr.transform(utf8.decoder).join();
  run.stdin.write(program);
  await run.stdin.close();
  if (await run.exitCode != 0) {
    throw StateError('native hook fixture failed: ${await errors}');
  }
  checkHookCommandProbe(await output);
  final directory = await Directory.systemTemp.createTemp(
    'hook-python-native-',
  );
  try {
    final script = File('${directory.path}/pre.py')
      ..writeAsStringSync(hookGatePreScript);
    String quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
    final python =
        Platform.environment['XIAOQI_TEST_PYTHON'] ??
        (Platform.isWindows ? 'python' : 'python3');
    final hook = PluginHooks.parse({}, {
      'hooks': {
        'PreToolUse': [
          {
            'matcher': r'^Bash$',
            'hooks': [
              {
                'type': 'command',
                'command':
                    '${quote(python)} ${quote(script.path.replaceAll('\\', '/'))}',
              },
            ],
          },
        ],
      },
    }, manifestPath: 'plugin.json').handlers.single;
    final code = PluginHookCommand.program(
      hook,
      {
        'hook_event_name': 'PreToolUse',
        'tool_name': 'Bash',
        'tool_input': {'command': 'echo agent-shell-verified'},
      },
      matchValue: 'Bash',
      shellExecutable: shell,
    );
    final node = await Process.start('node', ['-']);
    final stdoutResult = node.stdout.transform(utf8.decoder).join();
    final stderrResult = node.stderr.transform(utf8.decoder).join();
    node.stdin.write(code);
    await node.stdin.close();
    if (await node.exitCode != 0) throw StateError(await stderrResult);
    final raw = PluginHookCommand.result(await stdoutResult);
    final verdict = PluginHookOutput.parse(
      event: 'PreToolUse',
      exitCode: raw['exit_code'] as int?,
      stdout: raw['stdout'] as String,
      stderr: raw['stderr'] as String,
    );
    if (verdict.updatedInput?['command'] !=
        'echo agent-shell-verified\nprintf "hook-shell-verified" > /workspace/output/hook-verified.txt\n') {
      throw StateError(
        'native Python pre-hook did not return the real command rewrite: ${verdict.error}',
      );
    }
  } finally {
    await directory.delete(recursive: true);
  }
  stdout.writeln(
    'HOOK_COMMAND_NATIVE_VERIFIED cases=7 bytes=${utf8.encode(program).length}',
  );
}
