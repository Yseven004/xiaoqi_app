import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;

import '../lib/src/agent_runtime.dart';
import '../lib/src/api.dart';
import '../lib/src/image_service.dart';
import '../lib/src/mcp_server.dart';
import '../lib/src/store.dart';

Future<void> main() async {
  final store = CloudStore();
  store.removeOrphanedTempFiles();
  final imageService = ImageService(store);
  final api = XiaoqiApi(store, GenkitXiaoqiAgentRuntime(store, imageService));
  final mcp = XiaoqiMcpService(store, imageService);
  final mcpPort =
      int.tryParse(Platform.environment['MCP_PORT'] ?? '8081') ?? 8081;
  await mcp.start(port: mcpPort);
  final address = InternetAddress.anyIPv4;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;
  late final HttpServer server;
  try {
    server = await shelf_io.serve(
      api.handler,
      address,
      port,
      poweredByHeader: null,
    );
  } on Object {
    await mcp.close();
    store.checkpointWal();
    store.close();
    rethrow;
  }
  stdout.writeln(
    'Xiaoqi Genkit runtime listening on ${server.address.address}:${server.port}; MCP on :$mcpPort',
  );
  var shuttingDown = false;
  Future<void> shutdown() async {
    if (shuttingDown) return;
    shuttingDown = true;
    await server.close(force: false);
    await mcp.close();
    store.checkpointWal();
    store.close();
  }

  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await shutdown();
      exit(0);
    });
  }
  ProcessSignal.sigint.watch().listen((_) async {
    await shutdown();
    exit(0);
  });
}
