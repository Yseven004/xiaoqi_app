import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/mcp_connection_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_access_policy.dart';

class _CatalogConnections extends McpConnectionService {
  _CatalogConnections(super.store);

  @override
  List<McpCatalogEntry> catalog() => [
    McpCatalogEntry(
      id: 'library',
      name: 'Library',
      description: 'Library data',
      url: Uri.parse('https://example.com/mcp'),
      version: '1',
      runtime: 'remote_https',
      authMode: 'none',
      status: 'verified',
      toolEffects: const {
        'fetch': ToolEffect.read,
        'remove': ToolEffect.delete,
        'pretend_workspace': ToolEffect.workspace,
      },
    ),
  ];
}

void main() {
  test('safe task effects do not require repeated confirmation', () {
    for (final effect in [ToolEffect.read, ToolEffect.workspace]) {
      expect(ToolAccessPolicy.decide(effect: effect), ToolAccessDecision.allow);
    }
    for (final effect in [
      ToolEffect.write,
      ToolEffect.send,
      ToolEffect.delete,
      ToolEffect.payment,
      ToolEffect.unknown,
    ]) {
      expect(
        ToolAccessPolicy.decide(effect: effect),
        ToolAccessDecision.confirm,
      );
      expect(
        ToolAccessPolicy.decide(effect: effect, hasExactUserGrant: true),
        ToolAccessDecision.allow,
      );
    }
  });

  test(
    'remote effects require exact deployment-owned catalog identity and URL',
    () {
      final root = Directory.systemTemp.createTempSync('tool-policy-');
      final store = CloudStore(root: root.path);
      try {
        final service = _CatalogConnections(store);
        McpConnectionCredentials connection(
          String url, {
          String? catalogId = 'library',
        }) => McpConnectionCredentials(
          id: 'owned',
          name: 'Library',
          url: Uri.parse(url),
          bearerToken: null,
          catalogId: catalogId,
        );
        final owned = connection('https://example.com/mcp');
        expect(service.effectFor(owned, 'fetch'), ToolEffect.read);
        expect(service.effectFor(owned, 'remove'), ToolEffect.delete);
        expect(
          service.effectFor(owned, 'pretend_workspace'),
          ToolEffect.unknown,
        );
        expect(
          service.effectFor(owned, 'fetch_everything'),
          ToolEffect.unknown,
        );
        expect(
          service.effectFor(connection('https://other.example/mcp'), 'fetch'),
          ToolEffect.unknown,
        );
        expect(
          service.effectFor(
            connection('https://example.com/mcp', catalogId: null),
            'fetch',
          ),
          ToolEffect.unknown,
        );
        final advertised = McpCatalogEntry.fromJson({
          'id': 'other',
          'name': 'Other',
          'description': 'Tools',
          'url': 'https://example.com/mcp',
          'annotations': {'readOnlyHint': true},
        })!;
        expect(
          advertised.toolEffects,
          isEmpty,
          reason: 'Remote annotations must not turn into server effect rules',
        );
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}
