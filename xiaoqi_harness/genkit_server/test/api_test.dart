import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart' show CancellationToken;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/api.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/release.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class _FakeRuntime implements XiaoqiAgentRuntime {
  void Function(String tenantId, String taskId)? beforeReturn;
  bool emitImageGenerationStarted = false;

  @override
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String) onDelta,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
  }) async {
    cancellation.throwIfCancelled();
    onDelta('你好');
    if (emitImageGenerationStarted) onImageGenerationStarted?.call();
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
    void Function()? onImageGenerationStarted,
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

class _FailingRuntime implements XiaoqiAgentRuntime {
  _FailingRuntime(this.error);

  final Object error;

  @override
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String) onDelta,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
  }) async {
    throw error;
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
        'x-xiaoqi-contract': apiContractVersion,
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

  test(
    'MCP catalog is authenticated and returns only configured entries',
    () async {
      final unauthenticated = await call('GET', '/v1/mcp/catalog', auth: false);
      expect(unauthenticated.statusCode, 401);

      final response = await call('GET', '/v1/mcp/catalog');
      expect(response.statusCode, 200);
      expect(jsonDecode(await response.readAsString())['items'], isA<List>());
    },
  );

  test(
    'rejects missing contract and reports both versions before normal API use',
    () async {
      final response = await api.router.call(
        Request(
          'GET',
          Uri.parse('http://localhost/v1/capabilities'),
          headers: {'authorization': 'Bearer $token'},
        ),
      );
      expect(response.statusCode, 426);
      expect(await response.readAsString(), contains('接口版本'));
      final health = await call('GET', '/health');
      expect(
        jsonDecode(await health.readAsString())['api_contract_version'],
        apiContractVersion,
      );
    },
  );

  test('import job and inspection lookups are tenant-scoped', () async {
    store.put('import-job/other/private', {'status': 'completed'}, null);
    final response = await call('GET', '/v1/capabilities/import-jobs/private');
    expect(response.statusCode, 404);
    expect(
      (await call(
        'POST',
        '/v1/capabilities/import-jobs/private/cancel',
      )).statusCode,
      404,
    );
  });

  test(
    'capability switches reject nonboolean values before mutation',
    () async {
      for (final field in ['enabled', 'show_in_menu']) {
        final response = await call(
          'PATCH',
          '/v1/capabilities/example/visibility',
          body: {field: 'false', 'expected_revision': 1},
        );
        expect(response.statusCode, 400);
        expect(store.get('cap/personal/example'), isNull);
      }
    },
  );

  test('defaults new and legacy auto agent tasks to network off', () async {
    Future<void> createTask(String taskId, {String? networkMode}) async {
      final body = <String, Object?>{
        'task_id': taskId,
        'messages': [
          {'role': 'user', 'content': '你好'},
        ],
        'model_id': 'deepseek-flash',
        'reasoning_level': 'medium',
        'materials': [],
        if (networkMode != null) 'network_mode': networkMode,
      };
      final response = await call('POST', '/v1/agent/tasks', body: body);
      expect(response.statusCode, 202);
      expect(store.get('task/personal/$taskId')!.value['network_mode'], 'off');
    }

    await createTask('task-network-default');
    await createTask('task-network-legacy', networkMode: 'auto');
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
        if (events['status'] == 'succeeded') break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(events['status'], 'succeeded');
      final taskResponse = await call('GET', '/v1/agent/tasks/task-test');
      final task = jsonDecode(await taskResponse.readAsString()) as Map;
      expect(task['status'], 'succeeded');
      final entries = events['events'] as List;
      expect(
        entries.map((event) => event['type']),
        containsAll(['assistant_delta', 'completed']),
      );
    },
  );

  test('returns generated artifacts in the completed task event', () async {
    runtime.emitImageGenerationStarted = true;
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
      if (events['status'] == 'succeeded') break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final completed = (events['events'] as List).cast<Map>().firstWhere(
      (event) => event['type'] == 'completed',
    );
    expect(
      (events['events'] as List).cast<Map>().map((event) => event['type']),
      contains('image_generation_started'),
    );
    final artifact = (completed['artifacts'] as List).single as Map;
    expect(artifact['id'], 'image-1');
    expect(artifact.containsKey('object_key'), isFalse);
  });

  test(
    'keeps text and marks an image-only miss as partially completed',
    () async {
      runtime.emitImageGenerationStarted = true;
      runtime.beforeReturn = (tenantId, taskId) {
        final key = 'task/$tenantId/$taskId';
        final task = store.get(key)!;
        store.put(key, {
          ...task.value,
          'turn_scope': {'mode': 'create', 'image_limit': 1},
        }, task.revision);
      };
      await call(
        'POST',
        '/v1/agent/tasks',
        body: {
          'task_id': 'task-image-partial',
          'messages': [
            {'role': 'user', 'content': '生成一张图片'},
          ],
          'model_id': 'deepseek-flash',
          'reasoning_level': 'medium',
          'materials': [],
        },
      );

      Map<String, dynamic> task = {};
      for (var i = 0; i < 40; i++) {
        final response = await call(
          'GET',
          '/v1/agent/tasks/task-image-partial',
        );
        task = Map<String, dynamic>.from(
          jsonDecode(await response.readAsString()) as Map,
        );
        if (task['status'] == 'partially_completed') break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(task['status'], 'partially_completed');
      expect(task['partial_reason'], 'requested_image_missing');
      expect(task['result'], contains('你好'));
      expect(task['result'], contains('图片未生成'));
    },
  );

  test(
    'explains Ark overdue balance for an automatically called image tool',
    () async {
      api = XiaoqiApi(
        store,
        _FailingRuntime(
          HttpException(
            'AgentError(INTERNAL): tool "generate_image" failed: '
            'HttpException: 生图服务返回错误 (403): The request failed because '
            'your account has an overdue balance. Request id: test-request-id',
          ),
        ),
      );
      await call(
        'POST',
        '/v1/agent/tasks',
        body: {
          'task_id': 'task-image-overdue',
          'messages': [
            {'role': 'user', 'content': '生成一张动漫风景图'},
          ],
          'model_id': 'deepseek-flash',
          'reasoning_level': 'medium',
          'materials': [],
        },
      );

      Map<String, dynamic> task = {};
      for (var i = 0; i < 40; i++) {
        final response = await call(
          'GET',
          '/v1/agent/tasks/task-image-overdue',
        );
        task = Map<String, dynamic>.from(
          jsonDecode(await response.readAsString()) as Map,
        );
        if (task['status'] == 'failed') break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(task['status'], 'failed');
      expect(task['error_code'], 'ark_account_overdue');
      expect(task['error'], contains('欠款'));
      expect(task['error'], contains('Seedream'));
    },
  );

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
    expect(events['status'], 'succeeded');
    expect(networkRuntime.authorizedDomains, ['example.com']);
  });
}
