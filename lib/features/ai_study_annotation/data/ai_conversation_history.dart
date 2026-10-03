import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/ai_web_source.dart';
import '../../../models/home_chat_attachment.dart';

int _generatedMessageSequence = 0;
const String _rootMessageKey = '__conversation_root__';

String _newMessageId() =>
    'message-${DateTime.now().microsecondsSinceEpoch}-${_generatedMessageSequence++}';

/// A message node in a locally stored conversation tree.
class AiConversationMessage {
  AiConversationMessage({
    required this.text,
    required this.isUser,
    required this.createdAt,
    String? id,
    this.parentMessageId,
    this.pageLabel = '',
    this.attachments = const [],
    this.isDeletedMarker = false,
    this.isIncomplete = false,
    this.capabilityMetadata,
    this.outputArtifacts = const [],
  }) : id = id ?? _newMessageId();

  final String id;
  final String? parentMessageId;
  final String text;
  final bool isUser;
  final String pageLabel;
  final DateTime createdAt;
  final List<HomeChatAttachment> attachments;
  final bool isDeletedMarker;
  final bool isIncomplete;
  final Map<String, Object?>? capabilityMetadata;
  final List<Map<String, Object?>> outputArtifacts;

  AiConversationMessage copyWith({
    String? id,
    String? parentMessageId,
    bool clearParentMessageId = false,
    String? text,
    bool? isUser,
    String? pageLabel,
    DateTime? createdAt,
    List<HomeChatAttachment>? attachments,
    bool? isDeletedMarker,
    bool? isIncomplete,
    Map<String, Object?>? capabilityMetadata,
    bool clearCapabilityMetadata = false,
    List<Map<String, Object?>>? outputArtifacts,
  }) => AiConversationMessage(
    id: id ?? this.id,
    parentMessageId: clearParentMessageId
        ? null
        : parentMessageId ?? this.parentMessageId,
    text: text ?? this.text,
    isUser: isUser ?? this.isUser,
    pageLabel: pageLabel ?? this.pageLabel,
    createdAt: createdAt ?? this.createdAt,
    attachments: attachments ?? this.attachments,
    isDeletedMarker: isDeletedMarker ?? this.isDeletedMarker,
    isIncomplete: isIncomplete ?? this.isIncomplete,
    capabilityMetadata: clearCapabilityMetadata
        ? null
        : capabilityMetadata ?? this.capabilityMetadata,
    outputArtifacts: outputArtifacts ?? this.outputArtifacts,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'parent_message_id': parentMessageId,
    'text': text,
    'is_user': isUser,
    'page_label': pageLabel,
    'created_at': createdAt.toIso8601String(),
    'attachments': attachments
        .map(
          (item) =>
              Map<String, Object?>.from(item.toJson())
                ..remove('extracted_text'),
        )
        .toList(),
    'is_deleted_marker': isDeletedMarker,
    'is_incomplete': isIncomplete,
    if (capabilityMetadata != null) 'capability_metadata': capabilityMetadata,
    if (outputArtifacts.isNotEmpty) 'output_artifacts': outputArtifacts,
  };

