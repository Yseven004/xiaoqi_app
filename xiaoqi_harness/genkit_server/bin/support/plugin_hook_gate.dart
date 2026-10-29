import 'dart:convert';
import 'package:genkit/genkit.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hooks.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_command.dart';
import 'package:xiaoqi_genkit_server/src/plugin_hook_output.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

const _input = {
  'hook_event_name': 'PreToolUse',
  'tool_name': 'Bash',
  'tool_input': {
    'command':
        '中文\n'
        r'$(touch SHOULD_NOT_EXIST); `not-code`',
  },
};

/// Same launcher probe for native development and real Linux sandbox gates.
String hookCommandProbe({
  String shellExecutable = '/bin/bash',
  String pythonExecutable = 'python3',
}) {
  String quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
  final python = quote(pythonExecutable.replaceAll('\\', '/'));
  final commands = [
    {'command': r'''IFS= read -r payload; printf '%s' "$payload"'''},
    {'command': 'exit 2'},
    {'command': 'exit 99', 'matcher': r'^Write$'},
    {'command': 'sleep 2', 'timeout': 0.05},
    {'command': 'exit 0', 'matcher': r'(a+)+$'},
    {
      'command':
          r'''printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"source-guard"}}' ''',
    },
    {
      'command':
          '$python -c ${quote(r'''import json; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"large source verdict","additionalContext":"x"*70000}}))''')}',
    },
    {
      'command':
          '$python -c ${quote('import sys; sys.stdout.buffer.write(bytes(120000))')}',
    },
    {
      'command': pythonExecutable,
      'shell': 'powershell', // Ignored for exec form, even on Linux.
      'args': [
        '-c',
        'import json,sys; print(json.dumps({"argv":sys.argv[1:],"stdin":json.load(sys.stdin)}))',
        '中文 空格',
        r'literal; $(touch SHOULD_NOT_EXIST); `not-code`',
        r'${CLAUDE_PLUGIN_ROOT}/path with spaces/file',
        r'${CLAUDE_PROJECT_DIR}/file',
        '',
      ],
    },
  ];
  final programs = <String>[];
  for (final entry in commands) {
    final hook = PluginHooks.parse({}, {
      'hooks': {
        'PreToolUse': [
          {
            'matcher': entry['matcher'],
            'hooks': [
              {
                'type': 'command',
                'command': entry['command'],
                if (entry.containsKey('args')) 'args': entry['args'],
                if (entry.containsKey('shell')) 'shell': entry['shell'],
                if (entry.containsKey('timeout')) 'timeout': entry['timeout'],
              },
            ],
          },
        ],
      },
    }, manifestPath: 'plugin.json').handlers.single;
    programs.add(
      PluginHookCommand.program(
        hook,
        _input,
        matchValue: entry['matcher'] == r'(a+)+$' ? '${'a' * 10000}!' : 'Bash',
        shellExecutable: shellExecutable,
      ),
    );
  }
  // Keep the runtime script inside the existing 64 KiB admission budget. The
  // large regex subject is already JSON data and never API-host regex input.
  final encoded = jsonEncode(jsonEncode(programs));
  return '''
