import 'dart:convert';
import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/isolated_mcp_spec.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

/// Real PyPI install, stdio handshake and deterministic tool call. The time
/// server performs no outbound calls and needs no credentials or paid service.
Future<void> verifyPythonMcp(
  CloudStore store,
  DockerCodeExecutionService executor,
  String tenant,
) async {
  const task = 'python-mcp-roundtrip';
  store.put('task/$tenant/$task', {
    'status': 'running',
    'artifacts': [],
    'events': [],
  }, null);
  final config = {
    'command': 'uvx',
    'args': [
      '--with',
      'mcp>=1.29,<2',
      'mcp-server-time@2025.8.4',
      '--local-timezone',
      'UTC',
    ],
  };
  final files = IsolatedMcpSpec.installationFiles(config, {});
  files.addAll(await executor.prepareDependencies(tenant, files));
  final spec = IsolatedMcpSpec.resolve(config, files);
  final cancellation = CancellationController();
  final transport = await executor.connectMcp(
    tenantId: tenant,
    taskId: task,
    command: spec.command,
    environment: spec.environment,
    files: spec.files,
    materials: [],
    cancellation: cancellation.token,
  );
  final client = createMcpClient(
    McpClientOptions(
      name: 'python-mcp-verification',
      mcpServer: McpServerConfig(
        transport: transport,
        timeout: const Duration(seconds: 20),
      ),
    ),
  );
  try {
    await client.ready();
    final tools = (await client.listTools())['tools'] as List;
    if (!tools.whereType<Map>().any((tool) => tool['name'] == 'convert_time')) {
      throw StateError('Python MCP console entry did not expose time tools');
    }
    final converted = await client.callTool(
      name: 'convert_time',
      arguments: {
        'source_timezone': 'UTC',
        'time': '12:00',
        'target_timezone': 'Asia/Shanghai',
      },
    );
    final encoded = jsonEncode(converted);
    if (converted['isError'] == true ||
        !encoded.contains('Asia/Shanghai') ||
        !encoded.contains('20:00')) {
      throw StateError('Python MCP deterministic conversion failed: $encoded');
    }
  } finally {
    cancellation.cancel();
    await client.close();
    await executor.finishMcp(tenant, task, transport);
  }
  if (transport.completion?['cleanup_pending'] != false) {
    throw StateError('Python MCP cleanup was not confirmed');
  }
}
