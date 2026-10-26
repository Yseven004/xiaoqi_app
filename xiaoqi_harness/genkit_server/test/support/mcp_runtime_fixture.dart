import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/mcp_connection_service.dart';
import 'package:xiaoqi_genkit_server/src/public_agent_process.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_access_policy.dart';

class FixtureMcpConnections extends McpConnectionService {
  FixtureMcpConnections(
    super.store,
    this.port, {
    this.readOnly = false,
    this.toolCount = 1,
  });
  final int port;
  final bool readOnly;
  final int toolCount;
  @override
  List<McpCatalogEntry> catalog() => [
    McpCatalogEntry(
      id: 'fixture',
      name: 'Library',
      description: 'Fixture library',
      url: Uri.parse('https://example.com/mcp'),
      version: '1',
      runtime: 'remote_https',
      authMode: 'none',
      status: 'verified',
      toolEffects: {
        if (readOnly && toolCount == 1) 'fetch_card': ToolEffect.read,
        if (readOnly && toolCount > 1)
          for (var i = 0; i < toolCount; i++) 'fetch_card_$i': ToolEffect.read,
      },
    ),
  ];
  @override
  Future<GenkitMcpClient> connect(McpConnectionCredentials connection) async {
    final client = createMcpClient(
      McpClientOptions(
        name: 'fixture',
        serverName: 'fixture',
        mcpServer: McpServerConfig(
          url: Uri.parse('http://127.0.0.1:$port/mcp'),
        ),
      ),
    );
    await client.ready();
    return client;
  }
}

Future<void> main(List<String> args) async {
  final readOnly = const {'mcp-read', 'mcp-large'}.contains(args.single);
  final toolCount = args.single == 'mcp-large' ? 120 : 1;
  final userText = readOnly ? '请读取 MCP 中已有的图片卡片' : '请用 MCP 生成图片卡片';
  final root = await Directory.systemTemp.createTemp('mcp-runtime-');
  final store = CloudStore(root: root.path);
  final rpc = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var calls = 0;
  final calledTools = <String>[];
  final serving = rpc.listen((request) async {
    if (request.method != 'POST') {
      request.response.statusCode = 405;
      await request.response.close();
      return;
    }
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    if (body['id'] == null) {
      request.response.statusCode = 202;
      await request.response.close();
      return;
    }
    if (!const {
      'initialize',
      'tools/list',
      'tools/call',
      'ping',
    }.contains(body['method'])) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': body['id'],
          'error': {'code': -32601, 'message': 'Method not found'},
        }),
      );
      await request.response.close();
      return;
    }
    final result = switch (body['method']) {
      'initialize' => {
        'protocolVersion': '2025-11-25',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'fixture', 'version': '1'},
      },
      'tools/list' => {
        'tools': [
          for (var i = 0; i < toolCount; i++)
            {
              'name': toolCount > 1
                  ? 'fetch_card_$i'
                  : readOnly
                  ? 'fetch_card'
                  : 'make_card',
              'description': 'Return a real image card',
              'annotations': {'readOnlyHint': true},
              'inputSchema': {
                'type': 'object',
                'properties': {},
                'additionalProperties': false,
              },
            },
        ],
      },
      'tools/call' =>
        args.single == 'mcp-error'
            ? {
                'isError': true,
                'content': [
                  {'type': 'text', 'text': 'permission denied'},
                ],
              }
            : {
                'content': [
                  {
                    'type': 'image',
                    'mimeType': 'image/png',
                    'data':
                        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jGJ0AAAAASUVORK5CYII=',
                  },
                ],
              },
      _ => {},
    };
    if (body['method'] == 'tools/call') {
      calls++;
      calledTools.add((body['params'] as Map)['name'].toString());
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
    );
    await request.response.close();
  });
  store.put('mcp/personal/library', {
    'id': 'library',
    'name': 'Library',
    'status': 'ready',
    'url': 'https://example.com/mcp',
    'catalog_id': 'fixture',
  }, null);
  store.put('task/personal/turn', {'artifacts': [], 'events': []}, null);
  final runtime = GenkitXiaoqiAgentRuntime(
    store,
    ImageService(store),
    mcpConnections: FixtureMcpConnections(
      store,
      rpc.port,
      readOnly: readOnly,
      toolCount: toolCount,
    ),
  );
  final request = <String, dynamic>{
    'model_id': 'mimo-v2.6-flash',
    'current_turn_text': userText,
    'selected_mcp_connections': [
      {'id': 'library'},
    ],
  };
  final events = <Map<String, Object?>>[];
  // One dev instance installs process-wide instrumentation for the real agent
  // loop. Runtime instances keep reflection disabled; this owner shuts it down.
  final telemetry =
      (Platform.environment['GENKIT_TELEMETRY_SERVER'] ?? '').isEmpty
      ? null
      : Genkit(promptDir: null, isDevEnv: true);
  final process = PublicAgentProcess('mcp');
  void event(Map<String, Object?> value) {
    events.add(value);
    process.add(value);
  }

  try {
    final first = await runtime.runAgentTurn(
      tenantId: 'personal',
      taskId: 'turn',
      request: request,
      messages: agentMessagesFromRequest([
        {'role': 'user', 'content': userText},
      ]),
      onChunk: (_) {},
      onProcessEvent: event,
      cancellation: CancellationController().token,
    );
    final beforeApproval = calls;
    final pendingRequests = first.messages
        .expand((message) => message.content)
        .where(
          (part) => part.isToolRequest && part.metadata?['interrupt'] is Map,
        )
        .map(
          (part) => ToolRequestPart(
            toolRequest: part.toolRequest!,
            metadata: part.metadata,
          ),
        )
        .toList();
    if (!readOnly && pendingRequests.isEmpty)
      throw StateError('Expected an MCP approval interrupt');
    if (readOnly && pendingRequests.isNotEmpty)
      throw StateError('Read-only MCP unexpectedly required confirmation');
    final pending = pendingRequests.lastOrNull;
    final approval = pending?.metadata?['interrupt'] as Map?;
    final next = readOnly
        ? first
        : await runtime.runAgentTurn(
            tenantId: 'personal',
            taskId: 'turn',
            request: request,
            messages: first.messages,
            restart: [
              pending!.restart({
                'approved': true,
                'approval_hash': approval!['approval_hash'],
              }),
            ],
            onChunk: (_) {},
            onProcessEvent: event,
            cancellation: CancellationController().token,
          );
    final artifacts =
        store.get('task/personal/turn')!.value['artifacts'] as List;
    final lastMcp = process.rows.where((row) => row['tool'] == 'mcp_tool').last;
    stdout.writeln(
      'RESULT:${jsonEncode({'text': next.text, 'missing': next.extensionEvidenceMissing, 'before_approval': beforeApproval, 'mcp_calls': calls, 'called_tools': calledTools, 'artifacts': artifacts.length, 'mcp_status': lastMcp['status'], 'events': events})}',
    );
  } finally {
    await rpc.close(force: true);
    await serving.cancel();
    store.close();
    await root.delete(recursive: true);
    await telemetry?.shutdown();
  }
}
