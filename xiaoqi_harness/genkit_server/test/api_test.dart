import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart' show CancellationToken;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/api.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class _FakeRuntime implements XiaoqiAgentRuntime {
  void Function(String tenantId, String taskId)? beforeReturn;

  @override
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String) onDelta,
    required CancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    onDelta('你好');
    beforeReturn?.call(tenantId, taskId);
    return '你好';
  }
}

class _NetworkRuntime implements XiaoqiAgentRuntime {
  _NetworkRuntime(this.store);

  final CloudStore store;
  var requested = false;
  List<String> authorizedDomains = const [];

  @override
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String) onDelta,
    required CancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    if (!requested) {
      requested = true;
      throw const NetworkPermissionRequired(['example.com'], '读取公开资料');
    }
    authorizedDomains =
        (store
                    .get('task/$tenantId/$taskId')!
                    .value['authorized_network_domains']
                as List)
            .cast<String>();
    onDelta('读取完成');
    return '读取完成';
  }
}

void main() {
  late Directory directory;
  late CloudStore store;
  late XiaoqiApi api;
  late _FakeRuntime runtime;
  late String token;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('xiaoqi-api-test-');
    store = CloudStore(root: directory.path);
    runtime = _FakeRuntime();
    api = XiaoqiApi(store, runtime);
    token = 'test-owner-token';
    store.put('device/${sha256.convert(utf8.encode(token))}', {
      'tenant_id': 'personal',
      'device_id': 'device-test',
      'auth_method': 'email',
      'account_email': 'owner@example.com',
      'revoked_at': null,
    }, null);
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
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
        if (auth) 'authorization': 'Bearer $token',
        if (body != null) 'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );

  test('requires owner device authentication', () async {
    final response = await call('GET', '/v1/capabilities', auth: false);
    expect(response.statusCode, 401);
  });

  test('requires owner device authentication for chat completions', () async {
    final response = await call(
      'POST',
      '/v1/chat/completions',
      body: {
        'messages': [
          {'role': 'user', 'content': 'hello'},
        ],
      },
      auth: false,
    );
    expect(response.statusCode, 401);
  });

  test(
    'preserves draft conflict behavior and task event stream format',
    () async {
      final saved = await call(
        'PUT',
        '/v1/drafts',
        body: {
          'draft': {'id': 'draft-1', 'content': 'hello'},
        },
      );
      expect(saved.statusCode, 200);
      final savedJson = jsonDecode(await saved.readAsString()) as Map;
      expect(savedJson['cloud_revision'], 1);

      final conflict = await call(
        'PUT',
        '/v1/drafts',
        body: {
          'draft': {'id': 'draft-1', 'content': 'stale'},
          'expected_revision': 4,
        },
      );
      expect(conflict.statusCode, 409);

      final created = await call(
        'POST',
        '/v1/agent/tasks',
        body: {
          'task_id': 'task-test',
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
          'model_id': 'deepseek-flash',
          'reasoning_level': 'medium',
          'materials': [],
        },
      );
      expect(created.statusCode, 202);
      Map events = {};
      for (var i = 0; i < 40; i++) {
        final response = await call(
          'GET',
          '/v1/agent/tasks/task-test/events?after=-1',
        );
        events = jsonDecode(await response.readAsString()) as Map;
        if (events['status'] == 'completed') break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(events['status'], 'completed');
      final entries = events['events'] as List;
      expect(
        entries.map((event) => event['type']),
        containsAll(['assistant_delta', 'completed']),
      );
    },
  );

  test('returns generated artifacts in the completed task event', () async {
    runtime.beforeReturn = (tenantId, taskId) {
      final key = 'task/$tenantId/$taskId';
      final current = store.get(key)!;
      store.put(key, {
        ...current.value,
        'artifacts': [
          {
            'id': 'image-1',
            'name': 'result.png',
            'media_type': 'image/png',
            'size': 3,
            'sha256': 'a' * 64,
            'object_key': 'private/path',
          },
        ],
      }, current.revision);
    };
    await call(
      'POST',
      '/v1/agent/tasks',
      body: {
        'task_id': 'task-image',
        'messages': [
          {'role': 'user', 'content': '生成一张图片'},
        ],
        'model_id': 'deepseek-flash',
        'reasoning_level': 'medium',
        'materials': [],
      },
    );

    Map events = {};
    for (var i = 0; i < 40; i++) {
      final response = await call(
        'GET',
        '/v1/agent/tasks/task-image/events?after=-1',
      );
      events = jsonDecode(await response.readAsString()) as Map;
      if (events['status'] == 'completed') break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final completed = (events['events'] as List).cast<Map>().firstWhere(
      (event) => event['type'] == 'completed',
    );
    final artifact = (completed['artifacts'] as List).single as Map;
    expect(artifact['id'], 'image-1');
    expect(artifact.containsKey('object_key'), isFalse);
  });

  test('resumes a task after the requested domain is authorized', () async {
    final networkRuntime = _NetworkRuntime(store);
    api = XiaoqiApi(store, networkRuntime);
    final created = await call(
      'POST',
      '/v1/agent/tasks',
      body: {
        'task_id': 'task-network',
        'messages': [
          {'role': 'user', 'content': '查找资料'},
        ],
        'model_id': 'deepseek-flash',
        'reasoning_level': 'medium',
        'materials': [],
      },
    );
    expect(created.statusCode, 202);

    Map events = {};
    for (var i = 0; i < 40; i++) {
      final response = await call(
        'GET',
        '/v1/agent/tasks/task-network/events?after=-1',
      );
      events = jsonDecode(await response.readAsString()) as Map;
      if (events['status'] == 'awaiting_network_permission') break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(events['status'], 'awaiting_network_permission');
    expect(
      (events['events'] as List).map((event) => event['type']),
      contains('network_permission_required'),
    );

    final authorized = await call(
      'POST',
      '/v1/agent/tasks/task-network/authorize-network',
      body: {
        'domains': ['example.com'],
      },
    );
    expect(authorized.statusCode, 200);

    for (var i = 0; i < 40; i++) {
      final response = await call(
        'GET',
        '/v1/agent/tasks/task-network/events?after=-1',
      );
      events = jsonDecode(await response.readAsString()) as Map;
      if (events['status'] == 'completed') break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(events['status'], 'completed');
    expect(networkRuntime.authorizedDomains, ['example.com']);
  });
}
