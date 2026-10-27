import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/isolated_mcp_spec.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

/// Real Docker/official-package gate. No model or image-provider calls.
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('xiaoqi-stdio-gate-');
  final store = CloudStore(root: directory.path);
  final executor = DockerCodeExecutionService(store);
  const tenant = 'stdio-verification';
  const task = 'filesystem-roundtrip';
  final cancellation = CancellationController();
  try {
    store.put('task/$tenant/$task', {
      'status': 'running',
      'artifacts': [],
      'events': [],
    }, null);
    final config = {
      'command': 'npx',
      'args': [
        '-y',
        '@modelcontextprotocol/server-filesystem@2.0.1',
        '/workspace/output',
      ],
    };
    final files = IsolatedMcpSpec.installationFiles(config, {});
    files.addAll(await executor.prepareDependencies(tenant, files));
    final spec = IsolatedMcpSpec.resolve(config, files);
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
        name: 'stdio-verification',
        mcpServer: McpServerConfig(
          transport: transport,
          timeout: const Duration(seconds: 20),
        ),
      ),
    );
    var tools = 0;
    try {
      await client.ready();
      tools = ((await client.listTools())['tools'] as List).length;
      if (tools < 10)
        throw StateError('Official filesystem tool discovery incomplete');
      final write = await client.callTool(
        name: 'write_file',
        arguments: {
          'path': '/workspace/output/roundtrip.txt',
          'content': 'isolated-stdio-roundtrip',
        },
      );
      final read = await client.callTool(
        name: 'read_text_file',
        arguments: {'path': '/workspace/output/roundtrip.txt'},
      );
      final outside = await client.callTool(
        name: 'read_text_file',
        arguments: {'path': '/etc/passwd'},
      );
      if (write['isError'] == true ||
          read['isError'] == true ||
          !jsonEncode(read).contains('isolated-stdio-roundtrip') ||
          outside['isError'] != true) {
        throw StateError(
          'Official filesystem roundtrip or directory boundary failed',
        );
      }
      await executor.snapshotMcp(tenant, task, transport);
      if ((store.get('task/$tenant/$task')!.value['artifacts'] as List)
              .length !=
          1) {
        throw StateError(
          'MCP artifact is unavailable before delivery verification',
        );
      }
      cancellation.cancel();
    } finally {
      await client.close();
      await executor.finishMcp(tenant, task, transport);
    }
    final artifacts =
        (store.get('task/$tenant/$task')!.value['artifacts'] as List)
            .whereType<Map>();
    final file = artifacts
        .where((item) => item['name'] == 'roundtrip.txt')
        .single;
    if (utf8.decode(store.getObject(file['object_key'].toString())) !=
        'isolated-stdio-roundtrip') {
      throw StateError('MCP output did not persist with intact bytes');
    }
    if (transport.completion?['cleanup_pending'] != false)
      throw StateError('MCP cleanup was not confirmed');
    stdout.writeln(
      jsonEncode({
        'gate': 'stdio-runtime',
        'passed': true,
        'tools': tools,
        'package': '@modelcontextprotocol/server-filesystem@2.0.1',
        'directory_boundary': true,
        'artifact_integrity': true,
        'cancel_cleanup': true,
      }),
    );
  } finally {
    store.close();
    await directory.delete(recursive: true);
  }
}
