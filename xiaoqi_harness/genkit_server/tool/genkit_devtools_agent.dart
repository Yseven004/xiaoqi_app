import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:genkit/experimental_client.dart';
import 'package:genkit/genkit.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:schemantic/schemantic.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:uuid/uuid.dart';
import 'package:xiaoqi_genkit_server/src/api.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/attachment_service.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/release.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

const _defaultApiPort = 8180;
const _devTenantId = 'genkit-devtools';
const _devDeviceId = 'genkit-devtools-device';
const _uuid = Uuid();
const _annotationProbePngs = [
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdLep8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3IPanc8OLDQitxAAAAAElFTkSuQmCC',
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdNvJ8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ2oPcf88OIhvJ6vAAAAAElFTkSuQmCC',
];

class _DevtoolsProxy extends HttpOverrides {
  _DevtoolsProxy(this.proxy);
  final String proxy;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    final endpoint = Uri.parse(proxy);
    client.findProxy = (uri) => uri.host == 'api.deepseek.com'
        ? 'PROXY ${endpoint.host}:${endpoint.port}'
        : 'DIRECT';
    return client;
  }
}

Future<void> main() async {
  final proxy = Platform.environment['XIAOQI_DEVTOOLS_PROXY'];
  if (proxy != null && proxy.isNotEmpty) {
    HttpOverrides.global = _DevtoolsProxy(proxy);
  }
  final projectRoot = Directory.current.parent.parent;
  final dataDir = Directory(
    Platform.environment['XIAOQI_DEVTOOLS_DATA_DIR'] ??
        p.join(projectRoot.path, '.codex-artifacts', 'genkit-devtools', 'data'),
  );
  dataDir.createSync(recursive: true);

  final apiPort =
      int.tryParse(Platform.environment['XIAOQI_DEVTOOLS_API_PORT'] ?? '') ??
      _defaultApiPort;
  final token = 'genkit-devtools-${_uuid.v4()}';
  final annotationToken = 'genkit-devtools-annotation-${_uuid.v4()}';
  final store = CloudStore(root: dataDir.path);
  store.put('device/${sha256.convert(utf8.encode(token))}', {
    'tenant_id': _devTenantId,
    'device_id': _devDeviceId,
    'auth_method': 'local-devtools',
    'account_email': 'genkit-devtools@invalid.local',
    'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'revoked_at': null,
  }, null);
  store.put('device/${sha256.convert(utf8.encode(annotationToken))}', {
    'tenant_id': _devTenantId,
    'device_id': '$_devDeviceId-annotation',
    'auth_method': 'email',
    'account_email': 'genkit-annotation-fixture@invalid.local',
    'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'revoked_at': null,
  }, null);

  final images = ImageService(store);
  final attachments = AttachmentService(store);
  final runtime = GenkitXiaoqiAgentRuntime(
    store,
    images,
    attachments: attachments,
  );
  final api = XiaoqiApi(store, runtime, attachments: attachments);
  final server = await shelf_io.serve(
    api.handler,
    InternetAddress.loopbackIPv4,
    apiPort,
    poweredByHeader: null,
  );

  AgentApi<Map<String, dynamic>> agentFor(
    String bearer, [
    String route = 'chat',
  ]) => remoteAgent<Map<String, dynamic>>(
    url: 'http://127.0.0.1:${server.port}/v1/agent/$route',
    headers: () async => {
      'authorization': 'Bearer $bearer',
      'x-xiaoqi-contract': apiContractVersion,
    },
  );
  final agent = agentFor(token);
  final annotationAgent = agentFor(annotationToken);

  final genkit = Genkit(isDevEnv: true, promptDir: null);
  genkit.defineFlow<Map<String, dynamic>, Map<String, dynamic>, void, void>(
    name: 'xiaoqi_reading_dev_test',
    inputSchema: SchemanticType.from<Map<String, dynamic>>(
      jsonSchema: {
        'type': 'object',
        'properties': {
          'mode': {
            'type': 'string',
            'enum': ['quick', 'discussion', 'delegation'],
          },
          'message': {'type': 'string'},
          'model_id': {'type': 'string'},
        },
        'required': ['mode', 'message'],
        'additionalProperties': false,
      },
      parse: (json) => Map<String, dynamic>.from(json as Map),
    ),
    fn: (input, context) async {
      final message = input['message'] as String;
      final model = input['model_id'] as String? ?? 'deepseek-flash';
      final quick = input['mode'] == 'quick';
      final delegation = input['mode'] == 'delegation';
      final book = sha256
          .convert(utf8.encode('devtools reading fixture'))
          .toString();
      final bytes = _readingFixture();
      final version = sha256.convert(bytes).toString();
      final url = Uri.parse(
        'http://127.0.0.1:${server.port}/v1/reading-books/$book/$version',
      );
      final headers = {
        'authorization': 'Bearer $annotationToken',
        'x-xiaoqi-contract': apiContractVersion,
        'x-xiaoqi-reading-binding': 'devtools-reading-fixture',
      };
      final status = await http.get(url, headers: headers);
      const authorizationHeader = 'x-xiaoqi-reading-authorization';
      final authorization = status.headers[authorizationHeader];
      if (authorization == null) {
        throw StateError('Cannot authorize fixture: HTTP ${status.statusCode}');
      }
      final upload = await http.post(
        url,
        headers: {
          ...headers,
          authorizationHeader: authorization,
          'content-type': 'application/epub+zip',
          'x-xiaoqi-filename': 'reading-fixture.epub',
          'x-xiaoqi-sha256': version,
          'x-xiaoqi-attachment-profile': 'reading-book-markitdown-v1',
        },
        body: bytes,
      );
      if (upload.statusCode != 202) {
        throw StateError('Cannot register fixture: HTTP ${upload.statusCode}');
      }
      final receipt = _asMap(jsonDecode(upload.body));
      final id = receipt['id'] as String;
      final watch = Stopwatch()..start();
      var ready = false;
      while (watch.elapsed < const Duration(seconds: 30)) {
        context.cancel?.throwIfCancelled();
        final response = await http.get(url, headers: headers);
        final result = _asMap(jsonDecode(response.body));
        ready = result['ready'] == true;
        if (ready ||
            const {
              'failed',
              'complete_with_errors',
            }.contains(result['status'])) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!ready)
        throw StateError('Reading fixture did not produce searchable text.');
      watch.stop();
      final task = _uuid.v4();
      final agent = agentFor(
        annotationToken,
        quick
            ? 'reading-explanation'
            : delegation
            ? 'chat'
            : 'reading-discussion',
      );
      try {
        final response = await agent.chat().send(
          message: Message(
            role: Role.user,
            content: [TextPart(text: message)],
            metadata: quick
                ? {
                    'reading_explanation': {
                      'quote': message,
                      'book': book,
                      'version': version,
                      'chapter_id': 'fixture-chapter',
                      'model_id': model,
                    },
                  }
                : {
                    'xiaoqi_agent_turn': {
                      'task_id': task,
                      'attempt_id': task,
                      'workflow_id': _uuid.v4(),
                      'user_message_id': _uuid.v4(),
                      'model_id': model,
                      'reasoning_level': 'low',
                      'reading_companion_book': book,
                      'reading_companion_version': version,
                      'materials': [
                        {
                          'id': 'reading-fixture',
                          'name': '合成资料',
                          'kind': 'document',
                          'reading_book_id': id,
                        },
                      ],
                    },
                  },
          ),
          cancel: context.cancel,
        );
        response.assertValid();
        final snapshot = delegation && response.snapshotId != null
            ? await CloudSessionStore(store).getSnapshot(
                snapshotId: response.snapshotId,
                context: {'tenant_id': _devTenantId},
              )
            : null;
        return {
          'text': response.text,
          'finish_reason': response.finishReason?.value,
          'reading_evidence': response.state?['reading_evidence'] ?? [],
          'snapshot_id': response.snapshotId,
          'fixture_ready_ms': watch.elapsedMilliseconds,
          if (delegation)
            'delegated':
                snapshot?.state?.messages?.any(
                  (message) => message.content.whereType<ToolRequestPart>().any(
                    (part) =>
                        part.toolRequest.name ==
                        'delegate_to_reading_companion',
                  ),
                ) ??
                false,
        };
      } finally {
        await agent.close();
      }
    },
  );
  genkit.defineFlow<
    Map<String, dynamic>,
    Map<String, dynamic>,
    Map<String, dynamic>,
    void
  >(
    name: 'xiaoqi_agent_dev_test',
    inputSchema: SchemanticType.from<Map<String, dynamic>>(
      jsonSchema: {
        'type': 'object',
        'properties': {
          'operation': {
            'type': 'string',
            'enum': ['new', 'branch', 'resume', 'continue_aborted'],
            'description': '新任务、从快照分支，或从最近恢复点继续。',
          },
          'message': {'type': 'string', 'description': '本轮用户消息；继续已中止任务时留空。'},
          'cancel_after_ms': {
            'type': 'integer',
            'minimum': 1000,
            'maximum': 120000,
            'description': '仅本地调试：延迟取消当前任务，用于验证暂停和快照恢复。',
          },
          'model_id': {'type': 'string'},
          'annotation_fixture': {
            'type': 'boolean',
            'description': '通过真实业务入口上传两张合成解释图，按注释顺序验证多模态。',
          },
          'book_search': {
            'type': 'boolean',
            'description': '使用网上找书弹窗入口，返回本次实际检索的候选。',
          },
          'book_search_linked_book': {
            'type': 'object',
            'description': '本地调试找书时关联的合成书架记录。',
            'properties': {
              'title': {'type': 'string'},
              'author': {'type': 'string'},
              'isbn': {'type': 'string'},
            },
            'required': ['title'],
            'additionalProperties': false,
          },
          'reasoning_level': {
            'type': 'string',
            'enum': ['low', 'medium', 'high'],
          },
          'selected_capabilities': {
            'type': 'array',
            'items': {'type': 'object'},
          },
          'selected_mcp_connections': {
            'type': 'array',
            'items': {'type': 'object'},
          },
          'materials': {
            'type': 'array',
            'items': {'type': 'object'},
          },
          'session_id': {'type': 'string'},
          'snapshot_id': {'type': 'string'},
          'turn_metadata': {'type': 'object'},
        },
        'required': ['message'],
        'additionalProperties': false,
      },
      parse: (json) => Map<String, dynamic>.from(json as Map),
    ),
    streamSchema: SchemanticType.from<Map<String, dynamic>>(
      jsonSchema: {
        'type': 'object',
        'properties': {
          'type': {'type': 'string'},
          'text': {'type': 'string'},
        },
        'required': ['type', 'text'],
      },
      parse: (json) => Map<String, dynamic>.from(json as Map),
    ),
    fn: (input, flowContext) async {
      final operation = (input['operation']?.toString() ?? 'new').trim();
      if (!const {
        'new',
        'branch',
        'resume',
        'continue_aborted',
      }.contains(operation)) {
        throw FormatException('不支持的调试操作：$operation');
      }

      final messageText = input['message']?.toString() ?? '';
      final isResume = const {'resume', 'continue_aborted'}.contains(operation);
      if (!isResume && messageText.trim().isEmpty) {
        throw const FormatException('新任务或分支需要填写 message');
      }

      final priorMetadata = _asMap(input['turn_metadata']);
      final taskId = isResume
          ? _requiredId(priorMetadata['task_id'], 'turn_metadata.task_id')
          : 'devtools-${_uuid.v4()}';
      final attemptId = isResume
          ? _requiredId(priorMetadata['attempt_id'], 'turn_metadata.attempt_id')
          : taskId;
      final workflowId = isResume
          ? _requiredId(
              priorMetadata['workflow_id'],
              'turn_metadata.workflow_id',
            )
          : operation == 'branch' && priorMetadata['workflow_id'] != null
          ? _requiredId(
              priorMetadata['workflow_id'],
              'turn_metadata.workflow_id',
            )
          : 'devtools-workflow-${_uuid.v4()}';
      final userMessageId = isResume
          ? _requiredId(
              priorMetadata['user_message_id'],
              'turn_metadata.user_message_id',
            )
          : 'devtools-message-${_uuid.v4()}';

      final annotationFixture = input['annotation_fixture'] == true;
      final annotationGroups = annotationFixture && !isResume
          ? await _uploadAnnotationProbes(
              port: server.port,
              token: annotationToken,
              messageId: userMessageId,
            )
          : const <Map<String, Object?>>[];

      final turnMetadata = isResume
          ? priorMetadata
          : <String, dynamic>{
              'task_id': taskId,
              if (input['book_search'] == true) 'book_search_id': taskId,
              if (input['book_search'] == true &&
                  input['book_search_linked_book'] is Map)
                'book_search_linked_book': input['book_search_linked_book'],
              'attempt_id': attemptId,
              'workflow_id': workflowId,
              'user_message_id': userMessageId,
              'work_context_message_ids': <String>[],
              'problem_attempt_stage_id': workflowId,
              'work_goal': messageText.trim(),
              'capability_scope_operation': 'replace',
              'keep_work_open': false,
              'model_id': _nonEmpty(input['model_id'])
                  ? input['model_id']
                  : Platform.environment['XIAOQI_DEFAULT_TEXT_MODEL']
                            ?.trim()
                            .isNotEmpty ==
                        true
                  ? Platform.environment['XIAOQI_DEFAULT_TEXT_MODEL']!.trim()
                  : 'deepseek-flash',
              'reasoning_level': _nonEmpty(input['reasoning_level'])
                  ? input['reasoning_level']
                  : 'medium',
              'selected_capabilities': _asList(input['selected_capabilities']),
              'selected_mcp_connections': _asList(
                input['selected_mcp_connections'],
              ),
              'materials': _asList(input['materials']),
              if (annotationGroups.isNotEmpty)
                'annotation_groups': annotationGroups,
              'current_turn_text': messageText.trim(),
            };

      final snapshotId = _nonEmpty(input['snapshot_id'])
          ? input['snapshot_id']!.toString().trim()
          : null;
      if ((operation == 'branch' || isResume) && snapshotId == null) {
        throw FormatException('$operation 操作需要 snapshot_id');
      }

      final metadata = <String, dynamic>{
        'xiaoqi_agent_turn': turnMetadata,
        // Resume from Genkit's saved snapshot/history. Partial streamed text
        // is presentation data and must never be sent as a provider prefix.
        if (isResume) 'xiaoqi_agent_resume': <String, dynamic>{},
      };
      final message = Message(
        role: Role.user,
        content: [if (!isResume) TextPart(text: messageText)],
        metadata: metadata,
      );
      final annotationRun = turnMetadata.containsKey('annotation_groups');
      final chat = (annotationRun ? annotationAgent : agent).chat(
        snapshotId: snapshotId,
        sessionId: operation == 'new' && _nonEmpty(input['session_id'])
            ? input['session_id']!.toString().trim()
            : null,
      );
      final turn = chat.sendStream(
        message: message,
        cancel: flowContext.cancel,
      );
      final partialText = StringBuffer();
      final partialReasoning = StringBuffer();
      final rawCancelAfter = input['cancel_after_ms'];
      final cancelAfterMs = rawCancelAfter is num
          ? rawCancelAfter.toInt().clamp(1000, 120000)
          : null;
      Future<int>? cancelRequest;
      Timer? cancelTimer;
      if (cancelAfterMs != null && !isResume) {
        cancelTimer = Timer(Duration(milliseconds: cancelAfterMs), () {
          cancelRequest ??= _cancelDevtoolsTask(
            port: server.port,
            token: annotationRun ? annotationToken : token,
            taskId: taskId,
          );
        });
      }

      Map<String, dynamic>? result;
      try {
        await for (final chunk in turn.stream) {
          if (chunk.text.isNotEmpty) {
            partialText.write(chunk.text);
            flowContext.sendChunk({'type': 'text', 'text': chunk.text});
          }
          if (chunk.reasoning.isNotEmpty) {
            partialReasoning.write(chunk.reasoning);
            flowContext.sendChunk({
              'type': 'reasoning',
              'text': chunk.reasoning,
            });
          }
        }
        final response = await turn.response;
        final finalText = response.text.isNotEmpty
            ? response.text
            : partialText.toString();
        final finalReasoning = response.reasoning.isNotEmpty
            ? response.reasoning
            : partialReasoning.toString();
        final taskStatus = store
            .get('task/$_devTenantId/$taskId')
            ?.value['status']
            ?.toString();
        final resultSnapshotId = response.snapshotId ?? snapshotId;
        result = <String, dynamic>{
          'operation': operation,
          'finish_reason': response.finishReason.value,
          'task_status': taskStatus,
          'text': finalText,
          'reasoning': finalReasoning,
          'task_id': taskId,
          'workflow_id': workflowId,
          'attempt_id': attemptId,
          'user_message_id': userMessageId,
          'session_id': response.sessionId,
          'snapshot_id': resultSnapshotId,
          'turn_metadata': turnMetadata,
          if (input['book_search'] == true &&
              response.state?['book_search_reference'] == taskId)
            'book_search': runtime.bookSearch.searches.read(
              owner: 'device/${sha256.convert(utf8.encode(token))}',
              id: taskId,
            ),
        };
        if ((response.finishReason.value == 'aborted' ||
                taskStatus == 'paused') &&
            resultSnapshotId != null) {
          result['resume_input'] = {
            'operation': 'resume',
            'message': '',
            'snapshot_id': resultSnapshotId,
            'turn_metadata': turnMetadata,
          };
        }
        if (!isResume && resultSnapshotId != null) {
          result['branch_input'] = {
            'operation': 'branch',
            'message': '在此分支上重新生成或提出后续问题',
            'snapshot_id': resultSnapshotId,
            'turn_metadata': turnMetadata,
          };
        }
      } catch (_) {
        if (cancelRequest != null) await cancelRequest;
        final taskValue = store.get('task/$_devTenantId/$taskId')?.value;
        var taskStatus = taskValue?['status']?.toString();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (taskStatus == 'pausing' && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          taskStatus = store
              .get('task/$_devTenantId/$taskId')
              ?.value['status']
              ?.toString();
        }
        if (taskStatus != 'paused') rethrow;
        final resumeSnapshotId =
            taskValue?['agent_snapshot_id']?.toString() ?? snapshotId;
        result = <String, dynamic>{
          'operation': operation,
          'finish_reason': 'aborted',
          'task_status': taskStatus,
          'text': partialText.toString(),
          'reasoning': partialReasoning.toString(),
          'task_id': taskId,
          'workflow_id': workflowId,
          'attempt_id': attemptId,
          'user_message_id': userMessageId,
          'snapshot_id': resumeSnapshotId,
          'turn_metadata': turnMetadata,
          'cancel_http_status': await cancelRequest,
          if (resumeSnapshotId != null)
            'resume_input': {
              'operation': 'resume',
              'message': '',
              'snapshot_id': resumeSnapshotId,
              'turn_metadata': turnMetadata,
            },
        };
      } finally {
        cancelTimer?.cancel();
        if (cancelRequest != null) await cancelRequest;
      }
      return result;
    },
  );

  stdout.writeln('Genkit Developer UI Agent Flow ready.');
  stdout.writeln('Local Agent API: http://127.0.0.1:${server.port}/v1');
  stdout.writeln('Isolated data: ${dataDir.path}');
  stdout.writeln('Synthetic tenant: $_devTenantId');

  try {
    await ProcessSignal.sigint.watch().first;
  } finally {
    await server.close(force: false);
    await agent.close();
    await annotationAgent.close();
    await api.close();
    await genkit.shutdown();
    store.checkpointWal();
    store.close();
  }
}

