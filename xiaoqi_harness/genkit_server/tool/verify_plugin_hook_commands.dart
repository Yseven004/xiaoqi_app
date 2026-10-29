import 'dart:io';
import 'dart:convert';
import '../bin/support/plugin_hook_gate.dart';

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
  stdout.writeln(
    'HOOK_COMMAND_NATIVE_VERIFIED cases=6 bytes=${utf8.encode(program).length}',
  );
}
