import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart' show CancellationToken;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/api.dart';
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/release.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class _UnusedRuntime implements XiaoqiAgentRuntime {
  @override
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String) onDelta,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
  }) async => throw UnimplementedError();
}

void main() {
  late Directory root;
  late CloudStore store;
  late XiaoqiApi api;
  const token = 'upload-test-token';
  const content =
      '---\nname: upload-test\ndescription: Read supplied input\n---\nExplain the input.\n';
  setUp(() {
    root = Directory.systemTemp.createTempSync('xiaoqi-upload-api-');
    store = CloudStore(root: root.path);
    api = XiaoqiApi(store, _UnusedRuntime());
    store.put('device/${sha256.convert(utf8.encode(token))}', {
      'tenant_id': 'alice',
      'device_id': 'upload-test',
      'auth_method': 'email',
      'account_email': 'owner@example.com',
      'revoked_at': null,
    }, null);
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });
  Future<Response> call(
    String method,
    String path, {
    Object? body,
    bool auth = true,
  }) => api.router.call(
    Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {
        'x-xiaoqi-contract': apiContractVersion,
        if (auth) 'authorization': 'Bearer $token',
        if (body != null) 'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );
  Future<Map<String, dynamic>> finish(String id) async {
    for (var i = 0; i < 100; i++) {
      final response = await call('GET', '/v1/capabilities/import-jobs/$id');
      final result =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      if (result['status'] != 'running') return result;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('import job did not finish');
  }

  test(
    'existing plugin derives keywords from its immutable manifest',
    () async {
      store.putImmutable('tests/plugin-package.zip', {
        '.claude-plugin/plugin.json': utf8.encode(
          '{"keywords":["论文总结","论文总结"]}',
        ),
      });
      store.put('cap/alice/existing-plugin', {
        'id': 'existing-plugin',
        'kind': 'plugin',
        'origin': 'upload',
        'keywords': ['手动添加的词'],
        'keywords_edited': true,
        'current_version_id': 'v1',
        'versions': [
          {'id': 'v1', 'artifact_key': 'tests/plugin-package.zip'},
        ],
      }, null);
      final response = await call('GET', '/v1/capabilities');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect((body['items'] as List).single['keywords'], ['论文总结']);
      expect(
        (body['items'] as List).single.containsKey('keywords_edited'),
        isFalse,
      );
    },
  );

  test(
    'upload policy requires auth and returns actual admission limits',
    () async {
      expect(
        (await call(
          'GET',
          '/v1/capabilities/import-policy',
          auth: false,
        )).statusCode,
        401,
      );
      final response = await call('GET', '/v1/capabilities/import-policy');
      expect(response.statusCode, 200);
      final policy = jsonDecode(await response.readAsString());
      expect(
        policy['max_archive_bytes'],
        CapabilityImportService.maxArchiveBytes,
      );
      expect(
        policy['upload_extensions'],
        containsAll(['zip', 'skill', 'tgz', 'tar.gz', 'md']),
      );
    },
  );

  test(
    'upload inspection and install use real tenant-scoped jobs and reject sync bypass',
    () async {
      final accepted = await call(
        'POST',
        '/v1/capabilities/imports',
        body: {
          'file_name': 'SKILL.md',
          'archive_base64': base64Encode(utf8.encode(content)),
        },
      );
      expect(accepted.statusCode, 202);
      final job = await finish(jsonDecode(await accepted.readAsString())['id']);
      expect(job['status'], 'completed');
      final inspection = job['inspection'];
      expect(inspection['source_type'], 'upload');
      final startInstall = await call(
        'POST',
        '/v1/capabilities/install',
        body: {
          'inspection_id': inspection['id'],
          'candidate_id': inspection['candidates'][0]['id'],
        },
      );
      final installed = await finish(
        jsonDecode(await startInstall.readAsString())['id'],
      );
      expect(installed['status'], 'completed');
      final record = installed['record'];
      expect(record['origin'], 'upload');
      expect(record['source']['file_name'], 'SKILL.md');
      final blocked = await call(
        'POST',
        '/v1/capabilities/sync',
        body: {
          'record': {...record, 'origin': 'local'},
          'expected_revision': record['cloud_revision'],
        },
      );
      expect(blocked.statusCode, 400);
      expect(store.get('cap/alice/${record['id']}')!.value['origin'], 'upload');
    },
  );

  test('ambiguous sources and invalid Base64 do not create a job', () async {
    for (final body in [
      {
        'url': 'https://github.com/example/repo',
        'file_name': 'safe.zip',
        'archive_base64': 'YQ==',
      },
      {'file_name': 'safe.zip', 'archive_base64': 'invalid'},
      {'file_name': 'bad.exe', 'archive_base64': 'YQ=='},
    ]) {
      expect(
        (await call('POST', '/v1/capabilities/imports', body: body)).statusCode,
        400,
      );
    }
    expect(store.list('import-job/alice/'), isEmpty);
  });

  test(
    'cancelled accepted upload retires its inspection without an installation',
    () async {
      final response = await call(
        'POST',
        '/v1/capabilities/imports',
        body: {
          'file_name': 'SKILL.md',
          'archive_base64': base64Encode(utf8.encode(content)),
        },
      );
      final id = jsonDecode(await response.readAsString())['id'];
      expect(
        (await call(
          'POST',
          '/v1/capabilities/import-jobs/$id/cancel',
        )).statusCode,
        200,
      );
      final job = await finish(id);
      expect(job['status'], 'cancelled');
      expect(store.list('import/alice/'), isEmpty);
      expect(store.list('cap/alice/'), isEmpty);
    },
  );

  test(
    'draft MCP tests are authenticated and reject local endpoints without storing anything',
    () async {
      expect(
        (await call(
          'POST',
          '/v1/mcp/connection-tests',
          auth: false,
          body: {},
        )).statusCode,
        401,
      );
      final response = await call(
        'POST',
        '/v1/mcp/connection-tests',
        body: {
          'name': 'Unsafe',
          'url': 'https://127.0.0.1/mcp',
          'bearer_token': 'temporary',
        },
      );
      expect(response.statusCode, 400);
      expect(store.list('mcp/'), isEmpty);
      expect(await response.readAsString(), isNot(contains('temporary')));
    },
  );

  test('bounded JSON reader stops consuming an oversized stream', () async {
    var consumed = 0;
    Stream<List<int>> body() async* {
      consumed++;
      yield List<int>.filled(17 * 1024, 32);
      consumed++;
      yield [0];
    }

    final response = await api.router.call(
      Request(
        'POST',
        Uri.parse('http://localhost/v1/mcp/connection-tests'),
        headers: {
          'x-xiaoqi-contract': apiContractVersion,
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: body(),
      ),
    );
    expect(response.statusCode, 400);
    expect(consumed, 1);
  });
}