  factory AiConversationMessage.fromJson(Object? raw) {
    if (raw is! Map) {
      return AiConversationMessage(
        text: '',
        isUser: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
    final createdAt = DateTime.tryParse(raw['created_at']?.toString() ?? '');
    return AiConversationMessage(
      id: raw['id']?.toString(),
      parentMessageId: raw['parent_message_id']?.toString(),
      text: raw['text']?.toString() ?? '',
      isUser: raw['is_user'] != false,
      pageLabel: raw['page_label']?.toString() ?? '',
      createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      attachments: raw['attachments'] is List
          ? (raw['attachments'] as List)
                .map(HomeChatAttachment.fromJson)
                .toList(growable: false)
          : const [],
      isDeletedMarker: raw['is_deleted_marker'] == true,
      isIncomplete: raw['is_incomplete'] == true,
      capabilityMetadata: raw['capability_metadata'] is Map
          ? Map<String, Object?>.from(raw['capability_metadata'] as Map)
          : null,
      outputArtifacts: raw['output_artifacts'] is List
          ? (raw['output_artifacts'] as List)
                .whereType<Map>()
                .map((item) => Map<String, Object?>.from(item))
                .toList(growable: false)
          : const [],
    );
  }
}

class AiConversationDeletePreview {
  const AiConversationDeletePreview({
    required this.deletesQuestion,
    required this.answerVersionCount,
    required this.followUpQuestionCount,
    required this.followUpReplyCount,
  });

  final bool deletesQuestion;
  final int answerVersionCount;
  final int followUpQuestionCount;
  final int followUpReplyCount;
}

/// A conversation visible in the history drawer.
class AiConversationRecord {
  AiConversationRecord({
    required this.id,
    required this.title,
    required List<AiConversationMessage> messages,
    required this.createdAt,
    required this.updatedAt,
    List<AiConversationMessage>? nodes,
    Map<String, String>? selectedChildren,
    this.bookId,
    this.bookName = '',
    this.pageLabel = '',
    this.isPinned = false,
    this.webSources = const [],
    this.modelId,
    this.reasoningLevel,
  }) : nodes = nodes == null
           ? List<AiConversationMessage>.unmodifiable(
               _linearizeMessages(messages),
             )
           : List<AiConversationMessage>.unmodifiable(nodes),
       selectedChildren = Map<String, String>.unmodifiable(
         selectedChildren ??
             _initialSelections(nodes ?? _linearizeMessages(messages)),
       );

  final String id;
  final String title;
  final List<AiConversationMessage> nodes;
  final Map<String, String> selectedChildren;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int? bookId;
  final String bookName;
  final String pageLabel;
  final bool isPinned;
  final List<AiWebSource> webSources;
  final String? modelId;
  final String? reasoningLevel;

  late final Map<String, AiConversationMessage> _nodesById = {
    for (final node in nodes) node.id: node,
  };
  late final Map<String, List<AiConversationMessage>> _childrenByParent =
      _indexChildrenByParent();

  Map<String, List<AiConversationMessage>> _indexChildrenByParent() {
    final grouped = <String, List<AiConversationMessage>>{};
    for (final node in nodes) {
      grouped
          .putIfAbsent(
            node.parentMessageId ?? _rootMessageKey,
            () => <AiConversationMessage>[],
          )
          .add(node);
    }
    return Map.unmodifiable({
      for (final entry in grouped.entries)
        entry.key: List<AiConversationMessage>.unmodifiable(entry.value),
    });
  }

  /// The currently selected root-to-leaf path. Other answer versions and
  /// their continuations remain in [nodes].
  List<AiConversationMessage> get messages {
    if (nodes.isEmpty) return const [];
    final path = <AiConversationMessage>[];
    final visited = <String>{};
    var parentKey = _rootMessageKey;
    while (true) {
      final candidates = _childrenByParent[parentKey];
      if (candidates == null || candidates.isEmpty) break;
      final selectedId = selectedChildren[parentKey];
      final selected = selectedId == null ? null : _nodesById[selectedId];
      var next =
          selected != null &&
              (selected.parentMessageId ?? _rootMessageKey) == parentKey
          ? selected
          : candidates.first;
      if (!next.isUser && !next.isDeletedMarker && next.text.trim().isEmpty) {
        final validAnswers = candidates
            .where(
              (node) =>
                  !node.isUser &&
                  !node.isDeletedMarker &&
                  node.text.trim().isNotEmpty,
            )
            .toList(growable: false);
        if (validAnswers.isNotEmpty) next = validAnswers.last;
      }
      if (!visited.add(next.id)) break;
      if (!next.isDeletedMarker &&
          (next.isUser || next.text.trim().isNotEmpty)) {
        path.add(next);
      }
      parentKey = next.id;
    }
    return path.toList(growable: false);
  }

  AiConversationMessage? nodeById(String messageId) => _nodesById[messageId];

  List<AiConversationMessage> answerVersionsFor(AiConversationMessage answer) {
    if (answer.isUser || answer.isDeletedMarker || answer.text.trim().isEmpty) {
      return const [];
    }
    final question = nodeById(answer.parentMessageId ?? '');
    if (question == null || !question.isUser) return [answer];
    final children = _childrenByParent[question.id];
    if (children == null) return const [];
    return children
        .where(
          (node) =>
              !node.isUser &&
              !node.isDeletedMarker &&
              node.text.trim().isNotEmpty,
        )
        .toList(growable: false);
  }

  List<AiConversationMessage> questionVersionsFor(
    AiConversationMessage question,
  ) {
    if (!question.isUser || question.isDeletedMarker) return [question];
    final siblings =
        _childrenByParent[question.parentMessageId ?? _rootMessageKey];
    if (siblings == null) return const [];
    return siblings
        .where((node) => node.isUser && !node.isDeletedMarker)
        .toList(growable: false);
  }

  AiConversationDeletePreview? previewDeleteReply(String messageId) {
    final answer = nodeById(messageId);
    if (answer == null || answer.isUser || answer.isDeletedMarker) return null;
    final question = nodeById(answer.parentMessageId ?? '');
    if (question == null || !question.isUser) return null;
    final versions = answerVersionsFor(answer);
    if (!versions.any((version) => version.id == answer.id)) return null;

    final deletesQuestion = versions.length == 1;
    final deletedIds = _subtreeIds(deletesQuestion ? question.id : answer.id);
    final deletedNodes = nodes.where((node) => deletedIds.contains(node.id));
    final followUpQuestionCount = deletedNodes
        .where((node) => node.isUser && node.id != question.id)
        .length;
    final removedReplyCount = deletedNodes
        .where((node) => !node.isUser && !node.isDeletedMarker)
        .length;

    return AiConversationDeletePreview(
      deletesQuestion: deletesQuestion,
      answerVersionCount: versions.length,
      followUpQuestionCount: followUpQuestionCount,
      followUpReplyCount: (removedReplyCount - 1)
          .clamp(0, removedReplyCount)
          .toInt(),
    );
  }

  AiConversationRecord? deleteReplyVersion(
    String messageId, {
    required DateTime updatedAt,
  }) {
    final preview = previewDeleteReply(messageId);
    if (preview == null) return null;
    final answer = nodeById(messageId)!;
    final question = nodeById(answer.parentMessageId!)!;
    final versions = answerVersionsFor(answer);
    final selectedIndex = versions.indexWhere(
      (version) => version.id == answer.id,
    );
    final currentSelection = nodeById(selectedChildren[question.id] ?? '');
    final hasOtherValidSelection =
        currentSelection != null &&
        currentSelection.id != answer.id &&
        versions.any((version) => version.id == currentSelection.id);
    final nextSelectedAnswer = preview.deletesQuestion
        ? null
        : hasOtherValidSelection
        ? currentSelection
        : versions[selectedIndex + 1 < versions.length
              ? selectedIndex + 1
              : selectedIndex - 1];
    final deletedIds = _subtreeIds(
      preview.deletesQuestion ? question.id : answer.id,
    );
    final updatedNodes = nodes
        .where((node) => !deletedIds.contains(node.id))
        .toList();
    while (true) {
      final parentsWithChildren = updatedNodes
          .map((node) => node.parentMessageId)
          .whereType<String>()
          .toSet();
      final emptyMarkers = updatedNodes
          .where(
            (node) =>
                node.isDeletedMarker && !parentsWithChildren.contains(node.id),
          )
          .map((node) => node.id)
          .toSet();
      if (emptyMarkers.isEmpty) break;
      updatedNodes.removeWhere((node) => emptyMarkers.contains(node.id));
    }
    final childrenByParent = <String, List<AiConversationMessage>>{};
    for (final node in updatedNodes) {
      childrenByParent
          .putIfAbsent(node.parentMessageId ?? _rootMessageKey, () => [])
          .add(node);
    }
    final selections = <String, String>{};
    for (final entry in childrenByParent.entries) {
      final children = entry.value;
      final previouslySelected = selectedChildren[entry.key];
      selections[entry.key] =
          children.any((child) => child.id == previouslySelected)
          ? previouslySelected!
          : children.first.id;
    }
    if (nextSelectedAnswer != null) {
      selections[question.id] = nextSelectedAnswer.id;
    }

    return copyWith(
      nodes: updatedNodes,
      selectedChildren: selections,
      updatedAt: updatedAt,
    );
  }

  Set<String> _subtreeIds(String rootId) {
    final childrenByParent = <String, List<String>>{};
    for (final node in nodes) {
      childrenByParent
          .putIfAbsent(node.parentMessageId ?? _rootMessageKey, () => [])
          .add(node.id);
    }
    final visited = <String>{};
    final pending = <String>[rootId];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!visited.add(id)) continue;
      pending.addAll(childrenByParent[id] ?? const <String>[]);
    }
    return visited;
  }

