import 'dart:convert';
import 'dart:io';
import 'package:genkit/genkit.dart';
import 'package:genkit_mcp/genkit_mcp.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/mcp_connection_service.dart';
import 'package:xiaoqi_genkit_server/src/public_agent_process.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class FixtureMcpConnections extends McpConnectionService {
  FixtureMcpConnections(super.store, this.port);
  final int port;
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
  final root = await Directory.systemTemp.createTemp('mcp-runtime-');
  final store = CloudStore(root: root.path);
  final rpc = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var calls = 0;
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
          {
            'name': 'make_card',
            'description': 'Return a real image card',
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
    if (body['method'] == 'tools/call') calls++;
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
  }, null);
  store.put('task/personal/turn', {'artifacts': [], 'events': []}, null);
  final runtime = GenkitXiaoqiAgentRuntime(
    store,
    ImageService(store),
    mcpConnections: FixtureMcpConnections(store, rpc.port),
  );
  final request = <String, dynamic>{
    'model_id': 'mimo-v2.6-flash',
    'current_turn_text': '请用 MCP 生成图片卡片',
    'selected_mcp_connections': [
      {'id': 'library'},
    ],
  };
  final events = <Map<String, Object?>>[];
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
        {'role': 'user', 'content': '请用 MCP 生成图片卡片'},
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
    if (pendingRequests.isEmpty)
      throw StateError('Expected an MCP approval interrupt');
    final pending = pendingRequests.last;
    final approval = pending.metadata!['interrupt'] as Map;
    final next = await runtime.runAgentTurn(
      tenantId: 'personal',
      taskId: 'turn',
      request: request,
      messages: first.messages,
      restart: [
        pending.restart({
          'approved': true,
          'approval_hash': approval['approval_hash'],
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
      'RESULT:${jsonEncode({'text': next.text, 'missing': next.extensionEvidenceMissing, 'before_approval': beforeApproval, 'mcp_calls': calls, 'artifacts': artifacts.length, 'mcp_status': lastMcp['status'], 'events': events})}',
    );
  } finally {
    await rpc.close(force: true);
    await serving.cancel();
    store.close();
    await root.delete(recursive: true);
  }
}
