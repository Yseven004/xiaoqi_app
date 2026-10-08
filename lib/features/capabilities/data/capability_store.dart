import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capability_models.dart';

class CapabilityStore {
  CapabilityStore._();
  static final CapabilityStore instance = CapabilityStore._();

  static const _recordsKey = 'xiaoqi_capabilities_v1';
  static const _draftsKey = 'xiaoqi_capability_drafts_v1';
  static const _draftDeletionQueueKey = 'xiaoqi_capability_draft_deletions_v1';
  static const _deletedDraftIdsKey = 'xiaoqi_capability_deleted_draft_ids_v1';
  final Random _random = Random.secure();

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

  Future<List<CapabilityDraft>> drafts() async {
    final prefs = await SharedPreferences.getInstance();
    final deletedIds = await deletedDraftIds();
    return _decodeDrafts(prefs.getString(_draftsKey)).values
        .where((draft) => !deletedIds.contains(draft.id))
        .toList(growable: false);
  }

  String newDraftId() => _newId('draft');

  Future<CapabilityRecord?> find(String id) async {
    for (final record in await list(includeDeleted: true)) {
      if (record.id == id) return record;
    }
    return null;
  }

  Future<CapabilityDraft?> loadDraft(String id) async {
    if (await isDraftDeleted(id)) return null;
    final prefs = await SharedPreferences.getInstance();
    final drafts = _decodeDrafts(prefs.getString(_draftsKey));
    return drafts[id];
  }

  Future<void> saveDraft(CapabilityDraft draft) async {
    if (await isDraftDeleted(draft.id)) return;
    final prefs = await SharedPreferences.getInstance();
    final drafts = _decodeDrafts(prefs.getString(_draftsKey));
    drafts[draft.id] = draft;
    final saved = await prefs.setString(
      _draftsKey,
      jsonEncode(drafts.map((key, value) => MapEntry(key, value.toJson()))),
    );
    if (!saved) throw StateError('草稿保存失败，请重试');
  }

  Future<void> discardDraft(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final drafts = _decodeDrafts(prefs.getString(_draftsKey))..remove(id);
    await prefs.setString(
      _draftsKey,
      jsonEncode(drafts.map((key, value) => MapEntry(key, value.toJson()))),
    );
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
    await prefs.setString(_draftDeletionQueueKey, jsonEncode(queue));
    final deletedIds = await deletedDraftIds();
    deletedIds.add(id);
    await prefs.setString(_deletedDraftIdsKey, jsonEncode(deletedIds.toList()));
    await discardDraft(id);
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
    await discardDraft(id);
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

  Future<void> markDraftSynced(
    String id,
    int cloudRevision, {
    String? accountEmail,
  }) async {
    if (await isDraftDeleted(id)) return;
    final prefs = await SharedPreferences.getInstance();
    final drafts = _decodeDrafts(prefs.getString(_draftsKey));
    final draft = drafts[id];
    if (draft == null) return;
    drafts[id] = draft.copyWith(
      cloudRevision: cloudRevision,
      cloudOwnerEmail: accountEmail ?? draft.cloudOwnerEmail,
    );
    await prefs.setString(
      _draftsKey,
      jsonEncode(drafts.map((key, value) => MapEntry(key, value.toJson()))),
    );
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
    final previousVersion = previous?.currentVersion;
    final packageHashInput = draft.files.isEmpty
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
    if (!saved) throw StateError('技能保存失败，草稿已保留');
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
