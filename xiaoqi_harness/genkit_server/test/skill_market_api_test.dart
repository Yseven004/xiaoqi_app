import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart' show CancellationToken;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/api.dart';
import 'package:xiaoqi_genkit_server/src/capability_import_service.dart';
import 'package:xiaoqi_genkit_server/src/release.dart';
import 'package:xiaoqi_genkit_server/src/skill_market.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class _NoModel implements XiaoqiAgentRuntime {
  @override
  Future<String> run({
    required String tenantId,
    required String taskId,
    required Map<String, dynamic> request,
    required void Function(String) onDelta,
    required CancellationToken cancellation,
    void Function()? onImageGenerationStarted,
  }) async => throw StateError('Market operations must not invoke a model');
}

void main() {
  late Directory directory;
  late CloudStore store;
  late XiaoqiApi api;
  const content =
      '---\nname: "paper-reader"\ndescription: "Read supplied papers"\n---\nExplain evidence and limitations.\n';
  setUp(() {
    directory = Directory.systemTemp.createTempSync('xiaoqi-skill-market-');
    store = CloudStore(root: directory.path);
    api = XiaoqiApi(store, _NoModel());
    for (final tenant in ['alice', 'bob']) {
      store.put('device/${sha256.convert(utf8.encode(tenant))}', {
        'tenant_id': tenant,
        'device_id': '$tenant-device',
        'auth_method': 'email',
        'account_email': 'owner@example.com',
        'revoked_at': null,
      }, null);
    }
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });
  Future<(int, Map<String, dynamic>)> call(
    String method,
    String path, {
    String tenant = 'alice',
    Object? body,
  }) async {
    final response = await api.router.call(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {
          'authorization': 'Bearer $tenant',
          'x-xiaoqi-contract': apiContractVersion,
          if (body != null) 'content-type': 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return (
      response.statusCode,
      Map<String, dynamic>.from(
        jsonDecode(await response.readAsString()) as Map,
      ),
    );
  }

  Map<String, dynamic> record({String title = '论文精读'}) => {
    'id': 'skill-a',
    'kind': 'skill',
    'name': 'paper-reader',
    'description': 'Read supplied papers',
    'current_version_id': 'version-a',
    'versions': [
      {
        'id': 'version-a',
        'number': 1,
        'content': content,
        'content_hash': sha256.convert(utf8.encode(content)).toString(),
        'files': <String, String>{},
      },
    ],
    'presentation': {
      'title': title,
      'introduction': '说明研究方法和证据。',
      'icon_asset': 'research',
      'images': [],
    },
  };

  test(
    'author publishes a snapshot; private edits stay private; installations are immutable',
    () async {
      final (saveStatus, saved) = await call(
        'POST',
        '/v1/capabilities/sync',
        body: {'record': record(), 'expected_revision': 0},
      );
      expect(saveStatus, 200, reason: '$saved');
      expect((saved['record'] as Map).containsKey('owner_tenant'), isFalse);
      final (publishStatus, published) = await call(
        'POST',
        '/v1/skill-market/skill-a/publish',
        body: {'expected_revision': 1, 'published_revision': 0},
      );
      expect(publishStatus, 200, reason: '$published');
      final publication = published['publication'] as Map;
      final id = publication['id'];
      expect(publication['is_owner'], isTrue);
      final duplicate = await call(
        'POST',
        '/v1/skill-market/skill-a/publish',
        body: {'expected_revision': 1, 'published_revision': 0},
      );
      expect(duplicate.$1, 200);
      expect(duplicate.$2['publication']['publication_revision'], 1);
      expect(
        (await call('GET', '/v1/skill-market', tenant: 'bob')).$2['items'],
        hasLength(1),
      );
      expect(
        (await call(
          'GET',
          '/v1/skill-market/$id',
          tenant: 'bob',
        )).$2['publication']['is_owner'],
        isFalse,
      );

      expect(
        (await call(
          'POST',
          '/v1/capabilities/sync',
          body: {
            'record': record(title: '未发布的修改'),
            'expected_revision': 1,
          },
        )).$1,
        200,
      );
      expect(
        (await call(
          'GET',
          '/v1/skill-market/$id',
          tenant: 'bob',
        )).$2['publication']['presentation']['title'],
        '论文精读',
      );
      expect(
        (await call(
          'POST',
          '/v1/skill-market/skill-a/publish',
          tenant: 'bob',
          body: {'expected_revision': 2, 'published_revision': 1},
        )).$1,
        400,
      );

      final (installStatus, installed) = await call(
        'POST',
        '/v1/skill-market/$id/install',
        tenant: 'bob',
        body: {'publication_revision': 1},
      );
      expect(installStatus, 200, reason: '$installed');
      final installedRecord = Map<String, dynamic>.from(
        installed['record'] as Map,
      );
      expect(installedRecord['origin'], 'market');
      expect(installedRecord['presentation']['title'], '论文精读');
      installedRecord['origin'] = 'local';
      expect(
        (await call(
          'POST',
          '/v1/capabilities/sync',
          tenant: 'bob',
          body: {'record': installedRecord, 'expected_revision': 1},
        )).$1,
        400,
      );
      expect(
        (await call(
          'POST',
          '/v1/skill-market/market-$id/publish',
          tenant: 'bob',
          body: {'expected_revision': 1, 'published_revision': 0},
        )).$1,
        400,
      );
      expect(
        (await call(
          'POST',
          '/v1/skill-market/skill-a/publish',
          body: {'expected_revision': 2, 'published_revision': 0},
        )).$1,
        409,
      );
      expect(
        (await call(
          'GET',
          '/v1/skill-market/$id',
        )).$2['publication']['presentation']['title'],
        '论文精读',
      );
      expect(
        (await call(
          'POST',
          '/v1/skill-market/skill-a/publish',
          body: {'expected_revision': 2, 'published_revision': 1},
        )).$1,
        200,
      );
      expect(
        (await call(
          'GET',
          '/v1/skill-market/$id',
        )).$2['publication']['presentation']['title'],
        '未发布的修改',
      );
      expect(
        store.get('cap/bob/market-$id')!.value['presentation']['title'],
        '论文精读',
      );
    },
  );

  test(
    'draft presentation persists privately and stale revisions cannot overwrite it',
    () async {
      final draft = {
        'id': 'draft-a',
        'authoring_version': 1,
        'kind': 'skill',
        'content': content,
        'presentation': {'title': '私人草稿', 'icon_asset': 'book', 'images': []},
      };
      expect(
        (await call(
          'PUT',
          '/v1/drafts',
          body: {'draft': draft, 'expected_revision': 0},
        )).$1,
        200,
      );
      final own = (await call('GET', '/v1/drafts')).$2['items'] as List;
      expect(own.single['authoring_version'], 1);
      expect(own.single['presentation']['title'], '私人草稿');
      expect(
        (await call('GET', '/v1/drafts', tenant: 'bob')).$2['items'],
        isEmpty,
      );
      expect(
        (await call('GET', '/v1/skill-market', tenant: 'bob')).$2['items'],
        isEmpty,
      );
      expect(
        (await call(
          'PUT',
          '/v1/drafts',
          body: {
            'draft': {...draft, 'content': 'overwritten'},
            'expected_revision': 0,
          },
        )).$1,
        409,
      );
      expect(store.get('draft/alice/draft-a')!.value['content'], content);
      expect(
        () => normalizeSkillPresentation({'icon_asset': '../../private'}),
        throwsFormatException,
      );
      expect(
        () => normalizeSkillPresentation({
          'icon_data':
              'data:image/svg+xml;base64,${base64Encode(utf8.encode('<svg><script>alert(1)</script></svg>'))}',
        }),
        throwsFormatException,
      );
      expect(
        () => normalizeSkillPresentation({
          'images': [
            {'data': 'https://private.example/image'},
          ],
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'checked imports export only the selected skill subtree without installing',
    () {
      store.putImmutable('inspection/checked.zip', {
        'skills/paper/SKILL.md': utf8.encode(content),
        'skills/paper/references/notes.md': utf8.encode('Evidence'),
        'private.txt': utf8.encode('not part of selected skill'),
      });
      store.put('import/alice/check-a', {
        'artifact_key': 'inspection/checked.zip',
        'expires_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
        'candidates': [
          {
            'id': 'candidate-a',
            'kind': 'skill',
            'status': 'supported',
            'root': 'skills/paper',
            'name': 'paper-reader',
            'description': 'Read supplied papers',
          },
        ],
      }, null);
      final imports = CapabilityImportService(store);
      final draft = imports.skillDraft('alice', 'check-a', 'candidate-a');
      expect(draft['content'], content);
      expect((draft['files'] as Map).keys, ['references/notes.md']);
      expect(store.list('cap/alice/'), isEmpty);
      expect(
        () => imports.skillDraft('bob', 'check-a', 'candidate-a'),
        throwsFormatException,
      );
      expect(
        () => imports.skillDraft('alice', 'check-a', 'other-candidate'),
        throwsFormatException,
      );
    },
  );
}
