import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

Future<void> main(List<String> args) async {
  final store = CloudStore(root: args[0]);
  final transport =
      await DockerCodeExecutionService(
        store,
        runnerUrl: Uri.parse(args[1]),
        runnerToken: 'r' * 40,
      ).connectMcp(
        tenantId: 'tenant',
        taskId: 'task',
        command: ['node', '/workspace/server.js'],
        environment: {'FIXTURE_PRIVATE_VALUE': 'must-not-be-journaled'},
        files: {},
        materials: [],
        cancellation: CancellationController().token,
      );
  if (args.length > 2 && args[2] == 'rpc') {
    final owner = ToolExecution(
      store,
      'tenant',
      'task',
      TurnContract(mode: 'workflow', imageLimit: 0),
      requestIdentity: 'human',
    )..bind();
    final client = createMcpClient(
      McpClientOptions(
        name: 'api-restart',
        mcpServer: McpServerConfig(transport: transport),
      ),
    );
    await client.ready();
    await owner.authorizedExternal(
      slot: 'effect',
      arguments: {'value': 'once'},
      invoke: (_) async =>
          await client.callTool(name: 'increment', arguments: {}),
    );
    throw StateError('Parent must terminate this API before its RPC response');
  }
  // Deliberately terminate the API owner without its normal transport cleanup.
  exit(0);
}
