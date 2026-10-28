import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/experimental.dart'
    show AgentFinishReason, AgentStreamChunk;
import 'package:genkit/experimental_client.dart' show AgentApi, remoteAgent;
import 'package:genkit/genkit.dart'
    show
        CancellationToken,
        Message,
        ModelResponseChunk,
        ReasoningPart,
        Role,
        TextPart,
        ToolRequest,
        ToolRequestPart,
        ToolResponsePart;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/api.dart';
import 'package:xiaoqi_genkit_server/src/release.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class _StreamingRuntime
    implements
        XiaoqiAgentRuntime,
        XiaoqiStreamingAgentRuntime,
        XiaoqiTaskNetworkController {
  _StreamingRuntime();

  bool interruptFirstTurn = false;
  var turnCount = 0;
  List<ToolRequestPart>? lastRestart;
  Map<String, dynamic>? lastRequest;
  Completer<void>? pauseBeforeReturn;
  Completer<void>? turnStarted;
  final disabledNetworkTasks = <String>[];
  final disabledNetworkRevisions = <int>[];
  Completer<void>? networkDisableStarted;
  Completer<void>? finishNetworkDisable;
  final preparationEvents = <Map<String, Object?>>[];
  bool failAfterPreparation = false;

  @override
  Future<void> disableTaskNetwork({
    required String tenantId,
    required String taskId,
    required int networkRevision,
  }) async {
    expect(tenantId, 'personal');
    disabledNetworkTasks.add(taskId);
    disabledNetworkRevisions.add(networkRevision);
    networkDisableStarted?.complete();
    await finishNetworkDisable?.future;
  }

  @override
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String text) onDelta,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
  }) => throw UnsupportedError('The Genkit route should call runAgentTurn.');

  @override
  Future<XiaoqiAgentTurnResult> runAgentTurn({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required List<Message> messages,
    List<ToolResponsePart>? respond,
    List<ToolRequestPart>? restart,
    required void Function(AgentStreamChunk chunk) onChunk,
    required void Function(Map<String, Object?> event) onProcessEvent,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
  }) async {
    cancellation.throwIfCancelled();
    turnCount++;
    lastRestart = restart;
    lastRequest = Map<String, dynamic>.from(request);

    if (interruptFirstTurn && restart == null) {
      final permissionRequest = ToolRequestPart(
        toolRequest: ToolRequest(
          ref: 'network-permission',
          name: 'request_network_permission',
          input: {
            'type': 'network_permission',
            'domains': ['example.com'],
            'purpose': 'Read public documentation',
          },
        ),
        metadata: {'interrupt': true},
      );
      onProcessEvent({
        'type': 'permission_required',
        'tool': 'request_network_permission',
      });
      onChunk(
        AgentStreamChunk(
          modelChunk: ModelResponseChunk(
            role: Role.model,
            content: [permissionRequest],
          ),
        ),
      );
      return XiaoqiAgentTurnResult(
        text: '',
        messages: [
          ...messages,
          Message(role: Role.model, content: [permissionRequest]),
        ],
        finishReason: AgentFinishReason.interrupted,
      );
    }

    for (final event in preparationEvents) {
      onProcessEvent(event);
    }
    if (failAfterPreparation) throw StateError('private-runtime-failure');
    onProcessEvent({'type': 'tool_started', 'tool': 'execute_python'});
    onChunk(
      AgentStreamChunk(
        modelChunk: ModelResponseChunk(
          role: Role.model,
          content: [ReasoningPart(reasoning: '先核对计算结果。')],
        ),
      ),
    );
    onProcessEvent({'type': 'tool_succeeded', 'tool': 'execute_python'});
    onProcessEvent({'type': 'answer_started'});
    onChunk(
      AgentStreamChunk(
        modelChunk: ModelResponseChunk(
          role: Role.model,
          content: [TextPart(text: '你好')],
        ),
      ),
    );
    turnStarted?.complete();
    await pauseBeforeReturn?.future;
    return XiaoqiAgentTurnResult(
      text: '你好',
      messages: [
        ...messages,
        Message(
          role: Role.model,
          content: [
            ReasoningPart(reasoning: '先核对计算结果。'),
            TextPart(text: '你好'),
          ],
        ),
      ],
    );
  }
}

