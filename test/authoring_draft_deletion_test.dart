import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_models.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'deleting a draft clears its private token and preserves the committed extension',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final store = CapabilityStore.instance;
      final draft = CapabilityDraft(
        id: 'delete-test',
        name: 'reading',
        description: 'Reading',
        content: '---\nname: reading\ndescription: Reading\n---\nRead',
        cloudOwnerEmail: 'owner@example.com',
        updatedAt: DateTime.utc(2026, 10, 24),
      );
      await store.saveAuthoringDraft(draft);
      const url = 'https://example.com/mcp';
      await store.saveDraftMcpToken(draft, 'private-test-token', url: url);
      final record = await store.commitDraft(draft);
      expect(await store.draftMcpToken(draft, url: url), 'private-test-token');
      expect(
        await store.draftMcpToken(draft, url: 'https://other.example.com/mcp'),
        isNull,
      );
      expect(draft.toJson().toString(), isNot(contains('private-test-token')));
      await store.deleteAuthoringDraft(draft);
      expect(await store.authoringDrafts('owner@example.com'), isEmpty);
      expect(await store.find(record.id), isNotNull);
      expect(await store.draftMcpToken(draft, url: url), isNull);
      expect((await store.pendingDraftDeletions()).single['id'], draft.id);
      expect(
        await store.skillPreview(draft.id, accountEmail: 'owner@example.com'),
        isNull,
      );
      FlutterSecureStorage.setMockInitialValues({
        'xiaoqi.capabilities.device_token.v1': 'test-token',
        'xiaoqi.auth.method.v1': 'email',
        'xiaoqi.auth.email.v1': 'owner@example.com',
      });
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path.endsWith('/health'))
            return http.Response(
              jsonEncode({
                'release_id': releaseId,
                'api_contract_version': apiContractVersion,
              }),
              200,
            );
          if (request.url.path.endsWith('/drafts'))
            return http.Response(
              jsonEncode({
                'items': [draft.toJson()],
              }),
              200,
            );
          if (request.method == 'DELETE')
            return http.Response('{"ok":true}', 200);
          if (request.method == 'POST')
            return http.Response('{"cloud_revision":1}', 200);
          return http.Response('{"items":[]}', 200);
        }),
      );
      await cloud.syncNow();
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().where(
        (key) => key.startsWith('xiaoqi_skill_authoring_'),
      )) {
        expect(prefs.getString(key), isNot(contains(draft.id)));
      }
      expect(await store.pendingDraftDeletions(), isEmpty);
    },
  );
}
