import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capability_models.dart';

String skillDraftFingerprint(CapabilityDraft draft) {
  Object? sorted(Object? value) {
    if (value is Map) {
      return {
        for (final key in value.keys.map((k) => k.toString()).toList()..sort())
          key: sorted(value[key]),
      };
    }
    if (value is List) return value.map(sorted).toList();
    return value;
  }

  final json = draft.toJson(includeLocalMetadata: false)
    ..remove('cloud_revision')
    ..remove('updated_at');
  return sha256.convert(utf8.encode(jsonEncode(sorted(json)))).toString();
}

class CapabilityStore {
  CapabilityStore._();
  static final CapabilityStore instance = CapabilityStore._();

  static const _recordsKey = 'xiaoqi_capabilities_v1';
  static const _draftsKey = 'xiaoqi_capability_drafts_v1';
  static const _draftDeletionQueueKey = 'xiaoqi_capability_draft_deletions_v1';
  static const _deletedDraftIdsKey = 'xiaoqi_capability_deleted_draft_ids_v1';
  final Random _random = Random.secure();
  Future<void> _authoringWrites = Future<void>.value();
  Future<T> _writeAuthoring<T>(Future<T> Function() action) {
    final result = _authoringWrites.then((_) => action());
    _authoringWrites = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  // Cache of account-scoped, persisted skill drafts.
  final Map<String, CapabilityDraft> _skillPreviews = {};

  Future<List<CapabilityRecord>> list({bool includeDeleted = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recordsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final records = decoded
          .map(CapabilityRecord.fromJson)
          .where((record) => includeDeleted || !record.isDeleted)
          .toList(growable: false);
      return records;
    } catch (_) {
      return const [];
    }
  }

  Future<List<CapabilityRecord>> visibleInMenu() async => (await list())
      .where((record) => record.showInMenu)
      .toList(growable: false);

  String _authoringKey(String? account) =>
      'xiaoqi_skill_authoring_${sha256.convert(utf8.encode(account ?? ""))}';

  Future<List<CapabilityDraft>> authoringDrafts(String? account) async {
    final prefs = await SharedPreferences.getInstance();
    final deleted = await deletedDraftIds();
    return _decodeDrafts(
      prefs.getString(_authoringKey(account)),
    ).values.where((draft) => !deleted.contains(draft.id)).toList();
  }

  Future<void> saveAuthoringDraft(CapabilityDraft draft) =>
      _writeAuthoring(() => _saveAuthoringDraft(draft));

  Future<CapabilityDraft> applySyncedAuthoringDraft(
    CapabilityDraft sent,
    CapabilityDraft remote,
  ) => _writeAuthoring(() async {
    final prefs = await SharedPreferences.getInstance();
    final current = _decodeDrafts(
      prefs.getString(_authoringKey(sent.cloudOwnerEmail)),
    )[sent.id];
    if (current == null || current.cloudRevision > remote.cloudRevision) {
      return current ?? sent;
    }
    final merged = skillDraftFingerprint(current) == skillDraftFingerprint(sent)
        ? remote
        : current.copyWith(
            cloudRevision: remote.cloudRevision,
            lastSyncedHash: remote.lastSyncedHash,
          );
    await _saveAuthoringDraft(merged);
    return merged;
  });

  Future<void> _saveAuthoringDraft(CapabilityDraft draft) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _authoringKey(draft.cloudOwnerEmail);
    final drafts = _decodeDrafts(prefs.getString(key));
    drafts[draft.id] = draft;
    if (!await prefs.setString(
      key,
      jsonEncode(drafts.map((id, value) => MapEntry(id, value.toJson()))),
    )) {
      throw StateError('草稿保存失败，当前编辑内容仍保留');
    }
    _skillPreviews[draft.id] = draft;
  }

  Future<List<CapabilityDraft>> skillPreviews({String? accountEmail}) async {
    for (final draft in await authoringDrafts(accountEmail)) {
      _skillPreviews[draft.id] = draft;
    }
    return _skillPreviews.values
        .where((d) => d.cloudOwnerEmail == accountEmail)
        .toList();
  }

