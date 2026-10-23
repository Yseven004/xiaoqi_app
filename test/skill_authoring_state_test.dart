import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_models.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CapabilityStore.instance.clearSkillPreviews();
  });
  CapabilityDraft draft() => CapabilityDraft(
    id: 'draft-a',
    name: 'paper-reader',
    description: 'Read papers',
    content:
        '---\nname: paper-reader\ndescription: Read papers\n---\nExplain evidence.',
    updatedAt: DateTime.utc(2026, 10, 23),
    cloudOwnerEmail: 'alice@example.com',
    presentation: {
      'title': '论文精读',
      'introduction': '梳理证据',
      'icon_asset': 'book',
      'images': [
        {'data': 'data:image/png;base64,aGVsbG8=', 'caption': '说明'},
      ],
    },
  );

  test(
    'plugin drafts preserve their kind and hash the real package without a synthetic SKILL.md',
    () async {
      final manifest = jsonEncode({'name': 'reading-bundle'});
      final files = {'plugin.json': base64Encode(utf8.encode(manifest))};
      final plugin = CapabilityDraft(
        id: 'plugin-draft',
        kind: CapabilityKind.plugin,
        name: 'reading-bundle',
        description: 'Reading tools',
        content: manifest,
        files: files,
        updatedAt: DateTime.utc(2026, 10, 23),
        cloudOwnerEmail: 'alice@example.com',
        presentation: {'title': '阅读工具包'},
      );
      final store = CapabilityStore.instance;
      await store.saveAuthoringDraft(plugin);
      final restored = (await store.authoringDrafts(
        'alice@example.com',
      )).single;
      expect(restored.kind, CapabilityKind.plugin);
      final saved = await store.commitDraft(restored);
      expect(saved.kind, CapabilityKind.plugin);
      expect(saved.currentVersion!.files, files);
      expect(saved.currentVersion!.files.containsKey('SKILL.md'), isFalse);
      expect(
        saved.currentVersion!.contentHash,
        sha256.convert(utf8.encode(jsonEncode(files))).toString(),
      );
    },
  );

  test(
    'drafts survive editor/chat navigation and stay scoped to their account',
    () async {
      final store = CapabilityStore.instance;
      await store.stageSkillPreview(draft());
      expect(
        await store.skillPreview('draft-a', accountEmail: 'bob@example.com'),
        isNull,
      );
      store.clearSkillPreviews();
      final restored = await store.skillPreview(
        'draft-a',
        accountEmail: 'alice@example.com',
      );
      expect(restored?.presentation['title'], '论文精读');
      expect(restored?.presentation['images'], hasLength(1));
      final revised = restored!.copyWith(
        content: 'Updated instructions',
        cloudRevision: 3,
      );
      await store.saveAuthoringDraft(revised);
      store.clearSkillPreviews();
      final latest = await store.skillPreview(
        'draft-a',
        accountEmail: 'alice@example.com',
      );
      expect(latest?.content, 'Updated instructions');
      expect(latest?.presentation, draft().presentation);
      expect(latest?.cloudRevision, 3);
    },
  );

  test(
    'late sync preserves edits saved while the request was running',
    () async {
      final store = CapabilityStore.instance;
      final sent = draft();
      await store.saveAuthoringDraft(sent);
      await store.saveAuthoringDraft(sent.copyWith(content: 'New local edits'));
      final remote = sent.copyWith(
        cloudRevision: 2,
        lastSyncedHash: skillDraftFingerprint(sent),
      );
      final merged = await store.applySyncedAuthoringDraft(sent, remote);
      expect(merged.content, 'New local edits');
      expect(merged.cloudRevision, 2);
      expect(merged.lastSyncedHash, skillDraftFingerprint(sent));
    },
  );

  test(
    'presentation and ownership metadata round trip independently of skill identifiers',
    () {
      final value = draft().copyWith(
        targetCapabilityId: 'cap-a',
        cloudRevision: 2,
      );
      final restored = CapabilityDraft.fromJson(value.toJson());
      expect(restored.name, 'paper-reader');
      expect(restored.presentation['title'], '论文精读');
      expect(restored.cloudOwnerEmail, 'alice@example.com');
      expect(restored.targetCapabilityId, 'cap-a');
      expect(
        value
            .toJson(includeLocalMetadata: false)
            .containsKey('cloud_owner_email'),
        isFalse,
      );
    },
  );

  test(
    'saving a skill carries presentation while marketplace installations stay read-only',
    () async {
      final record = await CapabilityStore.instance.commitDraft(draft());
      expect(record.displayName, '论文精读');
      expect(record.presentation['icon_asset'], 'book');
      final installed = CapabilityRecord.fromJson({
        ...record.toJson(),
        'origin': 'market',
      });
      expect(installed.isServerInstallation, isTrue);
      expect(
        installed.copyWith(name: 'changed').presentation,
        record.presentation,
      );
    },
  );
}
