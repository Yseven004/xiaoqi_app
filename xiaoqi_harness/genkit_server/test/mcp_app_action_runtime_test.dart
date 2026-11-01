import 'dart:convert';
import 'dart:io';
import 'package:genkit/experimental.dart';
import 'package:genkit/genkit.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/execution_limits.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';
import 'support/mcp_runtime_fixture.dart' show FixtureMcpConnections;

void main() {
  for (final send in [false, true]) {
    test(
      'App ${send ? 'account approval' : 'refresh and idempotence'} uses actual SDK tools without an LLM',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'mcp-app-action-',
        );
        final store = CloudStore(root: directory.path);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var calls = 0;
        final tool = send ? 'make_card' : 'fetch_card';
        final serving = server.listen((request) async {
          if (request.method != 'POST') {
            request.response.statusCode = 405;
            await request.response.close();
            return;
          }
          final rpc =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          if (rpc['id'] == null) {
            request.response.statusCode = 202;
            await request.response.close();
            return;
          }
          final Object? result;
          switch (rpc['method']) {
            case 'initialize':
              result = {
                'protocolVersion': '2025-11-25',
                'capabilities': {'tools': {}},
                'serverInfo': {'name': 'apps-test', 'version': '1'},
              };
            case 'tools/list':
              result = {
                'tools': [
                  {
                    'name': tool,
                    'description': 'App fixture',
                    'inputSchema': {
                      'type': 'object',
                      'properties': send
                          ? {
                              'destination': {'type': 'string'},
                            }
                          : {},
                      'additionalProperties': false,
                    },
                    '_meta': {
                      'ui': {
                        'visibility': ['app'],
                      },
                    },
                  },
                ],
              };
            case 'tools/call':
              calls++;
              result = {
                'content': [
                  {'type': 'text', 'text': 'actual-effect-$calls'},
                ],
                'structuredContent': {'count': calls},
              };
            case 'ping':
              result = {};
            default:
              result = null;
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': rpc['id'],
              if (result == null)
                'error': {'code': -32601, 'message': 'Method not found'}
              else
                'result': result,
            }),
          );
          await request.response.close();
        });
        try {
          store.put('mcp/personal/library', {
            'id': 'library',
            'name': 'Library',
            'status': 'ready',
            'url': 'https://example.com/mcp',
            'catalog_id': 'fixture',
          }, null);
          store.put('task/personal/task', {
            'status': 'completed',
            'events': [],
            'artifacts': [],
          }, null);
          final owner = ToolExecution(
            store,
            'personal',
            'task',
            TurnContract(
              mode: 'workflow',
              imageLimit: 0,
              connectionIds: ['library'],
            ),
            requestIdentity: 'original',
            requestText: '请发送到 archive',
          )..bind();
          final service = FixtureMcpConnections(
            store,
            server.port,
            readOnly: !send,
            userAuthorized: send,
          );
          final connection = (await service.selected('personal', [
            'library',
          ])).single;
          final surface = <String, dynamic>{
            'request_identity': owner.requestIdentity,
            'request_text': '请发送到 archive',
            'connection_id': 'library',
            'connection_binding': ToolExecution.digest(
              service.authorizationBinding(connection),
            ),
            'selection': {
              'selected_mcp_connections': ['library'],
              'network_mode': 'off',
            },
          };
          Future<XiaoqiAgentTurnResult> run(
            String call, {
            Map<String, dynamic>? approval,
          }) =>
              GenkitXiaoqiAgentRuntime(
                store,
                ImageService(store, apiKey: 'unused-fixture'),
                mcpConnections: service,
              ).runMcpAppAction(
                tenantId: 'personal',
                taskId: 'task',
                surface: surface,
                tool: tool,
                arguments: send ? {'destination': 'archive'} : {},
                callId: call,
                approval: approval,
                cancellation: CancellationController().token,
                onProcessEvent: (_) {},
              );
          final first = await run('one');
          if (send) {
            expect(first.finishReason, AgentFinishReason.interrupted);
            expect(calls, 0);
            final pending = first.messages
                .expand((message) => message.content)
                .where((part) => part.isToolRequest)
                .firstWhere((part) => part.metadata?['interrupt'] is Map);
            final grant = pending.metadata!['interrupt'] as Map;
            final approved = await run(
              'one',
              approval: {
                'approved': true,
                'approval_hash': grant['approval_hash'],
              },
            );
            expect(jsonDecode(approved.text)['status'], 'completed');
            expect(calls, 1);
            await run(
              'one',
              approval: {
                'approved': true,
                'approval_hash': grant['approval_hash'],
              },
            );
            expect(calls, 1);
          } else {
            expect(jsonDecode(first.text)['status'], 'completed');
            expect(calls, 1);
            await run('one');
            expect(calls, 1);
            final refreshed = await run('two');
            expect(calls, 2);
            expect(jsonDecode(refreshed.text)['structuredContent']['count'], 2);
            final task = store.get('task/personal/task')!;
            store.put('task/personal/task', {
              ...task.value,
              'code_execution_runs': const ExecutionLimits().toolOperations,
            }, task.revision);
            await expectLater(
              run('three'),
              throwsA(
                predicate<Object>(
                  (error) => error.toString().contains('已达到本轮操作数量上限'),
                ),
              ),
            );
            expect(calls, 2);
            final beforeModel = store.get('task/personal/task')!;
            store.put('task/personal/task', {
              ...beforeModel.value,
              'code_execution_runs': 0,
              'model_request_runs': const ExecutionLimits().modelRequests,
            }, beforeModel.revision);
            final noProvider = await run('four');
            expect(jsonDecode(noProvider.text)['status'], 'completed');
            expect(calls, 3);
            expect(
              store.get('task/personal/task')!.value['model_request_runs'],
              const ExecutionLimits().modelRequests,
            );
          }
        } finally {
          await serving.cancel();
          await server.close(force: true);
          store.close();
          await directory.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