  bool isLatestVisibleAnswer(String messageId) {
    final lastVisibleMessage = messages.lastOrNull;
    return lastVisibleMessage?.id == messageId &&
        lastVisibleMessage != null &&
        !lastVisibleMessage.isUser;
  }

  AiConversationRecord selectAnswerVersion(String messageId) {
    final answer = nodeById(messageId);
    if (answer == null || answer.isUser || answer.parentMessageId == null) {
      return this;
    }
    return copyWith(
      selectedChildren: {
        ...selectedChildren,
        answer.parentMessageId!: answer.id,
      },
    );
  }

  AiConversationRecord selectQuestionVersion(String messageId) {
    final question = nodeById(messageId);
    if (question == null || !question.isUser || question.isDeletedMarker) {
      return this;
    }
    return copyWith(
      selectedChildren: {
        ...selectedChildren,
        (question.parentMessageId ?? _rootMessageKey): question.id,
      },
    );
  }

  AiConversationRecord appendQuestionVersion(
    String sourceQuestionId,
    AiConversationMessage question,
  ) {
    final source = nodeById(sourceQuestionId);
    if (source == null ||
        !source.isUser ||
        source.isDeletedMarker ||
        !question.isUser ||
        question.isDeletedMarker ||
        nodes.any((node) => node.id == question.id)) {
      return this;
    }
    final newQuestion = question.copyWith(
      parentMessageId: source.parentMessageId,
      clearParentMessageId: source.parentMessageId == null,
    );
    return copyWith(
      nodes: [...nodes, newQuestion],
      selectedChildren: {
        ...selectedChildren,
        (newQuestion.parentMessageId ?? _rootMessageKey): newQuestion.id,
      },
    );
  }

  AiConversationRecord appendAnswerVersion(
    String questionId,
    AiConversationMessage answer,
  ) {
    final updatedAnswer = answer.copyWith(parentMessageId: questionId);
    return copyWith(
      nodes: [...nodes, updatedAnswer],
      selectedChildren: {...selectedChildren, questionId: updatedAnswer.id},
    );
  }

