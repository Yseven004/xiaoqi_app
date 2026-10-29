import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';
import 'mcp_restart_gate.dart';

Future<void> verifyMcpApiRestart(String mode, String root) async {
  final store = CloudStore(root: root);
  final executor = DockerCodeExecutionService(store);
  const tenant = 'stdio-verification';
  const task = 'api-pending-restart';
  ToolExecution owner() => ToolExecution(
    store,
    tenant,
    task,
    TurnContract(mode: 'workflow', imageLimit: 0),
    requestIdentity: 'original-human',
  )..bind();
  try {
    if (mode == '--mcp-api-start') {
      store.put('task/$tenant/$task', {
        'status': 'running',
        'artifacts': [],
        'events': [],
      }, null);
      final transport = await executor.connectMcp(
        tenantId: tenant,
        taskId: task,
        command: ['node', '/workspace/skill/restart.mjs'],
        environment: {},
        files: {
          'restart.mjs': utf8.encode(mcpRestartFixtureScript),
          'original-input.txt': utf8.encode('original input snapshot'),
        },
        materials: [],
        cancellation: CancellationController().token,
      );
      final client = createMcpClient(
        McpClientOptions(
          name: 'api-pending-probe',
          mcpServer: McpServerConfig(
            transport: transport,
            timeout: const Duration(seconds: 60),
          ),
        ),
      );
      await client.ready();
      await client.listTools();
      final pending = owner().authorizedExternal(
        slot: 'increment-once',
        arguments: {},
        invoke: (_) => client.callTool(name: 'increment', arguments: {}),
      );
      // Attach an error listener while checking the original process's file.
      final result = pending.then<Object?>(
        (value) => value,
        onError: (Object e) => e,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (true) {
        final artifacts = (await transport.snapshotArtifacts() as List)
            .whereType<Map>();
        final counter = artifacts
            .where((a) => a['name'] == 'counter.json')
            .firstOrNull;
        if (counter != null) {
          final before = jsonDecode(
            utf8.decode(base64Decode(counter['base64'])),
          );
          store.put('gate/api-before', {
            'value': before,
            'lease_id': transport.leaseId,
          }, null);
          stdout.writeln('MCP_API_RESTART_READY');
          await result;
          throw StateError(
            'CI did not terminate the API while the original response was pending',
          );
        }
        if (DateTime.now().isAfter(deadline))
          throw StateError('Original effect did not start');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (mode != '--mcp-api-recover')
      throw StateError('Invalid API restart gate mode');
    final before = store.get('gate/api-before')!.value['value'] as Map;
    await executor.recoverMcpLeases(tenantId: tenant, taskId: task);
    final cached = await owner().authorizedExternal(
      slot: 'increment-once',
      arguments: {},
      invoke: (_) async =>
          throw StateError('Recovered effect attempted replay'),
    );
    final value =
        jsonDecode((cached['content'] as List).whereType<Map>().single['text'])
            as Map;
    final state = store.get('task/$tenant/$task')!.value;
    final artifact = (state['artifacts'] as List).whereType<Map>().single;
    final bytes = store.getObject(artifact['object_key']);
    if (value['count'] != 1 ||
        value['boot'] != before['boot'] ||
        value['pid'] != before['pid'] ||
        value['input'] != 'original input snapshot' ||
        value['source_hash'] !=
            sha256.convert(utf8.encode(mcpRestartFixtureScript)).toString() ||
        (jsonDecode(utf8.decode(bytes)) as Map)['count'] != 1 ||
        artifact['sha256'] != sha256.convert(bytes).toString() ||
        state['code_execution_runs'] != 1 ||
        (state['scope_operations'] as Map).length != 1 ||
        store.list('private_mcp_lease/$tenant/$task/').isNotEmpty ||
        store.list('private_mcp_rpc/$tenant/$task/').isNotEmpty) {
      throw StateError(
        'API restart lost or replayed the original effect/result/process/files/budget',
      );
    }
    stdout.writeln(
      jsonEncode({
        'gate': 'mcp-api-restart',
        'passed': true,
        'original_response': true,
        'original_process': true,
        'one_effect': true,
        'original_input_and_files': true,
        'single_budget_charge': true,
      }),
    );
  } finally {
    store.close();
  }
}
