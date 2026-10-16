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
    });
    final updated = await service.save('tenant-a', {
      'id': saved['id'],
      'name': 'Renamed',
      'url': 'https://example.com/new-mcp',
      'bearer_token': '',
    });

    expect(updated['name'], 'Renamed');
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
}
