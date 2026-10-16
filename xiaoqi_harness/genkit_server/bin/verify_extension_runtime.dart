import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'package:shelf/shelf.dart';
import '../lib/src/agent_runtime.dart';
import '../lib/src/api.dart';
import '../lib/src/code_execution_service.dart';
import '../lib/src/image_service.dart';
import '../lib/src/release.dart';
import '../lib/src/store.dart';

/// Explicit smoke run, never loaded by the server. Uses an isolated temporary
/// store and the configured model/sandbox; does not modify a user's account.
Future<void> main(List<String> args) async {
  final ai = Genkit();
  final verify = ai.defineFlow(
    name: 'extensionRoundTrip',
    fn: (String input, _) async {
      final directory = await Directory.systemTemp.createTemp(
        'xiaoqi-extension-proof-',
      );
      final store = CloudStore(root: directory.path);
      final results = <Map<String, Object?>>[];
      try {
        final executor = DockerCodeExecutionService(store);
        final prepared = await executor.prepareDependencies('verification', {
          'requirements.txt': utf8.encode('packaging==24.2\n'),
          'package.json': utf8.encode('{"dependencies":{"is-number":"7.0.0"}}'),
        });
        final lock =
            jsonDecode(utf8.decode(prepared['.xiaoqi/dependency-lock.json']!))
                as Map;
        if ((lock['python'] as List).isEmpty || (lock['npm'] as Map).isEmpty) {
          throw StateError('Dependency locks missing');
        }
        store.put('task/verification/dependencies', {
          'status': 'running',
          'events': [],
          'artifacts': [],
          'network_mode': 'off',
        }, null);
        for (final check in [
          (
            'python',
            'import packaging; print("PYTHON_DEP=" + packaging.__version__)',
            'PYTHON_DEP=24.2',
          ),
          (
            'javascript',
            'console.log("NPM_DEP=" + require("is-number")(42))',
            'NPM_DEP=true',
          ),
          (
            'typescript',
            'const result: number = 6 * 7; console.log("TS_RESULT=" + result)',
            'TS_RESULT=42',
          ),
        ]) {
          final output = await executor.execute(
            tenantId: 'verification',
            taskId: 'dependencies',
            code: check.$2,
            language: check.$1,
            authorizedDomains: [],
            materials: [],
            skillFiles: prepared,
            cancellation: CancellationController().token,
          );
          if (!output.contains(check.$3))
            throw StateError('Dependency check failed: $output');
          results.add({'check': check.$1, 'output': output, 'verified': true});
          stdout.writeln('VERIFIED ${check.$1}: ${check.$3}');
        }
        final runtime = GenkitXiaoqiAgentRuntime(
          store,
          ImageService(store),
          codeExecutor: executor,
        );
        final api = XiaoqiApi(store, runtime);
        const proofToken = 'isolated-verification-only';
        store.put('device/${sha256.convert(utf8.encode(proofToken))}', {
          'tenant_id': 'verification',
          'device_id': 'proof',
          'auth_method': 'email',
          'account_email': 'proof@example.invalid',
          'revoked_at': null,
        }, null);
        Future<Map<String, dynamic>> call(
          String method,
          String path, [
          Object? body,
        ]) async {
          final response = await api.router.call(
            Request(
              method,
              Uri.parse('http://localhost$path'),
              headers: {
                'authorization': 'Bearer $proofToken',
                'x-xiaoqi-contract': apiContractVersion,
                'content-type': 'application/json',
              },
              body: body == null ? null : jsonEncode(body),
            ),
          );
          final result =
              jsonDecode(await response.readAsString()) as Map<String, dynamic>;
          if (response.statusCode >= 400)
            throw StateError('HTTP ${response.statusCode}: $result');
          return result;
        }

        Future<Map<String, dynamic>> operation(String path, Object body) async {
          final started = await call('POST', path, body);
          for (var poll = 0; poll < 180; poll++) {
            await Future<void>.delayed(const Duration(seconds: 2));
            final job = await call(
              'GET',
              '/v1/capabilities/import-jobs/${started['id']}',
            );
            if (job['status'] == 'completed') return job;
            if (job['status'] != 'running')
              throw StateError('Import operation: $job');
          }
          await call(
            'POST',
            '/v1/capabilities/import-jobs/${started['id']}/cancel',
          );
          throw StateError('Import operation timeout');
        }

        final samples = [
          (
            'https://github.com/anthropics/skills/tree/dbd4588f9e1033efb41dad4bef2f7947c8993d44/skills/brand-guidelines',
            '先调用选中技能的 use_skill，再根据技能原文报告 Anthropic 的主背景色和主文字颜色。不要联网搜索。',
            false,
          ),
          (
            'https://github.com/anthropics/claude-plugins-official/tree/8f814f49002ff824e8a9ba43cf96112dc7f5948d/plugins/frontend-design',
            '请先调用选中插件里的 use_skill，再给一个读书笔记页面提出三条视觉设计原则。不要写代码、不要联网。',
            false,
          ),
          (
            'https://github.com/anthropics/skills/tree/dbd4588f9e1033efb41dad4bef2f7947c8993d44/skills/webapp-testing',
            '先 use_skill；只使用已安装的 scripts/with_server.py（python），可以先 --help。然后 arguments 必须精确使用这个 JSON 数组：${jsonEncode(['--server', 'python3 -m http.server 8765 --bind 127.0.0.1', '--port', '8765', '--', 'python3', '-c', "import urllib.request; print('LOCAL_HTTP_STATUS=' + str(urllib.request.urlopen('http://127.0.0.1:8765').status))"])}。不要把 python3 和 -c 合并。执行本地服务生命周期验证，不运行浏览器或其他脚本，不需要外网权限。必须报告实际脚本输出。',
            true,
          ),
        ];
        for (var index = 0; index < samples.length; index++) {
          final sample = samples[index];
          final inspection =
              (await operation('/v1/capabilities/imports', {
                    'url': sample.$1,
                  }))['inspection']
                  as Map;
          final candidate = (inspection['candidates'] as List)
              .whereType<Map>()
              .where((c) => c['status'] != 'unsupported')
              .firstOrNull;
          if (candidate == null)
            throw StateError(
              'Sample unsupported: ${jsonEncode(inspection['candidates'])}',
            );
          final installed =
              (await operation('/v1/capabilities/install', {
                    'inspection_id': inspection['id'],
                    'candidate_id': candidate['id'],
                  }))['record']
                  as Map;
          final task = 'proof-$index';
          store.put('task/verification/$task', {
            'status': 'running',
            'events': [],
            'artifacts': [],
            'network_mode': 'off',
          }, null);
          final events = <Map<String, Object?>>[];
          final output = await runtime.runAgentTurn(
            tenantId: 'verification',
            taskId: task,
            request: {
              'selected_capabilities': [
                {
                  'id': installed['id'],
                  'version_id': installed['current_version_id'],
                },
              ],
              'network_mode': 'off',
              'model_id':
                  Platform.environment['XIAOQI_DEFAULT_TEXT_MODEL'] ??
                  'mimo-v2.6-flash',
              'materials': [],
            },
            messages: [
              Message(
                role: Role.user,
                content: [TextPart(text: sample.$2)],
              ),
            ],
            onChunk: (_) {},
            onProcessEvent: events.add,
            cancellation: CancellationController().token,
          );
          if (!events.any(
            (e) => e['tool'] == 'use_skill' && e['type'] == 'tool_succeeded',
          ))
            throw StateError('No real skill load for ${candidate['name']}');
          if (sample.$3 &&
              !events.any(
                (e) =>
                    e['tool'] == 'execute_skill_script' &&
                    e['type'] == 'tool_succeeded' &&
                    e['result'].toString().contains('LOCAL_HTTP_STATUS=200'),
              )) {
            throw StateError(
              'No verified script result: ${jsonEncode(events)}',
            );
          }
          results.add({
            'source': sample.$1,
            'commit': inspection['commit'],
            'kind': candidate['kind'],
            'name': candidate['name'],
            'tool_events': events,
            'answer': output.text,
            'verified': true,
          });
          stdout.writeln('VERIFIED ${candidate['kind']}: ${candidate['name']}');
        }
        return jsonEncode(results);
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
  if (args.contains('--run')) {
    final result = await verify('');
    stdout.writeln(jsonEncode(result));
  }
}
