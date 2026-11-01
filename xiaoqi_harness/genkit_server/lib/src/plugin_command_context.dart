import 'dart:convert';
import 'package:genkit/genkit.dart';
import 'code_execution_service.dart';
import 'tool_execution.dart';

class PluginCommandContextFailure implements Exception {
  PluginCommandContextFailure(this.message);
  final String message;
}

/// Source commands execute only in the isolated runner, never on the API host.
class PluginCommandContext {
  static const maxOutputBytes = 128 * 1024;
  static const resultKey = 'xiaoqi_command_context_v1';

  static Future<List<String>> expand({
    required DockerCodeExecutionService executor,
    required ToolExecution execution,
    required String sourceBinding,
    required String invocation,
    required List<String> commands,
    required String arguments,
    required List<String> argv,
    required Map<String, List<int>> Function() sourceFiles,
    required CancellationToken cancellation,
    required List<Map<String, dynamic>> materials,
    bool readOnly = false,
  }) async {
    void validateSource() {
      cancellation.throwIfCancelled();
      if (!execution.contract.executesWorkflow) {
        throw StateError('回答阶段不执行动态命令上下文');
      }
      sourceFiles();
    }

    void check() {
      execution.check('workspace');
      validateSource();
    }

    check();
    if (sourceBinding.isEmpty || invocation.isEmpty) {
      throw StateError('动态命令缺少原始来源或调用身份');
    }
    final code = program(commands, arguments, argv);
    final result = await ToolExecution.withAuthorityCheck(
      validateSource,
      () => execution.authorizedCode(
        slot: 'command-context:$sourceBinding:$invocation',
        arguments: {
          'source': sourceBinding,
          'commands': commands,
          'arguments': arguments,
          'argv': argv,
          'read_only': readOnly,
        },
        effectsPossible: (error) => error is SandboxExecutionError,
        invoke: (operationId) async => {
          'ok': true,
          'output': await executor.execute(
            tenantId: execution.tenantId,
            taskId: execution.taskId,
            code: code,
            language: 'javascript',
            authorizedDomains: const [],
            materials: materials,
            skillFiles: sourceFiles(),
            cancellation: cancellation,
            profile: readOnly
                ? SandboxExecutionProfile.pluginCommandContextReadOnly
                : SandboxExecutionProfile.pluginCommandContext,
            scopeOperationId: operationId,
            beforeSubmit: check,
          ),
        },
      ),
    );
    check();
    return outputs(
      (result['output'] as String).split('\n').first,
      commands.length,
    );
  }

  static String program(
    List<String> commands,
    String arguments,
    List<String> argv, {
    String shellExecutable = '/bin/bash',
  }) {
    if (commands.isEmpty ||
        commands.length > 16 ||
        commands.any((command) => command.trim().isEmpty)) {
      throw const FormatException('动态命令需要 1–16 个非空上下文命令');
    }
    final payload = jsonEncode(
      jsonEncode({
        'commands': commands,
        'arguments': arguments,
        'argv': argv,
        'shell': shellExecutable,
        'limit': maxOutputBytes,
      }),
    );
    final program = 'const spec = JSON.parse($payload);\n$_launcher';
    if (utf8.encode(program).length > 64 * 1024) {
      throw const FormatException('动态命令启动器超过 64 KiB');
    }
    return program;
  }

  static List<String> outputs(String text, int count) {
    if (utf8.encode(text).length > 1024 * 1024) {
      throw const FormatException('动态命令协议结果过大');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded[resultKey] is! Map) {
      throw const FormatException('动态命令没有返回完整协议结果');
    }
    final result = decoded[resultKey] as Map;
    if (result['ok'] != true) {
      throw PluginCommandContextFailure(
        result['error'] is String
            ? result['error'] as String
            : '动态命令执行失败，不能把未展开内容交给 Agent',
      );
    }
    final values = result['outputs'];
    if (values is! List ||
        values.length != count ||
        values.any((value) => value is! String) ||
        values.cast<String>().fold<int>(
              0,
              (size, value) => size + utf8.encode(value).length,
            ) >
            maxOutputBytes) {
      throw const FormatException('动态命令结果数量、类型或容量无效');
    }
    return values.cast<String>();
  }

  static const _launcher = r'''
const { spawnSync } = require('node:child_process');
const outputs = [];
let size = 0;
const deadline = Date.now() + 110000;
let result;
try {
  for (const command of spec.commands) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error('动态命令执行超时');
    const child = spawnSync(spec.shell, ['-c', command, 'plugin-command', ...spec.argv], {
      cwd: process.cwd(), encoding: 'utf8', timeout: remaining,
      maxBuffer: spec.limit, killSignal: 'SIGKILL',
      detached: process.platform !== 'win32',
      env: { ...process.env, ARGUMENTS: spec.arguments,
        CLAUDE_PLUGIN_ROOT: '/workspace/skill', CODEX_PLUGIN_ROOT: '/workspace/skill',
        CLAUDE_PROJECT_DIR: '/workspace/work', PYTHONIOENCODING: 'utf-8', PYTHONUTF8: '1' }
    });
    if (process.platform !== 'win32' && child.pid) {
      try { process.kill(-child.pid, 'SIGKILL'); } catch (_) {}
    }
    if (child.error || child.signal || child.status !== 0) {
      throw new Error(child.error ? '动态命令超时、输出过大或无法启动'
        : '动态命令失败（exit ' + child.status + '）：' + (child.stderr || '').slice(-4096));
    }
    size += Buffer.byteLength(child.stdout, 'utf8');
    if (size > spec.limit) throw new Error('动态命令总输出超过 128 KiB');
    outputs.push(child.stdout);
  }
  result = { ok: true, outputs };
} catch (error) {
  result = { ok: false, error: error.message };
}
process.stdout.write(JSON.stringify({ xiaoqi_command_context_v1: result }) + '\n');
''';
}
