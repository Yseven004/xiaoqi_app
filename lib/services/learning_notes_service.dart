import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import '../features/ai_study_annotation/data/ai_conversation_history.dart';
import '../features/capabilities/data/capability_cloud_sync.dart';
import '../features/capabilities/data/capability_store.dart';
import '../models/learning_note_delta.dart';
import 'database_service.dart';

typedef LearningNotesStatus = ({
  String conversationId,
  String message,
  int? noteId,
  bool retry,
});

class LearningNotesService with WidgetsBindingObserver {
  LearningNotesService._() {
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }
  static final instance = LearningNotesService._();
  final status = ValueNotifier<LearningNotesStatus?>(null);
  final editingNoteIds = <int>{};
  bool _foreground = true;
  Future<void>? _flushing;
  bool _catchingUp = false;
  LearningNotesStatus? _beforePause;
  String? _lastScope;

  Future<String?> accountScope() async {
    final email = await CapabilityCloudSync.instance.signedInEmail;
    final scope = email == null || email.trim().isEmpty
        ? null
        : sha256.convert(utf8.encode(email.trim().toLowerCase())).toString();
    if (scope != _lastScope) {
      status.value = null;
      _beforePause = null;
      _lastScope = scope;
    }
    return scope;
  }

  Future<bool> selected(Map<String, Object?>? capability) async {
    final raw = capability?['selected_capabilities'];
    final refs = raw is List
        ? raw
        : capability == null
        ? const []
        : [capability];
    for (final item in refs.whereType<Map>()) {
      final id = item['id']?.toString();
      if (id != null) {
        final record = await CapabilityStore.instance.find(id);
        final selectedVersionId =
            item['version_id']?.toString() ?? record?.currentVersionId;
        final version = record?.versions
            .where((candidate) => candidate.id == selectedVersionId)
            .firstOrNull;
        final release =
            version?.capabilityRelease ??
            (selectedVersionId == record?.currentVersionId
                ? record?.source['capability_release']
                : null);
        final claims = release is Map
            ? release['capabilities'] as List? ?? const []
            : const [];
        if (claims.contains('learning_notes.append') &&
            record!.enabled &&
            record.origin == 'market' &&
            record.source['curated_capability_id'] ==
                (release is Map ? release['id'] : null) &&
            record.deletedAt == null) {
          return true;
        }
      }
    }
    return false;
  }

  Future<List<Map<String, dynamic>>> topics() async {
    final scope = await accountScope();
    return scope == null
        ? const []
        : DatabaseService().learningNoteTopics(scope);
  }

  void beginEditing(int? noteId) {
    if (noteId != null) editingNoteIds.add(noteId);
  }

  void endEditing(int? noteId) {
    if (noteId != null) editingNoteIds.remove(noteId);
    unawaited(flush());
  }

  void processing(String conversationId) => status.value = (
    conversationId: conversationId,
    message: '正在整理本次讨论',
    noteId: null,
    retry: false,
  );

  void finishWithoutUpdates(String conversationId) {
    if (status.value?.conversationId == conversationId &&
        status.value?.message == '正在整理本次讨论') {
      status.value = (
        conversationId: conversationId,
        message: '已开启，等待新的学习内容',
        noteId: null,
        retry: false,
      );
    }
  }

  Future<void> collectTask(
    String taskId, {
    required String conversationId,
    required String messageId,
    required String? expectedScope,
  }) async {
    try {
      final task = await CapabilityCloudSync.instance.getTask(taskId);
      if (task['status'] == 'completed') {
        await accept(
          task['learning_notes'],
          conversationId: conversationId,
          messageId: messageId,
          expectedScope: expectedScope,
        );
      }
    } on Object {
      status.value = (
        conversationId: conversationId,
        message: '本次整理暂未接回，可重试',
        noteId: null,
        retry: true,
      );
    }
  }

