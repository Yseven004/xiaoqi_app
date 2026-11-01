import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_command_context.dart';
import 'package:xiaoqi_genkit_server/src/plugin_commands.dart';

void main() {
  test('context and argument outputs are inserted once as literal data', () {
    final command = PluginCommand.parse(
      'commands/context.md',
      utf8.encode(
        r'First=!`printf first`; second=!`printf second`; args=$ARGUMENTS; index=$0',
      ),
    );
    expect(command.contextCommands, ['printf first', 'printf second']);
    expect(
      command.render(
        r'"literal; $(never)"',
        contextOutputs: [
          r'!`never-execute` $ARGUMENTS',
          r'${CLAUDE_PLUGIN_ROOT}',
        ],
      ),
      r'First=!`never-execute` $ARGUMENTS; second=${CLAUDE_PLUGIN_ROOT}; args="literal; $(never)"; index=literal; $(never)',
    );
    for (final body in [
      '!`',
      '!``',
      '!`printf x',
      List.filled(17, '!`echo x`').join(),
    ]) {
      expect(
        () => PluginCommand.parse('commands/bad.md', utf8.encode(body)),
        throwsFormatException,
      );
    }
  });

  test(
    'incomplete failed oversized and wrongly counted results never become context',
    () {
      String envelope(Object value) =>
          jsonEncode({PluginCommandContext.resultKey: value});
      expect(
        PluginCommandContext.outputs(
          envelope({
            'ok': true,
            'outputs': ['a', 'b'],
          }),
          2,
        ),
        ['a', 'b'],
      );
      for (final result in [
        {
          'ok': true,
          'outputs': ['a'],
        },
        {
          'ok': true,
          'outputs': [7, 'b'],
        },
        {
          'ok': true,
          'outputs': ['x' * (128 * 1024 + 1), 'b'],
        },
      ]) {
        expect(
          () => PluginCommandContext.outputs(envelope(result), 2),
          throwsFormatException,
        );
      }
      expect(
        () => PluginCommandContext.outputs('{"partial":', 1),
        throwsFormatException,
      );
      expect(
        () => PluginCommandContext.outputs(
          envelope({'ok': false, 'error': 'exit 7'}),
          1,
        ),
        throwsA(isA<PluginCommandContextFailure>()),
      );
      expect(
        () => PluginCommandContext.program(['x' * 70000], '', []),
        throwsFormatException,
      );
    },
  );

  final node = Platform.isWindows
      ? r'C:\Program Files\nodejs\node.exe'
      : '/usr/bin/node';
  final bash = Platform.isWindows
      ? r'C:\Program Files\Git\bin\bash.exe'
      : '/bin/bash';
  test(
    'native launcher keeps shell argv literal and stops after a failed block',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'command-context-',
      );
      Future<String> run(List<String> commands) async {
        final script = File('${directory.path}/context.js');
        await script.writeAsString(
          PluginCommandContext.program(
            commands,
            r'literal; $(touch injected)',
            [r'argument; $(touch injected)', '!`literal`'],
            shellExecutable: bash,
          ),
        );
        final result = await Process.run(
          node,
          [script.path],
          workingDirectory: directory.path,
          includeParentEnvironment: false,
          environment: {
            'PATH': Platform.environment['PATH'] ?? '',
            if (Platform.isWindows)
              'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
          },
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        return result.stdout.toString();
      }

      try {
        final text = await run([
          r'''printf '%s' "$ARGUMENTS"''',
          r'''printf '%s|%s' "$1" "$2"''',
        ]);
        expect(PluginCommandContext.outputs(text, 2), [
          r'literal; $(touch injected)',
          r'argument; $(touch injected)|!`literal`',
        ]);
        expect(File('${directory.path}/injected').existsSync(), isFalse);
        final failure = await run(['exit 7', 'touch must-not-run']);
        expect(
          () => PluginCommandContext.outputs(failure, 2),
          throwsA(isA<PluginCommandContextFailure>()),
        );
        expect(File('${directory.path}/must-not-run').existsSync(), isFalse);
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !File(node).existsSync() || !File(bash).existsSync()
        ? 'Native Node/Bash unavailable; real-container gate runs this launcher'
        : false,
  );
}