  factory AiConversationRecord.empty({
    int? bookId,
    String bookName = '',
    String pageLabel = '',
  }) {
    final now = DateTime.now();
    return AiConversationRecord(
      id: 'conversation-${now.microsecondsSinceEpoch}',
      title: '',
      messages: const [],
      createdAt: now,
      updatedAt: now,
      bookId: bookId,
      bookName: bookName,
      pageLabel: pageLabel,
      webSources: const [],
    );
  }

  factory AiConversationRecord.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid conversation');
    final createdAt = DateTime.tryParse(raw['created_at']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(raw['updated_at']?.toString() ?? '');
    List<AiConversationMessage> readMessages(Object? value) => value is List
        ? value
              .map(AiConversationMessage.fromJson)
              .where(
                (message) =>
                    message.isDeletedMarker ||
                    message.text.trim().isNotEmpty ||
                    message.capabilityMetadata != null ||
                    message.attachments.isNotEmpty,
              )
              .toList(growable: false)
        : const <AiConversationMessage>[];
    final messages = readMessages(raw['messages']);
    final nodes = readMessages(raw['nodes']);
    final rawSelections = raw['selected_children'];
    final selectedChildren = rawSelections is Map
        ? rawSelections.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          )
        : null;
    return AiConversationRecord(
      id: raw['id']?.toString() ?? '',
      title: raw['title']?.toString() ?? '',
      messages: messages,
      nodes: nodes.isEmpty ? null : nodes,
      selectedChildren: selectedChildren,
      createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          updatedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      bookId: raw['book_id'] is int
          ? raw['book_id'] as int
          : int.tryParse(raw['book_id']?.toString() ?? ''),
      bookName: raw['book_name']?.toString() ?? '',
      pageLabel: raw['page_label']?.toString() ?? '',
      isPinned: raw['is_pinned'] == true,
      webSources: raw['web_sources'] is List
          ? (raw['web_sources'] as List)
                .map((item) {
                  try {
                    return AiWebSource.fromJson(item);
                  } on FormatException {
                    return null;
                  }
                })
                .whereType<AiWebSource>()
                .toList(growable: false)
          : const [],
      modelId: raw['model_id']?.toString(),
      reasoningLevel: raw['reasoning_level']?.toString(),
    );
  }

  AiConversationRecord copyWith({
    String? title,
    List<AiConversationMessage>? messages,
    DateTime? updatedAt,
    String? pageLabel,
    bool? isPinned,
    List<AiWebSource>? webSources,
    String? modelId,
    String? reasoningLevel,
    List<AiConversationMessage>? nodes,
    Map<String, String>? selectedChildren,
  }) {
    final updatedNodes =
        nodes ?? (messages == null ? this.nodes : _mergeVisiblePath(messages));
    final updatedSelections =
        selectedChildren ??
        (messages == null
            ? this.selectedChildren
            : _selectionsForVisiblePath(messages));
    return AiConversationRecord(
      id: id,
      title: title ?? this.title,
      messages: messages ?? _pathFor(updatedNodes, updatedSelections),
      nodes: updatedNodes,
      selectedChildren: updatedSelections,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      bookId: bookId,
      bookName: bookName,
      pageLabel: pageLabel ?? this.pageLabel,
      isPinned: isPinned ?? this.isPinned,
      webSources: webSources ?? this.webSources,
      modelId: modelId ?? this.modelId,
      reasoningLevel: reasoningLevel ?? this.reasoningLevel,
    );
  }

  Map<String, Object?> toJson() => {
    'schema_version': 2,
    'id': id,
    'title': title,
    'messages': messages.map((message) => message.toJson()).toList(),
    'nodes': nodes.map((message) => message.toJson()).toList(),
    'selected_children': selectedChildren,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'book_id': bookId,
    'book_name': bookName,
    'page_label': pageLabel,
    'is_pinned': isPinned,
    'web_sources': webSources.map((source) => source.toJson()).toList(),
    'model_id': modelId,
    'reasoning_level': reasoningLevel,
  };

  String get displayTitle {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isNotEmpty) return normalizedTitle;
    final firstQuestion = messages
        .where((message) => message.isUser && message.text.trim().isNotEmpty)
        .map((message) => message.text.trim())
        .firstOrNull;
    return firstQuestion == null ? '未命名会话' : _shorten(firstQuestion);
  }

  bool matches(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    return displayTitle.toLowerCase().contains(normalized) ||
        bookName.toLowerCase().contains(normalized) ||
        messages.any(
          (message) =>
              !message.isDeletedMarker &&
              message.text.toLowerCase().contains(normalized),
        );
  }

  String? matchSnippet(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    final candidates = <String>[
      displayTitle,
      bookName,
      ...messages
          .where((item) => !item.isDeletedMarker)
          .map((item) => item.text),
    ];
    for (final candidate in candidates) {
      final lower = candidate.toLowerCase();
      final index = lower.indexOf(normalized);
      if (index < 0) continue;
      final start = index > 18 ? index - 18 : 0;
      final end = (index + normalized.length + 28)
          .clamp(0, candidate.length)
          .toInt();
      return '${start > 0 ? '…' : ''}${candidate.substring(start, end)}${end < candidate.length ? '…' : ''}';
    }
    return null;
  }

  static String _shorten(String text) {
    if (text.length <= 28) return text;
    return '${text.substring(0, 28)}…';
  }

  List<AiConversationMessage> _mergeVisiblePath(
    List<AiConversationMessage> visibleMessages,
  ) {
    final merged = {for (final node in nodes) node.id: node};
    var parentId = null as String?;
    for (final message in visibleMessages) {
      final node = message.copyWith(
        parentMessageId: parentId,
        clearParentMessageId: parentId == null,
      );
      merged[node.id] = node;
      parentId = node.id;
    }
    return List<AiConversationMessage>.unmodifiable(merged.values);
  }

  Map<String, String> _selectionsForVisiblePath(
    List<AiConversationMessage> visibleMessages,
  ) {
    final selections = {...selectedChildren};
    String? parentId;
    for (final message in visibleMessages) {
      selections[parentId ?? _rootMessageKey] = message.id;
      parentId = message.id;
    }
    return selections;
  }
}

