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