  Future<List<CapabilityDraft>> legacyDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeDrafts(
      prefs.getString(_draftsKey),
    ).values.toList(growable: false);
  }

  String newDraftId() => _newId('draft');

  Future<CapabilityRecord?> find(String id) async {
    for (final record in await list(includeDeleted: true)) {
      if (record.id == id) return record;
    }
    return null;
  }

  Future<CapabilityDraft?> skillPreview(
    String id, {
    String? accountEmail,
  }) async {
    if (await isDraftDeleted(id)) return null;
    await skillPreviews(accountEmail: accountEmail);
    final draft = _skillPreviews[id];
    return draft?.cloudOwnerEmail == accountEmail ? draft : null;
  }

  Future<void> stageSkillPreview(CapabilityDraft draft) async {
    if (await isDraftDeleted(draft.id)) return;
    await saveAuthoringDraft(draft);
  }

  void discardSkillPreview(String id) {
    final draft = _skillPreviews.remove(id);
    if (draft != null) unawaited(_removeAuthoringDraft(draft));
  }

  Future<void> _removeAuthoringDraft(CapabilityDraft draft) =>
      _writeAuthoring(() async {
        final prefs = await SharedPreferences.getInstance();
        final key = _authoringKey(draft.cloudOwnerEmail);
        final drafts = _decodeDrafts(prefs.getString(key))..remove(draft.id);
        await prefs.setString(
          key,
          jsonEncode(drafts.map((id, value) => MapEntry(id, value.toJson()))),
        );
      });

  Future<void> _discardLegacyDraft(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final drafts = _decodeDrafts(prefs.getString(_draftsKey))..remove(id);
    final saved = drafts.isEmpty
        ? await prefs.remove(_draftsKey)
        : await prefs.setString(
            _draftsKey,
            jsonEncode(
              drafts.map((key, value) => MapEntry(key, value.toJson())),
            ),
          );
    if (!saved) throw StateError('未保存内容清理失败，请重试');
  }

  void clearSkillPreviews() => _skillPreviews.clear();

  Future<void> retireLegacyDrafts({required String accountEmail}) async {
    for (final draft in await legacyDrafts()) {
      await queueDraftDeletion(
        id: draft.id,
        cloudRevision: draft.cloudRevision,
        accountEmail: draft.cloudOwnerEmail ?? accountEmail,
      );
    }
  }

  Future<Set<String>> deletedDraftIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_deletedDraftIdsKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded.map((item) => item.toString()).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<bool> isDraftDeleted(String id) async =>
      (await deletedDraftIds()).contains(id);

  Future<List<Map<String, Object?>>> pendingDraftDeletions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftDeletionQueueKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, Object?>.from(item))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> queueDraftDeletion({
    required String id,
    required int cloudRevision,
    required String accountEmail,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final email = accountEmail.trim().toLowerCase();
    final queue = (await pendingDraftDeletions())
        .where(
          (item) =>
              item['id']?.toString() != id ||
              item['account_email']?.toString() != email,
        )
        .toList();
    queue.add({
      'id': id,
      'account_email': email,
      'cloud_revision': cloudRevision,
    });
    if (!await prefs.setString(_draftDeletionQueueKey, jsonEncode(queue))) {
      throw StateError('旧草稿删除请求保存失败，请重试');
    }
    final deletedIds = await deletedDraftIds();
    deletedIds.add(id);
    if (!await prefs.setString(
      _deletedDraftIdsKey,
      jsonEncode(deletedIds.toList()),
    )) {
      throw StateError('旧草稿删除状态保存失败，请重试');
    }
    await _discardLegacyDraft(id);
  }

  Future<void> rememberRemoteDraftDeletion(
    String id, {
    String? accountEmail,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final deletedIds = await deletedDraftIds();
    deletedIds.add(id);
    await prefs.setString(_deletedDraftIdsKey, jsonEncode(deletedIds.toList()));
    if (accountEmail != null) {
      final queue = (await pendingDraftDeletions())
          .where((item) => item['id']?.toString() != id)
          .toList();
      await prefs.setString(_draftDeletionQueueKey, jsonEncode(queue));
    }
    await _discardLegacyDraft(id);
  }

  Future<void> completeDraftDeletion(String id, String accountEmail) async {
    final prefs = await SharedPreferences.getInstance();
    final email = accountEmail.trim().toLowerCase();
    final queue = (await pendingDraftDeletions())
        .where(
          (item) =>
              item['id']?.toString() != id ||
              item['account_email']?.toString() != email,
        )
        .toList();
    await prefs.setString(_draftDeletionQueueKey, jsonEncode(queue));
  }

  Future<void> markSynced(String id, int cloudRevision) async {
    await _update(
      id,
      (record) => record.copyWith(
        syncState: CapabilitySyncState.synced,
        cloudRevision: cloudRevision,
      ),
    );
  }

  Future<void> markConflict(String id) async {
    await _update(
      id,
      (record) => record.copyWith(syncState: CapabilitySyncState.conflict),
    );
  }

  Future<void> applyRemote(CapabilityRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    final records = (await list(includeDeleted: true)).toList();
    final normalized = record.copyWith(syncState: CapabilitySyncState.synced);
    final index = records.indexWhere((item) => item.id == record.id);
    if (index < 0) {
      records.add(normalized);
    } else {
      records[index] = normalized;
    }
    await prefs.setString(
      _recordsKey,
      jsonEncode(records.map((item) => item.toJson()).toList()),
    );
  }

  Future<CapabilityRecord> commitDraft(
    CapabilityDraft draft, {
    String? existingId,
    bool? showInMenu,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final records = (await list(includeDeleted: true)).toList();
    final now = DateTime.now();
    final existingIndex = records.indexWhere(
      (record) => record.id == (existingId ?? draft.id),
    );
    final previous = existingIndex < 0 ? null : records[existingIndex];
    if (previous?.isServerInstallation == true) {
      throw StateError('已安装的第三方扩展不能覆盖为作者作品');
    }
    final previousVersion = previous?.currentVersion;
    final packageHashInput = draft.kind == CapabilityKind.plugin
        ? utf8.encode(
            jsonEncode({
              for (final path in draft.files.keys.toList()..sort())
                path: draft.files[path],
            }),
          )
        : draft.files.isEmpty
        ? utf8.encode(draft.content)
        : utf8.encode(
            jsonEncode({
              for (final path in [...draft.files.keys, 'SKILL.md']..sort())
                path: path == 'SKILL.md'
                    ? base64.encode(utf8.encode(draft.content))
                    : draft.files[path],
            }),
          );
    final digest = sha256.convert(packageHashInput).toString();
    final version = CapabilityVersion(
      id: _newId('version'),
      number: (previous?.versions.length ?? 0) + 1,
      content: draft.content,
      contentHash: digest,
      createdAt: now,
      parentVersionId: previousVersion?.id,
      files: draft.files,
    );
    final unchanged = previousVersion?.contentHash == digest;
    final next = CapabilityRecord(
      id: previous?.id ?? draft.id,
      kind: draft.kind,
      name: draft.name.trim(),
      description: draft.description.trim(),
      versions: unchanged
          ? previous!.versions
          : [...?previous?.versions, version],
      currentVersionId: unchanged ? previousVersion!.id : version.id,
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
      showInMenu: showInMenu ?? previous?.showInMenu ?? true,
      syncState: CapabilitySyncState.pending,
      deletedAt: null,
      cloudRevision: previous?.cloudRevision ?? 0,
      presentation: draft.presentation,
      keywords: previous?.keywords,
      keywordsEdited: previous?.keywordsEdited ?? false,
      publicationId: previous?.publicationId,
      publishedRevision: previous?.publishedRevision ?? 0,
    );
    final nextRecords = [...records];
    if (existingIndex < 0) {
      nextRecords.add(next);
    } else {
      nextRecords[existingIndex] = next;
    }
    final saved = await prefs.setString(
      _recordsKey,
      jsonEncode(nextRecords.map((record) => record.toJson()).toList()),
    );
    if (!saved) throw StateError('技能保存失败，编辑内容仍保留在当前页面');
    return next;
  }

  Future<void> setMenuVisibility(String id, bool visible) async {
    await _update(
      id,
      (record) => record.copyWith(
        showInMenu: visible,
        updatedAt: DateTime.now(),
        syncState: CapabilitySyncState.pending,
      ),
    );
  }

  Future<void> markDeleted(String id) async {
    final now = DateTime.now();
    await _update(
      id,
      (record) => record.copyWith(
        deletedAt: now,
        updatedAt: now,
        syncState: CapabilitySyncState.pending,
      ),
    );
  }

  Future<void> _update(
    String id,
    CapabilityRecord Function(CapabilityRecord) transform,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final records = (await list(includeDeleted: true)).toList();
    final index = records.indexWhere((record) => record.id == id);
    if (index < 0) return;
    records[index] = transform(records[index]);
    await prefs.setString(
      _recordsKey,
      jsonEncode(records.map((record) => record.toJson()).toList()),
    );
  }

  Map<String, CapabilityDraft> _decodeDrafts(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) =>
            MapEntry(key.toString(), CapabilityDraft.fromJson(value)),
      );
    } catch (_) {
      return {};
    }
  }

  String _newId(String prefix) {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = _random.nextInt(1 << 32).toRadixString(36);
    return '$prefix-$stamp-$salt';
  }
}
