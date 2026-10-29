import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

void main() {
  test(
    'API death after submission recovers original RPC and its budget without replay',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-api-rpc-');
      final store = CloudStore(root: root.path);
      store.put('task/tenant/task', {'events': [], 'artifacts': []}, null);
      final submitted = Completer<void>();
      final available = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var starts = 0, effects = 0, stops = 0, acks = 0;
      String? lease, token;
      Object? toolRpc;
      Map<String, dynamic>? initialization;
      final cursors = <int>[];
      final serving = server.listen((request) async {
        try {
          expect(request.headers.value('Authorization'), 'Bearer ${'r' * 40}');
          Map<String, dynamic> result;
          if (request.uri.path == '/v1/mcp') {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            starts++;
            lease = body['lease_id'];
            token = body['lease_token'];
            result = {
              'ready': true,
              'control_version': 2,
              'deduplicated_sends': true,
            };
          } else {
            expect(request.headers.value('X-Xiaoqi-Lease-Token'), token);
            if (request.uri.path.endsWith('/messages')) {
              final body =
                  jsonDecode(await utf8.decoder.bind(request).join()) as Map;
              if (body['method'] == 'initialize') {
                initialization = {
                  'jsonrpc': '2.0',
                  'id': body['id'],
                  'result': {
                    'protocolVersion': '2024-11-05',
                    'capabilities': {'tools': {}},
                    'serverInfo': {'name': 'original-process', 'version': '1'},
                  },
                };
              } else if (body['method'] == 'tools/call') {
                effects++;
                toolRpc = body['id'];
                final journals = store.list(
                  'private_mcp_rpc/tenant/task/$lease/',
                );
                expect(journals, hasLength(1)); // Durable before the effect.
                expect(journals.single.$2.value['response'], isNull);
                submitted.complete();
              }
              result = {'accepted': true};
            } else if (request.uri.path.endsWith('/events')) {
              final cursor = int.parse(
                request.headers.value('X-Xiaoqi-Event-Cursor')!,
              );
              cursors.add(cursor);
              if (cursor == 0) {
                while (initialization == null) {
                  await Future<void>.delayed(const Duration(milliseconds: 5));
                }
                result = {
                  'messages': [initialization],
                  'cursor': 1,
                  'closed': false,
                };
              } else {
                await available.future;
                result = {
                  'messages': [
                    {
                      'jsonrpc': '2.0',
                      'id': toolRpc,
                      'result': {
                        'content': [
                          {'type': 'text', 'text': 'original-effect-result'},
                        ],
                      },
                    },
                  ],
                  'cursor': 2,
                  'closed': false,
                };
              }
            } else if (request.method == 'DELETE') {
              stops++;
              result = {
                'closed': true,
                'completion': {
                  'ok': true,
                  'artifacts': [],
                  'cleanup_pending': false,
                },
              };
            } else if (request.uri.path.endsWith('/ack')) {
              acks++;
              result = {'acknowledged': true};
            } else {
              throw StateError(
                'Unexpected recovery request ${request.uri.path}',
              );
            }
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(result));
          await request.response.close();
        } on IOException {
          /* The original API is killed deliberately. */
        }
      });
      Process? child;
      try {
        child = await Process.start(Platform.resolvedExecutable, [
          '--disable-dart-dev',
          '--packages=.dart_tool/package_config.json',
          'test/support/mcp_lease_restart_fixture.dart',
          root.path,
          'http://127.0.0.1:${server.port}',
          'rpc',
        ]);
        final output = child.stdout.transform(utf8.decoder).join();
        final errors = child.stderr.transform(utf8.decoder).join();
        await Future.any([
          submitted.future,
          child.exitCode.then((code) async {
            throw StateError(
              'API exited before submission ($code): ${await output} ${await errors}',
            );
          }),
        ]).timeout(const Duration(seconds: 20));
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        await output;
        await errors;
        expect(effects, 1);
        expect(
          store
              .get('private_mcp_lease/tenant/task/$lease')!
              .value['event_cursor'],
          1,
        );
        available.complete();
        await DockerCodeExecutionService(
          store,
          runnerUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          runnerToken: 'r' * 40,
        ).recoverMcpLeases(tenantId: 'tenant', taskId: 'task');
        expect((starts, effects, stops, acks), (1, 1, 1, 1));
        expect(cursors, contains(1));
        final operations =
            store.get('task/tenant/task')!.value['scope_operations'] as Map;
        expect(operations, hasLength(1));
        expect(operations.values.single['status'], 'succeeded');
        expect(operations.values.single['mcp_response_id'], isNotNull);
        final owner = ToolExecution(
          store,
          'tenant',
          'task',
          TurnContract(mode: 'workflow', imageLimit: 0),
          requestIdentity: 'human',
        )..bind();
        final cached = await owner.authorizedExternal(
          slot: 'effect',
          arguments: {'value': 'once'},
          invoke: (_) async =>
              throw StateError('Recovered effect must not be resubmitted'),
        );
        expect(jsonEncode(cached), contains('original-effect-result'));
        expect(store.list('private_mcp_rpc/tenant/task/'), isEmpty);
        expect(store.list('private_mcp_lease/tenant/task/'), isEmpty);
      } finally {
        child?.kill(ProcessSignal.sigkill);
        if (!available.isCompleted) available.complete();
        await server.close(force: true);
        await serving.cancel();
        store.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