  Future<void> accept(
    Object? raw, {
    required String conversationId,
    required String messageId,
    required String? expectedScope,
  }) async {
    if (raw is! List || raw.isEmpty) return;
    try {
      if (raw.length > 3) throw const FormatException('笔记主题数量无效');
      final scope = await accountScope();
      if (scope == null || scope != expectedScope) return;
      final updates = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is! Map ||
            item['conversation_id'] != conversationId ||
            item['message_id'] != messageId ||
            item['source_text'] is! String) {
          throw const FormatException('笔记来源不匹配，原笔记已保留');
        }
        final value = Map<String, dynamic>.from(item);
        LearningNoteDelta.fromJson(value);
        updates.add(value);
      }
      await DatabaseService().enqueueLearningNotes(scope, updates);
      await flush();
    } on Object {
      status.value = (
        conversationId: conversationId,
        message: '本次整理未保存，原聊天和笔记已保留',
        noteId: null,
        retry: true,
      );
    }
  }

  Future<void> flush() {
    if (!_foreground) return Future.value();
    return _flushing ??= _flush().whenComplete(() => _flushing = null);
  }

  Future<void> _flush() async {
    final scope = await accountScope();
    if (scope == null || !_foreground) return;
    try {
      final enabledConversations = <String>{};
      for (final record in await AiConversationHistoryService.instance.list(
        allBooks: true,
      )) {
        if (await selected(record.activeCapabilityMetadata)) {
          enabledConversations.add(record.id);
        }
      }
      final saved = await DatabaseService().applyLearningNotes(
        scope,
        editingNoteIds,
        enabledConversations: enabledConversations,
        shouldContinue: () => _foreground,
      );
      if (scope != await accountScope()) return;
      if (saved.isNotEmpty) {
        final last = saved.last;
        status.value = (
          conversationId: last.conversationId,
          message: '已整理到「${last.title}」',
          noteId: last.noteId,
          retry: false,
        );
      }
      final error = saved.isNotEmpty
          ? null
          : await DatabaseService().learningNoteError(
              scope,
              conversationId: status.value?.conversationId,
            );
      if (error != null) {
        status.value = (
          conversationId: error.conversationId,
          message: error.message,
          noteId: null,
          retry: error.retry,
        );
      }
    } on Object {
      status.value = (
        conversationId: status.value?.conversationId ?? '',
        message: '本次整理未完成，稍后可重试',
        noteId: null,
        retry: true,
      );
    }
  }

  Future<void> retry() async {
    final scope = await accountScope();
    if (scope == null) return;
    await DatabaseService().retryLearningNotes(scope);
    await catchUp();
    await flush();
  }

  Future<void> catchUp() async {
    if (_catchingUp ||
        !_foreground ||
        !await CapabilityCloudSync.instance.hasEmailSession) {
      return;
    }
    _catchingUp = true;
    try {
      final records = await AiConversationHistoryService.instance.list(
        allBooks: true,
      );
      final scope = await accountScope();
      for (final record in records) {
        if (!_foreground) break;
        if (!await selected(record.activeCapabilityMetadata)) continue;
        for (final message in record.messages.where(
          (m) => m.isUser && m.agentTaskId != null,
        )) {
          // Only existing private tasks are inspected; never start new model jobs.
          if (!message.agentTaskPending) continue;
          try {
            final task = await CapabilityCloudSync.instance.getTask(
              message.agentTaskId!,
            );
            if (task['status'] == 'completed') {
              await accept(
                task['learning_notes'],
                conversationId: record.id,
                messageId: message.id,
                expectedScope: scope,
              );
            }
          } on Object {
            /* A later resume can retry the same persisted task. */
          }
        }
      }
      await flush();
    } finally {
      _catchingUp = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      if (_beforePause != null) status.value = _beforePause;
      _beforePause = null;
      unawaited(catchUp());
    } else if (status.value != null) {
      final old = status.value!;
      _beforePause = old;
      status.value = (
        conversationId: old.conversationId,
        message: '已暂停，重开后继续整理',
        noteId: old.noteId,
        retry: false,
      );
    }
  }
}
