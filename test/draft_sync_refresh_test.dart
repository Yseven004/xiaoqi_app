import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_models.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_store.dart';

const owner = 'owner@example.com';
http.Response response(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
http.Response health() => response({
  'release_id': releaseId,
  'api_contract_version': apiContractVersion,
});
CapabilityDraft draft(String id, {String content = 'Instructions'}) =>
    CapabilityDraft(
      id: id,
      name: 'reading',
      description: 'Reading',
      content: content,
      cloudOwnerEmail: owner,
      updatedAt: DateTime.utc(2026, 10, 24),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = CapabilityStore.instance;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.clearSkillPreviews();
    FlutterSecureStorage.setMockInitialValues({
      'xiaoqi.capabilities.device_token.v1': 'test-token',
      'xiaoqi.auth.method.v1': 'email',
      'xiaoqi.auth.email.v1': owner,
    });
  });

  test(
    'queued uploads use the latest saved content and never downgrade revisions',
    () async {
      final entered = Completer<void>();
      final firstReply = Completer<http.Response>();
      var puts = 0;
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          final body = jsonDecode(request.body) as Map;
          final sent = Map<String, dynamic>.from(body['draft'] as Map);
          puts++;
          if (puts == 1) {
            expect(body['expected_revision'], 0);
            entered.complete();
            return firstReply.future;
          }
          expect(body['expected_revision'], 1);
          expect(sent['content'], 'New edit');
          return response({
            'draft': {...sent, 'cloud_revision': 2},
          });
        }),
      );
      final original = draft('queued');
      await store.saveAuthoringDraft(original);
      final first = cloud.syncAuthoringDraft(original);
      await entered.future;
      final edited = original.copyWith(content: 'New edit');
      await store.saveAuthoringDraft(edited);
      final second = cloud.syncAuthoringDraft(edited);
      await Future<void>.delayed(Duration.zero);
      expect(puts, 1);
      firstReply.complete(
        response({
          'draft': {
            ...original.toJson(includeLocalMetadata: false),
            'cloud_revision': 1,
          },
        }),
      );
      await first;
      await second;
      final saved = (await store.authoringDrafts(owner)).single;
      expect(saved.content, 'New edit');
      expect(saved.cloudRevision, 2);
      expect(saved.lastSyncedHash, skillDraftFingerprint(saved));
      await store.saveAuthoringDraft(original.copyWith(content: 'Third edit'));
      final third = (await store.authoringDrafts(owner)).single;
      expect(third.cloudRevision, 2);
      expect(third.syncIssue, DraftSyncIssue.conflict);
      expect(third.lastSyncedHash, original.lastSyncedHash);
      expect(third.content, 'Third edit');
    },
  );

  test(
    'a draft conflict cannot block installed records or another draft',
    () async {
      final baseline = draft('conflict', content: 'Base');
      final local = baseline.copyWith(
        content: 'Local',
        cloudRevision: 1,
        lastSyncedHash: skillDraftFingerprint(baseline),
      );
      final remote = baseline.copyWith(content: 'Remote', cloudRevision: 2);
      await store.saveAuthoringDraft(local);
      await store.saveAuthoringDraft(draft('healthy'));
      var capabilityReads = 0, healthyWrites = 0;
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          if (request.url.path.endsWith('/capabilities')) {
            capabilityReads++;
            return response({'items': []});
          }
          if (request.method == 'GET')
            return response({
              'items': [remote.toJson(includeLocalMetadata: false)],
            });
          final sent = (jsonDecode(request.body) as Map)['draft'] as Map;
          if (sent['id'] == 'conflict')
            return response({
              'error': {'current': remote.toJson(includeLocalMetadata: false)},
            }, 409);
          healthyWrites++;
          return response({
            'draft': {...sent, 'cloud_revision': 1},
          });
        }),
      );
      await cloud.syncNow();
      expect(capabilityReads, 1);
      expect(healthyWrites, 1);
      final drafts = await store.authoringDrafts(owner);
      expect(
        drafts.firstWhere((d) => d.id == 'conflict').syncIssue,
        DraftSyncIssue.conflict,
      );
      expect(drafts.firstWhere((d) => d.id == 'conflict').content, 'Local');
      expect(drafts.firstWhere((d) => d.id == 'healthy').cloudRevision, 1);
      await cloud.refreshCapabilityRecords();
      expect(capabilityReads, 1);
    },
  );

  test(
    'remote deletion preserves an edited local draft for recovery',
    () async {
      final local = draft('deleted').copyWith(cloudRevision: 1);
      await store.saveAuthoringDraft(local);
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          expect(request.method, 'GET');
          return response({
            'items': request.url.path.endsWith('/drafts')
                ? [
                    {
                      'id': local.id,
                      'deleted_at': '2026-10-24T00:00:00Z',
                      'cloud_revision': 2,
                    },
                  ]
                : [],
          });
        }),
      );
      await cloud.syncNow();
      final saved = (await store.authoringDrafts(owner)).single;
      expect(saved.content, local.content);
      expect(saved.syncIssue, DraftSyncIssue.deleted);
    },
  );

  test(
    'an acknowledged retry compares normalized content and skips later unchanged uploads',
    () async {
      final local = draft('retry');
      await store.saveAuthoringDraft(local);
      var puts = 0;
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          if (request.method == 'GET')
            return response({
              'items': [
                {
                  ...local.toJson(includeLocalMetadata: false),
                  'cloud_revision': 3,
                },
              ],
            });
          puts++;
          return response({
            'error': {
              'current': {
                ...local.toJson(includeLocalMetadata: false),
                'cloud_revision': 3,
                'presentation': {
                  'image_layout': 'horizontal',
                  'title': '',
                  'introduction': '',
                  'icon_asset': 'research',
                  'icon_data': '',
                  'images': [],
                },
              },
            },
          }, 409);
        }),
      );
      final synced = await cloud.syncAuthoringDraft(local);
      expect(synced.cloudRevision, 3);
      expect(synced.syncIssue, DraftSyncIssue.none);
      expect(synced.lastSyncedHash, skillDraftFingerprint(local));
      await cloud.syncAuthoringDraft(local.copyWith(updatedAt: DateTime.now()));
      expect(puts, 1);
      expect(
        synced.toJson(includeLocalMetadata: false).containsKey('sync_issue'),
        isFalse,
      );
    },
  );

  test(
    'market reads coalesce, cache, invalidate and stay scoped to the session',
    () async {
      final entered = Completer<void>(),
          firstReply = Completer<http.Response>();
      var reads = 0;
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          reads++;
          if (reads == 1) {
            entered.complete();
            return firstReply.future;
          }
          return response({
            'items': [
              {'id': 'new-$reads'},
            ],
          });
        }),
      );
      final first = cloud.skillMarket();
      await entered.future;
      final second = cloud.skillMarket();
      firstReply.complete(
        response({
          'items': [
            {'id': 'first'},
          ],
        }),
      );
      expect((await first).single['id'], 'first');
      expect((await second).single['id'], 'first');
      await cloud.skillMarket();
      expect(reads, 1);
      cloud.invalidateMarketCache('publications');
      expect((await cloud.skillMarket()).single['id'], 'new-2');
      FlutterSecureStorage.setMockInitialValues({
        'xiaoqi.capabilities.device_token.v1': 'different-token',
        'xiaoqi.auth.method.v1': 'email',
        'xiaoqi.auth.email.v1': 'other@example.com',
      });
      expect((await cloud.skillMarket()).single['id'], 'new-3');
    },
  );

  test(
    'concurrent refresh requests do not schedule another full synchronization',
    () async {
      var reads = 0;
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          reads++;
          return response({'items': []});
        }),
      );
      await Future.wait([cloud.syncNow(), cloud.syncNow(), cloud.syncNow()]);
      expect(reads, 2);
    },
  );

  test('simultaneous local deletions retain every pending deletion', () async {
    final a = draft('delete-a'), b = draft('delete-b');
    await store.saveAuthoringDraft(a);
    await store.saveAuthoringDraft(b);
    await Future.wait([
      store.deleteAuthoringDraft(a),
      store.deleteAuthoringDraft(b),
    ]);
    expect((await store.pendingDraftDeletions()).map((d) => d['id']).toSet(), {
      'delete-a',
      'delete-b',
    });
    expect(await store.authoringDrafts(owner), isEmpty);
  });

  test(
    'installation updates apply the server acknowledgement without a blocking list read',
    () async {
      final record = await store.commitDraft(draft('visibility'));
      var listReads = 0;
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          if (request.method == 'GET') listReads++;
          return response({
            'record': record
                .copyWith(enabled: false, cloudRevision: 1)
                .toJson(),
            'cloud_revision': 1,
          });
        }),
      );
      await cloud.manageInstallation(record, enabled: false);
      final saved = await store.find(record.id);
      expect(saved?.enabled, isFalse);
      expect(saved?.cloudRevision, 1);
      expect(listReads, 0);
    },
  );

  test(
    'a remote pull racing a local save cannot silently rebase both changed versions',
    () async {
      final base = draft('pull-race').copyWith(cloudRevision: 1);
      final synced = base.copyWith(lastSyncedHash: skillDraftFingerprint(base));
      await store.saveAuthoringDraft(synced);
      await store.saveAuthoringDraft(synced.copyWith(content: 'Local edit'));
      final remote = base.copyWith(
        content: 'Remote edit',
        cloudRevision: 2,
        lastSyncedHash: skillDraftFingerprint(
          base.copyWith(content: 'Remote edit'),
        ),
      );
      final merged = await store.applySyncedAuthoringDraft(synced, remote);
      expect(merged.content, 'Local edit');
      expect(merged.cloudRevision, 1);
      expect(merged.lastSyncedHash, synced.lastSyncedHash);
      expect(merged.syncIssue, DraftSyncIssue.conflict);
      var puts = 0;
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          if (request.method == 'PUT') puts++;
          return response({
            'items': [remote.toJson(includeLocalMetadata: false)],
          });
        }),
      );
      await expectLater(
        cloud.syncAuthoringDraft(merged),
        throwsA(isA<SkillDraftConflict>()),
      );
      expect(puts, 0);
    },
  );

  test(
    'explicit sync verifies an unchanged draft against a newer cloud version',
    () async {
      final base = draft('verify').copyWith(cloudRevision: 1);
      final local = base.copyWith(lastSyncedHash: skillDraftFingerprint(base));
      await store.saveAuthoringDraft(local);
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          expect(request.method, 'GET');
          return response({
            'items': [
              base
                  .copyWith(content: 'New remote', cloudRevision: 2)
                  .toJson(includeLocalMetadata: false),
            ],
          });
        }),
      );
      await expectLater(
        cloud.syncAuthoringDraft(local),
        throwsA(isA<SkillDraftConflict>()),
      );
      expect((await store.authoringDrafts(owner)).single.content, base.content);
    },
  );
}
