import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:xiaoqi_genkit_server/src/code_execution_service.dart';
import 'package:xiaoqi_genkit_server/src/isolated_mcp_spec.dart';
import 'package:xiaoqi_genkit_server/src/mcp_app_surface.dart';
import 'package:xiaoqi_genkit_server/src/mcp_apps_transport.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_execution.dart';
import 'package:xiaoqi_genkit_server/src/turn_contract.dart';

/// Published upstream App runs offline in the production isolated stdio path.
Future<void> verifyMcpApps(
  CloudStore store,
  DockerCodeExecutionService executor,
  String tenant,
) async {
  const task = 'official-mcp-app';
  const package = '@modelcontextprotocol/server-basic-vanillajs@2.0.4';
  final config = {
    'command': 'npx',
    'args': ['-y', package, '--stdio'],
  };
  final files = IsolatedMcpSpec.installationFiles(config, {});
  files.addAll(await executor.prepareDependencies(tenant, files));
  final lock =
      jsonDecode(utf8.decode(files['.xiaoqi/dependency-lock.json']!)) as Map;
  final installed =
      lock['npm']['packages']['node_modules/@modelcontextprotocol/server-basic-vanillajs']
          as Map;
  if (installed['version'] != '2.0.4' ||
      installed['integrity'] !=
          'sha512-L+IOxLjfX9oAwvnzLAMGX1pwBsIsXUsc9mB5iOTFuQ7lIaejetsrfYngPKwf9ZPHk9iCNVbHHaI7sj5dqax55Q==') {
    throw StateError('Official Apps package version/integrity changed');
  }
  store.put('task/$tenant/$task', {
    'status': 'running',
    'artifacts': [],
    'events': [],
  }, null);
  final execution = ToolExecution(
    store,
    tenant,
    task,
    TurnContract(mode: 'workflow', imageLimit: 0),
    requestIdentity: 'official-app-original',
  )..bind();
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
      name: 'official-app-acceptance',
      mcpServer: McpServerConfig(
        transport: McpAppsTransport(transport),
        timeout: const Duration(seconds: 20),
      ),
    ),
  );
  try {
    await client.ready();
    final tool = Map<String, dynamic>.from(
      ((await client.listTools())['tools'] as List).single as Map,
    );
    if (tool['name'] != 'get-time' ||
        McpAppMetadata.resourceUri(tool) != 'ui://get-time/mcp-app.html') {
      throw StateError('Published App tool/resource declaration changed');
    }
    final result = await client.callTool(name: 'get-time', arguments: {});
    if (DateTime.tryParse(
          (result['structuredContent'] as Map)['time'].toString(),
        ) ==
        null) {
      throw StateError('Published App tool did not return time');
    }
    var current = true;
    void check() {
      if (!current) throw StateError('App source revoked');
    }

    final surfaces = McpAppSurfaceStore(store, tenant, task);
    final output = await surfaces.publish(
      execution: execution,
      connectionId: 'official-app',
      connectionBinding: 'official-app-2.0.4',
      tool: tool,
      input: {},
      result: result,
      selection: {},
      readResource: (uri) => client.readResource(uri: uri),
      check: check,
    );
    if (output == null || jsonEncode(output).contains('<html'))
      throw StateError('HTML leaked into model result');
    final record = store
        .list('private_mcp_apps/$tenant/$task/')
        .single
        .$2
        .value;
    final surface = surfaces.load(
      record['id'] as String,
      check: (_) => check(),
    );
    if (!(surface['html'] as String).contains('Get Server Time'))
      throw StateError('Official App HTML missing');
    current = false;
    var refused = false;
    try {
      surfaces.load(record['id'] as String, check: (_) => check());
    } on StateError {
      refused = true;
    }
    if (!refused) throw StateError('Revoked App surface remained readable');
    stdout.writeln(
      jsonEncode({
        'gate': 'official-mcp-app',
        'passed': true,
        'package': package,
        'integrity_verified': true,
        'isolated_offline_stdio': true,
        'declared_resource_read': true,
        'owned_surface': true,
        'revocation_rechecked': true,
        'html_bytes': utf8.encode(surface['html'] as String).length,
      }),
    );
  } finally {
    await client.close();
  }
}
