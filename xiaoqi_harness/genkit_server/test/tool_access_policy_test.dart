import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/mcp_connection_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';
import 'package:xiaoqi_genkit_server/src/tool_access_policy.dart';
import 'package:xiaoqi_genkit_server/src/isolated_mcp_spec.dart';

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
  test(
    'isolated startup and calls share the immutable plugin availability check',
    () {
      final root = Directory.systemTemp.createTempSync('isolated-current-');
      final store = CloudStore(root: root.path);
      final service = _CatalogConnections(store);
      final connection = McpConnectionCredentials(
        id: 'isolated',
        name: 'Plugin',
        url: Uri.parse('isolated://workspace/plugin'),
        bearerToken: null,
        isolated: IsolatedMcpSpec(
          ['node', 'server.js'],
          {},
          {},
          capabilityId: 'plugin',
          versionId: 'v1',
        ),
      );
      store.put('cap/personal/plugin', {
        'enabled': true,
        'versions': [
          {'id': 'v1'},
        ],
      }, null);
      try {
        expect(service.isCurrent('personal', connection), true);
        expect(service.isCurrent('other', connection), false);
        var record = store.get('cap/personal/plugin')!;
        store.put('cap/personal/plugin', {
          ...record.value,
          'enabled': false,
        }, record.revision);
        expect(service.isCurrent('personal', connection), false);
        record = store.get('cap/personal/plugin')!;
        store.put('cap/personal/plugin', {
          'enabled': true,
          'versions': [
            {'id': 'v2'},
          ],
        }, record.revision);
        expect(service.isCurrent('personal', connection), false);
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );
  test('availability and explicit denial cannot be overridden by a grant', () {
    expect(
      ToolAccessPolicy.decide(
        effect: ToolEffect.send,
        hasExactUserGrant: true,
        available: false,
      ),
      ToolAccessDecision.unavailable,
    );
    expect(
      ToolAccessPolicy.decide(
        effect: ToolEffect.send,
        hasExactUserGrant: true,
        hasUserDenial: true,
      ),
      ToolAccessDecision.deny,
    );
    expect(
      ToolAccessPolicy.decide(effect: ToolEffect.read, hasUserDenial: true),
      ToolAccessDecision.deny,
    );
  });

  test(
    'approval identity binds all arguments separately from authority and scope',
    () {
      String hash(
        Map<String, dynamic> arguments, {
        String request = 'turn',
        Map<String, dynamic> authority = const {
          'url': 'https://example.com/mcp',
          'revision': 1,
        },
      }) => ToolAccessPolicy.actionHash(
        connectionId: 'c',
        tool: 'send',
        requestIdentity: request,
        authority: authority,
        arguments: arguments,
      );
      final original = hash({
        'to': 'a@example.com',
        'body': {'x': 1, 'y': 2},
      });
      expect(
        hash({
          'body': {'y': 2, 'x': 1},
          'to': 'a@example.com',
        }),
        original,
      );
      expect(
        hash({
          'to': 'b@example.com',
          'body': {'x': 1, 'y': 2},
        }),
        isNot(original),
      );
      expect(
        hash({
          'to': 'a@example.com',
          'body': {'x': 1, 'y': 2},
        }, request: 'updated'),
        isNot(original),
      );
      expect(
        hash(
          {
            'to': 'a@example.com',
            'body': {'x': 1, 'y': 2},
          },
          authority: {'url': 'https://other.example/mcp', 'revision': 1},
        ),
        isNot(original),
      );
      expect(
        hash(
          {
            'to': 'a@example.com',
            'body': {'x': 1, 'y': 2},
          },
          authority: {'url': 'https://example.com/mcp', 'revision': 2},
        ),
        isNot(original),
      );
      expect(
        hash({'_turn_identity': 'a'}),
        isNot(hash({'_turn_identity': 'b'})),
      );
      expect(hash({'_authority': 'a'}), isNot(hash({'_authority': 'b'})));
    },
  );

  test(
    'selected connections recheck disablement, configuration revision and tenant',
    () async {
      final root = Directory.systemTemp.createTempSync('tool-current-');
      final store = CloudStore(root: root.path);
      final service = _CatalogConnections(store);
      const key = 'mcp/personal/owned';
      store.put(key, {
        'id': 'owned',
        'name': 'Library',
        'url': 'https://example.com/mcp',
        'catalog_id': 'library',
        'status': 'ready',
      }, null);
      try {
        final selected = (await service.selected('personal', ['owned'])).single;
        expect(service.isCurrent('personal', selected), true);
        expect(service.isCurrent('other', selected), false);
        var current = store.get(key)!;
        store.put(key, {
          ...current.value,
          'name': 'Renamed',
          'tool_count': 99,
          'updated_at': 'health-refresh',
        }, current.revision);
        expect(
          service.isCurrent('personal', selected),
          true,
          reason:
              'A health or presentation update must not revoke the actual connection authority',
        );
        current = store.get(key)!;
        store.put(key, {
          ...current.value,
          'encrypted_bearer_token': {'changed': true},
        }, current.revision);
        expect(service.isCurrent('personal', selected), false);
        current = store.get(key)!;
        store.put(key, {...current.value, 'enabled': false}, current.revision);
        await expectLater(
          service.selected('personal', ['owned']),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'reason',
              contains('停用'),
            ),
          ),
        );
        store.delete(key);
        expect(service.isCurrent('personal', selected), false);
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );

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
