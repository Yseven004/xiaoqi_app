import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../config/note_page_theme.dart';
import '../data/ai_conversation_history.dart';
import '../domain/ai_annotation_source_attachment.dart';
import '../domain/ai_web_source.dart';
import '../../realtime_voice/domain/realtime_voice_session.dart';
import '../../../services/web_article_source_service.dart';
import 'ai_annotation_attachment_tray.dart';
import '../../../widgets/app_text_input_dialog.dart';
import '../../../widgets/math_markdown.dart';
import '../../../widgets/app_toast.dart';

final _aiAnswerMarkdownStyle = MarkdownStyleSheet(
  p: const TextStyle(color: NotePageTheme.ink, fontSize: 15, height: 1.55),
  h1: const TextStyle(
    color: NotePageTheme.ink,
    fontSize: 21,
    fontWeight: FontWeight.w700,
    height: 1.3,
  ),
  h2: const TextStyle(
    color: NotePageTheme.ink,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    height: 1.35,
  ),
  h3: const TextStyle(
    color: NotePageTheme.ink,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.4,
  ),
  listBullet: const TextStyle(color: NotePageTheme.ochre, fontSize: 15),
  strong: const TextStyle(fontWeight: FontWeight.w700),
  em: const TextStyle(fontStyle: FontStyle.italic),
  blockquote: const TextStyle(
    color: NotePageTheme.inkSecondary,
    fontSize: 15,
    height: 1.55,
  ),
  code: const TextStyle(
    color: NotePageTheme.ink,
    fontFamily: 'monospace',
    fontSize: 14,
    backgroundColor: Color(0x11000000),
  ),
);

String _markdownForDisplay(String raw, {required bool streaming}) {
  var value = raw.replaceAll('\r\n', '\n');

  // Hide a formatting prefix while the model is still completing that line.
  value = value.replaceAllMapped(
    RegExp(r'^(\s*)(#{1,6})(?!#)(\S)', multiLine: true),
    (match) => '${match[1]}${match[3]}',
  );
  value = value.replaceAllMapped(
    RegExp(r'^\s*(#{1,6})\s*$', multiLine: true),
    (_) => '',
  );
  value = value.replaceAllMapped(
    RegExp(r'^(\s*)([-+*]|\d+[.)]|>)\s*$', multiLine: true),
    (match) => match[1] ?? '',
  );

  // An unmatched delimiter is the only part that must be hidden during a
  // stream; complete delimiters remain available to flutter_markdown.
  for (final delimiter in const ['```', '**', '__', '~~', '`']) {
    if (delimiter.allMatches(value).length.isOdd) {
      final index = value.lastIndexOf(delimiter);
      value = value.replaceRange(index, index + delimiter.length, '');
    }
  }
  return streaming ? '$value▌' : value;
}

/// The conversation surface used by the book editor.
///
/// It owns only presentation state (compact, expanded, and history). Source
/// attachments remain owned by the editor so changing pages cannot silently
/// lose them.
class AiConversationPanel extends StatefulWidget {
  const AiConversationPanel({
    super.key,
    required this.annotationCount,
    required this.onClose,
    this.onSubmit,
    this.onVoice,
    this.voiceSession,
    this.onEndVoice,
    this.onClearVoiceFocus,
    this.bookId,
    this.bookName,
    this.pageLabel,
    this.historyService,
    this.attachments = const [],
    this.onRemoveAttachment,
    this.onSubmitWithWebSources,
  });

  final int annotationCount;
  final VoidCallback onClose;
  final ValueChanged<String>? onSubmit;
  final VoidCallback? onVoice;
  final RealtimeVoiceSession? voiceSession;
  final VoidCallback? onEndVoice;
  final VoidCallback? onClearVoiceFocus;
  final int? bookId;
  final String? bookName;
  final String? pageLabel;
  final AiConversationHistoryService? historyService;
  final List<AiAnnotationSourceAttachment> attachments;
  final ValueChanged<String>? onRemoveAttachment;
  final void Function(String text, List<AiWebSource> sources)?
  onSubmitWithWebSources;

  @override
  State<AiConversationPanel> createState() => _AiConversationPanelState();
}

class _AiConversationPanelState extends State<AiConversationPanel> {
  final _composerController = TextEditingController();
  final _historySearchController = TextEditingController();
  final _messages = <AiConversationMessage>[];
  late final AiConversationHistoryService _historyService;
  List<AiConversationRecord> _history = const [];
  AiConversationRecord? _conversation;
  String _historyQuery = '';
  bool _historyAllBooks = false;
  bool _historyLoading = false;
  bool _historySelectionMode = false;
  final _selectedHistoryIds = <String>{};
  bool _expanded = false;
  bool _historyOpen = false;
  List<AiWebSource> _webSources = const [];
  bool _webSourceLoading = false;
  RealtimeVoiceSession? _boundVoiceSession;
  final _ingestedVoiceTranscriptKeys = <String>{};
  final _voiceDraftTranscriptIndexes = <String, int>{};

  int _historyRequest = 0;

  @override
  void initState() {
    super.initState();
    _historyService =
        widget.historyService ?? AiConversationHistoryService.instance;
    _bindVoiceSession(widget.voiceSession);
    unawaited(_restoreLatestConversation());
  }

