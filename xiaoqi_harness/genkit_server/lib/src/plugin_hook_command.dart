import 'dart:convert';
import 'plugin_hooks.dart';
import 'plugin_hook_output.dart';

/// Produces code for the existing isolated code runner. Never execute this
/// program on the API host. The runner supplies its minimal environment,
/// immutable plugin copy, network policy, resource budget and cancellation.
class PluginHookCommand {
  static const resultKey = 'xiaoqi_hook_command_v1';

  static String? unsupported(PluginHook hook) {
    if (hook.type != 'command') return '不是 command hook';
    if (hook.config['async'] == true || hook.config['asyncRewake'] == true) {
      return '后台 hook 尚需独立生命周期映射';
    }
    if (hook.config['shell'] != null && hook.config['shell'] != 'bash') {
      return '当前隔离宿主提供 Bash';
    }
    if (hook.config['args'] != null || hook.config['if'] != null) {
      return '直接 argv 或条件命令尚需宿主映射';
    }
    if (hook.config['onFailure'] != null &&
        !const {'continue', 'block'}.contains(hook.config['onFailure'])) {
      return 'onFailure 需要 continue 或 block';
    }
    return null;
  }

  /// `shellExecutable` is host-owned, never part of a model/tool input. It is
  /// injectable only so the same launcher can be verified on a Windows host.
  static String program(
    PluginHook hook,
    Map<String, dynamic> input, {
    required String matchValue,
    String shellExecutable = '/bin/bash',
  }) {
    final issue = unsupported(hook);
    if (issue != null) throw StateError(issue);
    if (input['hook_event_name'] != hook.event) {
      throw StateError('hook 输入事件与来源声明不匹配');
    }
    // Encoding JSON twice makes ALL source/input bytes data, including shell
    // syntax, newlines, Unicode separators and JavaScript prototype key names.
    final payload = jsonEncode(
      jsonEncode({
        'command': hook.config['command'],
        'matcher': hook.matcher,
        'matchValue': matchValue,
        'input': input,
        'shell': shellExecutable,
        // Leave time for result collection within the normal 120s code budget.
        'timeoutMs': ((hook.config['timeout'] as num? ?? 600) * 1000)
            .clamp(1, 115000)
            .toInt(),
        'limit': PluginHookOutput.maxOutputBytes,
      }),
    );
    return 'const spec = JSON.parse($payload);\n$_launcher';
  }

  static Map<String, dynamic> result(String text) {
    final decoded = jsonDecode(text.trim());
    if (decoded is! Map || decoded[resultKey] is! Map) {
      throw const FormatException('隔离 hook 没有返回完整结果');
    }
    final result = Map<String, dynamic>.from(decoded[resultKey] as Map);
    if (result['matched'] is! bool ||
        result['timed_out'] is! bool ||
        result['stdout'] is! String ||
        result['stderr'] is! String ||
        (result['exit_code'] != null && result['exit_code'] is! int)) {
      throw const FormatException('隔离 hook 结果格式无效');
    }
    return result;
  }

  static const _launcher = r'''
const { Worker } = require('node:worker_threads');
const { spawn } = require('node:child_process');
const output = { matched: false, timed_out: false, exit_code: null, stdout: '', stderr: '' };
function emit() { process.stdout.write(JSON.stringify({ xiaoqi_hook_command_v1: output }) + '\n'); }
async function matches() {
  if (spec.matcher == null || spec.matcher === '' || spec.matcher === '*') return true;
  return await new Promise((resolve, reject) => {
    const worker = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads');
      try { parentPort.postMessage({match: new RegExp(workerData.pattern).test(workerData.value)}); }
      catch (_) { parentPort.postMessage({error: 'hook matcher 无效'}); }
    `, { eval: true, workerData: { pattern: spec.matcher, value: spec.matchValue } });
    let done = false;
    const settle = (error, value) => {
      if (done) return;
      done = true; clearTimeout(timer); worker.terminate();
      if (error) reject(new Error(error)); else resolve(value);
    };
    const timer = setTimeout(() => settle('hook matcher 超时'), 500);
    worker.on('message', m => settle(m.error, m.match));
    worker.on('error', () => settle('hook matcher 执行失败'));
    worker.on('exit', () => { if (!done) settle('hook matcher 未返回结果'); });
  });
}
(async () => {
  try {
    if (!await matches()) { emit(); return; }
    output.matched = true;
    await new Promise(resolve => {
      const child = spawn(spec.shell, ['-c', spec.command], {
        cwd: process.cwd(),
        env: { ...process.env, CLAUDE_PLUGIN_ROOT: '/workspace/skill', CLAUDE_PROJECT_DIR: '/workspace/work' },
        detached: process.platform !== 'win32', stdio: ['pipe', 'pipe', 'pipe']
      });
      let done = false, size = 0;
      const chunks = { stdout: [], stderr: [] };
      const kill = () => {
        try { if (process.platform !== 'win32' && child.pid) process.kill(-child.pid, 'SIGKILL'); else child.kill('SIGKILL'); } catch (_) {}
      };
      const finish = (code, error) => {
        if (done) return;
        done = true; clearTimeout(timer); kill();
        output.exit_code = code;
        output.stdout = Buffer.concat(chunks.stdout).toString('utf8');
        output.stderr = error || Buffer.concat(chunks.stderr).toString('utf8');
        resolve();
      };
      const timer = setTimeout(() => { output.timed_out = true; finish(null, 'hook 执行超时'); }, spec.timeoutMs);
      for (const name of ['stdout', 'stderr']) child[name].on('data', data => {
        size += data.length;
        if (size > spec.limit) { finish(null, 'hook 输出超过 128 KiB'); return; }
        if (!done) chunks[name].push(data);
      });
      child.on('error', () => finish(null, 'hook 命令无法启动'));
      child.on('close', code => finish(code));
      // Broken pipes are command failures, never exceptions that print an
      // incomplete envelope or bypass a declared onFailure:block policy.
      child.stdin.on('error', () => {});
      child.stdin.end(JSON.stringify(spec.input) + '\n');
    });
  } catch (error) { output.stderr = error.message; }
  emit();
})();
''';
}