List<AiConversationMessage> _linearizeMessages(
  List<AiConversationMessage> messages,
) {
  final result = <AiConversationMessage>[];
  String? parentId;
  for (final message in messages) {
    final node = message.copyWith(
      parentMessageId: parentId,
      clearParentMessageId: parentId == null,
    );
    result.add(node);
    parentId = node.id;
  }
  return List<AiConversationMessage>.unmodifiable(result);
}

Map<String, String> _initialSelections(List<AiConversationMessage> nodes) {
  final result = <String, String>{};
  for (final node in nodes) {
    result.putIfAbsent(node.parentMessageId ?? _rootMessageKey, () => node.id);
  }
  return result;
}

List<AiConversationMessage> _pathFor(
  List<AiConversationMessage> nodes,
  Map<String, String> selectedChildren,
) {
  final snapshot = AiConversationRecord(
    id: '',
    title: '',
    messages: const [],
    nodes: nodes,
    selectedChildren: selectedChildren,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
  return snapshot.messages;
}

/// Local-only persistence for conversation history.
///
/// It deliberately stores only conversations that contain a real user
/// message. Empty sessions never appear in history, which prevents design
/// placeholder data from looking like a user's past conversation.
class AiConversationHistoryService {
  AiConversationHistoryService({SharedPreferences? preferences})
    : _preferences = preferences;

  static final AiConversationHistoryService instance =
      AiConversationHistoryService();

  static const _storageKey = 'ai_study_annotation.conversations.v1';
  static const _versionSelectionStorageKey =
      'ai_study_annotation.version_selections.v1';

  final Map<String, AiConversationRecord> _records = {};
  final Map<String, _VersionSelectionSnapshot> _versionSelections = {};
  final Map<String, _VersionSelectionSnapshot> _persistedVersionSelections = {};
  final Map<String, _VersionSelectionSnapshot> _versionSelectionFallbacks = {};
  final Map<String, int> _versionSelectionRevisions = {};
  final List<_PendingVersionSelectionWrite> _versionSelectionWaiters = [];
  bool _versionSelectionFlushScheduled = false;
  SharedPreferences? _preferences;
  Future<void>? _loading;
  Future<void>? _writeQueue;
  bool _loaded = false;

  Future<List<AiConversationRecord>> list({
    int? bookId,
    String bookName = '',
    bool allBooks = false,
    String query = '',
  }) async {
    await _ensureLoaded();
    final result = _records.values
        .map(_applyVersionSelection)
        .where(
          (record) =>
              (allBooks ||
                  _sameBook(record, bookId: bookId, bookName: bookName)) &&
              record.matches(query),
        )
        .toList();
    result.sort((a, b) {
      final pinOrder = (b.isPinned ? 1 : 0).compareTo(a.isPinned ? 1 : 0);
      if (pinOrder != 0) return pinOrder;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return result;
  }

  Future<AiConversationRecord?> latestForBook({
    int? bookId,
    String bookName = '',
  }) async {
    final records = await list(bookId: bookId, bookName: bookName);
    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return records.firstOrNull;
  }

  Future<void> save(AiConversationRecord record) async {
    if (record.messages.isEmpty) return;
    await _ensureLoaded();
    await _enqueueMutation(
      apply: () {
        _synchronizeSelectionForStructuralWrite(record);
        return true;
      },
      rollback: () {},
    );
  }

  /// Persists a structural conversation change atomically and restores the
  /// in-memory record when the underlying local write fails.
  Future<void> saveTransactional(AiConversationRecord record) async {
    await _ensureLoaded();
    AiConversationRecord? previous;
    var hadPrevious = false;
    _VersionSelectionSnapshot? previousSelection;
    var selectionChanged = false;
    await _enqueueMutation(
      apply: () {
        hadPrevious = _records.containsKey(record.id);
        previous = _records[record.id];
        previousSelection = _versionSelections[record.id];
        selectionChanged =
            previous != null &&
            !_sameSelections(
              previous!.selectedChildren,
              record.selectedChildren,
            );
        _synchronizeSelectionForStructuralWrite(record);
        return true;
      },
      rollback: () {
        if (hadPrevious && previous != null) {
          _records[record.id] = previous!;
        } else {
          _records.remove(record.id);
        }
        if (selectionChanged) {
          if (previousSelection == null) {
            _versionSelections.remove(record.id);
          } else {
            _versionSelections[record.id] = previousSelection!;
          }
        }
      },
      throwOnFailure: true,
    );
  }

  /// Updates the visible branch immediately and persists only its selection.
  Future<void> saveVersionSelection(
    AiConversationRecord record, {
    required AiConversationRecord fallbackRecord,
  }) {
    final revision = (_versionSelectionRevisions[record.id] ?? 0) + 1;
    _versionSelectionRevisions[record.id] = revision;
    _versionSelectionFallbacks.putIfAbsent(
      record.id,
      () => _snapshotSelection(fallbackRecord),
    );
    _versionSelections[record.id] = _snapshotSelection(record);
    final stored = _records[record.id];
    _records[record.id] = stored == null
        ? record
        : stored.copyWith(
            selectedChildren: record.selectedChildren,
            updatedAt: record.updatedAt,
          );

    final completer = Completer<void>();
    _versionSelectionWaiters.add(
      _PendingVersionSelectionWrite(record.id, revision, completer),
    );
    _scheduleVersionSelectionFlush();
    return completer.future;
  }

  /// Restores the most recently persisted selection after a write failure.
  AiConversationRecord restoreVersionSelection(AiConversationRecord record) {
    final snapshot =
        _persistedVersionSelections[record.id] ??
        _versionSelectionFallbacks[record.id];
    if (snapshot == null) return record;
    return record.copyWith(
      selectedChildren: snapshot.selectedChildren,
      updatedAt: snapshot.updatedAt,
    );
  }

  AiConversationRecord _applyVersionSelection(AiConversationRecord record) {
    final snapshot = _versionSelections[record.id];
    if (snapshot == null || !snapshot.updatedAt.isAfter(record.updatedAt)) {
      return record;
    }
    return record.copyWith(
      selectedChildren: snapshot.selectedChildren,
      updatedAt: snapshot.updatedAt,
    );
  }

  void _synchronizeSelectionForStructuralWrite(AiConversationRecord record) {
    final previous = _records[record.id];
    if (previous != null &&
        !_sameSelections(previous.selectedChildren, record.selectedChildren)) {
      // Structural actions can deliberately move a branch selection, such as
      // appending a new reply or removing the selected version. Let that
      // current tree replace the older browsing override.
      _versionSelections[record.id] = _snapshotSelection(record);
    }
    _records[record.id] = _applyVersionSelection(record);
  }

  bool _sameSelections(Map<String, String> first, Map<String, String> second) {
    if (identical(first, second)) return true;
    if (first.length != second.length) return false;
    for (final entry in first.entries) {
      if (second[entry.key] != entry.value) return false;
    }
    return true;
  }

  _VersionSelectionSnapshot _snapshotSelection(AiConversationRecord record) =>
      _VersionSelectionSnapshot(record.selectedChildren, record.updatedAt);

  void _scheduleVersionSelectionFlush() {
    if (_versionSelectionFlushScheduled) return;
    _versionSelectionFlushScheduled = true;
    scheduleMicrotask(() {
      _versionSelectionFlushScheduled = false;
      final waiters = List<_PendingVersionSelectionWrite>.of(
        _versionSelectionWaiters,
      );
      _versionSelectionWaiters.clear();
      final revisions = {
        for (final waiter in waiters) waiter.conversationId: waiter.revision,
      };
      unawaited(_flushVersionSelectionWrites(waiters, revisions));
    });
  }

  Future<void> _flushVersionSelectionWrites(
    List<_PendingVersionSelectionWrite> waiters,
    Map<String, int> revisions,
  ) async {
    try {
      await _ensureLoaded();
      final previous = _writeQueue;
      final operation = (previous ?? Future<void>.value())
          .catchError((Object _) {})
          .then((_) => _writeVersionSelections());
      _writeQueue = operation;
      try {
        await operation;
      } finally {
        if (identical(_writeQueue, operation)) _writeQueue = null;
      }
      for (final entry in revisions.entries) {
        if (_versionSelectionRevisions[entry.key] == entry.value) {
          _versionSelectionFallbacks.remove(entry.key);
        }
      }
      for (final waiter in waiters) {
        if (!waiter.completer.isCompleted) waiter.completer.complete();
      }
    } catch (error, stackTrace) {
      for (final entry in revisions.entries) {
        if (_versionSelectionRevisions[entry.key] != entry.value) continue;
        final saved = _persistedVersionSelections[entry.key];
        final fallback = _versionSelectionFallbacks[entry.key];
        final restore = saved ?? fallback;
        if (restore == null) {
          _versionSelections.remove(entry.key);
        } else {
          _versionSelections[entry.key] = restore;
        }
        final record = _records[entry.key];
        if (record != null && restore != null) {
          _records[entry.key] = record.copyWith(
            selectedChildren: restore.selectedChildren,
            updatedAt: restore.updatedAt,
          );
        }
      }
      for (final waiter in waiters) {
        if (!waiter.completer.isCompleted) {
          waiter.completer.completeError(error, stackTrace);
        }
      }
    }
    if (_versionSelectionWaiters.isNotEmpty) {
      _scheduleVersionSelectionFlush();
    }
  }

  Future<void> _writeVersionSelections() async {
    _preferences ??= await SharedPreferences.getInstance();
    final snapshot = Map<String, _VersionSelectionSnapshot>.of(
      _versionSelections,
    );
    final activeIds = _records.keys.toSet();
    snapshot.removeWhere((id, _) => !activeIds.contains(id));
    final saved = await _preferences!.setString(
      _versionSelectionStorageKey,
      jsonEncode({
        for (final entry in snapshot.entries) entry.key: entry.value.toJson(),
      }),
    );
    if (!saved) throw StateError('Could not save conversation version');
    _persistedVersionSelections
      ..clear()
      ..addAll(snapshot);
    _versionSelections.removeWhere((id, _) => !activeIds.contains(id));
  }

  Future<void> setPinned(String id, bool pinned) async {
    await _ensureLoaded();
    await _enqueueMutation(
      apply: () {
        final record = _records[id];
        if (record == null) return false;
        _records[id] = record.copyWith(isPinned: pinned);
        return true;
      },
      rollback: () {},
    );
  }

  /// Moves an existing conversation into a book without changing its id,
  /// messages, timestamps, or source lineage.
  Future<void> attachToBook(
    String id, {
    required int bookId,
    required String bookName,
  }) async {
    await _ensureLoaded();
    AiConversationRecord? previous;
    AiConversationRecord? updated;
    await _enqueueMutation(
      apply: () {
        final record = _records[id];
        if (record == null) return false;
        previous = record;
        updated = AiConversationRecord(
          id: record.id,
          title: record.title,
          messages: record.messages,
          nodes: record.nodes,
          selectedChildren: record.selectedChildren,
          createdAt: record.createdAt,
          updatedAt: record.updatedAt,
          bookId: bookId,
          bookName: bookName,
          pageLabel: record.pageLabel,
          isPinned: record.isPinned,
          webSources: record.webSources,
          modelId: record.modelId,
          reasoningLevel: record.reasoningLevel,
        );
        _records[id] = updated!;
        return true;
      },
      rollback: () {
        if (previous != null && identical(_records[id], updated)) {
          _records[id] = previous!;
        }
      },
      throwOnFailure: true,
    );
  }

  /// Moves a conversation back to the independent list without changing its
  /// messages, timestamps, title, or source lineage.
  Future<void> detachFromBook(String id) async {
    await _ensureLoaded();
    AiConversationRecord? previous;
    AiConversationRecord? updated;
    await _enqueueMutation(
      apply: () {
        final record = _records[id];
        if (record == null ||
            (record.bookId == null && record.bookName.trim().isEmpty)) {
          return false;
        }
        previous = record;
        updated = AiConversationRecord(
          id: record.id,
          title: record.title,
          messages: record.messages,
          nodes: record.nodes,
          selectedChildren: record.selectedChildren,
          createdAt: record.createdAt,
          updatedAt: record.updatedAt,
          pageLabel: record.pageLabel,
          isPinned: record.isPinned,
          webSources: record.webSources,
          modelId: record.modelId,
          reasoningLevel: record.reasoningLevel,
        );
        _records[id] = updated!;
        return true;
      },
      rollback: () {
        if (previous != null && identical(_records[id], updated)) {
          _records[id] = previous!;
        }
      },
      throwOnFailure: true,
    );
  }

  Future<void> rename(String id, String title) async {
    await _ensureLoaded();
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) return;
    AiConversationRecord? previous;
    AiConversationRecord? updated;
    await _enqueueMutation(
      apply: () {
        final record = _records[id];
        if (record == null) return false;
        previous = record;
        updated = record.copyWith(
          title: normalizedTitle,
          updatedAt: DateTime.now(),
        );
        _records[id] = updated!;
        return true;
      },
      rollback: () {
        if (previous != null && identical(_records[id], updated)) {
          _records[id] = previous!;
        }
      },
      throwOnFailure: true,
    );
  }

  Future<void> delete(Iterable<String> ids) async {
    await _ensureLoaded();
    final uniqueIds = ids.toSet();
    final previous = <String, AiConversationRecord>{};
    await _enqueueMutation(
      apply: () {
        for (final id in uniqueIds) {
          final record = _records[id];
          if (record != null) previous[id] = record;
        }
        if (previous.isEmpty) return false;
        for (final id in previous.keys) {
          _records.remove(id);
        }
        return true;
      },
      rollback: () => _records.addAll(previous),
      throwOnFailure: true,
    );
  }

  Future<void> _enqueueMutation({
    required bool Function() apply,
    required void Function() rollback,
    bool throwOnFailure = false,
  }) async {
    final previous = _writeQueue;
    final operation = (previous ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) async {
          try {
            if (!apply()) return;
            await _writeRecords();
          } catch (_) {
            if (throwOnFailure) {
              rollback();
              rethrow;
            }
          }
        });
    _writeQueue = operation;
    try {
      await operation;
    } finally {
      if (identical(_writeQueue, operation)) _writeQueue = null;
    }
  }

  Future<void> _writeRecords() async {
    _preferences ??= await SharedPreferences.getInstance();
    final currentRecords = _records.values
        .where((record) => record.messages.isNotEmpty)
        .toList(growable: false);
    final records = currentRecords.map((record) => record.toJson()).toList();
    final saved = await _preferences!.setString(
      _storageKey,
      jsonEncode(records),
    );
    if (!saved) throw StateError('Could not save conversation history');

    final activeIds = currentRecords.map((record) => record.id).toSet();
    _versionSelections.removeWhere((id, _) => !activeIds.contains(id));
    _persistedVersionSelections.removeWhere((id, _) => !activeIds.contains(id));
    for (final record in currentRecords) {
      final persisted = _snapshotSelection(record);
      _persistedVersionSelections[record.id] = persisted;
      final pending = _versionSelections[record.id];
      if (pending == null ||
          (!pending.updatedAt.isAfter(record.updatedAt) &&
              _sameSelections(
                pending.selectedChildren,
                record.selectedChildren,
              ))) {
        _versionSelections[record.id] = persisted;
      }
    }
    // The full record write already committed these selections. The compact
    // index is a fast-path mirror, so its failure must not roll back that write.
    try {
      await _writeVersionSelections();
    } catch (_) {}
  }

  Future<void> _ensureLoaded() async {
    final activeLoad = _loading;
    if (activeLoad != null) return activeLoad;
    if (_loaded) return;
    final load = _load();
    _loading = load;
    try {
      await load;
    } finally {
      if (identical(_loading, load)) _loading = null;
    }
  }

  Future<void> _load() async {
    try {
      _preferences ??= await SharedPreferences.getInstance();
      final selectionsRaw = _preferences!.getString(
        _versionSelectionStorageKey,
      );
      if (selectionsRaw != null && selectionsRaw.trim().isNotEmpty) {
        try {
          final decodedSelections = jsonDecode(selectionsRaw);
          if (decodedSelections is Map) {
            for (final entry in decodedSelections.entries) {
              try {
                final id = entry.key.toString();
                final snapshot = _VersionSelectionSnapshot.fromJson(
                  entry.value,
                );
                _persistedVersionSelections[id] = snapshot;
                _versionSelections.putIfAbsent(id, () => snapshot);
              } on FormatException {
                // Ignore a corrupt selection without hiding its conversation.
              }
            }
          }
        } on FormatException {
          // The main history remains usable if this small index is corrupt.
        }
      }
      final raw = _preferences!.getString(_storageKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            try {
              final record = AiConversationRecord.fromJson(item);
              if (record.id.isNotEmpty && record.messages.isNotEmpty) {
                final snapshot = _versionSelections[record.id];
                if (snapshot != null &&
                    !snapshot.updatedAt.isAfter(record.updatedAt)) {
                  final persisted = _snapshotSelection(record);
                  _versionSelections[record.id] = persisted;
                  _persistedVersionSelections[record.id] = persisted;
                  _records[record.id] = record;
                } else {
                  _records[record.id] = _applyVersionSelection(record);
                }
              }
            } on FormatException {
              // Ignore one corrupt record without hiding the remaining history.
            }
          }
        }
      }
    } catch (_) {
      // History is an enhancement; a storage/plugin failure must not block
      // opening the editor or sending the current question.
    } finally {
      _loaded = true;
    }
  }

  bool _sameBook(
    AiConversationRecord record, {
    required int? bookId,
    required String bookName,
  }) {
    if (bookId != null) return record.bookId == bookId;
    final normalizedName = bookName.trim();
    if (normalizedName.isNotEmpty) {
      return record.bookId == null && record.bookName.trim() == normalizedName;
    }
    return record.bookId == null && record.bookName.trim().isEmpty;
  }
}

class _VersionSelectionSnapshot {
  _VersionSelectionSnapshot(
    Map<String, String> selectedChildren,
    this.updatedAt,
  ) : selectedChildren = Map<String, String>.unmodifiable(selectedChildren);

  final Map<String, String> selectedChildren;
  final DateTime updatedAt;

  factory _VersionSelectionSnapshot.fromJson(Object? raw) {
    if (raw is! Map || raw['selected_children'] is! Map) {
      throw const FormatException('Invalid conversation selection');
    }
    final rawSelections = raw['selected_children'] as Map;
    final updatedAt = DateTime.tryParse(raw['updated_at']?.toString() ?? '');
    if (updatedAt == null) {
      throw const FormatException('Invalid conversation selection date');
    }
    return _VersionSelectionSnapshot(
      rawSelections.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      updatedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'selected_children': selectedChildren,
    'updated_at': updatedAt.toIso8601String(),
  };
}

class _PendingVersionSelectionWrite {
  const _PendingVersionSelectionWrite(
    this.conversationId,
    this.revision,
    this.completer,
  );

  final String conversationId;
  final int revision;
  final Completer<void> completer;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
