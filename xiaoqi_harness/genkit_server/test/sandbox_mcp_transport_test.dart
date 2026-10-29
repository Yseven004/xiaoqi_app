import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/sandbox_mcp_transport.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';

void main() {
  test(
    'a runner without durable deduplication is closed before any RPC is sent',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      String? lease;
      final serving = server.listen((request) async {
        paths.add('${request.method} ${request.uri.path}');
        final value = request.method == 'POST'
            ? jsonDecode(await utf8.decoder.bind(request).join()) as Map
            : null;
        if (value != null) lease = value['lease_id'] as String;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            request.method == 'POST'
                ? {
                    'ready': true,
                    'control_version': 2,
                    'deduplicated_sends': false,
                  }
                : {
                    'completion': {'ok': false, 'artifacts': []},
                  },
          ),
        );
        await request.response.close();
      });
      try {
        await expectLater(
          SandboxMcpTransport.connect(
            runnerUrl: Uri.parse('http://127.0.0.1:${server.port}'),
            runnerToken: 'fixture',
            request: {'task_id': 'bound-task'},
            cancellation: CancellationController().token,
          ),
          throwsStateError,
        );
        expect(paths, ['POST /v1/mcp', 'DELETE /v1/mcp/$lease']);
        expect(SandboxMcpTransport.isActive(lease!), isFalse);
      } finally {
        await server.close(force: true);
        await serving.cancel();
      }
    },
  );

  for (final mode in ['success', 'rejected', 'revoked']) {
    final rejected = mode != 'success';
    test(
      'concurrent sends retain original bodies and order; mode=$mode',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final firstArrived = Completer<void>();
        final release = Completer<void>();
        final stopped = Completer<void>();
        final bodies = <Map>[];
        final sequences = <String?>[];
        var sourceEnabled = true;
        final serving = server.listen((request) async {
          Map<String, dynamic> result;
          if (request.method == 'POST' && request.uri.path == '/v1/mcp') {
            await request.drain<void>();
            result = {
              'ready': true,
              'control_version': 2,
              'deduplicated_sends': true,
            };
          } else if (request.uri.path.endsWith('/messages')) {
            sequences.add(request.headers.value('X-Xiaoqi-Message-Sequence'));
            bodies.add(
              jsonDecode(await utf8.decoder.bind(request).join()) as Map,
            );
            if (bodies.length == 1) {
              firstArrived.complete();
              await release.future;
              if (rejected) {
                request.response.statusCode = mode == 'revoked' ? 503 : 400;
                if (mode == 'revoked') sourceEnabled = false;
              }
            }
            result = {'ok': !rejected};
          } else if (request.method == 'DELETE') {
            if (!stopped.isCompleted) stopped.complete();
            result = {
              'completion': {'ok': true, 'artifacts': []},
            };
          } else {
            await stopped.future;
            result = {'messages': [], 'closed': true, 'cursor': 1};
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(result));
          await request.response.close();
        });
        SandboxMcpTransport? transport;
        StreamSubscription<Map<String, dynamic>>? inbound;
        try {
          transport = await SandboxMcpTransport.connect(
            runnerUrl: Uri.parse('http://127.0.0.1:${server.port}'),
            runnerToken: 'fixture',
            request: {'task_id': 'bound-task'},
            cancellation: CancellationController().token,
          );
          inbound = transport.inbound.listen((_) {});
          final firstBody = <String, dynamic>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {'text': 'original'},
          };
          Future<void> send(Map<String, dynamic> message) =>
              ToolExecution.withAuthorityCheck(() {
                if (!sourceEnabled)
                  throw StateError('Original plugin source disabled');
              }, () => transport!.send(message));
          final first = send(firstBody);
          // Attach rejection listeners before releasing the server response.
          final firstResult = rejected
              ? expectLater(first, throwsStateError)
              : first;
          await firstArrived.future.timeout(const Duration(seconds: 2));
          final second = send({
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/list',
          });
          final secondResult = rejected
              ? expectLater(second, throwsStateError)
              : second;
          (firstBody['params'] as Map)['text'] = 'changed after submission';
          expect(bodies, hasLength(1));
          release.complete();
          await Future.wait([firstResult, secondResult]);
          expect(sequences, rejected ? ['1'] : ['1', '2']);
          expect((bodies.first['params'] as Map)['text'], 'original');
          expect(bodies.map((body) => body['id']), rejected ? [1] : [1, 2]);
        } finally {
          if (!release.isCompleted) release.complete();
          await transport?.close();
          await inbound?.cancel();
          await server.close(force: true);
          await serving.cancel();
        }
      },
    );
  }
  test(
    'private transport carries bidirectional JSON-RPC and releases its lease on cancel',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cancellation = CancellationController();
      final queued = <Map<String, dynamic>>[];
      final sent = <Map<String, dynamic>>[];
      final observed = <Map<String, dynamic>>[];
      final seen = Completer<void>();
      var wake = Completer<void>();
      String? leaseToken;
      String? leaseId;
      var deletes = 0;
      var acknowledgements = 0;
      var closed = false;
      var eventCursor = 0;
      var lostResponse = false;
      var lostSendAck = false;
      final acceptedSends = <int, String>{};
      final sendSequences = <int>[];
      Map<String, dynamic>? retainedBatch;
      final serving = server.listen((request) async {
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer fixture-runner-token',
        );
        final path = request.uri.path;
        Map<String, dynamic> result;
        if (request.method == 'POST' && path == '/v1/mcp') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          leaseToken = body['lease_token'] as String;
          leaseId = body['lease_id'] as String;
          expect(leaseToken!.length, 64);
          expect(leaseId!.length, 32);
          result = {
            'ready': true,
            'control_version': 2,
            'deduplicated_sends': true,
          };
        } else {
          expect(request.headers.value('X-Xiaoqi-Lease-Token'), leaseToken);
          expect(path, startsWith('/v1/mcp/$leaseId'));
          if (request.method == 'GET' && path.endsWith('/artifacts')) {
            result = {
              'artifacts': [
                {
                  'name': 'retained.txt',
                  'media_type': 'text/plain',
                  'base64': base64Encode(utf8.encode('retained bytes')),
                },
              ],
            };
          } else if (request.method == 'GET') {
            final cursor = int.parse(
              request.headers.value('X-Xiaoqi-Event-Cursor')!,
            );
            if (retainedBatch != null && cursor == eventCursor - 1) {
              result = retainedBatch!;
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode(result));
              await request.response.close();
              return;
            }
            expect(cursor, eventCursor);
            if (queued.isEmpty && !closed) await wake.future;
            if (queued.isNotEmpty || closed) eventCursor++;
            result = {
              'messages': [...queued],
              'closed': closed,
              'cursor': eventCursor,
            };
            retainedBatch = result;
            queued.clear();
            wake = Completer<void>();
            if (!lostResponse && (result['messages'] as List).isNotEmpty) {
              lostResponse = true;
              // The runner has produced the batch, but its HTTP response is lost.
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              socket.destroy();
              return;
            }
          } else if (request.method == 'POST' && path.endsWith('/ack')) {
            await request.drain<void>();
            acknowledgements++;
            result = {'acknowledged': true};
          } else if (request.method == 'POST') {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, dynamic>;
            final sequence = int.parse(
              request.headers.value('X-Xiaoqi-Message-Sequence')!,
            );
            sendSequences.add(sequence);
            final serialized = jsonEncode(body);
            if (acceptedSends.containsKey(sequence)) {
              expect(acceptedSends[sequence], serialized);
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({'ok': true}));
              await request.response.close();
              return;
            }
            acceptedSends[sequence] = serialized;
            sent.add(body);
            queued.addAll([
              {
                'jsonrpc': '2.0',
                'id': body['id'],
                'result': {'tools': []},
              },
              {'jsonrpc': '2.0', 'id': 'server-1', 'method': 'roots/list'},
            ]);
            if (!wake.isCompleted) wake.complete();
            if (!lostSendAck) {
              lostSendAck = true;
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              socket.destroy();
              return;
            }
            result = {'ok': true};
          } else {
            deletes++;
            closed = true;
            if (!wake.isCompleted) wake.complete();
            result = {
              'closed': true,
              'completion': {
                'ok': true,
                'cleanup_pending': false,
                'artifacts': [
                  {
                    'name': 'retained.txt',
                    'media_type': 'text/plain',
                    'base64': base64Encode(utf8.encode('retained bytes')),
                  },
                ],
              },
            };
          }
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result));
        await request.response.close();
      });
      SandboxMcpTransport? transport;
      final directory = await Directory.systemTemp.createTemp(
        'mcp-completion-',
      );
      final store = CloudStore(root: directory.path);
      store.put('task/tenant/task', {'artifacts': [], 'events': []}, null);
      StreamSubscription<Map<String, dynamic>>? subscription;
      try {
        transport = await SandboxMcpTransport.connect(
          runnerUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          runnerToken: 'fixture-runner-token',
          request: {'task_id': 'tenant-bound-task'},
          cancellation: cancellation.token,
        );
        subscription = transport.inbound.listen((message) {
          observed.add(message);
          if (observed.length == 2) seen.complete();
        });
        expect(SandboxMcpTransport.isActive(transport.leaseId), true);
        await transport.send({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/list',
        });
        await seen.future.timeout(const Duration(seconds: 5));
        expect(sent.single['method'], 'tools/list');
        expect(lostResponse, true);
        expect(lostSendAck, true);
        expect(sendSequences, [1, 1]);
        expect(observed.first['result'], {'tools': []});
        expect(observed.last['method'], 'roots/list');
        final executor = DockerCodeExecutionService(store);
        await executor.snapshotMcp('tenant', 'task', transport);
        expect(store.get('task/tenant/task')!.value['artifacts'], hasLength(1));
        cancellation.cancel();
        await transport.close();
        expect(SandboxMcpTransport.isActive(transport.leaseId), false);
        expect(deletes, 1);
        await executor.finishMcp('tenant', 'task', transport);
        await executor.finishMcp('tenant', 'task', transport);
        final task = store.get('task/tenant/task')!.value;
        final artifacts = task['artifacts'] as List;
        expect(artifacts, hasLength(1));
        expect(
          utf8.decode(store.getObject(artifacts.single['object_key'])),
          'retained bytes',
        );
        expect(
          (task['events'] as List).where(
            (event) => event['type'] == 'artifacts_ready',
          ),
          hasLength(1),
        );
        expect(acknowledgements, 2);
        await expectLater(
          transport.send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
          throwsStateError,
        );
      } finally {
        await transport?.close();
        await subscription?.cancel();
        await server.close(force: true);
        await serving.cancel();
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
