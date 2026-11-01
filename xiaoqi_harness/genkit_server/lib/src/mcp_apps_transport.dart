import 'package:genkit_mcp/genkit_mcp.dart';
import 'mcp_app_surface.dart';

/// Adds the negotiated UI extension on the existing isolated JSON transport.
/// The original transport still owns requests, leases, replay and cancellation.
class McpAppsTransport implements McpClientTransport {
  McpAppsTransport(this.delegate);
  final McpClientTransport delegate;
  @override
  Stream<Map<String, dynamic>> get inbound => delegate.inbound;
  @override
  Future<void> close() => delegate.close();
  @override
  Future<void> send(Map<String, dynamic> message) {
    if (message['method'] != 'initialize') return delegate.send(message);
    final params = Map<String, dynamic>.from(message['params'] as Map);
    final capabilities = Map<String, dynamic>.from(
      params['capabilities'] as Map? ?? {},
    );
    final extensions = Map<String, dynamic>.from(
      capabilities['extensions'] as Map? ?? {},
    );
    extensions['io.modelcontextprotocol/ui'] = {
      'mimeTypes': [McpAppMetadata.mime],
    };
    capabilities['extensions'] = extensions;
    return delegate.send({
      ...message,
      'params': {...params, 'capabilities': capabilities},
    });
  }
}
