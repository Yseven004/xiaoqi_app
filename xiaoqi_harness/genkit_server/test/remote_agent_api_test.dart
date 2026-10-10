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
import 'package:xiaoqi_genkit_server/src/store.dart';

class _StreamingRuntime
    implements XiaoqiAgentRuntime, XiaoqiStreamingAgentRuntime {
  _StreamingRuntime();

  bool interruptFirstTurn = false;
  var turnCount = 0;
  List<ToolRequestPart>? lastRestart;

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

    onProcessEvent({'type': 'tool_started', 'tool': 'execute_python'});
    onChunk(
      AgentStreamChunk(
        modelChunk: ModelResponseChunk(
          role: Role.model,
          content: [
            ReasoningPart(reasoning: 'Check the calculation'),
            TextPart(text: '你'),
          ],
        ),
      ),
    );
    onChunk(
      AgentStreamChunk(
        modelChunk: ModelResponseChunk(
          role: Role.model,
          content: [TextPart(text: '好')],
        ),
      ),
    );
    onProcessEvent({'type': 'tool_succeeded', 'tool': 'execute_python'});
    return XiaoqiAgentTurnResult(
      text: '你好',
      messages: [
        ...messages,
        Message(
          role: Role.model,
          content: [
            ReasoningPart(reasoning: 'Check the calculation'),
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
      headers: () async => {'authorization': 'Bearer $ownerToken'},
    );
    otherTenantAgent = remoteAgent<Map<String, dynamic>>(
      url: 'http://127.0.0.1:${server.port}/v1/agent/chat',
      headers: () async => {'authorization': 'Bearer $otherTenantToken'},
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
    'streams text, model reasoning, process updates, and isolated snapshots',
    () async {
      final chat = ownerAgent.chat();
      final turn = chat.sendStream(
        message: userMessage('请计算 1 + 1', 'stream-task-1'),
      );
      final body = StringBuffer();
      final reasoning = StringBuffer();
      var sawToolStart = false;
      var sawToolSuccess = false;
      await for (final chunk in turn.stream) {
        body.write(chunk.text);
        reasoning.write(chunk.reasoning);
        final custom = chunk.custom;
        if (custom != null) {
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
      expect(reasoning.toString(), 'Check the calculation');
      expect(response.text, '你好');
      expect(response.sessionId, isNotEmpty);
      expect(response.snapshotId, isNotEmpty);
      expect(sawToolStart, isTrue);
      expect(sawToolSuccess, isTrue);
      expect(
        await otherTenantAgent.getSnapshot(snapshotId: response.snapshotId),
        isNull,
      );

      final restored = await ownerAgent.loadChat(
        snapshotId: response.snapshotId,
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
}