List<int> _readingFixture() {
  final archive = Archive();
  for (final entry in const {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
    'book.opf':
        '<package><metadata><title>合成阅读资料</title></metadata>'
        '<manifest><item id="fixture-chapter" href="body.xhtml" media-type="application/xhtml+xml"/></manifest>'
        '<spine><itemref idref="fixture-chapter"/></spine></package>',
    'body.xhtml':
        '<html><body><h1>档案室</h1><p>青栎档案存放在北塔第二层。</p>'
        '<p>登记物品的编号是七四三。</p></body></html>',
  }.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile.bytes(entry.key, bytes));
  }
  return ZipEncoder().encode(archive);
}

Future<List<Map<String, Object?>>> _uploadAnnotationProbes({
  required int port,
  required String token,
  required String messageId,
}) async {
  final client = http.Client();
  try {
    final groups = <Map<String, Object?>>[];
    for (final (index, png) in _annotationProbePngs.indexed) {
      final id = index + 1;
      final bytes = base64Decode(png);
      final response = await client
          .post(
            Uri.parse('http://127.0.0.1:$port/v1/annotation-images/$messageId'),
            headers: {
              'authorization': 'Bearer $token',
              'x-xiaoqi-contract': apiContractVersion,
              'x-xiaoqi-filename': 'fixture.png',
              'x-xiaoqi-sha256': sha256.convert(bytes).toString(),
              'content-type': 'image/png',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('合成解释图 $id 上传失败 HTTP ${response.statusCode}');
      }
      final uploaded = _asMap(jsonDecode(response.body));
      groups.add({
        'id': 'devtools-annotation-$id',
        'number': id,
        'text': '请说出这条注释的解释图颜色。',
        'image_ids': [_requiredId(uploaded['id'], 'attachment.id')],
      });
    }
    return groups;
  } finally {
    client.close();
  }
}

Map<String, dynamic> _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> _asList(Object? value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
    : <Map<String, dynamic>>[];

bool _nonEmpty(Object? value) =>
    value != null && value.toString().trim().isNotEmpty;

String _requiredId(Object? value, String name) {
  final id = value?.toString().trim() ?? '';
  if (!RegExp(r'^[A-Za-z0-9_-]{1,120}$').hasMatch(id)) {
    throw FormatException('$name 缺失或格式无效');
  }
  return id;
}

Future<int> _cancelDevtoolsTask({
  required int port,
  required String token,
  required String taskId,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/v1/agent/tasks/$taskId/cancel'),
    );
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set('x-xiaoqi-contract', apiContractVersion);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } on Object {
    return 0;
  } finally {
    client.close(force: true);
  }
}
