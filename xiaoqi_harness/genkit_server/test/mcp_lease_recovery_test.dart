import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  test(
    'API process death preserves original lease and recovers artifacts without restart',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-lease-restart-');
      final store = CloudStore(root: root.path);
      store.put('task/tenant/task', {'events': [], 'artifacts': []}, null);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var starts = 0, stops = 0, acknowledgements = 0;
      String? leaseId, leaseToken;
      final requests = <String>[];
      final serving = server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        expect(request.headers.value('Authorization'), 'Bearer ${'r' * 40}');
        Map<String, dynamic> result;
        if (request.method == 'POST' && request.uri.path == '/v1/mcp') {
          starts++;
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          leaseId = body['lease_id'] as String;
          leaseToken = body['lease_token'] as String;
          final checkpoint = store
              .get('private_mcp_lease/tenant/task/$leaseId')!
              .value;
          expect(checkpoint['lease_token'], leaseToken);
          expect(checkpoint['issued_at'], body['issued_at']);
          expect(
            jsonEncode(checkpoint),
            isNot(contains('must-not-be-journaled')),
          );
          expect(
            jsonEncode(store.get('task/tenant/task')!.value),
            isNot(contains(leaseToken!)),
          );
          result = {
            'ready': true,
            'control_version': 2,
            'deduplicated_sends': true,
          };
        } else {
          expect(request.headers.value('X-Xiaoqi-Lease-Token'), leaseToken);
          if (request.method == 'DELETE') {
            stops++;
            result = {
              'closed': true,
              'completion': {
                'ok': true,
                'cleanup_pending': false,
                'artifacts': [
                  {
                    'name': 'recovered.txt',
                    'media_type': 'text/plain',
                    'base64': base64Encode(utf8.encode('original bytes')),
                  },
                ],
              },
            };
          } else if (request.method == 'POST') {
            acknowledgements++;
            if (acknowledgements == 1) request.response.statusCode = 503;
            result = {'acknowledged': true};
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            result = {'messages': [], 'closed': false, 'cursor': 0};
          }
        }
        try {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(result));
          await request.response.close();
        } on IOException {
          /* The child process intentionally exits. */
        }
      });
      try {
        final url = Uri.parse('http://127.0.0.1:${server.port}');
        final child = await Process.run(Platform.resolvedExecutable, [
          '--disable-dart-dev',
          '--packages=.dart_tool/package_config.json',
          'test/support/mcp_lease_restart_fixture.dart',
          root.path,
          url.toString(),
        ]);
        expect(child.exitCode, 0, reason: '${child.stdout}\n${child.stderr}');
        expect(starts, 1);
        expect(stops, 0);
        final service = DockerCodeExecutionService(
          store,
          runnerUrl: url,
          runnerToken: 'r' * 40,
        );
        await service.recoverMcpLeases(
          tenantId: 'other-tenant',
          taskId: 'task',
        );
        expect(stops, 0);
        await DockerCodeExecutionService(
          store,
          runnerUrl: url.resolve('/changed-runner'),
          runnerToken: 'r' * 40,
        ).recoverMcpLeases(tenantId: 'tenant', taskId: 'task');
        expect(stops, 0);
        await service.recoverExecutions(tenantId: 'tenant', taskId: 'task');
        expect(starts, 1);
        expect(stops, 1);
        expect(acknowledgements, 1);
        expect(requests.where((path) => path.endsWith('/messages')), isEmpty);
        final artifacts =
            store.get('task/tenant/task')!.value['artifacts'] as List;
        expect(artifacts, hasLength(1));
        expect(
          utf8.decode(store.getObject(artifacts.single['object_key'])),
          'original bytes',
        );
        expect(store.get('private_mcp_lease/tenant/task/$leaseId'), isNotNull);
        await service.recoverExecutions(tenantId: 'tenant', taskId: 'task');
        expect(starts, 1);
        expect(stops, 2);
        expect(acknowledgements, 2);
        expect(store.get('private_mcp_lease/tenant/task/$leaseId'), isNull);
        await service.recoverExecutions(tenantId: 'tenant', taskId: 'task');
        expect(stops, 2);
        expect(
          (store.get('task/tenant/task')!.value['artifacts'] as List),
          hasLength(1),
        );
      } finally {
        await server.close(force: true);
        await serving.cancel();
        store.close();
        await root.delete(recursive: true);
      }
    },
  );
}
