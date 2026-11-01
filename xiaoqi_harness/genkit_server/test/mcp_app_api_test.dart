import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/api.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/mcp_app_surface.dart';
import 'package:xiaoqi_genkit_server/src/release.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

class _Runtime extends GenkitXiaoqiAgentRuntime {
  _Runtime(CloudStore store)
    : super(store, ImageService(store, apiKey: 'unused'));
  int calls = 0;
  Object? failure;
  Completer<void>? gate;
  void Function()? afterEffect;
  @override
  Future<XiaoqiAgentTurnResult> runMcpAppAction({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> surface,
    required String tool,
    required Map<String, dynamic> arguments,
    required String callId,
    Map<String, dynamic>? approval,
    required CancellationToken cancellation,
    required void Function(Map<String, Object?>) onProcessEvent,
  }) async {
    calls++;
    if (gate != null)
      await Future.any([gate!.future, cancellation.whenCancelled]);
    cancellation.throwIfCancelled();
    if (failure != null) throw failure!;
    afterEffect?.call();
    return XiaoqiAgentTurnResult(
      text: jsonEncode({
        'status': 'completed',
        'content': [
          {'type': 'text', 'text': 'verified result'},
        ],
      }),
      messages: [],
    );
  }
}

void main() {
  late Directory directory;
  late CloudStore store;
  late XiaoqiApi api;
  late _Runtime runtime;
  late String app;
  const token = 'fixture-owner';
  Future<Response> request(
    String method, {
    Map<String, dynamic>? body,
    String? otherToken,
    String suffix = '',
  }) async => api.handler(
    Request(
      method,
      Uri.parse('http://localhost/v1/agent/tasks/task/apps/$app$suffix'),
      headers: {
        'authorization': 'Bearer ${otherToken ?? token}',
        'x-xiaoqi-contract': apiContractVersion,
        'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );
  Map<String, dynamic> call(String id) => {
    'call_id': id,
    'tool_name': 'get-time',
    'arguments': <String, dynamic>{},
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('app-api-');
    store = CloudStore(root: directory.path);
    for (final owner in [token, 'other'])
      store.put('device/${sha256.convert(utf8.encode(owner))}', {
        'tenant_id': owner == token ? 'personal' : 'other',
        'device_id': owner,
        'auth_method': 'email',
        'account_email': 'fixture@example.com',
        'revoked_at': null,
      }, null);
    store.put('cap/personal/plugin', {
      'enabled': true,
      'versions': [
        {'id': 'v1', 'artifact_key': 'immutable'},
      ],
    }, null);
    store.put('task/personal/task', {
      'status': 'completed',
      'artifacts': [],
      'events': [],
    }, null);
    final execution = ToolExecution(
      store,
      'personal',
      'task',
      TurnContract(mode: 'workflow', imageLimit: 0),
      requestIdentity: 'original',
    )..bind();
    await McpAppSurfaceStore(store, 'personal', 'task').publish(
      execution: execution,
      connectionId: 'server',
      connectionBinding: 'binding',
      tool: {
        'name': 'get-time',
        '_meta': {
          'ui': {'resourceUri': 'ui://time/view'},
        },
      },
      input: {},
      result: {
        'content': [
          {'type': 'text', 'text': 'initial'},
        ],
      },
      selection: {},
      source: {
        'capability_id': 'plugin',
        'version_id': 'v1',
        'artifact_key': 'immutable',
      },
      check: () {},
      readResource: (uri) async => {
        'contents': [
          {'uri': uri, 'mimeType': McpAppMetadata.mime, 'text': '<p>time</p>'},
        ],
      },
    );
    app =
        store.list('private_mcp_apps/personal/task/').single.$2.value['id']
            as String;
    runtime = _Runtime(store);
    api = XiaoqiApi(store, runtime);
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });
  test(
    'surface ownership, original action identity and cached completion remain source bound',
    () async {
      expect((await request('GET')).statusCode, 200);
      expect(
        (await request('GET', otherToken: 'other')).statusCode,
        isNot(200),
      );
      expect((await request('POST', body: call('one'))).statusCode, 200);
      expect((await request('POST', body: call('one'))).statusCode, 200);
      expect(runtime.calls, 1);
      expect(
        (await request(
          'POST',
          body: {
            ...call('one'),
            'arguments': {'changed': true},
          },
        )).statusCode,
        409,
      );
      final cap = store.get('cap/personal/plugin')!;
      store.put('cap/personal/plugin', {
        ...cap.value,
        'enabled': false,
      }, cap.revision);
      expect((await request('POST', body: call('one'))).statusCode, 409);
      expect(runtime.calls, 1);
    },
  );
  test(
    'concurrent calls cannot replace the owned controller; closing cancels only its original call',
    () async {
      runtime.gate = Completer<void>();
      final running = request('POST', body: call('one'));
      for (var i = 0; runtime.calls == 0 && i < 100; i++)
        await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(runtime.calls, 1);
      expect((await request('POST', body: call('two'))).statusCode, 409);
      expect(
        (await request(
          'POST',
          suffix: '/cancel',
          body: {'call_id': 'one'},
        )).statusCode,
        200,
      );
      expect((await running).statusCode, 409);
      final opened =
          jsonDecode(await (await request('GET')).readAsString()) as Map;
      expect(opened['pending_call']['call_id'], 'one');
      expect(store.get('task/personal/task')!.value['status'], 'completed');
    },
  );
  test(
    'unknown result blocks a fresh identity but permits original-request recovery',
    () async {
      runtime.failure = StateError('private diagnostic must not leave server');
      final first = await request('POST', body: call('one'));
      expect(first.statusCode, 409);
      expect(await first.readAsString(), isNot(contains('private diagnostic')));
      expect((await request('POST', body: call('two'))).statusCode, 409);
      expect(runtime.calls, 1);
      runtime.failure = null;
      expect((await request('POST', body: call('one'))).statusCode, 200);
      expect(runtime.calls, 2);
    },
  );
  test(
    'withdrawal after effect preserves known outcome without delivering new data or replaying',
    () async {
      runtime.afterEffect = () {
        final cap = store.get('cap/personal/plugin')!;
        store.put('cap/personal/plugin', {
          ...cap.value,
          'enabled': false,
        }, cap.revision);
      };
      expect((await request('POST', body: call('one'))).statusCode, 409);
      expect(
        store
            .list('private_mcp_app_calls/personal/task/$app/')
            .single
            .$2
            .value['phase'],
        'completed',
      );
      final cap = store.get('cap/personal/plugin')!;
      store.put('cap/personal/plugin', {
        ...cap.value,
        'enabled': true,
      }, cap.revision);
      expect((await request('POST', body: call('one'))).statusCode, 200);
      expect(runtime.calls, 1);
    },
  );
}
