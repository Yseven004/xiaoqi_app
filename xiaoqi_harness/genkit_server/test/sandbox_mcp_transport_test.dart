import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/sandbox_mcp_transport.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
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
          result = {'ready': true};
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
            if (queued.isEmpty && !closed) await wake.future;
            result = {
              'messages': [...queued],
              'closed': closed,
            };
            queued.clear();
            wake = Completer<void>();
          } else if (request.method == 'POST' && path.endsWith('/ack')) {
            await request.drain<void>();
            acknowledgements++;
            result = {'acknowledged': true};
          } else if (request.method == 'POST') {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, dynamic>;
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
        await transport.send({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/list',
        });
        await seen.future.timeout(const Duration(seconds: 5));
        expect(sent.single['method'], 'tools/list');
        expect(observed.first['result'], {'tools': []});
        expect(observed.last['method'], 'roots/list');
        final executor = DockerCodeExecutionService(store);
        await executor.snapshotMcp('tenant', 'task', transport);
        expect(store.get('task/tenant/task')!.value['artifacts'], hasLength(1));
        cancellation.cancel();
        await transport.close();
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
