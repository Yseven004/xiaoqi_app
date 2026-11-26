import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/experimental.dart'
    show AgentFinishReason, AgentStreamChunk, Artifact;
import 'package:genkit/experimental_client.dart' show AgentApi, remoteAgent;
import 'package:genkit/genkit.dart'
    show
        CancellationToken,
        Message,
        ModelResponseChunk,
        PartExtension,
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
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

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
  List<Message>? lastMessages;
  Completer<void>? pauseBeforeReturn;
  Completer<void>? turnStarted;
  final disabledNetworkTasks = <String>[];
  final disabledNetworkRevisions = <int>[];
  Completer<void>? networkDisableStarted;
  Completer<void>? finishNetworkDisable;
  final preparationEvents = <Map<String, Object?>>[];
  bool failAfterPreparation = false;
  bool waitForCancellation = false;
  bool waitForUser = false;
  CloudStore? effectStore;
  int imageSubmissions = 0;

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
    bool continueAbortedTurn = false,
    required void Function(AgentStreamChunk chunk) onChunk,
    required void Function(Map<String, Object?> event) onProcessEvent,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
  }) async {
    cancellation.throwIfCancelled();
    turnCount++;
    lastRestart = restart;
    lastRequest = Map<String, dynamic>.from(request);
    lastMessages = List<Message>.of(messages);
    if (effectStore != null) {
      final execution = ToolExecution(
        effectStore!,
        tenantId,
        taskId,
        TurnContract(mode: 'workflow', imageLimit: 0),
        requestIdentity: 'pause-question',
      )..bind();
      await execution.authorizedExternal(
        slot: '1',
        arguments: {'prompt': 'same illustration'},
        invoke: (_) async {
          imageSubmissions++;
          return {'artifact_id': 'original-image'};
        },
      );
    }

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
    if (waitForUser) {
      const question = '请确认是否继续处理这份材料。';
      onChunk(
        AgentStreamChunk(
          modelChunk: ModelResponseChunk(
            role: Role.model,
            content: [TextPart(text: question)],
          ),
        ),
      );
      turnStarted?.complete();
      return XiaoqiAgentTurnResult(
        text: question,
        messages: [
          ...messages,
          Message(
            role: Role.model,
            content: [TextPart(text: question)],
          ),
        ],
        waitingForUser: true,
        pendingQuestion: question,
      );
    }
    onChunk(
      AgentStreamChunk(
        modelChunk: ModelResponseChunk(
          role: Role.model,
          content: [TextPart(text: '你好')],
        ),
      ),
    );
    turnStarted?.complete();
    if (waitForCancellation) {
      await cancellation.whenCancelled;
      cancellation.throwIfCancelled();
    }
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
  late XiaoqiApi api;
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
    api = XiaoqiApi(store, runtime);
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
    await api.close();
    store.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'book revocation invalidates outstanding uploads before the first POST',
    () async {
      const header = 'x-xiaoqi-reading-authorization';
      final book = 'a' * 64;
      final bytes = utf8.encode('%PDF-1.4\n%%EOF\n');
      final version = sha256.convert(bytes).toString();
      final uri = Uri.parse(
        'http://127.0.0.1:${server.port}/v1/reading-books/$book/$version',
      );
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      Future<HttpClientResponse> send(
        String method, {
        String token = ownerToken,
        String? authorization,
        String binding = 'reading-review-device',
        String path = '',
        List<int>? original,
        Map<String, Object>? body,
      }) async {
        final request = await http.openUrl(method, Uri.parse('$uri$path'));
        request.headers
          ..set('authorization', 'Bearer $token')
          ..set('x-xiaoqi-contract', apiContractVersion)
          ..set('x-xiaoqi-reading-binding', binding);
        if (authorization != null) request.headers.set(header, authorization);
        if (original != null) {
          request.headers
            ..contentType = ContentType('application', 'pdf')
            ..set('x-xiaoqi-filename', 'fixture.pdf')
            ..set('x-xiaoqi-attachment-profile', 'reading-book-markitdown-v1');
          request.add(original);
        }
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        await response.drain<void>();
        return response;
      }

      final first = await send('GET');
      expect(first.statusCode, 404);
      final before = first.headers.value(header);
      expect(before, isNotNull);
      expect((await send('DELETE')).statusCode, 200);
      final second = await send('GET');
      expect(second.statusCode, 404);
      final after = second.headers.value(header);
      expect(after, isNotNull);
      expect(after, isNot(before));
      expect((await send('POST', authorization: before)).statusCode, 409);
      expect((await send('POST')).statusCode, 409);
      expect((await send('POST', authorization: after)).statusCode, 400);
      expect(
        (await send('PUT', authorization: before, path: '/binding')).statusCode,
        409,
      );
      expect(
        (await send('PUT', authorization: after, path: '/binding')).statusCode,
        404,
      );
      expect(
        (await send('GET', binding: 'other-device')).headers.value(header),
        before,
      );
      expect(
        (await send('GET', token: otherTenantToken)).headers.value(header),
        before,
      );

      expect(
        (await send('POST', authorization: after, original: bytes)).statusCode,
        202,
      );
      final firstBinding = await send('GET');
      expect(firstBinding.statusCode, 200);
      expect(
        firstBinding.headers.value('x-xiaoqi-reading-binding-active'),
        'true',
      );
      final secondBinding = await send('GET', binding: 'other-device');
      expect(secondBinding.statusCode, 200);
      expect(
        secondBinding.headers.value('x-xiaoqi-reading-binding-active'),
        'false',
      );
      const target = {'instance': 'reader', 'sequence': 1, 'page': 3};
      expect(
        (await send(
          'PUT',
          binding: 'other-device',
          path: '/target',
          body: target,
        )).statusCode,
        403,
      );
      expect(
        (await send(
          'PUT',
          authorization: before,
          binding: 'other-device',
          path: '/binding',
        )).statusCode,
        200,
      );
      expect(
        (await send(
          'PUT',
          binding: 'other-device',
          path: '/target',
          body: target,
        )).statusCode,
        200,
      );
      expect((await send('DELETE')).statusCode, 200);
      expect(
        (await send('POST', authorization: after, original: bytes)).statusCode,
        409,
      );
      expect(
        (await send('PUT', path: '/target', body: target)).statusCode,
        403,
      );
      expect((await send('GET', binding: 'other-device')).statusCode, 200);
      expect((await send('DELETE', binding: 'other-device')).statusCode, 200);
      expect((await send('GET')).statusCode, 404);
      expect(
        (await send(
          'PUT',
          authorization: before,
          binding: 'other-device',
          path: '/binding',
        )).statusCode,
        409,
      );
    },
  );

  test('reading discussion has a private book-scoped agent route', () async {
    const otherToken = 'reading-same-tenant-other-account';
    addDevice(otherToken, 'personal', 'different-reader');
    AgentApi<Map<String, dynamic>> discussion(String token) =>
        remoteAgent<Map<String, dynamic>>(
          url: 'http://127.0.0.1:${server.port}/v1/agent/reading-discussion',
          headers: () async => {
            'authorization': 'Bearer $token',
            'x-xiaoqi-contract': apiContractVersion,
          },
        );
    final reader = discussion(ownerToken);
    final otherReader = discussion(otherToken);
    addTearDown(reader.close);
    addTearDown(otherReader.close);
    final book = List.filled(64, 'a').join();
    final wrongBook = List.filled(64, 'b').join();
    Message request(String task, String bookKey) => Message(
      role: Role.user,
      content: [TextPart(text: '这一段怎么理解？')],
      metadata: {
        'xiaoqi_agent_turn': {
          'task_id': task,
          'workflow_id': 'private-reading-discussion',
          'user_message_id': '$task-message',
          'current_turn_text': '这一段怎么理解？',
          'reading_companion_book': bookKey,
          'materials': [
            {'id': 'user-notes', 'kind': 'document', 'text': '我的本地读书笔记。'},
          ],
        },
      },
    );

    final started = reader.chat().sendStream(
      message: request('read-first', book),
    );
    await started.stream.drain<void>();
    expect((await started.response).text, '你好');
    expect(runtime.lastRequest?['_reading_discussion'], isTrue);
    expect(
      (runtime.lastRequest?['materials'] as List).single['id'],
      'user-notes',
    );
    final checkpoint =
        store.get('task/personal/read-first')?.value['agent_snapshot_id']
            as String;
    for (final (agent, task, scope) in [
      (ownerAgent, 'read-on-main', book),
      (otherReader, 'read-other-account', book),
      (reader, 'read-other-book', wrongBook),
    ]) {
      final rejected = agent
          .chat(snapshotId: checkpoint)
          .sendStream(message: request(task, scope));
      final drained = rejected.stream.drain<void>().catchError((Object _) {});
      await expectLater(rejected.response, throwsA(isA<Object>()));
      await drained;
    }
    expect(runtime.turnCount, 1);

    const workflow = 'private-reading-discussion';
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    Future<int> select({
      String token = ownerToken,
      String? scope,
      String discussion = workflow,
      String? snapshot,
    }) async {
      final request = await http.putUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/v1/reading-discussions/'
          '${scope ?? book}/$discussion/selection',
        ),
      );
      request.headers
        ..set('authorization', 'Bearer $token')
        ..set('x-xiaoqi-contract', apiContractVersion)
        ..contentType = ContentType.json;
      request.write(jsonEncode({'snapshot_id': snapshot}));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(store.list('reading_discussion_summary/'), isEmpty);
    expect(await select(token: otherToken, snapshot: checkpoint), 404);
    expect(await select(scope: wrongBook, snapshot: checkpoint), 404);
    expect(
      await select(discussion: 'other-workflow', snapshot: checkpoint),
      404,
    );
    expect(await select(snapshot: checkpoint), 200);
    String? selectedSnapshot() =>
        store.list('reading_discussion_summary/').single.$2.value['snapshot_id']
            as String?;
    expect(selectedSnapshot(), checkpoint);

    final completed = reader
        .chat(snapshotId: checkpoint)
        .sendStream(message: request('read-next', book));
    await completed.stream.drain<void>();
    final next = (await completed.response).snapshotId;
    expect(next, isNotNull);
    expect(selectedSnapshot(), checkpoint);
    expect(await select(snapshot: next), 200);
    expect(selectedSnapshot(), next);
    expect(await select(snapshot: checkpoint), 200);
    expect(selectedSnapshot(), checkpoint);
    expect(await select(), 200);
    expect(selectedSnapshot(), isNull);
  });

  test(
    'annotation images follow their numbered groups and stay account and message scoped',
    () async {
      const otherToken = 'streaming-shared-tenant-other-account';
      addDevice(otherToken, 'personal', 'other-account');
      final other = remoteAgent<Map<String, dynamic>>(
        url: 'http://127.0.0.1:${server.port}/v1/agent/chat',
        headers: () async => {
          'authorization': 'Bearer $otherToken',
          'x-xiaoqi-contract': apiContractVersion,
        },
      );
      final http = HttpClient();
      addTearDown(() async {
        http.close(force: true);
        await other.close();
      });
      final base = 'http://127.0.0.1:${server.port}/v1';
      Future<HttpClientRequest> request(
        String verb,
        String path,
        String token,
      ) async {
        final result = await http.openUrl(verb, Uri.parse('$base/$path'));
        result.headers.set('authorization', 'Bearer $token');
        result.headers.set('x-xiaoqi-contract', apiContractVersion);
        return result;
      }

      List<int> tinyPng(int sentinel) => [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        sentinel,
      ];
      Future<String> upload(String message, List<int> bytes) async {
        final pending = await request(
          'POST',
          'annotation-images/$message',
          ownerToken,
        );
        pending.headers
          ..set('x-xiaoqi-filename', 'same-name.png')
          ..contentType = ContentType('image', 'png');
        pending.add(bytes);
        final response = await pending.close();
        final text = await response.transform(utf8.decoder).join();
        expect(response.statusCode, anyOf(200, 202), reason: text);
        return (jsonDecode(text) as Map)['id'] as String;
      }

      const messageId = 'annotated-question';
      const taskId = 'numbered-image-task';
      final firstBytes = tinyPng(1);
      final secondBytes = tinyPng(2);
      final first = await upload(messageId, firstBytes);
      final second = await upload(messageId, secondBytes);
      expect(first, isNot(second));

      Message grouped(String message, String task, [List<String>? media]) {
        final ids = media ?? [first, second];
        return Message(
          role: Role.user,
          content: [TextPart(text: '比较解释图')],
          metadata: {
            'xiaoqi_agent_turn': {
              'task_id': task,
              'workflow_id': 'numbered-image-conversation',
              'user_message_id': message,
              'current_turn_text': '比较解释图',
              'annotation_groups': [
                {
                  'id': 'annotation-1',
                  'number': 1,
                  'text': '甲',
                  'image_ids': [ids[0]],
                },
                {
                  'id': 'annotation-2',
                  'number': 2,
                  'text': '乙',
                  'image_ids': [ids[1]],
                },
              ],
            },
          },
        );
      }

      final turn = ownerAgent.chat().sendStream(
        message: grouped(messageId, taskId),
      );
      await turn.stream.drain<void>();
      final settled = await turn.response;
      expect(settled.text, '你好');
      final originalCheckpoint = store
          .get('task/personal/$taskId')!
          .value['agent_snapshot_id'];
      final parts = runtime.lastMessages!
          .lastWhere((item) => item.role == Role.user)
          .content;
      expect(parts.map((part) => part.isMedia ? part.media!.url : part.text), [
        '比较解释图',
        '[注释 1] 甲',
        'data:image/png;base64,${base64Encode(firstBytes)}',
        '[注释 2] 乙',
        'data:image/png;base64,${base64Encode(secondBytes)}',
      ]);
      final duplicate = ownerAgent.chat().sendStream(
        message: grouped(messageId, taskId),
      );
      await duplicate.stream.drain<void>();
      expect((await duplicate.response).text, '你好');
      expect(runtime.turnCount, 1);
      for (final (agent, id, wrongTask, media) in [
        (other, messageId, 'forged-account-image', <String>[first, second]),
        (other, messageId, taskId, <String>[first, second]),
        (
          ownerAgent,
          'other-message',
          'forged-message-image',
          <String>[first, second],
        ),
        (ownerAgent, messageId, taskId, <String>[second, first]),
      ]) {
        final rejected = agent.chat().sendStream(
          message: grouped(id, wrongTask, media),
        );
        await expectLater(rejected.response, throwsA(isA<Object>()));
      }
      expect(runtime.turnCount, 1);
      expect(
        store.get('task/personal/$taskId')!.value['agent_snapshot_id'],
        originalCheckpoint,
      );
      final publicRead = await (await request(
        'GET',
        'attachments/$first',
        ownerToken,
      )).close();
      expect(publicRead.statusCode, 404);
      await publicRead.drain<void>();
      final taskRead = await (await request(
        'GET',
        'agent/tasks/$taskId',
        otherToken,
      )).close();
      expect(taskRead.statusCode, 404);
      await taskRead.drain<void>();
      final privateSnapshot = await CloudSessionStore(store).getSnapshot(
        snapshotId: settled.snapshotId,
        context: {'tenant_id': 'personal', '_annotation_account': 'other'},
      );
      expect(privateSnapshot, isNull);

      const followupTask = 'numbered-image-followup';
      final followup = ownerAgent
          .chat(snapshotId: settled.snapshotId)
          .sendStream(
            message: Message(
              role: Role.user,
              content: [TextPart(text: '第一张图是什么颜色？')],
              metadata: {
                'xiaoqi_agent_turn': {
                  'task_id': followupTask,
                  'workflow_id': 'numbered-image-conversation',
                  'user_message_id': 'question-after-numbered-images',
                },
              },
            ),
          );
      await followup.stream.drain<void>();
      expect((await followup.response).text, '你好');
      for (final path in [
        'agent/tasks/$followupTask',
        'agent/tasks/$followupTask/events',
      ]) {
        final rejected = await (await request('GET', path, otherToken)).close();
        expect(rejected.statusCode, 404);
        await rejected.drain<void>();
      }
      final ownerRead = await (await request(
        'GET',
        'agent/tasks/$followupTask',
        ownerToken,
      )).close();
      expect(ownerRead.statusCode, 200);
      await ownerRead.drain<void>();
    },
  );

  test('share snapshot is public until its owner revokes it', () async {
    final http = HttpClient();
    try {
      final tooMany = await http.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/chat-shares'),
      );
      tooMany.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken')
        ..set('x-xiaoqi-contract', apiContractVersion)
        ..contentType = ContentType.json;
      tooMany.write(
        jsonEncode({
          'rounds': [
            for (var index = 0; index < 51; index++)
              {'question': '问题 $index', 'answer': '回答 $index'},
          ],
        }),
      );
      final tooManyResponse = await tooMany.close();
      expect(tooManyResponse.statusCode, 400);
      expect(
        await tooManyResponse.transform(utf8.decoder).join(),
        contains('50 组问答'),
      );

      final create = await http.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/chat-shares'),
      );
      create.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken')
        ..set('x-xiaoqi-contract', apiContractVersion)
        ..contentType = ContentType.json;
      create.write(
        jsonEncode({
          'conversation_id': 'conversation-share-test',
          'rounds': [
            {
              'question': '公开问题一',
              'answer': '公开回答一',
              'sources': [
                {'title': '来源', 'url': 'https://example.com/article'},
              ],
            },
            {'question': '公开问题二', 'answer': '公开回答二'},
          ],
          'hidden_branch': '不能公开',
        }),
      );
      final createdResponse = await create.close();
      final created =
          jsonDecode(await createdResponse.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(createdResponse.statusCode, 201);

      final publicResponse = await (await http.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/s/${created['id']}'),
      )).close();
      final html = await publicResponse.transform(utf8.decoder).join();
      expect(publicResponse.statusCode, 200);
      expect(publicResponse.headers.value('cache-control'), 'no-store');
      expect(html, contains('公开问题一'));
      expect(html, contains('公开回答二'));
      expect(html, isNot(contains('不能公开')));

      final oldCreate = await http.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/chat-shares'),
      );
      oldCreate.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken')
        ..set('x-xiaoqi-contract', apiContractVersion)
        ..contentType = ContentType.json;
      oldCreate.write(jsonEncode({'question': '旧问题', 'answer': '旧回答'}));
      final oldCreated =
          jsonDecode(
                await (await oldCreate.close()).transform(utf8.decoder).join(),
              )
              as Map<String, dynamic>;
      expect(
        oldCreated['id'],
        matches(RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')),
      );
      final associate = await http.postUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/v1/chat-shares/${oldCreated['id']}/associate',
        ),
      );
      associate.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken')
        ..set('x-xiaoqi-contract', apiContractVersion)
        ..contentType = ContentType.json;
      associate.write(
        jsonEncode({'conversation_id': 'conversation-share-test'}),
      );
      expect((await associate.close()).statusCode, 200);

      final list = await http.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/chat-shares'),
      );
      list.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken')
        ..set('x-xiaoqi-contract', apiContractVersion);
      final listedResponse = await list.close();
      final listed =
          jsonDecode(await listedResponse.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      final listedItems = listed['items'] as List;
      expect(listedItems, hasLength(2));
      expect(
        listedItems.every(
          (item) => item['url'].toString().endsWith('/s/${item['id']}'),
        ),
        isTrue,
      );

      final revoke = await http.deleteUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/v1/chat-shares?conversation_id=conversation-share-test',
        ),
      );
      revoke.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken')
        ..set('x-xiaoqi-contract', apiContractVersion);
      final revoked = await revoke.close();
      expect(revoked.statusCode, 200);
      expect(
        (jsonDecode(await revoked.transform(utf8.decoder).join())
            as Map<String, dynamic>)['revoked'],
        2,
      );

      final revokedResponse = await (await http.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/s/${created['id']}'),
      )).close();
      expect(revokedResponse.statusCode, 404);
    } finally {
      http.close(force: true);
    }
  });

  test(
    'recovers interrupted tasks on read without mutating startup data',
    () async {
      const taskId = 'interrupted-after-restart';
      final key = 'task/personal/$taskId';
      final seeded = store.put(key, {
        'remote_agent_turn': true,
        'status': 'pausing',
        'attempt': 2,
        'agent_snapshot_id': 'snapshot-before-restart',
      }, null);

      await server.close(force: true);
      server = await shelf_io.serve(
        XiaoqiApi(store, _StreamingRuntime()).handler,
        InternetAddress.loopbackIPv4,
        0,
      );
      expect(store.get(key)!.revision, seeded.revision);
      expect(store.get(key)!.value['status'], 'pausing');

      final http = HttpClient();
      try {
        final request = await http.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/v1/agent/tasks/$taskId'),
        );
        request.headers.set('authorization', 'Bearer $ownerToken');
        request.headers.set('x-xiaoqi-contract', apiContractVersion);
        final response = await request.close();
        final payload =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, dynamic>;

        expect(response.statusCode, 200);
        expect(payload['status'], 'paused');
        expect(payload['remote_agent_turn'], isTrue);
        expect(payload['error_code'], isNull);
        expect(payload['agent_snapshot_id'], 'snapshot-before-restart');
        expect(store.get(key)!.value['status'], 'paused');
      } finally {
        http.close(force: true);
      }
    },
  );

  Message userMessage(String text, String taskId) => Message(
    role: Role.user,
    content: [TextPart(text: text)],
    metadata: {
      'xiaoqi_agent_turn': {'task_id': taskId, 'model': 'test-model'},
    },
  );

  test('stop pauses and restores the same task from its checkpoint', () async {
    runtime.waitForCancellation = true;
    runtime.effectStore = store;
    runtime.turnStarted = Completer<void>();
    const taskId = 'pause-resume-task';
    const bookMaterials = [
      {
        'id': 'book-source-markdown',
        'name': '示例书籍.md',
        'kind': 'document',
        'attachment_id': 'fixture-ready-book',
      },
    ];
    final initial = ownerAgent.chat().sendStream(
      message: Message(
        role: Role.user,
        content: [TextPart(text: 'explain and draw')],
        metadata: {
          'xiaoqi_agent_turn': {
            'task_id': taskId,
            'workflow_id': 'pause-conversation',
            'user_message_id': 'pause-question',
            'current_turn_text': 'explain and draw',
            'materials': bookMaterials,
          },
        },
      ),
    );
    final response = initial.response.then<Object?>(
      (v) => v,
      onError: (Object e) => e,
    );
    final drained = initial.stream.drain<void>().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    await runtime.turnStarted!.future.timeout(const Duration(seconds: 5));
    final task = store.get('task/personal/$taskId')!.value;
    final checkpoint = task['agent_snapshot_id'] as String;
    final duplicate = ownerAgent.chat(snapshotId: checkpoint).sendStream();
    final duplicateResponse = duplicate.response.then<Object?>(
      (v) => v,
      onError: (Object e) => e,
    );
    await expectLater(duplicate.stream.drain<void>(), throwsA(anything));
    await duplicateResponse;
    expect(runtime.turnCount, 1);
    final http = HttpClient();
    try {
      final request = await http.postUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/v1/agent/tasks/$taskId/cancel',
        ),
      );
      request.headers.set('authorization', 'Bearer $ownerToken');
      request.headers.set('x-xiaoqi-contract', apiContractVersion);
      final result = await request.close();
      expect(result.statusCode, 200);
      await result.drain<void>();
    } finally {
      http.close(force: true);
    }
    await Future.wait([response, drained]).timeout(const Duration(seconds: 5));
    expect(store.get('task/personal/$taskId')!.value['status'], 'paused');
    expect((await response as dynamic).finishReason, AgentFinishReason.aborted);
    final stoppedSnapshot = await ownerAgent.getSnapshot(
      snapshotId: checkpoint,
    );
    expect(stoppedSnapshot!.status!.value, 'aborted');
    expect(stoppedSnapshot.finishReason, AgentFinishReason.aborted);
    runtime.waitForCancellation = false;
    runtime.turnStarted = null;
    final restored = ownerAgent
        .chat(snapshotId: checkpoint)
        .sendStream(
          message: Message(
            role: Role.user,
            content: const [],
            metadata: {'xiaoqi_agent_resume': const <String, dynamic>{}},
          ),
        );
    await restored.stream.drain<void>();
    expect((await restored.response).text, '你好');
    expect(runtime.turnCount, 2);
    expect(runtime.lastRequest!['task_id'], taskId);
    expect(runtime.lastRequest!['user_message_id'], 'pause-question');
    expect(runtime.lastRequest!['materials'], bookMaterials);
    expect(runtime.imageSubmissions, 1);
    final completedRetry = ownerAgent.chat(snapshotId: checkpoint).sendStream();
    await completedRetry.stream.drain<void>();
    expect((await completedRetry.response).text, '你好');
    expect(runtime.turnCount, 2);
    expect(runtime.imageSubmissions, 1);
  });

  test(
    'replays a waiting question and its status artifact after reconnect',
    () async {
      runtime.waitForUser = true;
      const taskId = 'waiting-replay-task';
      final first = ownerAgent.chat().sendStream(
        message: userMessage('继续处理', taskId),
      );
      final firstArtifacts = <Artifact>[];
      await for (final chunk in first.stream) {
        if (chunk.artifact != null) firstArtifacts.add(chunk.artifact!);
      }
      final firstResponse = await first.response;
      expect(firstResponse.text, '请确认是否继续处理这份材料。');
      expect(firstResponse.finishReason, AgentFinishReason.stop);
      expect(
        store.get('task/personal/$taskId')!.value['status'],
        'waiting_for_user',
      );
      expect(
        firstArtifacts.any(
          (artifact) =>
              artifact.metadata?['pending_question'] == '请确认是否继续处理这份材料。' &&
              artifact.metadata?['task_status'] == 'waiting_for_user',
        ),
        isTrue,
      );

      final replay = ownerAgent
          .chat(snapshotId: firstResponse.snapshotId)
          .sendStream();
      final replayArtifacts = <Artifact>[];
      await for (final chunk in replay.stream) {
        if (chunk.artifact != null) replayArtifacts.add(chunk.artifact!);
      }
      final replayResponse = await replay.response;
      expect(replayResponse.text, '请确认是否继续处理这份材料。');
      expect(
        replayArtifacts.any(
          (artifact) =>
              artifact.metadata?['pending_question'] == '请确认是否继续处理这份材料。',
        ),
        isTrue,
      );
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

  test('removed network mode endpoint cannot grant script access', () async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/v1/agent/tasks/old-task/network-mode',
        ),
      );
      request.headers
        ..contentType = ContentType.json
        ..set('x-xiaoqi-contract', apiContractVersion)
        ..set(HttpHeaders.authorizationHeader, 'Bearer $ownerToken');
      request.write(jsonEncode({'mode': 'on'}));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 404);
      expect(runtime.disabledNetworkTasks, isEmpty);
    } finally {
      client.close(force: true);
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