void main() {
  late Directory directory;
  late CloudStore store;
  late HttpServer server;
  late _StreamingRuntime runtime;
  late AgentApi<Map<String, dynamic>> ownerAgent;
  late AgentApi<Map<String, dynamic>> otherTenantAgent;
  const ownerToken = 'streaming-owner-token';
  const otherTenantToken = 'streaming-other-tenant-token';

  void addDevice(String token, String tenantId, String deviceId) {
    store.put('device/${sha256.convert(utf8.encode(token))}', {
      'tenant_id': tenantId,
      'device_id': deviceId,
      'auth_method': 'email',
      'account_email': '$deviceId@example.com',
      'revoked_at': null,
    }, null);
  }

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('xiaoqi-remote-agent-');
    store = CloudStore(root: directory.path);
    runtime = _StreamingRuntime();
    addDevice(ownerToken, 'personal', 'owner-device');
    addDevice(otherTenantToken, 'other-tenant', 'other-device');
    final api = XiaoqiApi(store, runtime);
    server = await shelf_io.serve(api.handler, InternetAddress.loopbackIPv4, 0);
    ownerAgent = remoteAgent<Map<String, dynamic>>(
      url: 'http://127.0.0.1:${server.port}/v1/agent/chat',
      headers: () async => {
        'authorization': 'Bearer $ownerToken',
        'x-xiaoqi-contract': apiContractVersion,
      },
    );
    otherTenantAgent = remoteAgent<Map<String, dynamic>>(
      url: 'http://127.0.0.1:${server.port}/v1/agent/chat',
      headers: () async => {
        'authorization': 'Bearer $otherTenantToken',
        'x-xiaoqi-contract': apiContractVersion,
      },
    );
  });

  tearDown(() async {
    await ownerAgent.close();
    await otherTenantAgent.close();
    await server.close(force: true);
    store.close();
    directory.deleteSync(recursive: true);
  });

  Message userMessage(String text, String taskId) => Message(
    role: Role.user,
    content: [TextPart(text: text)],
    metadata: {
      'xiaoqi_agent_turn': {'task_id': taskId, 'model': 'test-model'},
    },
  );

  test(
    'ordinary followups preserve capabilities while removal and branches isolate scope',
    () async {
      Message scoped(
        String text,
        String task,
        String operation, {
        bool select = false,
      }) => Message(
        role: Role.user,
        content: [TextPart(text: text)],
        metadata: {
          'xiaoqi_agent_turn': {
            'task_id': task,
            'workflow_id': 'book',
            'capability_scope_operation': operation,
            'selected_capabilities': select
                ? [
                    {'id': 'notes', 'version_id': 'fixed-v1', 'type': 'plugin'},
                  ]
                : [],
            'selected_mcp_connections': select ? ['library'] : [],
          },
        },
      );
      final chat = ownerAgent.chat();
      final first = chat.sendStream(
        message: scoped('选能力', 'scope-first', 'replace', select: true),
      );
      await first.stream.drain<void>();
      final firstResult = await first.response;
      final followup = chat.sendStream(
        message: scoped('请用它整理', 'scope-next', 'inherit'),
      );
      await followup.stream.drain<void>();
      await followup.response;
      expect(runtime.lastRequest!['selected_capabilities'], [
        {'id': 'notes', 'version_id': 'fixed-v1', 'type': 'plugin'},
      ]);
      expect(runtime.lastRequest!['selected_mcp_connections'], ['library']);
      final clear = chat.sendStream(
        message: scoped('移除', 'scope-clear', 'clear'),
      );
      await clear.stream.drain<void>();
      await clear.response;
      expect(runtime.lastRequest!['selected_capabilities'], isEmpty);
      expect(
        runtime.lastRequest!['excluded_capability_ids'],
        contains('notes'),
      );
      final branch = ownerAgent.chat(snapshotId: firstResult.snapshotId);
      final branched = branch.sendStream(
        message: scoped('分支继续', 'scope-branch', 'inherit'),
      );
      await branched.stream.drain<void>();
      await branched.response;
      expect(runtime.lastRequest!['selected_mcp_connections'], ['library']);
    },
  );

  test(
    'updates one live status through MCP, skills, search and the final answer',
    () async {
      runtime.preparationEvents.addAll([
        {'type': 'mcp_connection_started', 'connection_name': '资料库'},
        {'type': 'mcp_tool_approval_required', 'connection_name': '资料库'},
        {
          'type': 'tool_started',
          'tool': 'MCP · 资料库 · lookup',
          'capability_name': '资料库',
        },
        {
          'type': 'tool_started',
          'tool': 'use_skill',
          'capability_name': '资料整理',
        },
        {'type': 'network_permission_required', 'tool': 'execute_skill_script'},
        {'type': 'tool_started', 'tool': 'web_search'},
        {'type': 'tool_succeeded', 'tool': 'web_search'},
        {'type': 'thinking_started'},
      ]);
      final turn = ownerAgent.chat().sendStream(
        message: userMessage('查找并整理资料', 'status-sequence'),
      );
      final titles = <String>[];
      await for (final chunk in turn.stream) {
        final state = chunk.custom;
        if (state != null) titles.add(state['current_step'] as String);
      }
      await turn.response;
      expect(
        titles,
        containsAllInOrder([
          '正在连接 MCP',
          '等待操作确认',
          '正在调用 MCP',
          '正在调用技能',
          '等待操作确认',
          '正在搜索',
          '正在思考',
          '正在执行代码',
          '正在生成回复',
        ]),
      );
    },
  );

  test(
    'streams public process updates without raw reasoning and isolates snapshots',
    () async {
      final chat = ownerAgent.chat();
      final turn = chat.sendStream(
        message: userMessage('请计算 1 + 1', 'stream-task-1'),
      );
      final body = StringBuffer();
      final reasoning = StringBuffer();
      var sawToolStart = false;
      var sawToolSuccess = false;
      var sawAnswerStart = false;
      final phases = <String>[];
      await for (final chunk in turn.stream) {
        body.write(chunk.text);
        reasoning.write(chunk.reasoning);
        final custom = chunk.custom;
        if (custom != null) {
          phases.add(custom['process_phase'] as String);
          if (custom['answer_started'] == true) sawAnswerStart = true;
          final events = (custom['agent_process'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          sawToolStart |= events.any(
            (event) => event['type'] == 'tool_started',
          );
          sawToolSuccess |= events.any(
            (event) => event['type'] == 'tool_succeeded',
          );
        }
      }
      final response = await turn.response;

      expect(body.toString(), '你好');
      expect(reasoning.toString(), isEmpty);
      expect(response.text, '你好');
      expect(response.sessionId, isNotEmpty);
      expect(response.snapshotId, isNotEmpty);
      expect(sawToolStart, isTrue);
      expect(sawToolSuccess, isTrue);
      expect(sawAnswerStart, isTrue);
      expect(phases, contains('executing'));
      expect(phases.last, 'answer');
      expect(
        await otherTenantAgent.getSnapshot(snapshotId: response.snapshotId),
        isNull,
      );

      final restored = await ownerAgent.loadChat(
        snapshotId: response.snapshotId,
      );
      expect(
        restored.messages
            .expand((message) => message.content)
            .where((part) => part.toJson().containsKey('reasoning')),
        isEmpty,
      );
      final nextTurn = restored.sendStream(
        message: userMessage('继续', 'stream-task-2'),
      );
      await nextTurn.stream.drain<void>();
      final nextResponse = await nextTurn.response;
      expect(nextResponse.text, '你好');
      expect(nextResponse.sessionId, response.sessionId);
      expect(nextResponse.snapshotId, isNot(response.snapshotId));
    },
  );

  test(
    'keeps the full public timeline and removes private event payloads',
    () async {
      for (var index = 0; index < 55; index++) {
        runtime.preparationEvents.addAll([
          {
            'type': 'tool_started',
            'tool': 'web_search',
            'script_path': '/workspace/private',
          },
          {
            'type': 'tool_succeeded',
            'tool': 'web_search',
            'source_count': 2,
            'result': 'private-result',
            'request': {'API_KEY': 'private-credential'},
          },
        ]);
      }
      runtime.preparationEvents.addAll([
        {
          'type': 'reasoning_update',
          'source': 'model_reasoning',
          'reasoning_id': 'call-1',
          'revision': 1,
          'status': 'completed',
          'text': '已找到原始采访，接下来核对成本案例。',
        },
        {
          'type': 'reasoning_update',
          'source': 'model_reasoning',
          'reasoning_id': 'call-2',
          'revision': 1,
          'status': 'completed',
          'text': 'API_KEY 是 VALUECHECK_999_XYZ。',
        },
      ]);
      final turn = ownerAgent.chat().sendStream(
        message: userMessage('查找资料', 'full-public-process'),
      );
      final observed = StringBuffer();
      await for (final chunk in turn.stream) {
        observed.write(jsonEncode(chunk.custom));
      }
      final response = await turn.response;
      final rows = (response.state!['agent_process'] as List)
          .whereType<Map>()
          .toList();
      expect(rows, hasLength(57));
      expect(rows.map((row) => row['step_id']).toSet(), hasLength(57));
      expect(
        rows.where((row) => row['kind'] == 'reasoning').single['text'],
        '已找到原始采访，接下来核对成本案例。',
      );
      expect(rows.every((row) => row['status'] == 'completed'), isTrue);
      expect(response.state!['process_status'], 'completed');
      expect(observed.toString(), isNot(contains('private-')));
      expect(observed.toString(), isNot(contains('VALUECHECK_999_XYZ')));
      final stored = store.get('task/personal/full-public-process')!.value;
      expect(jsonEncode(stored['events']), isNot(contains('/workspace')));
      expect(jsonEncode(stored['events']), isNot(contains('private-')));
    },
  );

  test(
    'failed turns settle pending tools before the stream reports failure',
    () async {
      runtime.failAfterPreparation = true;
      runtime.preparationEvents.add({
        'type': 'tool_started',
        'tool': 'web_search',
      });
      final turn = ownerAgent.chat().sendStream(
        message: userMessage('查找资料', 'failed-public-process'),
      );
      Map<String, dynamic>? finalState;
      await expectLater(() async {
        await for (final chunk in turn.stream) {
          if (chunk.custom != null) finalState = chunk.custom;
        }
        await turn.response;
      }(), throwsA(anything));
      expect(finalState!['process_status'], 'failed');
      final row = (finalState!['agent_process'] as List).single as Map;
      expect(row['status'], 'incomplete');
      expect(row['text'], isNot(startsWith('正在')));
      expect(jsonEncode(finalState), isNot(contains('private-')));
    },
  );

  test(
    'inherits turn metadata when an A2UI action message omits app metadata',
    () async {
      final chat = ownerAgent.chat();
      final first = chat.sendStream(
        message: userMessage('先展示一个选项', 'a2ui-metadata-task'),
      );
      await first.stream.drain<void>();
      final firstResponse = await first.response;

      final action = chat.sendStream(
        message: Message(
          role: Role.user,
          content: [TextPart(text: '用户点击了选项')],
        ),
      );
      await action.stream.drain<void>();
      final actionResponse = await action.response;

      expect(actionResponse.text, '你好');
      expect(actionResponse.sessionId, firstResponse.sessionId);
      expect(actionResponse.snapshotId, isNot(firstResponse.snapshotId));
    },
  );

  test(
    'preserves an explicit empty image turn instead of deriving a prompt',
    () async {
      final chat = ownerAgent.chat();
      final turn = chat.sendStream(
        message: Message(
          role: Role.user,
          content: [TextPart(text: '我选择了“创建图像”，请结合当前对话继续。')],
          metadata: {
            'xiaoqi_agent_turn': {
              'task_id': 'empty-image-contract-task',
              'capability': {'type': 'action', 'id': 'create-image'},
              'current_turn_text': '',
            },
          },
        ),
      );
      await turn.stream.drain<void>();
      await turn.response;

      expect(runtime.lastRequest?['current_turn_text'], '');
    },
  );

  test('surfaces a permission interrupt and resumes through Genkit', () async {
    // The API keeps this same runtime instance from setUp.
    runtime.interruptFirstTurn = true;
    final chat = ownerAgent.chat();
    final turn = chat.sendStream(
      message: userMessage('读取 example.com', 'permission-task'),
    );
    await turn.stream.drain<void>();
    final interrupted = await turn.response;
    expect(interrupted.finishReason, AgentFinishReason.interrupted);
    expect(interrupted.interrupts, hasLength(1));
    expect((interrupted.interrupts.single.input as Map)['domains'], [
      'example.com',
    ]);

    final resumed = chat.resumeStream(
      restart: [
        interrupted.interrupts.single.restart({
          'authorized_network_domains': ['example.com'],
        }),
      ],
    );
    await resumed.stream.drain<void>();
    expect((await resumed.response).text, '你好');
    expect(runtime.lastRestart, hasLength(1));
    expect(runtime.lastRestart!.single.metadata?['resumed'], {
      'authorized_network_domains': ['example.com'],
    });
  });

  test(
    'accepts ordered, idempotent steering while an agent task is running',
    () async {
      const taskId = 'steering-task';
      const messageId = 'steering-message-1';
      runtime.pauseBeforeReturn = Completer<void>();
      runtime.turnStarted = Completer<void>();
      final chat = ownerAgent.chat();
      final turn = chat.sendStream(message: userMessage('请整理这份资料', taskId));
      final streamDone = turn.stream.drain<void>();
      await runtime.turnStarted!.future;

      Future<(int, Map<String, dynamic>)> postInstruction(
        String content,
      ) async {
        final client = HttpClient();
        try {
          final request = await client.postUrl(
            Uri.parse(
              'http://127.0.0.1:${server.port}/v1/agent/tasks/$taskId/instructions',
            ),
          );
          request.headers
            ..contentType = ContentType.json
            ..set('x-xiaoqi-contract', apiContractVersion)
            ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken');
          request.write(
            jsonEncode({
              'message_id': messageId,
              'sequence': 1,
              'content': content,
            }),
          );
          final response = await request.close();
          final body =
              (jsonDecode(await utf8.decoder.bind(response).join()) as Map)
                  .cast<String, dynamic>();
          return (response.statusCode, body);
        } finally {
          client.close(force: true);
        }
      }

      final accepted = await postInstruction('只整理标题和要点');
      expect(accepted.$1, 200);
      expect(accepted.$2['status'], 'received');

      final duplicate = await postInstruction('只整理标题和要点');
      expect(duplicate.$1, 200);
      expect(duplicate.$2['duplicate'], isTrue);

      final conflictingDuplicate = await postInstruction('改成另一条内容');
      expect(conflictingDuplicate.$1, 409);

      runtime.pauseBeforeReturn!.complete();
      await streamDone;
      await turn.response;
    },
  );

  test('revokes running task network access when mode changes to off', () async {
    const taskId = 'network-mode-task';
    runtime.pauseBeforeReturn = Completer<void>();
    runtime.turnStarted = Completer<void>();
    final chat = ownerAgent.chat();
    final turn = chat.sendStream(message: userMessage('搜索这个主题', taskId));
    final streamDone = turn.stream.drain<void>();
    await runtime.turnStarted!.future;

    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/v1/agent/tasks/$taskId/network-mode',
        ),
      );
      request.headers
        ..contentType = ContentType.json
        ..set('x-xiaoqi-contract', apiContractVersion)
        ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken');
      request.write(jsonEncode({'mode': 'off'}));
      final response = await request.close();
      final body = (jsonDecode(await utf8.decoder.bind(response).join()) as Map)
          .cast<String, dynamic>();

      expect(response.statusCode, 200);
      expect(body['mode'], 'off');
      expect(body['network_revoked'], isTrue);
      expect(runtime.disabledNetworkTasks, [taskId]);
      expect(runtime.disabledNetworkRevisions, [1]);
      expect(store.get('task/personal/$taskId')!.value['network_mode'], 'off');
    } finally {
      client.close(force: true);
      runtime.pauseBeforeReturn!.complete();
      await streamDone;
      await turn.response;
    }
  });

  test('captures off revision before a concurrent on changes the task', () async {
    const taskId = 'network-mode-reordered';
    runtime.pauseBeforeReturn = Completer<void>();
    runtime.turnStarted = Completer<void>();
    runtime.networkDisableStarted = Completer<void>();
    runtime.finishNetworkDisable = Completer<void>();
    final turn = ownerAgent.chat().sendStream(
      message: userMessage('搜索', taskId),
    );
    final streamDone = turn.stream.drain<void>();
    await runtime.turnStarted!.future;
    final client = HttpClient();
    Future<int> setMode(String mode) async {
      final request = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/v1/agent/tasks/$taskId/network-mode',
        ),
      );
      request.headers
        ..contentType = ContentType.json
        ..set('x-xiaoqi-contract', apiContractVersion)
        ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken');
      request.write(jsonEncode({'mode': mode}));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    try {
      final off = setMode('off');
      await runtime.networkDisableStarted!.future;
      expect(await setMode('on'), 200);
      final task = store.get('task/personal/$taskId')!.value;
      expect(task['network_mode'], 'on');
      expect(task['network_policy_revision'], 2);
      expect(runtime.disabledNetworkRevisions, [1]);
      runtime.finishNetworkDisable!.complete();
      expect(await off, 200);
      expect(store.get('task/personal/$taskId')!.value['network_mode'], 'on');
    } finally {
      if (!runtime.finishNetworkDisable!.isCompleted)
        runtime.finishNetworkDisable!.complete();
      client.close(force: true);
      runtime.pauseBeforeReturn!.complete();
      await streamDone;
      await turn.response;
    }
  });

  test(
    'directs late steering to the next turn in the same conversation',
    () async {
      const taskId = 'completed-steering-task';
      final chat = ownerAgent.chat();
      final turn = chat.sendStream(message: userMessage('请总结这段资料', taskId));
      await turn.stream.drain<void>();
      final completed = await turn.response;
      expect(completed.text, '你好');

      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse(
            'http://127.0.0.1:${server.port}/v1/agent/tasks/$taskId/instructions',
          ),
        );
        request.headers
          ..contentType = ContentType.json
          ..set('x-xiaoqi-contract', apiContractVersion)
          ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken');
        request.write(
          jsonEncode({
            'message_id': 'late-steering-message',
            'sequence': 1,
            'content': '补充说明第二点',
          }),
        );
        final response = await request.close();
        final body =
            (jsonDecode(await utf8.decoder.bind(response).join()) as Map)
                .cast<String, dynamic>();

        expect(response.statusCode, 409);
        final error = body['error'];
        expect(error is Map ? error['message'] : error, contains('下一条消息发送'));
      } finally {
        client.close(force: true);
      }
    },
  );
}