  @override
  void didUpdateWidget(covariant AiConversationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.voiceSession, widget.voiceSession)) {
      _bindVoiceSession(widget.voiceSession);
    }
  }

  @override
  void dispose() {
    _boundVoiceSession?.removeListener(_onVoiceSessionChanged);
    _composerController.dispose();
    _historySearchController.dispose();
    super.dispose();
  }

  void _bindVoiceSession(RealtimeVoiceSession? session) {
    _boundVoiceSession?.removeListener(_onVoiceSessionChanged);
    _boundVoiceSession = session;
    _ingestedVoiceTranscriptKeys.clear();
    _voiceDraftTranscriptIndexes.clear();
    session?.addListener(_onVoiceSessionChanged);
    _ingestVoiceTranscripts(session);
  }

  void _onVoiceSessionChanged() {
    _ingestVoiceTranscripts(_boundVoiceSession);
    if (mounted) setState(() {});
  }

  void _ingestVoiceTranscripts(RealtimeVoiceSession? session) {
    if (session == null) return;
    for (var index = 0; index < session.transcripts.length; index++) {
      final transcript = session.transcripts[index];
      if (transcript.speaker == VoiceSpeaker.system) continue;
      if (transcript.text.trim().isEmpty) continue;
      final turnKey =
          transcript.turnId ?? 'legacy:$index:${transcript.speaker.name}';
      if (!transcript.isFinal) {
        if (transcript.speaker == VoiceSpeaker.assistant) {
          _upsertVoiceAssistantDraft(turnKey, transcript);
        }
        continue;
      }
      final key = '$turnKey:final';
      if (!_ingestedVoiceTranscriptKeys.add(key)) continue;
      final now = transcript.createdAt;
      final current =
          _conversation ??
          AiConversationRecord.empty(
            bookId: widget.bookId,
            bookName: widget.bookName ?? '',
            pageLabel: widget.pageLabel ?? '',
          );
      final draftIndex = transcript.speaker == VoiceSpeaker.assistant
          ? _voiceDraftTranscriptIndexes.remove(turnKey)
          : null;
      var messageText = transcript.text.trim();
      if (draftIndex != null &&
          draftIndex >= 0 &&
          draftIndex < current.messages.length &&
          !current.messages[draftIndex].isUser) {
        messageText = _keepStreamingText(
          current.messages[draftIndex].text,
          messageText,
        );
      }
      final nextMessage = AiConversationMessage(
        text: messageText,
        isUser: transcript.speaker == VoiceSpeaker.user,
        pageLabel: widget.pageLabel ?? current.pageLabel,
        createdAt: now,
      );
      final nextMessages = [...current.messages];
      if (draftIndex != null &&
          draftIndex >= 0 &&
          draftIndex < nextMessages.length) {
        nextMessages[draftIndex] = nextMessage;
      } else {
        nextMessages.add(nextMessage);
      }
      final updated = current.copyWith(
        title:
            current.title.trim().isEmpty &&
                transcript.speaker == VoiceSpeaker.user
            ? transcript.text.trim()
            : current.title,
        messages: nextMessages,
        pageLabel: widget.pageLabel ?? current.pageLabel,
        updatedAt: now,
      );
      _conversation = updated;
      _messages
        ..clear()
        ..addAll(updated.messages);
      unawaited(_saveConversation(updated));
    }
  }

  void _upsertVoiceAssistantDraft(String turnKey, VoiceTranscript transcript) {
    final current =
        _conversation ??
        AiConversationRecord.empty(
          bookId: widget.bookId,
          bookName: widget.bookName ?? '',
          pageLabel: widget.pageLabel ?? '',
        );
    final now = transcript.createdAt;
    final message = AiConversationMessage(
      text: transcript.text,
      isUser: false,
      pageLabel: widget.pageLabel ?? current.pageLabel,
      createdAt: now,
    );
    final draftIndex = _voiceDraftTranscriptIndexes[turnKey];
    final nextMessages = [...current.messages];
    if (draftIndex != null &&
        draftIndex >= 0 &&
        draftIndex < nextMessages.length &&
        !nextMessages[draftIndex].isUser) {
      nextMessages[draftIndex] = message;
    } else {
      _voiceDraftTranscriptIndexes[turnKey] = nextMessages.length;
      nextMessages.add(message);
    }
    _conversation = current.copyWith(
      messages: nextMessages,
      pageLabel: widget.pageLabel ?? current.pageLabel,
      updatedAt: now,
    );
    _messages
      ..clear()
      ..addAll(nextMessages);
  }

  String _keepStreamingText(String previous, String incoming) {
    if (incoming.length >= previous.length && incoming.startsWith(previous)) {
      return incoming;
    }
    if (previous.startsWith(incoming)) return previous;
    return previous;
  }

  int? get _streamingVoiceMessageIndex {
    if (_voiceDraftTranscriptIndexes.isEmpty) return null;
    final indexes = _voiceDraftTranscriptIndexes.values
        .where((index) => index >= 0 && index < _messages.length)
        .toList(growable: false);
    if (indexes.isEmpty) return null;
    return indexes.reduce(math.max);
  }

  Future<void> _submit() async {
    final text = _composerController.text.trim();
    if (text.isEmpty || _webSourceLoading) return;
    var sources = _webSources;
    final url = extractWebUrl(text);
    if (url != null && !_webSources.any((source) => source.finalUrl == url)) {
      setState(() => _webSourceLoading = true);
      try {
        final source = await _fetchWebSource(url);
        sources = List.unmodifiable([..._webSources, source]);
        if (mounted) setState(() => _webSources = sources);
      } catch (error) {
        if (mounted) {
          AppToast.show(context, '网页暂时无法分析：$error');
        }
        return;
      } finally {
        if (mounted) setState(() => _webSourceLoading = false);
      }
    }
    final now = DateTime.now();
    final current =
        _conversation ??
        AiConversationRecord.empty(
          bookId: widget.bookId,
          bookName: widget.bookName ?? '',
          pageLabel: widget.pageLabel ?? '',
        );
    final updated = current.copyWith(
      title: current.title.trim().isEmpty ? text : current.title,
      messages: [
        ...current.messages,
        AiConversationMessage(
          text: text,
          isUser: true,
          pageLabel: widget.pageLabel ?? current.pageLabel,
          createdAt: now,
        ),
      ],
      pageLabel: widget.pageLabel ?? current.pageLabel,
      updatedAt: now,
      webSources: sources,
    );
    setState(() {
      _conversation = updated;
      _messages
        ..clear()
        ..addAll(updated.messages);
      _composerController.clear();
    });
    unawaited(_saveConversation(updated));
    widget.onSubmit?.call(text);
    widget.onSubmitWithWebSources?.call(text, sources);
  }

  void _startNewConversation() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _conversation = AiConversationRecord.empty(
        bookId: widget.bookId,
        bookName: widget.bookName ?? '',
        pageLabel: widget.pageLabel ?? '',
      );
      _messages.clear();
      _voiceDraftTranscriptIndexes.clear();
      _ingestedVoiceTranscriptKeys.clear();
      _webSources = const [];
      _historyOpen = false;
      _historySelectionMode = false;
      _selectedHistoryIds.clear();
    });
  }

  Future<void> _restoreLatestConversation() async {
    final conversation = await _historyService.latestForBook(
      bookId: widget.bookId,
      bookName: widget.bookName ?? '',
    );
    if (!mounted || conversation == null || _conversation != null) return;
    setState(() {
      _conversation = conversation;
      _messages
        ..clear()
        ..addAll(conversation.messages);
      _voiceDraftTranscriptIndexes.clear();
      _ingestedVoiceTranscriptKeys.clear();
      _webSources = conversation.webSources;
    });
  }

  Future<void> _saveConversation(AiConversationRecord conversation) async {
    await _historyService.save(conversation);
    if (_historyOpen) unawaited(_refreshHistory());
  }

  void _openHistory() {
    setState(() => _historyOpen = true);
    unawaited(_refreshHistory());
  }

  Future<void> _refreshHistory() async {
    final request = ++_historyRequest;
    if (mounted) setState(() => _historyLoading = true);
    final history = await _historyService.list(
      bookId: widget.bookId,
      bookName: widget.bookName ?? '',
      allBooks: _historyAllBooks,
      query: _historyQuery,
    );
    if (!mounted || request != _historyRequest) return;
    setState(() {
      _history = history;
      _historyLoading = false;
    });
  }

  void _updateHistoryQuery(String query) {
    setState(() => _historyQuery = query);
    unawaited(_refreshHistory());
  }

  void _updateHistoryScope(bool allBooks) {
    setState(() => _historyAllBooks = allBooks);
    unawaited(_refreshHistory());
  }

  Future<void> _restoreConversation(AiConversationRecord conversation) async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _conversation = conversation;
      _messages
        ..clear()
        ..addAll(conversation.messages);
      _webSources = conversation.webSources;
      _historyOpen = false;
      _historySelectionMode = false;
      _selectedHistoryIds.clear();
    });
  }

  Future<AiWebSource> _fetchWebSource(String rawUrl) async {
    final service = const WebArticleSourceService();
    final result = await service.fetchAndParse(rawUrl);
    final snapshotPath = await service.saveSnapshot(result);
    final sourceText = result.document.chapters.first.plainText.trim();
    return AiWebSource(
      id: 'web-source-${DateTime.now().microsecondsSinceEpoch}',
      title: result.document.title,
      finalUrl: result.finalUrl,
      contentHash: result.contentHash,
      fetchedAt: result.fetchedAt,
      snapshotPath: snapshotPath,
      excerpt: sourceText.length > 180
          ? '${sourceText.substring(0, 180)}…'
          : sourceText,
    );
  }

  void _removeWebSource(String id) {
    final source = _webSources.where((item) => item.id == id).firstOrNull;
    if (source == null) return;
    setState(() {
      _webSources = _webSources
          .where((item) => item.id != id)
          .toList(growable: false);
    });
    if (source.snapshotPath.isNotEmpty) {
      unawaited(() async {
        try {
          final file = File(source.snapshotPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }());
    }
    if (source.visualSnapshotPath.isNotEmpty) {
      unawaited(() async {
        try {
          final file = File(source.visualSnapshotPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }());
    }
    final conversation = _conversation;
    if (conversation != null && conversation.messages.isNotEmpty) {
      final updated = conversation.copyWith(webSources: _webSources);
      _conversation = updated;
      unawaited(_saveConversation(updated));
    }
  }

  void _closeHistory() {
    setState(() {
      _historyOpen = false;
      _historySelectionMode = false;
      _selectedHistoryIds.clear();
    });
  }

  Future<void> _togglePinned(AiConversationRecord conversation) async {
    await _historyService.setPinned(conversation.id, !conversation.isPinned);
    if (mounted) unawaited(_refreshHistory());
  }

  void _enterHistorySelection(AiConversationRecord initial) {
    setState(() {
      _historySelectionMode = true;
      _selectedHistoryIds.clear();
      _selectedHistoryIds.add(initial.id);
    });
  }

  void _toggleHistorySelection(AiConversationRecord conversation) {
    setState(() {
      if (!_selectedHistoryIds.add(conversation.id)) {
        _selectedHistoryIds.remove(conversation.id);
      }
    });
  }

  void _exitHistorySelection() {
    setState(() {
      _historySelectionMode = false;
      _selectedHistoryIds.clear();
    });
  }

  Future<void> _renameConversation(AiConversationRecord conversation) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => AppTextInputDialog(
        title: '重命名会话',
        label: '会话名称',
        initialText: conversation.displayTitle,
        maxLength: 60,
      ),
    );
    if (!mounted || title == null || title.trim().isEmpty) return;
    try {
      await _historyService.rename(conversation.id, title);
    } catch (error) {
      if (mounted) {
        AppToast.show(context, '重命名失败：$error');
      }
      return;
    }
    if (!mounted) return;
    if (_conversation?.id == conversation.id) {
      setState(() {
        _conversation = _conversation!.copyWith(
          title: title.trim(),
          updatedAt: DateTime.now(),
        );
      });
    }
    unawaited(_refreshHistory());
  }

  Future<void> _deleteConversations(Iterable<String> ids) async {
    final normalizedIds = ids.toSet();
    if (normalizedIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${normalizedIds.length} 个会话？'),
        content: const Text('删除后不会再出现在历史记录中，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _historyService.delete(normalizedIds);
    } catch (error) {
      if (mounted) {
        AppToast.show(context, '删除失败：$error');
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      if (_conversation != null && normalizedIds.contains(_conversation!.id)) {
        _conversation = null;
        _messages.clear();
      }
      _historySelectionMode = false;
      _selectedHistoryIds.clear();
    });
    unawaited(_refreshHistory());
  }

  Future<void> _togglePinnedForSelection() async {
    final selected = _history
        .where((record) => _selectedHistoryIds.contains(record.id))
        .toList(growable: false);
    if (selected.isEmpty) return;
    final shouldPin = selected.any((record) => !record.isPinned);
    for (final record in selected) {
      await _historyService.setPinned(record.id, shouldPin);
    }
    if (mounted) unawaited(_refreshHistory());
  }

  void _showAllSources() {
    if (widget.attachments.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('已圈选 ${widget.attachments.length} 条来源'),
        content: SizedBox(
          width: 420,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: widget.attachments.length,
            separatorBuilder: (_, _) => const SizedBox(height: 16),
            itemBuilder: (context, index) {
              final attachment = widget.attachments[index];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AiAnnotationAttachmentThumbnail(
                    attachment: attachment,
                    selected: false,
                    showRemove: false,
                    onRemove: () {},
                  ),
                  const SizedBox(height: 8),
                  Text(
                    attachment.pageLabel,
                    style: const TextStyle(
                      color: NotePageTheme.muted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    attachment.quote.trim().isEmpty
                        ? '已保留圈选区域，未提取到文字'
                        : attachment.quote,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: NotePageTheme.ink,
                      fontSize: 14,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final top = MediaQuery.viewPaddingOf(context).top + 66;
        final compactWidth = math.min(
          constraints.maxWidth,
          math.max(360.0, constraints.maxWidth * .55),
        );
        final panelWidth = _expanded ? constraints.maxWidth : compactWidth;
        return Stack(
          children: [
            Positioned(
              top: top,
              right: 0,
              bottom: 0,
              width: panelWidth,
              child: _PanelSurface(
                key: const Key('ai_conversation_panel_surface'),
                expanded: _expanded,
                historyOpen: _historyOpen,
                annotationCount: widget.annotationCount,
                messages: _messages,
                streamingMessageIndex: _streamingVoiceMessageIndex,
                history: _history,
                historyQuery: _historyQuery,
                historyAllBooks: _historyAllBooks,
                historyLoading: _historyLoading,
                currentConversationId: _conversation?.id,
                historySelectionMode: _historySelectionMode,
                selectedHistoryIds: _selectedHistoryIds,
                attachments: widget.attachments,
                voiceSession: widget.voiceSession,
                webSources: _webSources,
                webSourceLoading: _webSourceLoading,
                onRemoveWebSource: _removeWebSource,
                composerController: _composerController,
                historySearchController: _historySearchController,
                onToggleExpanded: () => setState(() => _expanded = !_expanded),
                onOpenHistory: _openHistory,
                onCloseHistory: _closeHistory,
                onClose: widget.onClose,
                onSubmit: _submit,
                onVoice: widget.onVoice,
                onEndVoice: widget.onEndVoice,
                onClearVoiceFocus: widget.onClearVoiceFocus,
                onNewConversation: _startNewConversation,
                onRestoreConversation: _restoreConversation,
                onTogglePinned: _togglePinned,
                onSearchChanged: _updateHistoryQuery,
                onHistoryScopeChanged: _updateHistoryScope,
                onRenameConversation: _renameConversation,
                onDeleteConversations: _deleteConversations,
                onEnterHistorySelection: _enterHistorySelection,
                onExitHistorySelection: _exitHistorySelection,
                onToggleHistorySelection: _toggleHistorySelection,
                onTogglePinnedForSelection: _togglePinnedForSelection,
                onRemoveAttachment: widget.onRemoveAttachment,
                onViewAllSources: _showAllSources,
              ),
            ),
          ],
        );
      },
    );
  }
}

String? extractWebUrl(String text) {
  final match = RegExp(
    r'https?://[^\s<>"“”‘’]+',
    caseSensitive: false,
  ).firstMatch(text);
  if (match == null) return null;
  return match.group(0)?.replaceFirst(RegExp(r'[.,!?;:，。！？；：）】》」』]+$'), '');
}

class _PanelSurface extends StatelessWidget {
  const _PanelSurface({
    super.key,
    required this.expanded,
    required this.historyOpen,
    required this.annotationCount,
    required this.messages,
    this.streamingMessageIndex,
    required this.history,
    required this.historyQuery,
    required this.historyAllBooks,
    required this.historyLoading,
    required this.currentConversationId,
    required this.historySelectionMode,
    required this.selectedHistoryIds,
    required this.attachments,
    this.voiceSession,
    required this.webSources,
    required this.webSourceLoading,
    required this.onRemoveWebSource,
    required this.composerController,
    required this.historySearchController,
    required this.onToggleExpanded,
    required this.onOpenHistory,
    required this.onCloseHistory,
    required this.onClose,
    required this.onSubmit,
    this.onVoice,
    this.onEndVoice,
    this.onClearVoiceFocus,
    required this.onNewConversation,
    required this.onRestoreConversation,
    required this.onTogglePinned,
    required this.onSearchChanged,
    required this.onHistoryScopeChanged,
    required this.onRenameConversation,
    required this.onDeleteConversations,
    required this.onEnterHistorySelection,
    required this.onExitHistorySelection,
    required this.onToggleHistorySelection,
    required this.onTogglePinnedForSelection,
    required this.onRemoveAttachment,
    required this.onViewAllSources,
  });

  final bool expanded;
  final bool historyOpen;
  final int annotationCount;
  final List<AiConversationMessage> messages;
  final int? streamingMessageIndex;
  final List<AiConversationRecord> history;
  final String historyQuery;
  final bool historyAllBooks;
  final bool historyLoading;
  final String? currentConversationId;
  final bool historySelectionMode;
  final Set<String> selectedHistoryIds;
  final List<AiAnnotationSourceAttachment> attachments;
  final RealtimeVoiceSession? voiceSession;
  final List<AiWebSource> webSources;
  final bool webSourceLoading;
  final ValueChanged<String> onRemoveWebSource;
  final TextEditingController composerController;
  final TextEditingController historySearchController;
  final VoidCallback onToggleExpanded;
  final VoidCallback onOpenHistory;
  final VoidCallback onCloseHistory;
  final VoidCallback onClose;
  final VoidCallback onSubmit;
  final VoidCallback? onVoice;
  final VoidCallback? onEndVoice;
  final VoidCallback? onClearVoiceFocus;
  final VoidCallback onNewConversation;
  final ValueChanged<AiConversationRecord> onRestoreConversation;
  final ValueChanged<AiConversationRecord> onTogglePinned;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<bool> onHistoryScopeChanged;
  final ValueChanged<AiConversationRecord> onRenameConversation;
  final ValueChanged<Iterable<String>> onDeleteConversations;
  final ValueChanged<AiConversationRecord> onEnterHistorySelection;
  final VoidCallback onExitHistorySelection;
  final ValueChanged<AiConversationRecord> onToggleHistorySelection;
  final VoidCallback onTogglePinnedForSelection;
  final ValueChanged<String>? onRemoveAttachment;
  final VoidCallback onViewAllSources;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) {},
        child: ClipRRect(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(expanded ? 0 : 18),
            bottomLeft: Radius.circular(expanded ? 0 : 18),
          ),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xF5F8F9FB),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x24000000),
                    blurRadius: 20,
                    offset: Offset(-6, 0),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  Column(
                    children: [
                      _PanelHeader(
                        expanded: expanded,
                        onOpenHistory: onOpenHistory,
                        onToggleExpanded: onToggleExpanded,
                        onClose: onClose,
                        onNewConversation: onNewConversation,
                      ),
                      Expanded(
                        child: _ConversationBody(
                          annotationCount: annotationCount,
                          messages: messages,
                          streamingMessageIndex: streamingMessageIndex,
                          attachments: attachments,
                          voiceSession: voiceSession,
                          onEndVoice: onEndVoice,
                          onClearVoiceFocus: onClearVoiceFocus,
                          webSources: webSources,
                          onRemoveWebSource: onRemoveWebSource,
                          onRemoveAttachment: onRemoveAttachment,
                          onViewAllSources: onViewAllSources,
                        ),
                      ),
                      // Reserve the resting composer height. Keyboard motion
                      // must not resize the panel or reposition its header.
                      const SizedBox(height: 146),
                    ],
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Builder(
                      builder: (context) {
                        final inset = MediaQuery.viewInsetsOf(context).bottom;
                        return Padding(
                          padding: EdgeInsets.only(bottom: inset),
                          child: _Composer(
                            controller: composerController,
                            onSubmit: onSubmit,
                            onVoice: onVoice,
                            webSourceLoading: webSourceLoading,
                          ),
                        );
                      },
                    ),
                  ),
                  if (historyOpen)
                    Positioned.fill(
                      child: LayoutBuilder(
                        builder: (context, bounds) {
                          final width = math.min(320.0, bounds.maxWidth * .78);
                          return Stack(
                            children: [
                              Positioned.fill(
                                child: GestureDetector(
                                  key: const Key('ai_history_dismiss_barrier'),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: onCloseHistory,
                                  child: const ColoredBox(
                                    color: Color(0x18000000),
                                  ),
                                ),
                              ),
                              Positioned(
                                key: const Key('ai_history_drawer_bounds'),
                                left: 0,
                                top: 0,
                                bottom: 0,
                                width: width,
                                child: _HistoryDrawer(
                                  searchController: historySearchController,
                                  history: history,
                                  query: historyQuery,
                                  allBooks: historyAllBooks,
                                  loading: historyLoading,
                                  currentConversationId: currentConversationId,
                                  selectionMode: historySelectionMode,
                                  selectedIds: selectedHistoryIds,
                                  onClose: onCloseHistory,
                                  onNewConversation: onNewConversation,
                                  onRestoreConversation: onRestoreConversation,
                                  onTogglePinned: onTogglePinned,
                                  onSearchChanged: onSearchChanged,
                                  onHistoryScopeChanged: onHistoryScopeChanged,
                                  onRenameConversation: onRenameConversation,
                                  onDeleteConversations: onDeleteConversations,
                                  onEnterSelection: onEnterHistorySelection,
                                  onExitSelection: onExitHistorySelection,
                                  onToggleSelection: onToggleHistorySelection,
                                  onTogglePinnedForSelection:
                                      onTogglePinnedForSelection,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.expanded,
    required this.onOpenHistory,
    required this.onToggleExpanded,
    required this.onClose,
    required this.onNewConversation,
  });

  final bool expanded;
  final VoidCallback onOpenHistory;
  final VoidCallback onToggleExpanded;
  final VoidCallback onClose;
  final VoidCallback onNewConversation;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      child: Row(
        children: [
          _SharedCapsule(
            children: [
              _PanelIconButton(
                icon: Icons.view_sidebar_outlined,
                tooltip: '查看历史会话',
                onPressed: onOpenHistory,
              ),
              _PanelIconButton(
                icon: Icons.add,
                tooltip: '新建会话',
                onPressed: onNewConversation,
              ),
            ],
          ),
          const Spacer(),
          _PanelIconButton(
            icon: expanded ? Icons.fullscreen_exit : Icons.open_in_full,
            tooltip: expanded ? '还原侧栏' : '展开对话',
            onPressed: onToggleExpanded,
          ),
          _PanelIconButton(
            icon: Icons.remove,
            tooltip: '收起对话',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _SharedCapsule extends StatelessWidget {
  const _SharedCapsule({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .56),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: .8)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _PanelIconButton extends StatelessWidget {
  const _PanelIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 22, color: NotePageTheme.ink),
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      padding: EdgeInsets.zero,
    );
  }
}

class _ConversationBody extends StatelessWidget {
  const _ConversationBody({
    required this.annotationCount,
    required this.messages,
    this.streamingMessageIndex,
    required this.attachments,
    this.voiceSession,
    this.onEndVoice,
    this.onClearVoiceFocus,
    required this.webSources,
    required this.onRemoveWebSource,
    required this.onRemoveAttachment,
    required this.onViewAllSources,
  });

  final int annotationCount;
  final List<AiConversationMessage> messages;
  final int? streamingMessageIndex;
  final List<AiAnnotationSourceAttachment> attachments;
  final RealtimeVoiceSession? voiceSession;
  final VoidCallback? onEndVoice;
  final VoidCallback? onClearVoiceFocus;
  final List<AiWebSource> webSources;
  final ValueChanged<String> onRemoveWebSource;
  final ValueChanged<String>? onRemoveAttachment;
  final VoidCallback onViewAllSources;

  Widget _sourceSummary() {
    return _ConversationSourceSummary(
      attachments: attachments,
      onRemoveAttachment: onRemoveAttachment,
      onViewAllSources: onViewAllSources,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty || attachments.isNotEmpty || webSources.isNotEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        children: [
          if (voiceSession != null) ...[
            _VoiceConversationSection(
              session: voiceSession!,
              onEndVoice: onEndVoice,
              onClearVoiceFocus: onClearVoiceFocus,
            ),
            const SizedBox(height: 18),
          ],
          if (attachments.isNotEmpty) ...[
            _sourceSummary(),
            const SizedBox(height: 22),
          ],
          if (webSources.isNotEmpty) ...[
            _WebSourcesSummary(
              sources: webSources,
              onRemove: onRemoveWebSource,
            ),
            const SizedBox(height: 22),
          ],
          if (attachments.isEmpty && annotationCount > 0)
            Text(
              '当前页 · $annotationCount 条上下文',
              style: const TextStyle(
                color: NotePageTheme.muted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          if (messages.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Center(
                child: Text(
                  '可以直接问当前页，或粘贴网页链接后发送',
                  style: TextStyle(
                    color: NotePageTheme.inkSecondary,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          if (messages.isNotEmpty)
            for (var index = 0; index < messages.length; index++) ...[
              if (index > 0) const SizedBox(height: 18),
              _MessageView(
                message: messages[index],
                streaming: index == streamingMessageIndex,
              ),
            ],
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      itemCount: messages.length + (voiceSession == null ? 0 : 1),
      separatorBuilder: (_, _) => const SizedBox(height: 18),
      itemBuilder: (context, index) {
        if (voiceSession != null && index == 0) {
          return _VoiceConversationSection(
            session: voiceSession!,
            onEndVoice: onEndVoice,
            onClearVoiceFocus: onClearVoiceFocus,
          );
        }
        final messageIndex = voiceSession == null ? index : index - 1;
        return _MessageView(
          message: messages[messageIndex],
          streaming: messageIndex == streamingMessageIndex,
        );
      },
    );
  }
}

class _VoiceConversationSection extends StatelessWidget {
  const _VoiceConversationSection({
    required this.session,
    this.onEndVoice,
    this.onClearVoiceFocus,
  });

  final RealtimeVoiceSession session;
  final VoidCallback? onEndVoice;
  final VoidCallback? onClearVoiceFocus;

  @override
  Widget build(BuildContext context) {
    final state = session.state;
    final label = switch (state) {
      RealtimeVoiceState.connecting => '正在连接实时语音…',
      RealtimeVoiceState.listening => '正在聆听，你可以直接说话',
      RealtimeVoiceState.thinking => '小七正在整理当前页…',
      RealtimeVoiceState.speaking => '小七正在讲解，可随时打断',
      RealtimeVoiceState.reconnecting => '网络波动，正在重连…',
      RealtimeVoiceState.ending => '正在结束本次会话…',
      RealtimeVoiceState.error => session.errorMessage ?? '连接失败，请重试',
      RealtimeVoiceState.disconnected => '语音已结束',
    };
    final color = switch (state) {
      RealtimeVoiceState.error => const Color(0xFFB44848),
      RealtimeVoiceState.speaking => NotePageTheme.ochre,
      RealtimeVoiceState.thinking => const Color(0xFF4F67A8),
      _ => const Color(0xFF287A55),
    };
    VoiceTranscript? interim;
    for (final item in session.transcripts.reversed) {
      if (item.speaker == VoiceSpeaker.user && !item.isFinal) {
        interim = item;
      }
      if (interim != null) break;
    }
    final focus = session.context?.selectedText.trim() ?? '';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .20)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(color: color, fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 2,
                children: [
                  if (state == RealtimeVoiceState.speaking)
                    TextButton(
                      onPressed: () => unawaited(session.interrupt()),
                      child: const Text('打断'),
                    ),
                  if (state == RealtimeVoiceState.error &&
                      session.context != null)
                    TextButton(
                      onPressed: () =>
                          unawaited(session.start(context: session.context!)),
                      child: const Text('重试'),
                    ),
                  TextButton(
                    onPressed: session.state == RealtimeVoiceState.disconnected
                        ? null
                        : () async {
                            if (session.isMuted) {
                              await session.unmute();
                            } else {
                              await session.mute();
                            }
                          },
                    child: Text(session.isMuted ? '取消静音' : '静音'),
                  ),
                  TextButton(onPressed: onEndVoice, child: const Text('结束')),
                ],
              ),
            ),
            if (focus.isNotEmpty) ...[
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .82),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '聚焦：${focus.replaceAll(RegExp(r'\s+'), ' ').trim()}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: NotePageTheme.ink,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '清除聚焦内容',
                        onPressed: onClearVoiceFocus,
                        icon: const Icon(Icons.close, size: 16),
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (interim?.text.trim().isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(
                interim!.text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: NotePageTheme.ink,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConversationSourceSummary extends StatelessWidget {
  const _ConversationSourceSummary({
    required this.attachments,
    required this.onRemoveAttachment,
    required this.onViewAllSources,
  });

  final List<AiAnnotationSourceAttachment> attachments;
  final ValueChanged<String>? onRemoveAttachment;
  final VoidCallback onViewAllSources;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '已圈选 ${attachments.length} 条内容',
                style: const TextStyle(
                  color: NotePageTheme.inkSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: onViewAllSources,
              style: TextButton.styleFrom(
                foregroundColor: NotePageTheme.ochre,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(44, 40),
              ),
              child: const Text('查看全部来源'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 118,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: attachments.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final attachment = attachments[index];
              return AiAnnotationAttachmentThumbnail(
                attachment: attachment,
                selected: false,
                onRemove: onRemoveAttachment == null
                    ? () {}
                    : () => onRemoveAttachment!(attachment.id),
                showRemove: onRemoveAttachment != null,
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Text(
          attachments.first.quote.trim().isEmpty
              ? '已保留圈选区域，未提取到文字'
              : attachments.first.quote,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: NotePageTheme.ink,
            fontSize: 13,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({required this.message, this.streaming = false});

  final AiConversationMessage message;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFFE9EBEF),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Text(
                    message.text,
                    style: const TextStyle(
                      color: NotePageTheme.ink,
                      fontSize: 15,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            const _Avatar(user: true),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Avatar(user: false),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MathMarkdown(
                data: _markdownForDisplay(message.text, streaming: streaming),
                styleSheet: _aiAnswerMarkdownStyle,
              ),
              if (!streaming) ...[
                const SizedBox(height: 8),
                const _AnswerActions(),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.user});

  final bool user;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: user ? const Color(0xFFE9EBEF) : const Color(0xFFFFF4E8),
        border: Border.all(
          color: user ? const Color(0xFFD7D9DE) : const Color(0xFFFFC58E),
        ),
      ),
      child: SizedBox.square(
        dimension: 32,
        child: Icon(
          user ? Icons.person : Icons.auto_awesome,
          size: 18,
          color: user ? NotePageTheme.inkSecondary : NotePageTheme.ochre,
        ),
      ),
    );
  }
}

class _AnswerActions extends StatelessWidget {
  const _AnswerActions();

  @override
  Widget build(BuildContext context) {
    const icons = [
      Icons.copy_outlined,
      Icons.refresh,
      Icons.thumb_up_outlined,
      Icons.thumb_down_outlined,
      Icons.call_split,
      Icons.share_outlined,
    ];
    return SizedBox(
      height: 44,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < icons.length; index++)
            Padding(
              padding: EdgeInsets.only(
                right: index == icons.length - 1 ? 0 : 0,
              ),
              child: IconButton(
                tooltip: const [
                  '复制',
                  '重新生成',
                  '点赞',
                  '反馈',
                  '分支到新对话',
                  '分享',
                ][index],
                onPressed: () {},
                icon: Icon(icons[index], size: 18, color: NotePageTheme.muted),
                constraints: const BoxConstraints.tightFor(
                  width: 44,
                  height: 44,
                ),
                padding: EdgeInsets.zero,
              ),
            ),
        ],
      ),
    );
  }
}

class _WebSourcesSummary extends StatelessWidget {
  const _WebSourcesSummary({required this.sources, required this.onRemove});

  final List<AiWebSource> sources;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '网页来源 ${sources.length} 条',
        style: const TextStyle(
          color: NotePageTheme.inkSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 8),
      for (final source in sources) ...[
        DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .74),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E3DF)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        source.title.isEmpty ? source.finalUrl : source.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: NotePageTheme.ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => onRemove(source.id),
                      tooltip: '移除网页来源',
                      icon: const Icon(Icons.close, size: 18),
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  source.finalUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NotePageTheme.inkSecondary,
                    fontSize: 12,
                  ),
                ),
                if (source.excerpt.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    source.excerpt,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: NotePageTheme.ink,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    ],
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onSubmit,
    this.onVoice,
    required this.webSourceLoading,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  final VoidCallback? onVoice;
  final bool webSourceLoading;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .68),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: .9)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 16,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: '输入问题，或直接粘贴网页链接后发送…',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (webSourceLoading)
                      const Padding(
                        padding: EdgeInsets.only(right: 10),
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F1F3),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        child: Text(
                          '当前页',
                          style: TextStyle(
                            color: NotePageTheme.inkSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    _ComposerIcon(
                      icon: Icons.mic_none,
                      tooltip: '实时语音共读',
                      onPressed: onVoice,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '发送',
                      onPressed: onSubmit,
                      icon: const Icon(
                        Icons.arrow_upward,
                        color: Colors.white,
                        size: 20,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: NotePageTheme.ink,
                        shape: const CircleBorder(),
                        minimumSize: const Size(44, 44),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerIcon extends StatelessWidget {
  const _ComposerIcon({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: NotePageTheme.ink),
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      padding: EdgeInsets.zero,
    );
  }
}

class _HistoryDrawer extends StatelessWidget {
  const _HistoryDrawer({
    required this.searchController,
    required this.history,
    required this.query,
    required this.allBooks,
    required this.loading,
    required this.currentConversationId,
    required this.selectionMode,
    required this.selectedIds,
    required this.onClose,
    required this.onNewConversation,
    required this.onRestoreConversation,
    required this.onTogglePinned,
    required this.onSearchChanged,
    required this.onHistoryScopeChanged,
    required this.onRenameConversation,
    required this.onDeleteConversations,
    required this.onEnterSelection,
    required this.onExitSelection,
    required this.onToggleSelection,
    required this.onTogglePinnedForSelection,
  });

  final TextEditingController searchController;
  final List<AiConversationRecord> history;
  final String query;
  final bool allBooks;
  final bool loading;
  final String? currentConversationId;
  final bool selectionMode;
  final Set<String> selectedIds;
  final VoidCallback onClose;
  final VoidCallback onNewConversation;
  final ValueChanged<AiConversationRecord> onRestoreConversation;
  final ValueChanged<AiConversationRecord> onTogglePinned;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<bool> onHistoryScopeChanged;
  final ValueChanged<AiConversationRecord> onRenameConversation;
  final ValueChanged<Iterable<String>> onDeleteConversations;
  final ValueChanged<AiConversationRecord> onEnterSelection;
  final VoidCallback onExitSelection;
  final ValueChanged<AiConversationRecord> onToggleSelection;
  final VoidCallback onTogglePinnedForSelection;

  Map<String, List<AiConversationRecord>> _groupHistory() {
    final groups = <String, List<AiConversationRecord>>{};
    for (final record in history) {
      final group = record.isPinned ? '置顶' : _dateGroup(record.updatedAt);
      groups.putIfAbsent(group, () => []).add(record);
    }
    return groups;
  }

  String _dateGroup(DateTime updatedAt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(updatedAt.year, updatedAt.month, updatedAt.day);
    final days = today.difference(date).inDays;
    if (days <= 0) return '今天';
    if (days == 1) return '昨天';
    if (days <= 7) return '7 天内';
    if (days <= 30) return '30 天内';
    return '更早';
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupHistory();
    return Material(
      color: const Color(0xF8F8F9FB),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
              child: selectionMode
                  ? Row(
                      children: [
                        Expanded(
                          child: Text(
                            '已选择 ${selectedIds.length} 个对话',
                            style: const TextStyle(
                              color: NotePageTheme.ink,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '退出多选',
                          onPressed: onExitSelection,
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: searchController,
                            onChanged: onSearchChanged,
                            decoration: const InputDecoration(
                              hintText: '搜索对话内容…',
                              prefixIcon: Icon(Icons.search, size: 20),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                          ),
                        ),
                        PopupMenuButton<bool>(
                          tooltip: '切换搜索范围',
                          onSelected: onHistoryScopeChanged,
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: false, child: Text('当前书')),
                            PopupMenuItem(value: true, child: Text('全部会话')),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  allBooks ? '全部会话' : '当前书',
                                  style: const TextStyle(
                                    color: NotePageTheme.inkSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                                const Icon(Icons.expand_more, size: 16),
                              ],
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '返回对话',
                          onPressed: onClose,
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ],
                    ),
            ),
            if (!selectionMode)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: onNewConversation,
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('新建会话'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: .78),
                      foregroundColor: NotePageTheme.ink,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                children: history.isEmpty
                    ? [
                        _HistoryEmptyState(
                          loading: loading,
                          hasQuery: query.trim().isNotEmpty,
                        ),
                      ]
                    : [
                        for (final entry in groups.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
                            child: Text(
                              entry.key,
                              style: const TextStyle(
                                color: NotePageTheme.muted,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          for (final record in entry.value)
                            _HistoryRow(
                              record: record,
                              query: query,
                              selected: selectionMode
                                  ? selectedIds.contains(record.id)
                                  : record.id == currentConversationId,
                              selectionMode: selectionMode,
                              onTap: () => selectionMode
                                  ? onToggleSelection(record)
                                  : onRestoreConversation(record),
                              onTogglePinned: () => onTogglePinned(record),
                              onRename: () => onRenameConversation(record),
                              onDelete: () =>
                                  onDeleteConversations([record.id]),
                              onEnterSelection: () => onEnterSelection(record),
                            ),
                        ],
                      ],
              ),
            ),
            if (selectionMode)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: selectedIds.isEmpty
                            ? null
                            : onTogglePinnedForSelection,
                        icon: const Icon(Icons.push_pin_outlined, size: 20),
                        label: const Text('置顶'),
                      ),
                      const SizedBox(
                        height: 24,
                        child: VerticalDivider(width: 24),
                      ),
                      TextButton.icon(
                        onPressed: selectedIds.isEmpty
                            ? null
                            : () => onDeleteConversations(selectedIds),
                        icon: const Icon(Icons.delete_outline, size: 20),
                        label: const Text('删除'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              const Divider(height: 1, color: Color(0xFFE5E6E8)),
              const ListTile(
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: Color(0xFFE9EBEF),
                  child: Icon(
                    Icons.person,
                    size: 18,
                    color: NotePageTheme.inkSecondary,
                  ),
                ),
                title: Text('用户'),
                trailing: Icon(Icons.more_horiz, color: NotePageTheme.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HistoryEmptyState extends StatelessWidget {
  const _HistoryEmptyState({required this.loading, required this.hasQuery});

  final bool loading;
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final title = loading
        ? '正在读取历史会话…'
        : hasQuery
        ? '没有找到匹配的会话'
        : '暂无历史会话';
    final subtitle = loading
        ? '真实发送的问题会自动保存在这里'
        : hasQuery
        ? '可以换个关键词试试'
        : '发送第一个问题后，会自动保存在这里';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 56, 18, 24),
      child: Column(
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: NotePageTheme.inkSecondary,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: NotePageTheme.muted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

enum _HistoryAction { rename, pin, select, delete }

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.record,
    required this.query,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onTogglePinned,
    required this.onRename,
    required this.onDelete,
    required this.onEnterSelection,
  });

  final AiConversationRecord record;
  final String query;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onTogglePinned;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onEnterSelection;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFE5E5EA) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        boxShadow: selected
            ? const [
                BoxShadow(
                  color: Color(0x16000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: ListTile(
        onTap: onTap,
        dense: true,
        minVerticalPadding: 8,
        leading: selectionMode
            ? Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? const Color(0xFF4F7FF5) : NotePageTheme.muted,
                size: 26,
              )
            : null,
        title: Text(
          record.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: NotePageTheme.ink, fontSize: 14),
        ),
        subtitle: _historySubtitle(record, query),
        trailing: selectionMode
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (record.isPinned)
                    const Icon(
                      Icons.push_pin_outlined,
                      size: 16,
                      color: NotePageTheme.muted,
                    ),
                  PopupMenuButton<_HistoryAction>(
                    tooltip: '会话操作',
                    onSelected: (action) {
                      switch (action) {
                        case _HistoryAction.rename:
                          onRename();
                        case _HistoryAction.pin:
                          onTogglePinned();
                        case _HistoryAction.select:
                          onEnterSelection();
                        case _HistoryAction.delete:
                          onDelete();
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: _HistoryAction.rename,
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('重命名'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: _HistoryAction.pin,
                        child: ListTile(
                          leading: const Icon(Icons.push_pin_outlined),
                          title: Text(record.isPinned ? '取消置顶' : '置顶'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: _HistoryAction.select,
                        child: ListTile(
                          leading: Icon(Icons.checklist),
                          title: Text('多选'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: _HistoryAction.delete,
                        child: ListTile(
                          leading: Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                          title: Text(
                            '删除',
                            style: TextStyle(color: Colors.red),
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                    icon: const Icon(
                      Icons.more_horiz,
                      size: 20,
                      color: NotePageTheme.muted,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

Widget? _historySubtitle(AiConversationRecord record, String query) {
  if (query.trim().isEmpty) return null;
  final snippet = record.matchSnippet(query);
  return Text(
    [
      if (snippet != null) snippet,
      if (record.pageLabel.trim().isNotEmpty) '书页 ${record.pageLabel.trim()}',
      _formatHistoryTime(record.updatedAt),
    ].join(' · '),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(color: NotePageTheme.muted, fontSize: 11),
  );
}

String _formatHistoryTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// Entry used on the note canvas before the conversation side sheet opens.
class AiConversationEntryButton extends StatelessWidget {
  const AiConversationEntryButton({
    super.key,
    required this.annotationCount,
    required this.onPressed,
  });

  final int annotationCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: annotationCount > 0 ? '打开对话，$annotationCount 条待发送来源' : '打开对话',
      child: Material(
        color: Colors.white.withValues(alpha: .82),
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: .08),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 56,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const Center(child: _ConversationEntryGlyph()),
                if (annotationCount > 0)
                  Positioned(
                    right: -2,
                    top: -4,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: NotePageTheme.inkSecondary,
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Text(
                          '$annotationCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConversationEntryGlyph extends StatelessWidget {
  const _ConversationEntryGlyph();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 28,
      child: Stack(
        children: [
          const Positioned.fill(
            child: Icon(
              Icons.chat_bubble_outline,
              size: 25,
              color: NotePageTheme.ink,
            ),
          ),
          Positioned(
            right: -1,
            top: -3,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.north_east,
                size: 12,
                color: NotePageTheme.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
