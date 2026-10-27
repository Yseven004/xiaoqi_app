import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/mcp_connection_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

void main() {
  late Directory root;
  late CloudStore store;
  late McpConnectionService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('xiaoqi-mcp-test-');
    store = CloudStore(root: root.path);
    service = McpConnectionService(store, pepper: 'test-pepper-' * 4);
  });

  tearDown(() async {
    store.close();
    await root.delete(recursive: true);
  });

  test(
    'task selection keeps healthy components and tenant-safe failure details',
    () async {
      final healthy = await service.save('tenant-a', {
        'name': 'Healthy',
        'url': 'https://example.com/mcp',
      });
      final disabled = await service.save('tenant-a', {
        'name': 'Disabled',
        'url': 'https://example.com/disabled',
        'enabled': false,
      });
      final disabledKey = 'mcp/tenant-a/${disabled['id']}';
      final disabledDocument = store.get(disabledKey)!;
      store.put(disabledKey, {
        ...disabledDocument.value,
        'enabled': false,
      }, disabledDocument.revision);
      final broken = await service.save('tenant-a', {
        'name': 'Broken',
        'url': 'https://example.com/broken',
        'bearer_token': 'never-expose-this',
      });
      final brokenKey = 'mcp/tenant-a/${broken['id']}';
      final document = store.get(brokenKey)!;
      store.put(brokenKey, {
        ...document.value,
        'encrypted_bearer_token': {
          'version': 99,
          'ciphertext': 'never-expose-this',
        },
      }, document.revision);
      final other = await service.save('tenant-b', {
        'name': 'Other private name',
        'url': 'https://example.com/other',
        'bearer_token': 'other-secret',
      });
      final selected = await service.selectedForTask('tenant-a', [
        disabled['id'],
        broken['id'],
        other['id'],
        healthy['id'],
        healthy['id'],
      ]);
      expect(selected.connections.map((c) => c.id), [healthy['id']]);
      expect(selected.unavailable, hasLength(3));
      expect(selected.unavailable[0]['message'], contains('已停用'));
      expect(selected.unavailable[1]['message'], contains('重新保存'));
      expect(selected.unavailable[2]['name'], 'MCP 连接器');
      final encoded = jsonEncode(selected.unavailable);
      expect(encoded, isNot(contains('never-expose-this')));
      expect(encoded, isNot(contains('Other private name')));
      expect(encoded, isNot(contains('other-secret')));
    },
  );

  test(
    'task selection rejects malformed requests without silently dropping IDs',
    () async {
      for (final request in [
        42,
        ['../escape'],
        List.generate(9, (i) => 'connection-$i'),
      ]) {
        await expectLater(
          service.selectedForTask('tenant-a', request),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'stores bearer tokens encrypted and keeps records tenant-scoped',
    () async {
      final publicRecord = await service.save('tenant-a', {
        'name': 'GitHub',
        'url': 'https://api.githubcopilot.com/mcp/',
        'bearer_token': 'user-secret-token',
      });
      final id = publicRecord['id'] as String;
      final stored = store.get('mcp/tenant-a/$id')!.value;

      expect(jsonEncode(stored), isNot(contains('user-secret-token')));
      expect(publicRecord['has_bearer_token'], isTrue);
      expect(publicRecord.containsKey('bearer_token'), isFalse);
      expect(publicRecord.containsKey('encrypted_bearer_token'), isFalse);
      expect(
        (await service.selected('tenant-a', [id])).single.bearerToken,
        'user-secret-token',
      );
      await expectLater(
        service.selected('tenant-b', [id]),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('updates connection settings without erasing its saved token', () async {
    final saved = await service.save('tenant-a', {
      'name': 'One',
      'url': 'https://example.com/mcp',
      'bearer_token': 'keep-this-token',
      'keywords': [' 论文总结 ', '论文总结', '文献阅读'],
    });
    final updated = await service.save('tenant-a', {
      'id': saved['id'],
      'name': 'Renamed',
      'url': 'https://example.com/new-mcp',
      'bearer_token': '',
    });

    expect(updated['name'], 'Renamed');
    expect(updated['keywords'], ['论文总结', '文献阅读']);
    final cleared = await service.save('tenant-a', {
      'id': saved['id'],
      'name': 'Renamed',
      'url': 'https://example.com/new-mcp',
      'keywords': <String>[],
    });
    expect(cleared['keywords'], isEmpty);
    expect(
      (await service.selected('tenant-a', [saved['id']])).single.bearerToken,
      'keep-this-token',
    );
  });

  test(
    'connection icons survive updates and reject executable or external content',
    () async {
      final saved = await service.save('icon-owner', {
        'name': 'My server',
        'url': 'https://example.com/mcp',
        'bearer_token': 'test-token',
        'icon': {'icon_asset': 'book', 'icon_data': ''},
      });
      final updated = await service.save('icon-owner', {
        'id': saved['id'],
        'name': 'Renamed',
        'url': 'https://example.com/mcp',
      });
      expect(updated['icon'], {'icon_asset': 'book', 'icon_data': ''});
      expect(updated['has_bearer_token'], isTrue);
      for (final data in [
        'https://example.com/icon.svg',
        'data:image/svg+xml;base64,${base64Encode(utf8.encode('<svg><script>alert(1)</script></svg>'))}',
      ]) {
        await expectLater(
          service.save('icon-owner', {
            'id': saved['id'],
            'name': 'Renamed',
            'url': 'https://example.com/mcp',
            'icon': {'icon_asset': 'mcp', 'icon_data': data},
          }),
          throwsFormatException,
        );
      }
      expect(service.list('icon-owner').single['icon'], updated['icon']);
    },
  );

  test('accepts public HTTPS endpoints and rejects unsafe URL forms', () {
    expect(
      McpConnectionService.parseRemoteUrl(
        'https://api.githubcopilot.com/mcp/',
      ).scheme,
      'https',
    );
    for (final url in [
      'http://example.com/mcp',
      'https://localhost/mcp',
      'https://127.0.0.1/mcp',
      'https://user:password@example.com/mcp',
      'https://example.com/mcp?token=secret',
    ]) {
      expect(
        () => McpConnectionService.parseRemoteUrl(url),
        throwsA(isA<FormatException>()),
        reason: 'should reject $url',
      );
    }
  });

  test(
    'draft test uses temporary credentials without storing a connection',
    () async {
      McpConnectionCredentials? seen;
      final preview = McpConnectionService(
        store,
        discoverTools: (connection) async {
          seen = connection;
          return [
            {'name': 'search', 'description': 'Search documents'},
          ];
        },
      );
      final result = await preview.testDraft('tenant-a', {
        'name': 'Draft',
        'url': 'https://example.com/mcp',
        'bearer_token': 'temporary-secret',
      });
      expect(seen!.bearerToken, 'temporary-secret');
      expect(result['saved'], isFalse);
      expect(result['tool_count'], 1);
      expect(jsonEncode(result), isNot(contains('temporary-secret')));
      expect(store.list('mcp/'), isEmpty);
    },
  );

  test(
    'draft edits keep stored credentials tenant-scoped and never forward them to another host',
    () async {
      final saved = await service.save('tenant-a', {
        'name': 'Original',
        'url': 'https://example.com/mcp',
        'bearer_token': 'saved-secret',
      });
      final before = jsonEncode(
        store.get('mcp/tenant-a/${saved['id']}')!.value,
      );
      final preview = McpConnectionService(
        store,
        pepper: 'test-pepper-' * 4,
        discoverTools: (connection) async {
          expect(connection.bearerToken, 'saved-secret');
          return [];
        },
      );
      await preview.testDraft('tenant-a', {
        'id': saved['id'],
        'name': 'Unsaved name',
        'url': 'https://example.com/new',
      });
      expect(
        jsonEncode(store.get('mcp/tenant-a/${saved['id']}')!.value),
        before,
      );
      await expectLater(
        preview.testDraft('tenant-b', {
          'id': saved['id'],
          'name': 'No access',
          'url': 'https://example.com/mcp',
        }),
        throwsStateError,
      );
      await expectLater(
        preview.testDraft('tenant-a', {
          'id': saved['id'],
          'name': 'Other host',
          'url': 'https://other.example/mcp',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'draft tests reject unsafe inputs and hide transport credentials in errors',
    () async {
      final preview = McpConnectionService(
        store,
        discoverTools: (_) async => throw Exception('Bearer private-value'),
      );
      for (final input in [
        {'name': '', 'url': 'https://example.com/mcp'},
        {'name': 'Bad', 'url': 'https://localhost/mcp'},
        {'name': 'Bad', 'url': 'https://127.0.0.1/mcp'},
        {
          'name': 'Bad',
          'url': 'https://example.com/mcp',
          'bearer_token': 'secret\r\nInjected: yes',
        },
      ]) {
        await expectLater(
          preview.testDraft('tenant-a', input),
          throwsFormatException,
        );
      }
      await expectLater(
        preview.testDraft('tenant-a', {
          'name': 'Good',
          'url': 'https://example.com/mcp',
        }),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'redacted error',
            isNot(contains('private-value')),
          ),
        ),
      );
      expect(store.list('mcp/'), isEmpty);
    },
  );

  test(
    'normalizes verified catalog entries without exposing OAuth secrets',
    () {
      final entry = McpCatalogEntry.fromJson({
        'id': 'github',
        'name': 'GitHub',
        'description': 'Repository tools',
        'url': 'https://example.com/mcp',
        'version': '1.2.3',
        'auth_mode': 'oauth',
        'status': 'verified',
        'client_secret': 'do-not-return',
        'keywords': ['代码仓库'],
        'scopes': ['repo'],
      });

      expect(entry, isNotNull);
      expect(entry!.requiresLogin, isTrue);
      expect(entry.toPublic(), {
        'id': 'github',
        'name': 'GitHub',
        'description': 'Repository tools',
        'keywords': ['代码仓库'],
        'version': '1.2.3',
        'runtime': 'remote_https',
        'auth_mode': 'oauth',
        'status': 'verified',
      });
      expect(entry.toPublic().containsKey('client_secret'), isFalse);
    },
  );
}