const { spawnSync } = require('node:child_process');
const programs = JSON.parse($encoded);
const results = [];
for (const program of programs) {
  const run = spawnSync(process.execPath, ['-'], { input: program, encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024 });
  if (run.status !== 0) throw new Error('hook launcher probe failed: ' + run.status + ':' + run.stderr);
  results.push(JSON.parse(run.stdout));
}
process.stdout.write(JSON.stringify(results));
''';
}

void checkHookCommandProbe(String text) {
  final values = jsonDecode(text) as List;
  if (values.length != 9) throw StateError('hook probe result missing');
  final results = [
    for (final value in values) PluginHookCommand.result(jsonEncode(value)),
  ];
  if (results[0]['exit_code'] != 0 ||
      jsonEncode(jsonDecode(results[0]['stdout'] as String)) !=
          jsonEncode(_input) ||
      results[1]['exit_code'] != 2 ||
      results[2]['matched'] != false ||
      results[2]['exit_code'] != null ||
      results[3]['timed_out'] != true ||
      results[4]['stderr'] != 'hook matcher 超时' ||
      results[4]['exit_code'] != null) {
    throw StateError('hook stdin/matcher/exit/timeout boundary failed');
  }
  final denied = PluginHookOutput.parse(
    event: 'PreToolUse',
    exitCode: results[5]['exit_code'] as int?,
    stdout: results[5]['stdout'] as String,
    stderr: results[5]['stderr'] as String,
  );
  if (results[8]['exit_code'] != 0)
    throw StateError('exec hook failed: ${results[8]['stderr']}');
  final direct = jsonDecode(results[8]['stdout'] as String) as Map;
  if (jsonEncode(direct['stdin']) != jsonEncode(_input) ||
      jsonEncode(direct['argv']) !=
          jsonEncode([
            '中文 空格',
            r'literal; $(touch SHOULD_NOT_EXIST); `not-code`',
            '/workspace/skill/path with spaces/file',
            '/workspace/work/file',
            '',
          ])) {
    throw StateError(
      'exec hook changed argv, path placeholders or JSON stdin: ${jsonEncode(direct)}',
    );
  }
  if (!denied.preventAction || denied.reason != 'source-guard') {
    throw StateError('actual source hook denial was lost');
  }
  final large = PluginHookOutput.parse(
    event: 'PreToolUse',
    exitCode: results[6]['exit_code'] as int?,
    stdout: results[6]['stdout'] as String,
    stderr: results[6]['stderr'] as String,
  );
  if (!large.preventAction ||
      large.additionalContext?.length != 70000 ||
      large.error != null ||
      results[7]['exit_code'] != 0 ||
      results[7]['stdout'] != '\u0000' * 120000) {
    throw StateError(
      'Large hook JSON verdict or escaped payload was truncated',
    );
  }
}

Future<void> verifyPluginHookCommands(
  CloudStore store,
  DockerCodeExecutionService executor,
  String tenant,
) async {
  const task = 'plugin-hook-command-protocol';
  store.put('task/$tenant/$task', {
    'status': 'running',
    'artifacts': [],
    'events': [],
  }, null);
  final result = await executor.execute(
    tenantId: tenant,
    taskId: task,
    code: hookCommandProbe(),
    language: 'javascript',
    profile: SandboxExecutionProfile.pluginHook,
    authorizedDomains: [],
    materials: [],
    skillFiles: {},
    cancellation: CancellationController().token,
  );
  checkHookCommandProbe(result);
  if ((store.get('task/$tenant/$task')!.value['artifacts'] as List)
      .isNotEmpty) {
    throw StateError('hook private protocol output became a deliverable');
  }
  const readOnlyTask = 'plugin-hook-read-only';
  store.put('task/$tenant/$readOnlyTask', {
    'status': 'running',
    'artifacts': [],
    'events': [],
  }, null);
  final source = {'source.txt': utf8.encode('original installed source')};
  final calculation = await executor.execute(
    tenantId: tenant,
    taskId: readOnlyTask,
    language: 'javascript',
    profile: SandboxExecutionProfile.pluginHookReadOnly,
    code: r'''
const fs = require('fs');
if (fs.readFileSync('/workspace/skill/source.txt','utf8') !== 'original installed source') throw Error('missing source');
fs.writeFileSync('/workspace/skill/source.txt','ephemeral changed source');
fs.writeFileSync('/workspace/output/should-not-persist.txt','ephemeral result');
console.log('read-only-hook-calculation-verified');
''',
    authorizedDomains: [],
    materials: [],
    skillFiles: source,
    cancellation: CancellationController().token,
  );
  final state = store.get('task/$tenant/$readOnlyTask')!.value;
  if (!calculation.contains('read-only-hook-calculation-verified') ||
      calculation.contains('should-not-persist') ||
      (state['artifacts'] as List).isNotEmpty ||
      state['sandbox_cleanup_pending'] != false ||
      utf8.decode(source['source.txt']!) != 'original installed source') {
    throw StateError(
      'Read-only hook persisted ephemeral writes or lost cleanup',
    );
  }
}
