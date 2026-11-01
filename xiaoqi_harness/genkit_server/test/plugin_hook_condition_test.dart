import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hooks.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_command.dart';

void main() {
  final node = Platform.isWindows
      ? r'C:\Program Files\nodejs\node.exe'
      : 'node';
  for (final row in [
    ('git *', 'FOO=bar git push', true),
    ('git *', 'npm test && git push', true),
    ('git *', 'npm test', false),
    ('git *', 'git status', true),
    ('rm *', r'echo $(rm -rf /)', true),
  ]) {
    test('isolated if filter ${row.$1}: ${row.$2}', () async {
      final hook = PluginHooks.parse({}, {
        'hooks': {
          'PreToolUse': [
            {
              'hooks': [
                {
                  'type': 'command',
                  'command': node,
                  'args': ['-e', 'process.stdout.write("checked")'],
                  'if': 'Bash(${row.$1})',
                },
              ],
            },
          ],
        },
      }, manifestPath: 'plugin.json').handlers.single;
      final code = PluginHookCommand.program(hook, {
        'hook_event_name': 'PreToolUse',
        'tool_name': 'Bash',
        'tool_input': {'command': row.$2},
      }, matchValue: 'Bash');
      final result = await Process.run(node, ['-e', code]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final output = PluginHookCommand.result(result.stdout as String);
      expect(output['matched'], row.$3, reason: jsonEncode(output));
      expect(output['stdout'], row.$3 ? 'checked' : '');
      expect(output['stderr'], '');
    });
  }
}
