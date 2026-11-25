import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_painter/flutter_painter.dart' show FreeStyleDrawable;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';

import '../features/ai_study_annotation/data/ai_conversation_history.dart';
import '../features/ai_study_annotation/domain/ai_chat_process.dart';
import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/book_source.dart';
import '../models/companion_source_range.dart';
import '../models/page_annotation.dart';
import '../pages/drawing_board_page.dart';
import '../models/pdf_catalog.dart';
import '../models/reader_pagination.dart';
import '../models/xiaoqi_document.dart';
import '../services/book_library_service.dart';
import '../services/companion_pdf_reflow.dart';
import '../services/companion_annotation_store.dart';
import '../services/companion_annotation_sync.dart';
import '../services/database_service.dart';
import '../services/reader_pagination_preferences.dart';
import '../services/reading_task_context.dart';
import '../services/reading_companion_translation.dart';
import '../services/source_document_loader.dart';
import 'app_toast.dart';
import 'annotation_sheet.dart';
import 'chat_annotation_navigation.dart';
import 'chat_message_scroll_view.dart';
import 'companion_ink_surface.dart';
import 'companion_annotation_sheet.dart';
import 'companion_pdf_object_view.dart';
import 'companion_pdf_annotation_overlay.dart';
import 'epub_companion_object_preview.dart';
import 'message_selection_action_card.dart';
import 'pdf_page_canvas.dart'
    show horizontalPdfPageTarget, verticalPdfPageTarget, viewportPdfPageLayout;
import 'reflow_document_pager.dart';
import 'xiaoqi_document_block_view.dart';

/// Selected text and the location that the reader can resolve in the source.
class ReadingCompanionPassage {
  const ReadingCompanionPassage({
    required this.bookId,
    required this.sourceId,
    required this.text,
    required this.sourceName,
    required this.locator,
    required this.anchor,
    this.startOffset,
    this.endOffset,
    this.sourceRevision,
    this.translationRevision,
    this.endAnchor,
    this.annotationView = 'original',
    this.pdfPageTextHashes = const {},
    this.annotationAnchor,
    this.annotationStartOffset,
    this.annotationEndOffset,
    this.annotationCanonicalRange,
  });

  final int bookId;
  final int sourceId;
  final String text;
  final String sourceName;
  final String locator;
  final ReaderAnchor anchor;
  final int? startOffset;
  final int? endOffset;
  final String? sourceRevision;
  final String? translationRevision;
  final ReaderAnchor? endAnchor;
  final String annotationView;
  final Map<int, String> pdfPageTextHashes;
  final ReaderAnchor? annotationAnchor;
  final int? annotationStartOffset;
  final int? annotationEndOffset;
  final CompanionSourceRange? annotationCanonicalRange;

  CompanionAnnotationSelection get annotationSelection =>
      CompanionAnnotationSelection(
        bookId: bookId,
        sourceId: sourceId,
        sourceVersion: sourceRevision ?? '',
        anchor: annotationAnchor ?? anchor,
        endAnchor: endAnchor,
        locator: locator,
        quote: text,
        startOffset: annotationStartOffset ?? startOffset,
        endOffset: annotationEndOffset ?? endOffset,
        translationVersion: translationRevision,
        view: annotationView,
        pdfPageTextHashes: pdfPageTextHashes,
        canonicalRange: annotationCanonicalRange,
      );

  bool sameLocationAs(ReadingCompanionPassage other) =>
      bookId == other.bookId &&
      sourceId == other.sourceId &&
      anchor == other.anchor &&
      startOffset == other.startOffset &&
      endOffset == other.endOffset &&
      sourceRevision == other.sourceRevision &&
      translationRevision == other.translationRevision &&
      text == other.text;
}

typedef _ReaderSelection = ({ReadingCompanionPassage passage, Offset position});
typedef _CompanionBook = ({
  String title,
  List<BookSourceRecord> sources,
  int? preferredSourceId,
});

/// The exact local material selected by a reading task.
class ReadingCompanionTarget {
  const ReadingCompanionTarget({
    required this.title,
    required this.source,
    required this.sources,
  });

  final String title;
  final BookSourceRecord source;
  final List<BookSourceRecord> sources;

  static Future<ReadingCompanionTarget?> resolve({
    required BookLibraryService library,
    required int bookId,
    required String title,
    int? preferredSourceId,
    String? legacyPassage,
  }) async {
    final records = await library.listSourcesForBook(bookId);
    final candidates = records.where(
      (source) =>
          source.bookId == bookId &&
          SourceDocumentLoader.isReadableSource(source),
    );
    final checked = await Future.wait(
      candidates.map(
        (source) async => await File(source.filePath).exists() ? source : null,
      ),
    );
    final sources = checked.whereType<BookSourceRecord>().toList(
      growable: false,
    );
    final selected = legacyPassage == null
        ? sources
                  .where((source) => source.id == preferredSourceId)
                  .firstOrNull ??
              sources.singleOrNull
        : sourceForSavedPassage(legacyPassage, candidates);
    return selected == null || !sources.contains(selected)
        ? null
        : ReadingCompanionTarget(
            title: title,
            source: selected,
            sources: sources,
          );
  }
}

/// Postpones the first expensive chapter layout until the navigation animation
/// is finished. The document continues loading throughout the transition.
class ReadingCompanionLayoutGate extends InheritedWidget {
  const ReadingCompanionLayoutGate({
    super.key,
    required this.entering,
    required super.child,
  });

  final bool entering;

  @override
  bool updateShouldNotify(ReadingCompanionLayoutGate oldWidget) =>
      entering != oldWidget.entering;
}

/// The reader toolbar shares one row with the host's reading-space navigation.
double readingCompanionToolbarHeight(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 600 ? 72 : 56;

typedef ReadingCompanionToolbarBuilder =
    Widget Function(BuildContext context, Widget tools);

/// Book source reader embedded in the reading space.
///
/// The host owns the actual Agent conversation and composer. The reader only
/// owns navigation in the material and the selected passage's placement.
class ReadingCompanion extends StatefulWidget {
  const ReadingCompanion({
    super.key,
    required this.bookId,
    required this.library,
    required this.messages,
    required this.streamingReply,
    required this.composerBuilder,
    required this.onPassageOpened,
    this.onPassageClosed,
    this.onChatVisibilityChanged,
    this.onInkEditingChanged,
    this.onChooseBook,
    this.onOpenLibrary,
    this.loadPreferredSourceId,
    this.target,
    this.onSourceChanged,
    this.savedPassageExcerpt,
    this.immersive = false,
    this.onToggleImmersive,
    this.onEnterImmersive,
    this.onFreeChat,
    this.onDarkChanged,
    this.toolbarBuilder,
    this.initialAnnotationSelection,
  });

  final int? bookId;
  final BookLibraryService library;
  final List<AiConversationMessage> messages;
  final String? savedPassageExcerpt;
  final ValueListenable<String> streamingReply;
  final Widget Function(Widget history) composerBuilder;
  final ValueChanged<ReadingCompanionPassage> onPassageOpened;
  final VoidCallback? onPassageClosed;
  final ValueChanged<bool>? onChatVisibilityChanged;
  final ValueChanged<bool>? onInkEditingChanged;
  final AsyncCallback? onChooseBook;
  final AsyncCallback? onOpenLibrary;
  final Future<int?> Function(int bookId)? loadPreferredSourceId;
  final ReadingCompanionTarget? target;
  final Future<void> Function(BookSourceRecord source)? onSourceChanged;
  final bool immersive;
  final VoidCallback? onToggleImmersive;
  final VoidCallback? onEnterImmersive;
  final VoidCallback? onFreeChat;
  final ValueChanged<bool>? onDarkChanged;
  final ReadingCompanionToolbarBuilder? toolbarBuilder;
  final CompanionAnnotationSelection? initialAnnotationSelection;

  @override
  ReadingCompanionState createState() => ReadingCompanionState();
}

class ReadingCompanionState extends State<ReadingCompanion> {
  static const _annotationStore = CompanionAnnotationStore();
  List<CompanionAnnotation> _bookAnnotations = const [];
  String? _annotationScope;
  int _annotationLoad = 0;
  final _surface = GlobalKey();
  final _chatScroll = ScrollController();
  late Future<_CompanionBook> _book;
  _ReaderSelection? _selection;
  bool _chatOpen = false;
  final _messageKeys = <String, GlobalKey>{};
  int _historyRequest = 0;
  int? _sourceId;
  bool _minimized = false;
  (int, int, String, String)? _documentIdentity;
  GlobalKey<_CompanionDocumentState>? _documentKey;

  bool closeReaderPanelForBack() =>
      _documentKey?.currentState?._closeReaderPanel() ?? false;

  bool finishInkForBack({VoidCallback? onSaved}) {
    final state = _documentKey?.currentState;
    if (state == null || !state._inkEditing) return false;
    if (onSaved != null) state._afterInkSave = onSaved;
    if (!state._inkSaving) {
      unawaited(state._finishInk());
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    _book = _loadBook();
    CapabilityCloudSync.instance.emailSessionRevision.addListener(
      _onAnnotationSessionChanged,
    );
    CompanionAnnotationSync.instance.changes.addListener(_onAnnotationsSynced);
    unawaited(_loadBookAnnotations());
  }

  @override
  void didUpdateWidget(covariant ReadingCompanion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId ||
        oldWidget.library != widget.library ||
        oldWidget.target?.source.id != widget.target?.source.id ||
        oldWidget.target?.source.contentHash !=
            widget.target?.source.contentHash) {
      _annotationScope = null;
      _bookAnnotations = const [];
      unawaited(_loadBookAnnotations());
      _selection = null;
      _chatOpen = false;
      _historyRequest++;
      _messageKeys.clear();
      _sourceId = null;
      _minimized = false;
      _book = _loadBook();
    } else if (oldWidget.target != widget.target) {
      _book = _loadBook();
    }
  }

  @override
  void dispose() {
    CapabilityCloudSync.instance.emailSessionRevision.removeListener(
      _onAnnotationSessionChanged,
    );
    CompanionAnnotationSync.instance.changes.removeListener(
      _onAnnotationsSynced,
    );
    _chatScroll.dispose();
    super.dispose();
  }

  void _onAnnotationSessionChanged() {
    setState(() {
      _annotationScope = null;
      _bookAnnotations = const [];
    });
    unawaited(_loadBookAnnotations());
  }

  void _onAnnotationsSynced() {
    unawaited(_loadBookAnnotations());
  }

  Future<_CompanionBook> _loadBook() {
    final target = widget.target;
    if (target == null) return _loadBookById();
    return SynchronousFuture((
      title: target.title,
      sources: target.sources,
      preferredSourceId: target.source.id,
    ));
  }

  Future<_CompanionBook> _loadBookById() async {
    final bookId = widget.bookId;
    if (bookId == null) {
      return (
        title: '',
        sources: const <BookSourceRecord>[],
        preferredSourceId: null,
      );
    }
    final library = widget.library;
    final loadPreferredSourceId = widget.loadPreferredSourceId;
    final item = await library.getBookLibraryItem(bookId);
    final records = await library.listSourcesForBook(bookId);
    final checked = await Future.wait(
      records
          .where(SourceDocumentLoader.isReadableSource)
          .map(
            (source) async =>
                await File(source.filePath).exists() ? source : null,
          ),
    );
    final sources = checked.whereType<BookSourceRecord>().toList(
      growable: false,
    );
    return (
      title: item?.book.title ?? '',
      sources: sources,
      preferredSourceId: await loadPreferredSourceId?.call(bookId),
    );
  }

  bool closeChatForBack() {
    if (!_chatOpen) return false;
    _closeChat();
    return true;
  }

  void _closeChat() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selection = null;
      _minimized = false;
      _chatOpen = false;
      _historyRequest++;
      _messageKeys.clear();
    });
    widget.onChatVisibilityChanged?.call(false);
    widget.onPassageClosed?.call();
  }

  /// Opens the saved conversation without manufacturing a passage or a new turn.
  void openHistoryChat({String? messageId}) {
    final request = ++_historyRequest;
    setState(() {
      _selection = null;
      _chatOpen = true;
      _minimized = false;
      _messageKeys.clear();
    });
    widget.onChatVisibilityChanged?.call(true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool cancelled() => !mounted || request != _historyRequest || _minimized;
      if (cancelled() || !_chatScroll.hasClients) return;
      if (messageId == null) {
        _chatScroll.jumpTo(0);
        return;
      }
      await revealChatMessage(
        messageId: messageId,
        messageIds: widget.messages.reversed
            .where((message) => !message.isDeletedMarker)
            .map((message) => message.id)
            .toList(),
        anchors: _messageKeys,
        heights: {},
        controller: _chatScroll,
        cancelled: cancelled,
      );
    });
  }

  void _openChat(_ReaderSelection selection) {
    final previous = _selection;
    if (previous == null ||
        !previous.passage.sameLocationAs(selection.passage)) {
      widget.onPassageOpened(selection.passage);
      if (_chatScroll.hasClients) _chatScroll.jumpTo(0);
    }
    if (!mounted) return;
    setState(() {
      _selection = selection;
      _minimized = false;
      _chatOpen = true;
      _historyRequest++;
    });
    widget.onChatVisibilityChanged?.call(true);
  }

  Future<void> _openLibrary() async {
    final bookId = widget.bookId;
    await widget.onOpenLibrary?.call();
    if (mounted && widget.bookId == bookId) {
      _reloadBook();
    }
  }

  void _reloadBook() {
    setState(() {
      _book = _loadBook();
    });
  }

  Future<void> _chooseSource(
    List<BookSourceRecord> sources,
    BookSourceRecord current,
  ) async {
    final next = await _chooseReaderItem(
      context,
      title: '阅读资料',
      labels: sources.map((source) => source.displayName).toList(),
      activeIndex: sources.indexOf(current),
    );
    if (!mounted ||
        widget.bookId != current.bookId ||
        next == null ||
        sources[next].id == current.id) {
      return;
    }
    await _selectCompanionSource(sources[next]);
  }

  Future<void> _selectCompanionSource(BookSourceRecord source) async {
    final changeSource = widget.onSourceChanged;
    if (changeSource != null) {
      try {
        await changeSource(source);
      } catch (_) {
        if (mounted) AppToast.show(context, '切换阅读资料失败，请重试');
      }
      return;
    }
    if (_chatOpen) _closeChat();
    setState(() => _sourceId = source.id);
  }

  Future<void> _loadBookAnnotations() async {
    final generation = ++_annotationLoad;
    final bookId = widget.bookId ?? widget.target?.source.bookId;
    if (bookId == null) return;
    try {
      final scope = await _annotationStore.accountScope();
      final entries = await _annotationStore.list(scope, bookId);
      if (!mounted || generation != _annotationLoad) return;
      setState(() {
        _annotationScope = scope;
        _bookAnnotations = entries;
      });
    } catch (_) {
      if (!mounted || generation != _annotationLoad) return;
      setState(() {
        _annotationScope = null;
        _bookAnnotations = const [];
      });
    }
  }

  Future<bool> _canOpenAnnotations() async {
    try {
      final scope = await _annotationStore.accountScope();
      if (mounted && scope == _annotationScope) return true;
      final previous = _annotationScope;
      await _loadBookAnnotations();
      if (mounted && scope == _annotationScope) return previous == null;
    } catch (_) {
      // Loading failed or the account is changing.
    }
    if (mounted) AppToast.show(context, '无法读取本书注释，请重试');
    return false;
  }

  Future<CompanionAnnotation?> _editAnnotation(
    CompanionAnnotationSelection selection, {
    CompanionAnnotation? initial,
  }) async {
    final generation = CapabilityCloudSync.instance.emailSessionRevision.value;
    if (!await _canOpenAnnotations() || !mounted) return null;
    if (generation != CapabilityCloudSync.instance.emailSessionRevision.value ||
        (initial != null &&
            !_bookAnnotations.any(
              (entry) =>
                  entry.id == initial.id && entry.revision == initial.revision,
            ))) {
      return null;
    }
    final result = await editCompanionAnnotation(
      context,
      scope: _annotationScope!,
      selection: selection,
      initial: initial,
    );
    if (result != null && mounted) await _loadBookAnnotations();
    return result;
  }

  Future<void> _annotate(ReadingCompanionPassage passage) async {
    if (!await _canOpenAnnotations() || !mounted) return;
    final selection = passage.annotationSelection;
    final existing = _bookAnnotations
        .where((entry) => _sameAnnotationRange(entry.selection, selection))
        .firstOrNull;
    await _editAnnotation(existing?.selection ?? selection, initial: existing);
  }

  bool _sameAnnotationRange(
    CompanionAnnotationSelection before,
    CompanionAnnotationSelection after,
  ) {
    if (before.sourceId != after.sourceId ||
        before.sourceVersion != after.sourceVersion) {
      return false;
    }
    if (before.key == after.key) return true;
    if (before.canonicalRange != null && after.canonicalRange != null) {
      return false;
    }
    return before.view == after.view &&
        before.anchor == after.anchor &&
        before.endAnchor == after.endAnchor &&
        before.startOffset == after.startOffset &&
        before.endOffset == after.endOffset &&
        before.quote == after.quote &&
        before.translationVersion == after.translationVersion;
  }

  Future<void> _openAnnotation(CompanionAnnotation entry) async {
    if (!await _canOpenAnnotations() || !mounted) return;
    final current = _bookAnnotations
        .where((item) => item.id == entry.id)
        .firstOrNull;
    if (current == null) return;
    await viewCompanionAnnotation(
      context,
      initial: current,
      onEdit: (current) => _editAnnotation(current.selection, initial: current),
    );
  }

  Future<void> _deleteAnnotation(CompanionAnnotation entry) async {
    if (!await _canOpenAnnotations() || !mounted) return;
    final scope = _annotationScope!;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromSize(
        Rect.fromCenter(
          center: MediaQuery.sizeOf(context).center(Offset.zero),
          width: 1,
          height: 1,
        ),
        MediaQuery.sizeOf(context),
      ),
      items: const [PopupMenuItem(value: 'delete', child: Text('删除注释'))],
    );
    if (action != 'delete' || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条注释？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _annotationStore.remove(scope, entry);
      if (mounted) await _loadBookAnnotations();
    } catch (_) {
      if (mounted) AppToast.show(context, '注释删除失败，请重试');
    }
  }

  Widget _annotationList(BuildContext context, {VoidCallback? onReturn}) =>
      Column(
        children: [
          ValueListenableBuilder<String?>(
            valueListenable: CompanionAnnotationSync.instance.syncFailure,
            builder: (context, error, _) => error == null
                ? const SizedBox.shrink()
                : TextButton(
                    onPressed: () =>
                        unawaited(CompanionAnnotationSync.instance.syncNow()),
                    child: Text(error),
                  ),
          ),
          Expanded(child: _annotationItems(context, onReturn: onReturn)),
        ],
      );

  Widget _annotationItems(BuildContext context, {VoidCallback? onReturn}) =>
      ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _bookAnnotations.isEmpty ? 1 : _bookAnnotations.length,
        itemBuilder: (context, index) {
          if (_bookAnnotations.isEmpty) {
            return const ListTile(title: Text('暂无本书注释'));
          }
          final entry = _bookAnnotations[index];
          Future<void> remove() async {
            await _deleteAnnotation(entry);
            onReturn?.call();
          }

          return Semantics(
            customSemanticsActions: {
              const CustomSemanticsAction(label: '删除注释'): () =>
                  unawaited(remove()),
            },
            child: ListTile(
              onTap: () async {
                await _openAnnotation(entry);
                onReturn?.call();
              },
              onLongPress: () => unawaited(remove()),
              title: Text(
                entry.text.isNotEmpty
                    ? entry.text
                    : entry.audio.isNotEmpty
                    ? '录音'
                    : '图片',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                entry.selection.quote.replaceAll(RegExp(r'\s+'), ' '),
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
            ),
          );
        },
      );

  Future<void> _openAnnotationList() async {
    if (!await _canOpenAnnotations() || !mounted) return;
    final revision = CapabilityCloudSync.instance.emailSessionRevision.value;
    await showAnnotationSheet<void>(
      context,
      builder: (context) => guardPrivateAnnotationContent(
        revision,
        StatefulBuilder(
          builder: (context, update) => SizedBox(
            height: MediaQuery.sizeOf(context).height * .55,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    '本书注释',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: _annotationList(
                    context,
                    onReturn: () {
                      if (context.mounted) update(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bookFallback(BuildContext context, Widget content) {
    final toolbar = widget.toolbarBuilder;
    if (toolbar == null || widget.immersive) return content;
    return Column(
      children: [
        toolbar(context, const SizedBox.shrink()),
        Expanded(child: content),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: LayoutBuilder(
      builder: (context, constraints) => Stack(
        key: _surface,
        children: [
          Positioned.fill(
            child: FutureBuilder(
              future: _book,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return _bookFallback(context, const _ReadingPlaceholder());
                }
                if (snapshot.hasError) {
                  return _bookFallback(
                    context,
                    _ReaderStatus(
                      '阅读资料暂时无法打开',
                      action: '重试',
                      onAction: _reloadBook,
                    ),
                  );
                }
                final book = snapshot.requireData;
                final sources = book.sources;
                if (sources.isEmpty) {
                  final chooseBook = widget.bookId == null
                      ? widget.onChooseBook
                      : null;
                  return _bookFallback(
                    context,
                    _ReaderStatus(
                      widget.bookId == null ? '选择一本书后开始伴读' : '这本书还没有阅读资料',
                      action: widget.bookId != null
                          ? '打开本书资料'
                          : chooseBook == null
                          ? '打开书库'
                          : '选择书籍',
                      onAction:
                          chooseBook ??
                          (widget.onOpenLibrary == null ? null : _openLibrary),
                      secondaryAction: _bookAnnotations.isEmpty ? null : '本书注释',
                      onSecondaryAction: _bookAnnotations.isEmpty
                          ? null
                          : () => unawaited(_openAnnotationList()),
                    ),
                  );
                }
                final current =
                    sources
                        .where((source) => source.id == _sourceId)
                        .firstOrNull ??
                    sources
                        .where((source) => source.id == book.preferredSourceId)
                        .firstOrNull ??
                    sources.first;
                final pdf = sources.where(_isCompanionPdf).toList();
                final ebooks = sources
                    .where((item) => !_isCompanionPdf(item))
                    .toList();
                final identity = (
                  current.bookId,
                  current.id,
                  current.contentHash,
                  current.sourceVersionId,
                );
                if (_documentIdentity != identity) {
                  _documentIdentity = identity;
                  _documentKey = GlobalKey<_CompanionDocumentState>();
                }
                return _CompanionDocument(
                  key: _documentKey,
                  source: current,
                  bookTitle: book.title,
                  immersive: widget.immersive,
                  onToggleImmersive: _chatOpen
                      ? null
                      : widget.onToggleImmersive,
                  onEnterImmersive: _chatOpen ? null : widget.onEnterImmersive,
                  onFreeChat: _chatOpen ? null : widget.onFreeChat,
                  onDarkChanged: widget.onDarkChanged,
                  onInkEditingChanged: widget.onInkEditingChanged,
                  toolbarBuilder: widget.toolbarBuilder,
                  onSwitchFormat: pdf.isNotEmpty && ebooks.isNotEmpty
                      ? () {
                          final alternatives = _isCompanionPdf(current)
                              ? ebooks
                              : pdf;
                          if (alternatives.length == 1) {
                            unawaited(
                              _selectCompanionSource(alternatives.single),
                            );
                          } else {
                            unawaited(_chooseSource(alternatives, current));
                          }
                        }
                      : null,
                  library: widget.library,
                  onAsk: (passage, globalAnchor) {
                    final box = _surface.currentContext?.findRenderObject();
                    if (box is! RenderBox || !box.hasSize) return;
                    _openChat((
                      passage: passage,
                      position: box.globalToLocal(globalAnchor),
                    ));
                  },
                  onAnnotate: _annotate,
                  annotationList: _annotationList,
                  annotations: _bookAnnotations,
                  onOpenAnnotation: _openAnnotation,
                  initialAnnotationSelection: widget.initialAnnotationSelection,
                  onChooseSource: sources.length > 1
                      ? () => _chooseSource(sources, current)
                      : null,
                  onOpenLibrary: widget.onOpenLibrary == null
                      ? null
                      : _openLibrary,
                );
              },
            ),
          ),
          if (_chatOpen) _positionChat(constraints, _selection),
        ],
      ),
    ),
  );

  Widget _positionChat(BoxConstraints available, _ReaderSelection? selection) {
    final width = math.min(
      640.0,
      available.maxWidth < 600
          ? math.max(0.0, available.maxWidth - 24)
          : available.maxWidth * .60,
    );
    final right = available.maxWidth < 600 ? 12.0 : available.maxWidth / 30;
    final height = math.min(
      width * 4 / 3,
      math.max(0.0, available.maxHeight - 24),
    );
    if (_minimized || height < 152) {
      return Positioned(
        right: right,
        bottom: 64,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
          onPressed: height < 152
              ? () => FocusManager.instance.primaryFocus?.unfocus()
              : () {
                  setState(() => _minimized = false);
                  widget.onChatVisibilityChanged?.call(true);
                },
          icon: _readerIcon(
            'assets/icons/extension_market/detail/chat-dots.svg',
          ),
          label: const Text('继续问答'),
        ),
      );
    }
    final top =
        (selection == null
                ? (available.maxHeight - height) / 2
                : selection.position.dy + 12)
            .clamp(8.0, math.max(8.0, available.maxHeight - height - 8))
            .toDouble();
    return Positioned(
      right: right,
      top: top,
      width: width,
      height: height,
      child: _chatCard(selection?.passage.text ?? widget.savedPassageExcerpt),
    );
  }

  Widget _chatCard(String? quote) => Material(
    color: Colors.white,
    elevation: 5,
    shadowColor: const Color(0x26000000),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Color(0xFFD5D5D5)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 9, left: 5),
                  child: quote == null
                      ? const SizedBox.shrink()
                      : _PassageQuote(text: quote),
                ),
              ),
              const SizedBox(width: 6),
              _ReaderButton(
                label: '收起问答',
                icon: 'assets/images/reading_companion_minimize.svg',
                onPressed: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() => _minimized = true);
                  widget.onChatVisibilityChanged?.call(false);
                },
              ),
              _ReaderButton(
                label: '关闭问答',
                icon: 'assets/icons/extension_market/detail/close.svg',
                onPressed: _closeChat,
              ),
            ],
          ),
          Expanded(
            child: widget.composerBuilder(
              _CompanionHistory(
                controller: _chatScroll,
                messages: widget.messages,
                streamingReply: widget.streamingReply,
                messageKeys: _messageKeys,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CompanionDocument extends StatefulWidget {
  const _CompanionDocument({
    super.key,
    required this.bookTitle,
    required this.source,
    required this.library,
    required this.onAsk,
    required this.onAnnotate,
    required this.annotationList,
    required this.annotations,
    required this.onOpenAnnotation,
    this.onChooseSource,
    this.onOpenLibrary,
    required this.immersive,
    this.onToggleImmersive,
    this.onEnterImmersive,
    this.onSwitchFormat,
    this.onFreeChat,
    this.onDarkChanged,
    this.onInkEditingChanged,
    this.toolbarBuilder,
    this.initialAnnotationSelection,
  });

  final BookSourceRecord source;
  final BookLibraryService library;
  final String bookTitle;
  final void Function(ReadingCompanionPassage, Offset) onAsk;
  final ValueChanged<ReadingCompanionPassage> onAnnotate;
  final WidgetBuilder annotationList;
  final List<CompanionAnnotation> annotations;
  final ValueChanged<CompanionAnnotation> onOpenAnnotation;
  final VoidCallback? onChooseSource;
  final VoidCallback? onOpenLibrary;
  final bool immersive;
  final VoidCallback? onToggleImmersive;
  final VoidCallback? onEnterImmersive;
  final VoidCallback? onSwitchFormat;
  final VoidCallback? onFreeChat;
  final ValueChanged<bool>? onDarkChanged;
  final ValueChanged<bool>? onInkEditingChanged;
  final ReadingCompanionToolbarBuilder? toolbarBuilder;
  final CompanionAnnotationSelection? initialAnnotationSelection;

  @override
  State<_CompanionDocument> createState() => _CompanionDocumentState();
}

bool _isCompanionPdf(BookSourceRecord source) =>
    normalizeBookSourceFormat(source.format) == 'pdf';

enum _ReaderPanel { outline, progress, display }

class _CompanionDocumentState extends State<_CompanionDocument> {
  static const _preferences = ReaderPaginationPreferences();
  late Future<({XiaoqiDocument? document, ReaderAnchor? anchor})> _loading;
  File? _epubLayoutCache;
  final _pdf = PdfViewerController();
  late final _selectablePdfReference = PdfDocumentRefByLoader(
    (_) async => CompanionSelectionDocument(
      await PdfDocument.openFile(_source.filePath, useProgressiveLoading: true),
    ),
    key: PdfDocumentRefKey(_source.filePath, [this]),
  );
  bool _pdfToolbarVisible = false;
  bool _pdfHandleMoving = false;
  int _pdfGestureRevision = 0;
  ({int page, Offset center})? _pdfSwipeStart;
  Offset? _pdfPanStart;
  int? _pdfGesturePage;
  double _pdfTranslationOverscroll = 0;
  double _pdfTranslationHorizontalDelta = 0;
  ({
    List<PdfPage> pages,
    Size viewport,
    double margin,
    Axis axis,
    PdfPageLayout layout,
  })?
  _pdfViewportLayout;
  bool _pdfSnapPending = false;
  int _pdfSwipeRevision = 0;
  Timer? _pdfPageWork;
  bool _pdfTextProbePending = false;
  bool _pdfEbookEntryPending = false;
  late final _pdfReflow = CompanionPdfReflow(_source);
  CompanionReflowPage? _convertedPage;
  final _convertedPages = <int, CompanionReflowPage>{};
  PreparedCompanionPdf? _preparedBook;
  bool _preparingBook = false;
  String? _ebookError;
  bool _ebookLayoutReady = false;
  FlowReaderAnchor? _positionedEbookEntry;
  bool _returningToPdf = false;
  bool _readyAnnounced = false;
  ui.Image? _returnPreview;
  int? _returnPreviewPage;
  List<XiaoqiDocumentBlock> _ebookScreen = const [];
  int _ebookReadyRevision = 0;
  bool _ebookScrollActive = false;
  PdfReaderAnchor? _pdfReadingAnchor;
  XiaoqiDocument? _convertedDocument;
  FlowReaderAnchor? _convertedEntry;
  bool _requestedEbook = false;
  bool _ebookSwitchPending = false;
  int? _requestedPdfPage;
  int _ebookSwitchRevision = 0;
  FlowReaderAnchor? _chapterNavigation;
  FlowReaderAnchor? _flowPosition;
  FlowReaderAnchor? _flowPositionBeforeJump;
  PdfReaderAnchor? _pdfPositionBeforeJump;
  int _navigationRevision = 0;
  int _pdfPage = 1;
  int _pdfPageCount = 0;
  int? _pageBeforeJump;
  _ReaderPanel? _activePanel;
  double _outlineExtent = 0;
  bool _outlineShowsAnnotations = false;
  bool _outlineDragging = false;
  LocalHistoryEntry? _panelHistory;
  WidgetBuilder? _outlinePanel;
  Future<List<PdfCatalogEntry>>? _pdfBookmarkOutline;
  final _progressPreview = ValueNotifier<double?>(null);
  static const _defaultFontScale = 1.0;
  static const _defaultMarginFraction = .04;
  static const _defaultLineScale = 1.0;
  static const _defaultBrightness = .65;
  static const _brightnessPreference = 'reading-companion.brightness';
  double _fontScale = _defaultFontScale;
  double _marginFraction = _defaultMarginFraction;
  double _lineScale = _defaultLineScale;
  ReaderPaginationMode _pdfPageTurnMode = ReaderPaginationMode.vertical;
  ReaderPaginationMode _ebookPageTurnMode = ReaderPaginationMode.vertical;
  bool _ebookPaperTurn = false;
  double _brightness = _defaultBrightness;
  bool _adjustingTypography = false;
  bool _brightnessErrorReported = false;
  bool _hasBrightnessOverride = false;
  bool _dark = false;
  PdfDocument? _pdfDocumentRef;
  ui.FragmentShader? _nightShader;
  // On non-Impeller renderers retain chroma while reflecting luminance.
  // The same paint also colours the initial white tile before pixels arrive.
  final _nightPaint = Paint()
    ..colorFilter = const ColorFilter.matrix([
      .415,
      -.610,
      -.610,
      0,
      230,
      -.595,
      .405,
      -.595,
      0,
      227,
      -.582,
      -.582,
      .418,
      0,
      220,
      0,
      0,
      0,
      1,
      0,
    ]);
  bool _translationEnabled = false;
  bool _foreignSource = false;
  bool _pdfTextAvailable = false;
  bool _translationPending = false;
  bool _translationInFlight = false;
  bool _selectionActive = false;
  String? _translationError;
  Timer? _translationDelay;
  int _translationRevision = 0;
  List<XiaoqiDocumentBlock> _visibleBlocks = const [];
  final _flowTranslations = <String, String>{};
  final _alignedFlowTranslations = <String, CompanionTranslationText>{};
  CompanionTranslationText? _translatedPdfPage;
  bool _translatedPdfHasNativeSource = false;
  bool _handledInitialPdfAnnotation = false;
  ({int page, List<PdfRect> bounds})? _noteOriginPdfMark;
  Timer? _noteOriginMarkTimeout;
  int? _translatedPdfNumber;
  VoidCallback? _applyDeferredTranslation;
  final _savedInk = <String, _CompanionInkRecord>{};
  final _largeDrawings = <String>{};
  final _loadingDrawings = <String>{};
  final _failedDrawings = <String>{};
  final _drawingTools = DrawingAnnotationTools();
  final _drawingLayers =
      <String, ({DrawingAnnotationLayer layer, String? text})>{};
  bool _inkEditing = false;
  bool _inkSaving = false;
  VoidCallback? _afterInkSave;
  bool _inkLoaded = false;
  bool _inkLoadFailed = false;
  static const _brightnessChannel = MethodChannel('xiaoqi_app/runtime_config');
  static const _paperDark = Color(0xFF191B1E);
  static const _darkSelectionColor = Color(0x77949AA2);
  final _nightSelectionTextRequested = Expando<bool>();
  final _nightSelectionLoadedText = Expando<PdfPageText>();
  final _nightSelectionPaint = Paint()..color = _darkSelectionColor;
  bool _pdfSelectionUiUpdateScheduled = false;
  Color get _ink => _dark ? const Color(0xFFE6E3DC) : const Color(0xFF262626);

  ThemeData _readerTheme(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3D3D3D),
      brightness: _dark ? Brightness.dark : Brightness.light,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    );
    final base = Theme.of(context);
    final flatButtons = ButtonStyle(
      elevation: const WidgetStatePropertyAll(0.0),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? _ink.withValues(alpha: .10)
            : Colors.transparent,
      ),
    );
    return base.copyWith(
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: _dark ? _paperDark : Colors.white,
      textTheme: base.textTheme.apply(bodyColor: _ink, displayColor: _ink),
      iconTheme: base.iconTheme.copyWith(color: _ink),
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      textButtonTheme: TextButtonThemeData(style: flatButtons),
      iconButtonTheme: IconButtonThemeData(style: flatButtons),
      filledButtonTheme: FilledButtonThemeData(style: flatButtons),
      outlinedButtonTheme: OutlinedButtonThemeData(style: flatButtons),
    );
  }

  bool _renderedChapter = false;

  BookSourceRecord get _source => widget.source;
  String get _sourceKey => _source.id.toString();
  String get _annotationSourceVersion => _source.sourceVersionId.isEmpty
      ? _source.contentHash
      : _source.sourceVersionId;

  List<CompanionAnnotation> _pdfAnnotations(int page) => [
    for (final entry in widget.annotations)
      if (_sourceMatches(entry.selection) &&
          _annotationShowsOnPdfPage(entry.selection, page))
        entry,
  ];

  bool _annotationShowsOnPdfPage(
    CompanionAnnotationSelection selection,
    int page,
  ) {
    final range = selection.canonicalRange;
    return range is CompanionPdfSourceRange
        ? range.pages.any((span) => span.page == page)
        : selection.view == 'original' &&
              selection.pdfPageTextHashes.containsKey(page);
  }

  bool _sourceMatches(CompanionAnnotationSelection selection) =>
      selection.sourceId == _source.id &&
      selection.sourceVersion == _annotationSourceVersion;

  Future<void> _openMatchingAnnotations(
    List<CompanionAnnotation> entries,
  ) async {
    if (_inkEditing || _hasActiveSelection || entries.isEmpty) return;
    if (entries.length == 1) {
      widget.onOpenAnnotation(entries.first);
      return;
    }
    final revision = CapabilityCloudSync.instance.emailSessionRevision.value;
    final entry = await showAnnotationSheet<CompanionAnnotation>(
      context,
      builder: (context) => guardPrivateAnnotationContent(
        revision,
        ListView(
          shrinkWrap: true,
          children: [
            for (final entry in entries)
              ListTile(
                title: Text(
                  entry.text.isEmpty ? entry.selection.quote : entry.text,
                ),
                onTap: () => Navigator.pop(context, entry),
              ),
          ],
        ),
      ),
    );
    if (mounted && entry != null) widget.onOpenAnnotation(entry);
  }

  bool get _isPdfDocument => _isCompanionPdf(_source) && _convertedPage == null;
  bool get _isSelectingEbook =>
      !_isCompanionPdf(_source) || _convertedPage != null;
  bool get _canRetryEbook =>
      _isPdfDocument && _ebookError != null && !_preparingBook;
  bool get _hasPendingFormatSwitch =>
      _isPdfDocument ? _ebookSwitchPending && _requestedEbook : _returningToPdf;
  bool get _hasActiveSelection =>
      _selectionActive ||
      (_isPdfDocument &&
          _pdf.isReady &&
          _pdf.textSelectionDelegate.hasSelectedText);

  void _toggleReaderChrome() {
    if (_inkEditing) return;
    if (_hasActiveSelection) {
      _dismissFlowSelection();
      return;
    }
    widget.onToggleImmersive?.call();
  }

  void _dismissFlowSelection() {
    if (_isPdfDocument || !_selectionActive) return;
    final focus = FocusManager.instance.primaryFocus;
    final editor = focus?.context?.findAncestorStateOfType<EditableTextState>();
    if (editor != null && editor.widget.readOnly) {
      _collapseReaderTextSelection(editor);
    }
    focus?.unfocus();
    if (_selectionActive) _reportSelection(false);
  }

  void _collapseReaderTextSelection(EditableTextState editor) {
    final value = editor.textEditingValue;
    final selection = value.selection;
    if (selection.isValid && !selection.isCollapsed) {
      editor.userUpdateTextEditingValue(
        value.copyWith(
          selection: TextSelection.collapsed(offset: selection.extentOffset),
        ),
        SelectionChangedCause.tap,
      );
    }
    editor.hideToolbar();
    if (_selectionActive) _reportSelection(false);
  }

  void _hideReaderChrome() {
    if (widget.immersive ||
        _inkEditing ||
        _hasActiveSelection ||
        _readerPanelOpen) {
      return;
    }
    widget.onEnterImmersive?.call();
  }

  @override
  void initState() {
    super.initState();
    final savedDisplay = _restoreDisplay();
    _loading = _loadDocument().then((value) async {
      await savedDisplay;
      return value;
    });
    if (_isCompanionPdf(_source) && ui.ImageFilter.isShaderFilterSupported) {
      unawaited(_prepareNightPaint());
    }
    if (widget.initialAnnotationSelection == null) {
      unawaited(_restoreTranslation());
    }
    unawaited(_loadInk());
  }

  Future<void> _prepareBook() async {
    if (_preparingBook || _preparedBook != null) return;
    setState(() {
      _preparingBook = true;
      _ebookError = null;
    });
    try {
      final document = _pdfDocumentRef;
      final book = await _pdfReflow.prepareBook(
        loadedPageCount: document?.pages.length,
        allowsCopying: document == null
            ? null
            : document.permissions?.allowsCopying != false,
      );
      if (!mounted) return;
      setState(() {
        _preparedBook = book;
        _preparingBook = false;
        _pdfEbookEntryPending = true;
      });
      _schedulePdfPageWork();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _preparingBook = false;
        _ebookError = error is FormatException ? error.message : '电子书准备失败，请重试';
      });
    }
  }

  void _schedulePdfPageWork({bool probeText = false}) {
    _pdfTextProbePending = _pdfTextProbePending || probeText;
    _pdfPageWork?.cancel();
    _pdfPageWork = Timer(const Duration(milliseconds: 140), () {
      final document = _pdfDocumentRef;
      if (!mounted || !_isPdfDocument || document == null || _inkEditing) {
        return;
      }
      if (_pdfSnapPending || _pdfGesturePage != null) {
        _schedulePdfPageWork();
        return;
      }
      if (_pdfTextProbePending) {
        _pdfTextProbePending = false;
        unawaited(_detectPdfPage(document, _pdfPage));
      }
      if (_pdfEbookEntryPending && _preparedBook != null && !_requestedEbook) {
        final anchor = _pdfReadingAnchor;
        setState(
          () => _targetEbook(anchor?.pageNumber ?? _pdfPage, previous: anchor),
        );
      }
      if (_preparedBook == null && !_preparingBook && _ebookError == null) {
        unawaited(_prepareBook());
      }
    });
  }

  void _switchReaderFormat(bool pdf) {
    if (!_isCompanionPdf(_source)) {
      if (pdf) widget.onSwitchFormat?.call();
      return;
    }
    if (pdf) {
      unawaited(_returnToPdf());
    } else if (_canRetryEbook) {
      unawaited(_prepareBook());
    } else if (_ebookLayoutReady && !_inkEditing) {
      unawaited(
        _openConvertedPage(
          _pdfReadingAnchor?.pageNumber ?? _pdfPage,
          fromPdf: true,
        ),
      );
    }
  }

  void _activateFormatButton(bool pdf) {
    if (pdf == _isSelectingEbook) {
      _switchReaderFormat(pdf);
      return;
    }
    if (!_hasPendingFormatSwitch) {
      widget.onChooseSource?.call();
      return;
    }
    ++_ebookSwitchRevision;
    setState(() {
      _returningToPdf = false;
      _ebookSwitchPending = false;
      _requestedEbook = _convertedPage != null;
    });
  }

  void _targetEbook(
    int number, {
    PdfReaderAnchor? previous,
    bool recenter = false,
    double? edge,
  }) {
    final book = _preparedBook;
    final page = book?.pages[number];
    if (page == null || book == null) return;
    _pdfEbookEntryPending = false;
    final before = _convertedDocument;
    if (_ebookPageTurnMode == ReaderPaginationMode.horizontal) {
      if (!identical(_convertedDocument, book.document)) {
        _convertedPages
          ..clear()
          ..addAll(book.pages);
        _convertedDocument = book.document;
      }
    } else if (recenter ||
        _convertedDocument == null ||
        !_convertedPages.containsKey(number) ||
        (_convertedPages.length == book.pages.length &&
            book.pages.length > 9)) {
      _convertedPages.clear();
      for (
        var i = math.max(1, number - 4);
        i <= math.min(book.pages.length, number + 4);
        i++
      ) {
        _convertedPages[i] = book.pages[i]!;
      }
      _convertedDocument = CompanionReflowPage.readingWindow(
        _convertedPages.values,
        book.pages.length,
      );
    }
    final target = _convertedAnchor(
      page,
      top: edge,
      previous: previous?.pageNumber == number ? previous : null,
    );
    // Seeking to another paragraph in an already paginated book preserves
    // its layout. Its offstage pager acknowledges the new position separately.
    if (before != _convertedDocument) {
      if (before == null ||
          _ebookPageTurnMode == ReaderPaginationMode.horizontal) {
        _ebookLayoutReady = false;
      }
    }
    if (before != _convertedDocument || _convertedEntry != target) {
      _positionedEbookEntry = null;
      ++_ebookReadyRevision;
    }
    _requestedPdfPage = number;
    _convertedEntry = target;
    _chapterNavigation = null;
    _flowPosition = target;
    if (_convertedPage != null) _convertedPage = page;
  }

  Future<void> _openConvertedPage(
    int number, {
    bool fromPdf = false,
    double? edge,
    PdfReaderAnchor? position,
  }) async {
    if (_preparedBook?.pages.containsKey(number) != true || _inkEditing) return;
    final page = _preparedBook!.pages[number]!;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_pdf.isReady && _pdf.textSelectionDelegate.hasSelectedText) {
      unawaited(_pdf.textSelectionDelegate.clearTextSelection());
    }
    ++_ebookSwitchRevision;
    ++_pdfGestureRevision;
    setState(() {
      _targetEbook(
        number,
        previous: position ?? (fromPdf ? _pdfReadingAnchor : null),
        edge: edge,
      );
      _returningToPdf = false;
      _requestedEbook = true;
      _ebookSwitchPending =
          !_ebookLayoutReady || _positionedEbookEntry != _convertedEntry;
      if (!fromPdf || !_ebookSwitchPending) _convertedPage = page;
      _foreignSource =
          _foreignSource || ReadingCompanionTranslation.isForeign(page.text);
    });
    if (position != null && position.pageNumber == number) {
      _rememberPdfPosition(
        number,
        blockId: position.blockId,
        characterOffset: position.characterOffset,
        pageFraction: position.pageFraction,
      );
    } else if (!fromPdf) {
      _rememberConvertedPosition(_convertedDocument!, _convertedEntry!);
    }
    _scheduleTranslation();
  }

  Future<void> _ebookLayoutChanged(
    XiaoqiDocument document,
    FlowReaderAnchor? target,
    bool ready,
  ) async {
    if (!mounted ||
        _convertedDocument != document ||
        _convertedEntry != target) {
      return;
    }
    final revision = ++_ebookReadyRevision;
    if (_ebookLayoutReady == ready &&
        (!ready || (_positionedEbookEntry == target && !_ebookSwitchPending))) {
      return;
    }
    if (ready && _convertedPage == null) {
      for (final block in _ebookScreen) {
        if (block.kind != 'image') continue;
        final number = CompanionReflowPage.pageForBlock(block.id);
        final picture = _convertedPages[number]?.pictures
            .where((p) => p.asset.id == block.assetId)
            .firstOrNull;
        final path = picture?.cachePath;
        if (path == null) continue;
        Object? failure;
        await precacheImage(
          FileImage(File(path)),
          context,
          onError: (error, _) => failure = error,
        );
        if (!mounted ||
            revision != _ebookReadyRevision ||
            _convertedDocument != document ||
            _convertedEntry != target) {
          return;
        }
        if (failure != null) {
          if (number != null) {
            try {
              await _pdfReflow.invalidatePage(number);
            } on FileSystemException {
              /* Surface a retry below. */
            }
          }
          if (!mounted || revision != _ebookReadyRevision) return;
          setState(() {
            _preparedBook = null;
            _convertedDocument = null;
            _ebookLayoutReady = false;
            _positionedEbookEntry = null;
            _requestedEbook = false;
            _ebookSwitchPending = false;
            _ebookError = '当前页图片暂不可读，请重试';
          });
          return;
        }
      }
    }
    setState(() {
      _ebookLayoutReady = ready;
      _positionedEbookEntry = ready ? target : null;
      if (ready && _requestedEbook && _ebookSwitchPending && !_inkEditing) {
        _convertedPage = _preparedBook?.pages[_requestedPdfPage];
        _ebookSwitchPending = false;
      }
    });
    if (ready && !_readyAnnounced && _convertedPage == null) {
      _readyAnnounced = true;
      AppToast.show(context, '电子书已就绪');
    }
  }

  FlowReaderAnchor _convertedAnchor(
    CompanionReflowPage page, {
    double? top,
    PdfReaderAnchor? previous,
  }) {
    final fraction = previous?.pageFraction;
    final blockTop = page.originalTop(
      previous?.blockId,
      previous?.characterOffset,
    );
    final savedPosition =
        previous != null &&
            blockTop != null &&
            (fraction == null || (blockTop - fraction).abs() <= .015)
        ? CompanionReflowPage.displayPosition(
            _convertedDocument!,
            previous.blockId,
            previous.characterOffset,
          )
        : null;
    final entry = page.entryNear(top ?? fraction ?? 0);
    final position =
        savedPosition ??
        CompanionReflowPage.displayPosition(
          _convertedDocument!,
          entry?.blockId,
          entry?.offset ?? 0,
        );
    return FlowReaderAnchor(
      sourceId: _sourceKey,
      chapterId: CompanionReflowPage.readingChapterId,
      blockId: position?.blockId ?? entry?.blockId,
      characterOffset: position?.offset ?? entry?.offset ?? 0,
    );
  }

  int get _firstConvertedPage => _convertedPages.keys.first;
  int get _lastConvertedPage => _convertedPages.keys.last;

  Future<void> _continueConvertedReading(
    int target, {
    required bool forward,
  }) async {
    await _openConvertedPage(target, edge: forward ? 0 : 1);
  }

  void _prepareEbookNeighbors() {
    final page = _convertedPage?.number;
    if (page == null ||
        _ebookScrollActive ||
        _inkEditing ||
        _selectionActive ||
        _ebookPageTurnMode != ReaderPaginationMode.vertical) {
      return;
    }
    if ((page - _firstConvertedPage <= 1 && _firstConvertedPage > 1) ||
        (_lastConvertedPage - page <= 1 &&
            _lastConvertedPage < _pdfPageCount)) {
      setState(
        () => _targetEbook(page, previous: _pdfReadingAnchor, recenter: true),
      );
    }
  }

  void _paintReturnPreview(Canvas canvas, Rect rect, PdfPage page) {
    final image = _returnPreview;
    if (image == null || _returnPreviewPage != page.pageNumber) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  void _releaseReturnPreview() {
    if (_returnPreview == null) return;
    _returnPreview?.dispose();
    _returnPreview = null;
    _returnPreviewPage = null;
    if (_pdf.isReady) _pdf.invalidate();
  }

  Future<void> _returnToPdf() async {
    if (!_requestedEbook || _returningToPdf) return;
    final revision = ++_ebookSwitchRevision;
    setState(() => _returningToPdf = true);
    try {
      await _showOriginalPdf(revision);
    } finally {
      if (mounted && revision == _ebookSwitchRevision) {
        setState(() => _returningToPdf = false);
      }
    }
  }

  Future<void> _showOriginalPdf(int revision) async {
    final converted = _convertedPage;
    final page = _pdfReadingAnchor?.pageNumber ?? converted?.number ?? _pdfPage;
    FocusManager.instance.primaryFocus?.unfocus();
    if (converted != null) {
      if (_returnPreviewPage != page || _returnPreview == null) {
        try {
          final original = await _pdf.document.pages[page - 1].waitForLoaded(
            timeout: const Duration(seconds: 6),
          );
          if (!mounted || revision != _ebookSwitchRevision) return;
          if (original == null) throw const FormatException('原页未能及时加载');
          final pixels = MediaQuery.devicePixelRatioOf(context);
          final scale =
              math.min(
                _pdf.viewSize.width / original.width,
                _pdf.viewSize.height / original.height,
              ) *
              pixels;
          final raster = await original.render(
            fullWidth: original.width * scale,
            fullHeight: original.height * scale,
          );
          if (raster == null) throw const FormatException('无法显示原页');
          late final ui.Image image;
          try {
            image = await raster.createImage();
          } finally {
            raster.dispose();
          }
          if (!mounted ||
              revision != _ebookSwitchRevision ||
              _pdfReadingAnchor?.pageNumber != page &&
                  _pdfReadingAnchor != null) {
            image.dispose();
            return;
          }
          _returnPreview?.dispose();
          _returnPreview = image;
          _returnPreviewPage = page;
        } on Exception {
          if (mounted && revision == _ebookSwitchRevision) {
            AppToast.show(context, '暂时无法显示 PDF 原页，请重试');
          }
          return;
        }
      }
      _installPdfText(converted);
      await _goToPdfReaderPage(
        page,
        duration: Duration.zero,
        recordProgress: false,
      );
      if (!mounted || revision != _ebookSwitchRevision) return;
    }
    setState(() {
      _requestedEbook = false;
      _ebookSwitchPending = false;
      _convertedPage = null;
      _pdfPage = page;
      _visibleBlocks = const [];
      _targetEbook(page, previous: _pdfReadingAnchor);
    });
    _reportSelection(false);
    _scheduleTranslation();
    _schedulePdfPageWork(probeText: true);
  }

  void _rememberPdfPosition(
    int page, {
    String? blockId,
    int characterOffset = 0,
    double? pageFraction,
  }) {
    final anchor = PdfReaderAnchor(
      sourceId: _sourceKey,
      pageNumber: page,
      blockId: blockId,
      characterOffset: characterOffset,
      pageFraction: pageFraction,
    );
    if (anchor == _pdfReadingAnchor) return;
    _pdfReadingAnchor = anchor;
    if (_isPdfDocument && _preparedBook != null && !_inkEditing) {
      _pdfEbookEntryPending = true;
      _schedulePdfPageWork();
    }
    unawaited(_preferences.saveAnchor(bookId: _source.bookId, anchor: anchor));
  }

  void _rememberConvertedPosition(
    XiaoqiDocument document,
    FlowReaderAnchor anchor,
  ) {
    final source = CompanionReflowPage.sourcePosition(
      document,
      anchor.blockId,
      anchor.characterOffset,
    );
    final blockId = source?.blockId ?? anchor.blockId;
    final number = CompanionReflowPage.pageForBlock(blockId);
    final page = _convertedPages[number];
    if (page == null || blockId == null) return;
    final offset = source?.offset ?? anchor.characterOffset;
    _rememberPdfPosition(
      page.number,
      blockId: blockId,
      characterOffset: offset,
      pageFraction: page.originalTop(blockId, offset),
    );
  }

  void _installPdfText(CompanionReflowPage result) {
    final document = _pdfDocumentRef;
    if (document is CompanionSelectionDocument) document.install(result);
    if (_isPdfDocument && result.number == _pdfPage && document != null) {
      unawaited(_detectPdfPage(document, result.number));
    }
  }

  Future<void> _selectRecognizedText(Offset target) async {
    final revision = ++_pdfGestureRevision;
    if (!_pdf.isReady) return;
    final index = _pdf.layout.pageLayouts.indexWhere(
      (rect) => rect.contains(target),
    );
    if (index < 0) return;
    if (_pdfDocumentRef?.permissions?.allowsCopying == false) {
      AppToast.show(context, '这份 PDF 限制复制文字');
      return;
    }
    CompanionReflowPage? recognized;
    try {
      recognized = await _pdfReflow.load(_pdf, index + 1);
    } on Exception {
      // The original page stays visible if its text cannot be recognized.
    }
    if (!mounted ||
        !_isPdfDocument ||
        _inkEditing ||
        revision != _pdfGestureRevision ||
        !_pdf.isReady) {
      return;
    }
    if (recognized == null) {
      if (!_pdfTextAvailable) AppToast.show(context, '此页暂时无法识别文字');
      return;
    }
    final rect = _pdf.layout.pageLayouts[index];
    final point = Offset(
      (target.dx - rect.left) / rect.width,
      (target.dy - rect.top) / rect.height,
    );
    final line = recognized.lines
        .where(
          (item) =>
              item.recognized && item.bounds.inflate(.012).contains(point),
        )
        .firstOrNull;
    if (line == null) {
      if (!_pdfTextAvailable) AppToast.show(context, '此处没有可选文字');
      return;
    }
    _installPdfText(recognized);
    final text = await _pdf.document.pages[index].loadStructuredText();
    if (!mounted ||
        !_isPdfDocument ||
        _inkEditing ||
        revision != _pdfGestureRevision ||
        !_pdf.isReady) {
      return;
    }
    final fragment = text.fragments.where((run) {
      final bounds = _pdf.calcRectForRectInsidePage(
        pageNumber: index + 1,
        rect: run.bounds,
      );
      return bounds.inflate(6 / _pdf.currentZoom).contains(target);
    }).firstOrNull;
    if (fragment == null || fragment.length < 1) return;
    await _pdf.textSelectionDelegate.setTextSelectionPointRange(
      PdfTextSelectionRange.fromPoints(
        PdfTextSelectionPoint(text, fragment.index),
        PdfTextSelectionPoint(text, fragment.end - 1),
      ),
    );
  }

  Widget _readerBody(ReaderAnchor? anchor) {
    final converted = _convertedPage;
    final document = _convertedDocument;
    return IndexedStack(
      sizing: StackFit.expand,
      index: converted == null ? 0 : 1,
      children: [
        Listener(
          onPointerDown: (_) => _releaseReturnPreview(),
          onPointerSignal: (_) => _releaseReturnPreview(),
          child: _pdfDocument(anchor),
        ),
        if (document != null)
          _flow(
            document,
            _convertedEntry,
            originalPage: converted?.number ?? _requestedPdfPage ?? _pdfPage,
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }

  String _inkLocation(ReaderAnchor anchor, String view) => jsonEncode([
    _source.sourceVersionId,
    _source.contentHash,
    if (anchor is PdfReaderAnchor) anchor.pageNumber,
    if (anchor is FlowReaderAnchor) ...[anchor.chapterId, anchor.blockId],
    view,
  ]);

  Future<void> _loadInk() async {
    try {
      final db = await DatabaseService().database;
      // Camera images in the drawing codec may exceed Android's CursorWindow.
      // Index large records first and read them only for visible anchors.
      final rows = await db.rawQuery(
        'SELECT location, CASE WHEN length(drawing) < 131072 THEN drawing END AS drawing '
        'FROM companion_ink WHERE source_id = ?',
        [_source.id],
      );
      if (!mounted) return;
      setState(() {
        for (final row in rows) {
          final key = row['location']! as String;
          final source = row['drawing'] as String?;
          if (source == null) {
            _largeDrawings.add(key);
          } else {
            final record = _CompanionInkRecord.fromJson(source);
            if (record != null) _savedInk[key] = record;
          }
        }
        _inkLoaded = true;
        _inkLoadFailed = false;
      });
    } on Exception {
      if (mounted) setState(() => _inkLoadFailed = true);
    }
  }

  void _startInk() {
    if (_inkLoadFailed) {
      unawaited(_loadInk());
      return;
    }
    _closeReaderPanel();
    if (_ebookSwitchPending || _returningToPdf) {
      ++_ebookSwitchRevision;
      if (_ebookSwitchPending) _pdfReflow.cancel();
    }
    ++_pdfGestureRevision;
    ++_pdfSwipeRevision;
    _pdfSwipeStart = null;
    _pdfPanStart = null;
    _pdfGesturePage = null;
    _pdfSnapPending = false;
    if (_pdf.isReady) {
      unawaited(_pdf.goTo(_pdf.value, duration: Duration.zero));
      unawaited(_pdf.textSelectionDelegate.clearTextSelection());
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _drawingTools.begin(
      color: _dark ? const Color(0xFFE5E4DF) : const Color(0xFF252525),
    );
    setState(() {
      if (_ebookSwitchPending) {
        _ebookSwitchPending = false;
        _requestedEbook = _convertedPage != null;
        _requestedPdfPage = _convertedPage?.number;
      }
      _returningToPdf = false;
      _inkEditing = true;
    });
    widget.onInkEditingChanged?.call(true);
    if (!widget.immersive) widget.onToggleImmersive?.call();
  }

  Future<void> _readLargeDrawing(String key) async {
    if (!_loadingDrawings.add(key)) return;
    try {
      final db = await DatabaseService().database;
      final data = await db.transaction((tx) async {
        final buffer = StringBuffer();
        const chunk = 131072;
        for (var start = 1; ; start += chunk) {
          final result = await tx.rawQuery(
            'SELECT substr(drawing, ?, ?) AS part FROM companion_ink WHERE source_id = ? AND location = ?',
            [start, chunk, _source.id, key],
          );
          if (result.isEmpty) return null;
          final part = result.single['part'] as String;
          buffer.write(part);
          if (part.length < chunk) return buffer.toString();
        }
      });
      if (!mounted) return;
      final record = data == null ? null : _CompanionInkRecord.fromJson(data);
      if (data != null && record == null) throw const FormatException('涂鸦数据损坏');
      setState(() {
        _largeDrawings.remove(key);
        if (record != null) _savedInk[key] = record;
      });
    } catch (_) {
      if (mounted) setState(() => _failedDrawings.add(key));
    } finally {
      _loadingDrawings.remove(key);
    }
  }

  Widget _buildDrawingControls() => AbsorbPointer(
    absorbing: _inkSaving,
    child: _drawingTools.controls(onFinish: _inkSaving ? null : _finishInk),
  );

  Future<void> _finishInk() async {
    if (_inkSaving || _drawingTools.busy) return;
    _drawingTools.commitText();
    setState(() => _inkSaving = true);
    try {
      final updates = <String, _CompanionInkRecord>{};
      for (final entry in _drawingLayers.entries.toList()) {
        final part = entry.value;
        if (!part.layer.changed) continue;
        updates[entry.key] = _CompanionInkRecord(
          part.layer.size,
          part.text,
          const [],
          await part.layer.encode(),
        );
      }
      if (updates.isNotEmpty) {
        final db = await DatabaseService().database;
        final batch = db.batch();
        for (final entry in updates.entries) {
          if (entry.value.isEmpty) {
            batch.delete(
              'companion_ink',
              where: 'source_id = ? AND location = ?',
              whereArgs: [_source.id, entry.key],
            );
          } else {
            batch.insert('companion_ink', {
              'source_id': _source.id,
              'location': entry.key,
              'drawing': entry.value.encode(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        await batch.commit(noResult: true);
      }
      if (!mounted) return;
      setState(() {
        for (final entry in updates.entries) {
          _drawingLayers[entry.key]!.layer.saved(entry.value.document!);
          if (entry.value.isEmpty) {
            _savedInk.remove(entry.key);
          } else {
            _savedInk[entry.key] = entry.value;
          }
        }
        _inkEditing = false;
        _inkSaving = false;
      });
      widget.onInkEditingChanged?.call(false);
      _reportSelection(false);
      if (_isPdfDocument) _schedulePdfPageWork();
      final afterSave = _afterInkSave;
      _afterInkSave = null;
      afterSave?.call();
    } catch (_) {
      if (!mounted) return;
      setState(() => _inkSaving = false);
      AppToast.show(context, '涂鸦保存失败，请重试');
    }
  }

  Widget _inkSurface(
    ReaderAnchor anchor,
    String view, {
    String? text,
    bool recoverOriginalText = false,
    bool editable = true,
    bool adoptsLegacyAnnotations = false,
  }) => LayoutBuilder(
    builder: (context, bounds) {
      final editing = _inkEditing && editable;
      if (!editing && _savedInk.isEmpty && _largeDrawings.isEmpty) {
        return const SizedBox.shrink();
      }
      final size = bounds.biggest;
      if (size.isEmpty || !size.isFinite) return const SizedBox.shrink();
      final location = _inkLocation(anchor, view);
      final textHash = text == null ? null : sha256.convert(utf8.encode(text));
      final layout = text == null
          ? 'fixed'
          : jsonEncode([
              size.width.round(),
              size.height.round(),
              _fontScale,
              _marginFraction,
              _lineScale,
              textHash.toString(),
            ]);
      final key = '$location/$layout';
      final record = _savedInk[key];
      final sourcePage = recoverOriginalText && anchor is FlowReaderAnchor
          ? jsonEncode([
              _source.sourceVersionId,
              _source.contentHash,
              anchor.chapterId,
            ])
          : null;
      bool matchesLocation(String other) {
        if (other.startsWith('$location/')) return true;
        if (sourcePage == null) return false;
        // Earlier layout versions used a different line index for some
        // paragraphs. Recover the original snapshot only on an exact text
        // match within the same PDF, original page and reading view.
        return other.startsWith(
              '${sourcePage.substring(0, sourcePage.length - 1)},',
            ) &&
            other.contains(',${jsonEncode(view)}]/') &&
            other.endsWith(',"$textHash"]');
      }

      final pendingKey = _largeDrawings.contains(key)
          ? key
          : record == null && !editing
          ? _largeDrawings.where(matchesLocation).lastOrNull
          : null;
      if (pendingKey != null) {
        if (_failedDrawings.contains(pendingKey)) {
          return Align(
            alignment: Alignment.topRight,
            child: IconButton(
              tooltip: '重新读取涂鸦',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                setState(() => _failedDrawings.remove(pendingKey));
                unawaited(_readLargeDrawing(pendingKey));
              },
            ),
          );
        }
        unawaited(_readLargeDrawing(pendingKey));
        return const SizedBox.shrink();
      }
      final archived = record == null && !editing
          ? _savedInk.entries
                .where(
                  (entry) =>
                      matchesLocation(entry.key) && entry.value.text != null,
                )
                .lastOrNull
                ?.value
          : null;
      if (!editing && record == null && archived == null) {
        return const SizedBox.shrink();
      }
      final initial = record ?? _CompanionInkRecord(size, text, const []);
      final layer = _drawingLayers
          .putIfAbsent(key, () => (layer: initial.createLayer(), text: text))
          .layer;
      final viewLayer = !editing && record?.document == null
          ? IgnorePointer(
              child: CustomPaint(painter: CompanionInkPainter(initial.strokes)),
            )
          : DrawingBoardPage.annotation(
              key: ValueKey(key),
              layer: layer,
              annotationTools: _inkEditing ? _drawingTools : null,
              legacyAnnotation: !editable,
              adoptsLegacyAnnotations: adoptsLegacyAnnotations,
            );
      final surface = editing
          ? AbsorbPointer(absorbing: _inkSaving, child: viewLayer)
          : viewLayer;
      if (archived == null) return surface;
      return Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          surface,
          Positioned(
            top: 0,
            right: -12,
            child: IconButton(
              tooltip: '回看涂鸦',
              icon: const Icon(Icons.edit_note, size: 18),
              onPressed: () => _showArchivedInk(archived),
            ),
          ),
        ],
      );
    },
  );

  void _showArchivedInk(_CompanionInkRecord record) {
    final layer = record.createLayer();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('绘制时的正文'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: AspectRatio(
              aspectRatio: record.size.aspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FittedBox(
                    alignment: Alignment.topLeft,
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: record.size.width,
                      height: record.size.height,
                      child: Text(
                        record.text ?? '',
                        style: const TextStyle(fontSize: 19, height: 1.5),
                      ),
                    ),
                  ),
                  if (record.document == null)
                    CustomPaint(painter: CompanionInkPainter(record.strokes))
                  else
                    DrawingBoardPage.annotation(layer: layer),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _translationPreference =>
      'reading-companion.translation.${_source.bookId}.${_source.id}';

  Future<void> _restoreTranslation() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(
      () => _translationEnabled =
          (prefs.getBool('reading-companion.translation-consent') ?? false) &&
          (prefs.getBool(_translationPreference) ?? false),
    );
    _scheduleTranslation();
  }

  Future<void> _toggleTranslation() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (!_translationEnabled &&
        !(prefs.getBool('reading-companion.translation-consent') ?? false)) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开启连续翻译'),
          content: const Text(
            '当前 PDF 页或电子书屏内正文会通过小栖服务发送给 DeepSeek。翻页后继续翻译，点击「原」可停止。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开启'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
      await prefs.setBool('reading-companion.translation-consent', true);
      if (!mounted) return;
    }
    final next = !_translationEnabled;
    setState(() => _translationEnabled = next);
    _scheduleTranslation();
    await prefs.setBool(_translationPreference, next);
  }

  void _onVisibleBlocks(List<XiaoqiDocumentBlock> blocks) {
    final available = blocks
        .where(
          (block) =>
              block.text.trim().isNotEmpty &&
              const {
                'heading',
                'paragraph',
                'list_item',
                'quote',
              }.contains(block.kind),
        )
        .toList();
    if (listEquals(
      _visibleBlocks.map((item) => (item.id, item.text)).toList(),
      available.map((item) => (item.id, item.text)).toList(),
    )) {
      return;
    }
    for (final block in available) {
      if (_alignedFlowTranslations[block.id]?.source != block.text) {
        _flowTranslations.remove(block.id);
        _alignedFlowTranslations.remove(block.id);
      }
    }
    _visibleBlocks = available;
    _scheduleTranslation();
  }

  void _scheduleTranslation() {
    _translationDelay?.cancel();
    final revision = ++_translationRevision;
    _applyDeferredTranslation = null;
    if (!_translationEnabled) {
      if (_translationPending || _translationError != null) {
        setState(() {
          _translationPending = false;
          _translationError = null;
        });
      }
      return;
    }
    _translationDelay = Timer(
      const Duration(milliseconds: 220),
      () => unawaited(_translateVisible(revision)),
    );
  }

  Future<void> _detectPdfPage(PdfDocument document, int number) async {
    if (document.permissions?.allowsCopying == false) return;
    try {
      final page = await document.pages[number - 1].waitForLoaded(
        timeout: const Duration(seconds: 6),
      );
      if (page == null ||
          !mounted ||
          !_isPdfDocument ||
          _pdfDocumentRef != document ||
          _pdfPage != number) {
        return;
      }
      final text = (await page.loadText())?.fullText.trim() ?? '';
      if (!mounted ||
          !_isPdfDocument ||
          _pdfDocumentRef != document ||
          _pdfPage != number) {
        return;
      }
      final available = text.isNotEmpty;
      final foreign =
          _foreignSource || ReadingCompanionTranslation.isForeign(text);
      if (_pdfTextAvailable != available || _foreignSource != foreign) {
        setState(() {
          _pdfTextAvailable = available;
          _foreignSource = foreign;
        });
      }
      if (_translationEnabled) _scheduleTranslation();
    } on Exception {
      // A failed or unloaded page can be retried by revisiting it.
    }
  }

  Future<void> _translateVisible(int revision) async {
    if (!mounted ||
        revision != _translationRevision ||
        !_foreignSource ||
        _translationInFlight) {
      return;
    }
    final number = _pdfPage;
    final blocks = _visibleBlocks
        .where((block) => !_flowTranslations.containsKey(block.id))
        .toList();
    final pdf = _isPdfDocument ? _pdfDocumentRef : null;
    if ((pdf == null && blocks.isEmpty) ||
        (pdf != null &&
            (!_pdfTextAvailable || _translatedPdfNumber == number))) {
      if (_translationPending) setState(() => _translationPending = false);
      return;
    }
    _translationInFlight = true;
    setState(() {
      _translationPending = true;
      _translationError = null;
    });
    try {
      final List<String> originals;
      PdfPage? pdfSource;
      var hasNativePdfSource = false;
      if (pdf == null) {
        originals = blocks.map((block) => block.text).toList();
      } else {
        final page = pdf.pages[number - 1];
        pdfSource = page;
        hasNativePdfSource = identical(page, companionNativePdfPage(page));
        final text = await page.loadStructuredText();
        originals = [text.fullText];
      }
      if (!mounted || revision != _translationRevision) return;
      final translated = await ReadingCompanionTranslation(_source)
          .translateAligned(
            originals,
            legacyParagraphs: pdfSource == null
                ? null
                : () async {
                    final raw = await pdfSource!.loadText();
                    return [
                      (raw?.fullText ?? '')
                          .split(RegExp(r'\n\s*\n'))
                          .map((part) => part.trim())
                          .where((part) => part.isNotEmpty)
                          .toList(),
                    ];
                  },
          );
      if (!mounted || revision != _translationRevision) return;
      void apply() => setState(() {
        _translationPending = false;
        if (pdf == null) {
          for (var index = 0; index < blocks.length; index++) {
            _flowTranslations[blocks[index].id] = translated[index].text;
            _alignedFlowTranslations[blocks[index].id] = translated[index];
          }
        } else {
          _translatedPdfPage = translated.single;
          _translatedPdfHasNativeSource = hasNativePdfSource;
          _translatedPdfNumber = number;
        }
      });
      if (_hasActiveSelection || _inkEditing) {
        _applyDeferredTranslation = apply;
      } else {
        apply();
      }
    } on Exception {
      if (!mounted || revision != _translationRevision) return;
      setState(() {
        _translationPending = false;
        _translationError = '翻译失败，点击重试';
      });
    } finally {
      _translationInFlight = false;
      if (mounted && _translationEnabled && revision != _translationRevision) {
        _scheduleTranslation();
      }
    }
  }

  void _reportSelection(bool active) {
    _selectionActive = active;
    if (!active) _prepareEbookNeighbors();
    if (active || _inkEditing || _applyDeferredTranslation == null) return;
    final apply = _applyDeferredTranslation;
    final revision = _translationRevision;
    _applyDeferredTranslation = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          revision == _translationRevision &&
          !_selectionActive &&
          !_inkEditing &&
          _translationEnabled) {
        apply?.call();
      }
    });
  }

  Future<void> _restoreDisplay() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _dark = prefs.getBool('reading-companion.dark') ?? false;
      _fontScale =
          prefs.getDouble('reading-companion.font') ?? _defaultFontScale;
      _marginFraction =
          prefs.getDouble('reading-companion.margin') ?? _defaultMarginFraction;
      _lineScale =
          prefs.getDouble('reading-companion.line') ?? _defaultLineScale;
      final legacyTurn = prefs.getString('reading-companion.turn');
      _pdfPageTurnMode =
          (prefs.getString('reading-companion.pdf-turn') ?? legacyTurn) ==
              'horizontal'
          ? ReaderPaginationMode.horizontal
          : ReaderPaginationMode.vertical;
      final ebookTurn =
          prefs.getString('reading-companion.ebook-turn') ?? legacyTurn;
      _ebookPaperTurn = ebookTurn == 'paper';
      _ebookPageTurnMode = _ebookPaperTurn || ebookTurn == 'horizontal'
          ? ReaderPaginationMode.horizontal
          : ReaderPaginationMode.vertical;
      final brightness = prefs.getDouble(_brightnessPreference);
      if (brightness != null) {
        _brightness = brightness;
        _hasBrightnessOverride = true;
      }
    });
    if (_hasBrightnessOverride) unawaited(_applyBrightness(_brightness));
    widget.onDarkChanged?.call(_dark);
  }

  Future<void> _applyBrightness(double? value) async {
    if (!_supportsReaderBrightness) return;
    try {
      await _brightnessChannel.invokeMethod<void>('setCompanionBrightness', {
        'brightness': value,
      });
      _brightnessErrorReported = false;
    } on PlatformException {
      if (mounted && !_brightnessErrorReported) {
        _brightnessErrorReported = true;
        AppToast.show(context, '阅读亮度暂时无法调整');
      }
    } on MissingPluginException {
      // Desktop and widget tests do not have the Android window channel.
    }
  }

  @override
  void dispose() {
    final reportInkEditing = widget.onInkEditingChanged;
    if (_inkEditing && reportInkEditing != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => reportInkEditing(false),
      );
    }
    _drawingTools.dispose();
    _returnPreview?.dispose();
    _nightShader?.dispose();
    _progressPreview.dispose();
    _pdfPageWork?.cancel();
    _noteOriginMarkTimeout?.cancel();
    for (final part in _drawingLayers.values) {
      part.layer.dispose();
    }
    final panelHistory = _panelHistory;
    _panelHistory = null;
    panelHistory?.remove();
    _translationDelay?.cancel();
    ++_translationRevision;
    ++_ebookSwitchRevision;
    if (_isCompanionPdf(_source)) _pdfReflow.cancel();
    if (_hasBrightnessOverride) unawaited(_applyBrightness(null));
    super.dispose();
  }

  Future<void> _prepareNightPaint() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'shaders/companion_pdf_night.frag',
      );
      if (!mounted) return;
      _nightShader = program.fragmentShader();
      _nightPaint
        ..colorFilter = null
        ..imageFilter = ui.ImageFilter.shader(_nightShader!);
      if (_dark && _pdf.isReady) _pdf.invalidate();
    } on Exception {
      // The matrix filter also works before the program is available.
    }
  }

  void _beginNightPage(Canvas canvas, Rect rect, PdfPage page) {
    canvas.save();
    canvas.clipRect(rect, doAntiAlias: false);
    canvas.saveLayer(rect, _nightPaint);
  }

  void _endNightPage(Canvas canvas, Rect rect, PdfPage page) {
    canvas.restore();
    canvas.restore();
  }

  Future<({XiaoqiDocument? document, ReaderAnchor? anchor})>
  _loadDocument() async {
    final source = _source;
    final anchor = _preferences.loadAnchor(
      bookId: source.bookId,
      sourceId: source.id,
    );
    if (normalizeBookSourceFormat(source.format) == 'pdf') {
      final saved = await anchor;
      if (saved is PdfReaderAnchor && saved.sourceId == _sourceKey) {
        _pdfReadingAnchor = saved;
      }
      return (document: null, anchor: saved);
    }
    final revision = await widget.library.loadBookSourceRevision(source);
    final parsed = revision == null
        ? await SourceDocumentLoader.parseBookSourceForReader(source)
        : null;
    final document = revision ?? parsed!.document;
    _epubLayoutCache = parsed?.epubLayoutCache;
    if (document.chapters.isEmpty) {
      throw const FormatException('电子资料没有可读章节');
    }
    _foreignSource = ReadingCompanionTranslation.isForeign(
      document.chapters.first.plainText,
      language: document.language,
    );
    final selection = widget.initialAnnotationSelection;
    final origin = selection == null
        ? null
        : _flowAnnotationOrigin(document, selection);
    if (selection != null && origin == null) _showMissingAnnotationOrigin();
    final saved = origin ?? await anchor;
    if (saved is FlowReaderAnchor) _flowPosition = saved;
    return (document: document, anchor: saved);
  }

  bool _validAnnotationOrigin(CompanionAnnotationSelection selection) =>
      selection.bookId == _source.bookId && _sourceMatches(selection);

  FlowReaderAnchor? _flowAnnotationOrigin(
    XiaoqiDocument document,
    CompanionAnnotationSelection selection,
  ) {
    if (!_validAnnotationOrigin(selection)) return null;
    final canonical = selection.canonicalRange;
    final anchor = selection.anchor;
    final String chapter;
    final String? blockId;
    final int? start;
    final int? end;
    if (canonical is CompanionFlowSourceRange) {
      chapter = canonical.chapter;
      blockId = canonical.block;
      start = canonical.start;
      end = canonical.end;
    } else if (canonical == null &&
        anchor is FlowReaderAnchor &&
        selection.translationVersion == null) {
      chapter = anchor.chapterId;
      blockId = anchor.blockId;
      start = selection.startOffset;
      end = selection.endOffset;
    } else {
      return null;
    }
    final block = document.chapters
        .where((item) => item.id == chapter)
        .firstOrNull
        ?.blocks
        .where((item) => item.id == blockId)
        .firstOrNull;
    if (block == null ||
        start == null ||
        end == null ||
        start < 0 ||
        end > block.text.length ||
        end <= start) {
      return null;
    }
    final agrees = canonical is CompanionFlowSourceRange
        ? companionTextHash(block.text) == canonical.textHash
        : block.text.substring(start, end) == selection.quote;
    return agrees
        ? FlowReaderAnchor(
            sourceId: _sourceKey,
            chapterId: chapter,
            blockId: blockId,
            characterOffset: start,
          )
        : null;
  }

  void _showMissingAnnotationOrigin() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppToast.show(context, '暂时无法定位引文，可在注释中查看摘录');
    });
  }

  Future<bool> _jumpPdfAnnotationOrigin(
    PdfDocument document,
    CompanionAnnotationSelection selection,
  ) async {
    if (!_validAnnotationOrigin(selection) ||
        !_pdf.isReady ||
        document.permissions?.allowsCopying == false) {
      return false;
    }
    try {
      final origin = await _verifiedPdfOrigin(document, selection);
      if (!mounted ||
          !_pdf.isReady ||
          !identical(_pdfDocumentRef, document) ||
          origin == null) {
        return false;
      }
      final location = _pdf.calcRectForRectInsidePage(
        pageNumber: origin.page,
        rect: origin.rect,
      );
      await _goToPdfReaderPage(
        origin.page,
        duration: Duration.zero,
        recordProgress: false,
      );
      if (!mounted || !_pdf.isReady || !identical(_pdfDocumentRef, document)) {
        return false;
      }
      if (_pdfPageTurnMode == ReaderPaginationMode.vertical) {
        final center = Offset(
          _pdf.layout.pageLayouts[origin.page - 1].center.dx,
          location.center.dy,
        );
        await _pdf.goTo(
          _pdf.calcMatrixFor(center, zoom: 1, viewSize: _pdf.viewSize),
          duration: Duration.zero,
        );
      }
      if (!mounted || !identical(_pdfDocumentRef, document)) return false;
      setState(
        () => _noteOriginPdfMark = (page: origin.page, bounds: origin.bounds),
      );
      _noteOriginMarkTimeout?.cancel();
      _noteOriginMarkTimeout = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _noteOriginPdfMark = null);
      });
      return true;
    } on Exception {
      return false;
    }
  }

  Future<({int page, PdfRect rect, List<PdfRect> bounds})?> _verifiedPdfOrigin(
    PdfDocument document,
    CompanionAnnotationSelection selection,
  ) async {
    final range = selection.canonicalRange;
    if (range is CompanionPdfSourceRange) {
      final span = range.pages.firstOrNull;
      if (span == null) return null;
      final text = await _annotationPageText(
        document,
        span.page,
        span.textHash,
        native: true,
      );
      if (text == null ||
          span.start < 0 ||
          span.start >= span.end ||
          span.end > math.min(text.charRects.length, text.fullText.length)) {
        return null;
      }
      return _pdfOriginRange(text, span.start, span.end);
    }
    final legacy = legacyCompanionPdfRange(selection);
    if (legacy == null || legacy.lastPage > document.pages.length) return null;
    ({int page, PdfRect rect, List<PdfRect> bounds})? origin;
    final quote = <String>[];
    for (var number = legacy.firstPage; number <= legacy.lastPage; number++) {
      final hash = selection.pdfPageTextHashes[number];
      if (hash == null) return null;
      final text = await _annotationPageText(document, number, hash);
      if (text == null) return null;
      final first = number == legacy.firstPage;
      final last = number == legacy.lastPage;
      final start = first ? legacy.startOffset : 0;
      final end = last ? legacy.endOffset : text.fullText.length;
      if (start > end ||
          ((first || last) && start == end) ||
          end > text.fullText.length ||
          (first && start >= text.charRects.length) ||
          (last && end > text.charRects.length)) {
        return null;
      }
      if (first) {
        origin = _pdfOriginRange(
          text,
          start,
          math.min(end, text.charRects.length),
        );
      }
      quote.add(text.fullText.substring(start, end));
    }
    return quote.join('\n').trim() == selection.quote.trim() ? origin : null;
  }

  ({int page, PdfRect rect, List<PdfRect> bounds}) _pdfOriginRange(
    PdfPageText text,
    int start,
    int end,
  ) {
    final range = PdfPageTextRange(pageText: text, start: start, end: end);
    final bounds = [
      for (final fragment in range.enumerateFragmentBoundingRects())
        if (fragment.bounds.isNotEmpty) fragment.bounds,
    ];
    final rect = text.charRects[start];
    return (
      page: text.pageNumber,
      rect: rect,
      bounds: bounds.isEmpty ? [rect] : bounds,
    );
  }

  void _paintNoteOriginPdfMark(Canvas canvas, Rect pageRect, PdfPage page) {
    final mark = _noteOriginPdfMark;
    if (mark == null || mark.page != page.pageNumber) return;
    final paint = Paint()..color = const Color(0x559AC56B);
    for (final bound in mark.bounds) {
      final rect = bound.toRectInDocument(page: page, pageRect: pageRect);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(1), const Radius.circular(2)),
        paint,
      );
    }
  }

  Future<PdfPageText?> _annotationPageText(
    PdfDocument document,
    int number,
    String hash, {
    bool native = false,
  }) async {
    if (number < 1 || number > document.pages.length) return null;
    final loaded = await document.pages[number - 1].waitForLoaded(
      timeout: const Duration(seconds: 10),
    );
    if (loaded == null || !mounted || !identical(_pdfDocumentRef, document)) {
      return null;
    }
    final page = native ? companionNativePdfPage(loaded) : loaded;
    final text = await page.loadStructuredText();
    if (companionTextHash(text.fullText) == hash) return text;
    if (native ||
        document is! CompanionSelectionDocument ||
        !identical(page, companionNativePdfPage(page))) {
      return null;
    }
    final cached = await _pdfReflow.cachedTextLayer(number);
    if (cached == null || !mounted || !identical(_pdfDocumentRef, document)) {
      return null;
    }
    document.install(cached);
    final recognized = document.pages[number - 1];
    if (identical(recognized, page)) return null;
    final recognizedText = await recognized.loadStructuredText();
    return companionTextHash(recognizedText.fullText) == hash
        ? recognizedText
        : null;
  }

  void _showOutline(
    List<String> titles,
    int current,
    ValueChanged<int> onSelected, {
    List<int> levels = const [],
    Set<int> groupLabels = const {},
    List<int?> pages = const [],
    int? readingPage,
  }) {
    _openReaderPanel(
      _ReaderPanel.outline,
      outline: (context) => _outlineList(
        titles: titles,
        current: current,
        onSelected: onSelected,
        levels: levels,
        groupLabels: groupLabels,
        pages: pages,
        readingPage: readingPage,
      ),
    );
  }

  Widget _outlineList({
    Key? key,
    required List<String> titles,
    required int current,
    required ValueChanged<int> onSelected,
    required List<int> levels,
    required Set<int> groupLabels,
    required List<int?> pages,
    required int? readingPage,
  }) => _ReaderOutlineList(
    key: key,
    titles: titles,
    current: current,
    onSelected: (index) {
      _closeReaderPanel();
      onSelected(index);
    },
    levels: levels,
    groupLabels: groupLabels,
    pages: pages,
    readingPage: readingPage,
    wide: _readerWide,
    ink: _ink,
    rule: _readerRule,
    selectedColor: _readerSelected,
  );

  void _chapter(
    XiaoqiDocumentChapter chapter, {
    String? blockId,
    int characterOffset = 0,
  }) {
    _dismissFlowSelection();
    FocusManager.instance.primaryFocus?.unfocus();
    final next = FlowReaderAnchor(
      sourceId: _sourceKey,
      chapterId: chapter.id,
      blockId: blockId,
      characterOffset: characterOffset,
    );
    setState(() {
      _chapterNavigation = next;
      _flowPosition = next;
      _navigationRevision++;
    });
    if (_convertedPage == null) {
      unawaited(_preferences.saveAnchor(bookId: _source.bookId, anchor: next));
    }
  }

  void _showFlowOutline(
    XiaoqiDocument document,
    int chapterIndex,
    String? blockId,
  ) {
    final chapters = document.chapters;
    final chaptersById = {for (final chapter in chapters) chapter.id: chapter};
    final entries = document.outline
        .where(
          (entry) =>
              entry.chapterId == null ||
              chaptersById.containsKey(entry.chapterId),
        )
        .toList(growable: false);
    if (!entries.any((entry) => entry.chapterId != null)) {
      _showOutline(
        chapters.map((chapter) => chapter.title).toList(growable: false),
        chapterIndex,
        (index) => _chapter(chapters[index]),
      );
      return;
    }

    final currentChapterId = chapters[chapterIndex].id;
    final currentBlocks = chapters[chapterIndex].blocks;
    final currentBlock = currentBlocks.indexWhere(
      (block) => block.id == blockId,
    );
    final positions = {
      for (var index = 0; index < currentBlocks.length; index++)
        currentBlocks[index].id: index,
    };
    final currentEntry = entries.lastIndexWhere((entry) {
      if (entry.chapterId != currentChapterId) return false;
      if (entry.blockId == null) return true;
      final index = positions[entry.blockId];
      return index != null && index <= currentBlock;
    });
    _showOutline(
      entries.map((entry) => entry.title).toList(growable: false),
      currentEntry >= 0
          ? currentEntry
          : entries.indexWhere((entry) => entry.chapterId == currentChapterId),
      (index) {
        final entry = entries[index];
        final chapter = chaptersById[entry.chapterId];
        if (chapter != null) _chapter(chapter, blockId: entry.blockId);
      },
      levels: entries.map((entry) => entry.level).toList(growable: false),
      groupLabels: {
        for (var index = 0; index < entries.length; index++)
          if (entries[index].chapterId == null) index,
      },
    );
  }

  Future<void> _followLink(XiaoqiDocument document, String target) async {
    if (_inkEditing || _selectionActive) return;
    final uri = Uri.tryParse(target);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      } on Exception {
        /* report below */
      }
      if (mounted) AppToast.show(context, '无法打开网页');
      return;
    }
    if (uri?.scheme == 'pdf-page' && _preparedBook != null) {
      final page = int.tryParse(uri!.path);
      if (page != null) await _openConvertedPage(page);
      return;
    }
    final destination = document.resolveReadingLink(target);
    final chapter = document.chapters
        .where((c) => c.id == destination?.chapterId)
        .firstOrNull;
    if (chapter != null) _chapter(chapter, blockId: destination!.blockId);
  }

  Widget _flow(
    XiaoqiDocument document,
    ReaderAnchor? anchor, {
    int? originalPage,
  }) {
    final current =
        _chapterNavigation ?? (anchor is FlowReaderAnchor ? anchor : null);
    final chapters = document.chapters;
    final chapterIndex = math.max(
      0,
      chapters.indexWhere(
        (chapter) => chapter.id == (_flowPosition ?? current)?.chapterId,
      ),
    );
    final chapter = chapters[chapterIndex];
    // A long chapter is laid out as selectable blocks on the UI isolate.
    // Normal chapters are ready to slide immediately, and a chapter already
    // on screen stays rendered if the user reverses the transition.
    if (!_renderedChapter &&
        (chapter.blocks.length >= 96 || chapter.plainText.length >= 24000) &&
        context
                .dependOnInheritedWidgetOfExactType<
                  ReadingCompanionLayoutGate
                >()
                ?.entering ==
            true) {
      return const _ReadingPlaceholder();
    }
    _renderedChapter = true;
    final assets = {for (final asset in document.assets) asset.id: asset};
    final chaptersById = {for (final entry in chapters) entry.id: entry};
    return _footerWithBody(
      showChrome: originalPage == null || _convertedPage != null,
      body: LayoutBuilder(
        builder: (context, dimensions) {
          TextStyle textStyle(TextStyle style) => style.copyWith(
            fontFamily: style.fontFamily == 'monospace'
                ? 'monospace'
                : 'NotoSerifCJKSC',
            color: _ink,
            height: (style.height ?? 1.5) * _lineScale,
            fontSize:
                _fontScale * (style.fontSize ?? 17) +
                (dimensions.maxWidth >= 600 ? 3 : 0),
          );
          return ReflowDocumentPager(
            verticalPadding: EdgeInsets.fromLTRB(
              dimensions.maxWidth * _marginFraction,
              readingCompanionToolbarHeight(context) + (_readerWide ? 42 : 24),
              dimensions.maxWidth * _marginFraction,
              _readerNavHeight + 8,
            ),
            navigationRevision: _navigationRevision,
            sourceId: _sourceKey,
            document: document,
            initialChapterId: chapter.id,
            initialAnchor: current,
            epubLayoutCache: _epubLayoutCache,
            pdfLayoutCache: originalPage == null
                ? null
                : _preparedBook?.layoutCache,
            onLayoutReady: originalPage == null
                ? (ready) {
                    if (mounted && _ebookLayoutReady != ready) {
                      setState(() => _ebookLayoutReady = ready);
                    }
                  }
                : (ready) => _ebookLayoutChanged(document, current, ready),
            remapAnchor: originalPage == null
                ? null
                : (before, after, anchor) {
                    final source = CompanionReflowPage.sourcePosition(
                      before,
                      anchor.blockId,
                      anchor.characterOffset,
                    );
                    final relocated = CompanionReflowPage.displayPosition(
                      after,
                      source?.blockId ?? anchor.blockId,
                      source?.offset ?? anchor.characterOffset,
                    );
                    return relocated == null
                        ? anchor
                        : FlowReaderAnchor(
                            sourceId: anchor.sourceId,
                            chapterId: anchor.chapterId,
                            blockId: relocated.blockId,
                            characterOffset: relocated.offset,
                          );
                  },
            mode: _ebookPageTurnMode,
            paperTurn:
                _ebookPaperTurn && (originalPage == null || !_isPdfDocument),
            previewTypography: _adjustingTypography,
            userNavigationEnabled: !_inkEditing,
            inkCanvasBuilder: (_, position) {
              final origin = originalPage == null
                  ? null
                  : CompanionReflowPage.sourcePosition(
                      document,
                      position.blockId,
                      position.characterOffset,
                    );
              final blockId = origin?.blockId ?? position.blockId;
              final offset = origin?.offset ?? position.characterOffset;
              final sourcePage = originalPage == null
                  ? null
                  : CompanionReflowPage.pageForBlock(blockId) ?? originalPage;
              final firstBlock = chaptersById[position.chapterId]?.blocks
                  .where((block) => block.id == position.blockId)
                  .firstOrNull;
              final translation = _translationEnabled && firstBlock != null
                  ? _flowTranslations[firstBlock.id]
                  : null;
              return _inkSurface(
                FlowReaderAnchor(
                  sourceId: position.sourceId,
                  chapterId: sourcePage == null
                      ? position.chapterId
                      : 'pdf-page-$sourcePage',
                  blockId: blockId,
                ),
                'ebook-canvas-${_ebookPageTurnMode.name}-$offset'
                '${_translationEnabled ? '-translated' : ''}',
                text: translation ?? firstBlock?.text ?? '',
                adoptsLegacyAnnotations: true,
              );
            },
            textStyleBuilder: textStyle,
            translations: _translationEnabled ? _flowTranslations : null,
            onUserNavigationStart: originalPage == null || !_isPdfDocument
                ? _hideReaderChrome
                : null,
            onScrollActivityChanged: originalPage == null
                ? null
                : (active) {
                    _ebookScrollActive = active;
                    if (!active) {
                      scheduleMicrotask(() {
                        if (mounted) _prepareEbookNeighbors();
                      });
                    }
                  },
            onPreviousDocument: _inkEditing || _ebookSwitchPending
                ? null
                : originalPage != null
                ? _firstConvertedPage > 1
                      ? () => unawaited(
                          _continueConvertedReading(
                            _firstConvertedPage - 1,
                            forward: false,
                          ),
                        )
                      : null
                : _ebookPageTurnMode == ReaderPaginationMode.vertical &&
                      chapterIndex > 0
                ? () => _chapter(chapters[chapterIndex - 1])
                : null,
            onNextDocument: _inkEditing || _ebookSwitchPending
                ? null
                : originalPage != null
                ? _lastConvertedPage < _pdfPageCount
                      ? () => unawaited(
                          _continueConvertedReading(
                            _lastConvertedPage + 1,
                            forward: true,
                          ),
                        )
                      : null
                : _ebookPageTurnMode == ReaderPaginationMode.vertical &&
                      chapterIndex + 1 < chapters.length
                ? () => _chapter(chapters[chapterIndex + 1])
                : null,
            verticalBackground: _dark ? _paperDark : Colors.white,
            onVisibleBlocksChanged: (blocks) {
              if (originalPage != null) _ebookScreen = blocks;
              if (originalPage == null || _convertedPage != null) {
                _onVisibleBlocks(blocks);
              }
            },
            chapterTitleAlign: TextAlign.center,
            verticalChapterTitleStyle: TextStyle(
              fontFamily: 'NotoSerifCJKSC',
              fontSize: dimensions.maxWidth >= 600 ? 36 : 26,
              height: 1.4,
              fontWeight: FontWeight.w700,
              color: _dark ? const Color(0xFF9DC5FF) : const Color(0xFF205493),
            ),
            onAnchorChanged: (value) {
              if (originalPage != null) {
                if (!identical(document, _convertedDocument)) return;
                _flowPosition = value;
                return;
              }
              if (value.chapterId == _flowPosition?.chapterId) {
                _flowPosition = value;
              } else {
                setState(() => _flowPosition = value);
              }
              if (widget.initialAnnotationSelection == null) {
                unawaited(
                  _preferences.saveAnchor(
                    bookId: _source.bookId,
                    anchor: value,
                  ),
                );
              }
            },
            onUserAnchorChanged: originalPage == null
                ? widget.initialAnnotationSelection == null
                      ? null
                      : (value) => unawaited(
                          _preferences.saveAnchor(
                            bookId: _source.bookId,
                            anchor: value,
                          ),
                        )
                : (value) {
                    if (_convertedPage == null ||
                        !identical(document, _convertedDocument)) {
                      return;
                    }
                    _rememberConvertedPosition(document, value);
                    final page = _convertedPages[_pdfReadingAnchor?.pageNumber];
                    if (page != null && page.number != _convertedPage?.number) {
                      setState(() => _convertedPage = page);
                    }
                    _prepareEbookNeighbors();
                  },
            blockBuilder: (context, slice, setSelection) {
              final sliceChapter = chaptersById[slice.chapterId] ?? chapter;
              final origin = originalPage == null
                  ? null
                  : CompanionReflowPage.sourcePosition(
                      document,
                      slice.block.id,
                      slice.startOffset,
                    );
              final sourcePage = originalPage == null
                  ? null
                  : CompanionReflowPage.pageForBlock(
                          origin?.blockId ?? slice.block.id,
                        ) ??
                        int.tryParse(slice.block.originalPageLabel ?? '') ??
                        originalPage;
              final translation = _translationEnabled
                  ? _flowTranslations[slice.block.id]
                  : null;
              final displayText =
                  _ebookPageTurnMode == ReaderPaginationMode.horizontal
                  ? slice.text
                  : translation ?? slice.text;
              final annotationRanges = _flowAnnotationRanges(
                chapter: sliceChapter,
                slice: slice,
                visibleText: displayText,
              );
              final pdfPage = slice.block.kind == 'image' && sourcePage != null
                  ? _convertedPages[sourcePage]
                  : null;
              final pdfPicture = pdfPage?.pictures
                  .where((picture) => picture.asset.id == slice.block.assetId)
                  .firstOrNull;
              final asset = assets[slice.block.assetId];
              final previewEpub =
                  document.format == 'epub' &&
                  !_inkEditing &&
                  !_selectionActive &&
                  (slice.block.kind == 'table' ||
                      (slice.block.kind == 'image' &&
                          asset != null &&
                          asset.bytes.isNotEmpty));
              final block = pdfPicture != null && pdfPage != null
                  ? CompanionPdfObjectView(
                      picture: pdfPicture,
                      links: pdfPage.links,
                      onLinkTap: _inkEditing || _selectionActive
                          ? null
                          : (target) =>
                                unawaited(_followLink(document, target)),
                      pageObjects: pdfPage.keepOriginal
                          ? pdfPage.selectablePictures
                          : const [],
                      isOriginalPage: pdfPage.keepOriginal,
                      onPreview: _inkEditing || _selectionActive
                          ? null
                          : (picture) => unawaited(
                              _openPdfObjectPreview(pdfPage.number, picture),
                            ),
                    )
                  : XiaoqiDocumentBlockView(
                      block: slice.block,
                      darkReader: _dark,
                      onObjectPreview: previewEpub
                          ? () {
                              if (_inkEditing || _hasActiveSelection) return;
                              unawaited(
                                showEpubCompanionObjectPreview(
                                  context: this.context,
                                  block: slice.block,
                                  asset: asset,
                                ),
                              );
                            }
                          : null,
                      headingColor: _dark
                          ? const Color(0xFF9DC5FF)
                          : const Color(0xFF205493),
                      onLinkTap: _inkEditing || translation != null
                          ? null
                          : (target) =>
                                unawaited(_followLink(document, target)),
                      selectionControls: _companionTextSelectionControls,
                      asset: asset,
                      textOverride: displayText,
                      textOffset:
                          (translation == null ||
                                  translation == slice.block.text) &&
                              displayText == slice.text
                          ? slice.startOffset
                          : null,
                      tableRowsOverride: slice.tableRows,
                      continuation: slice.continuation,
                      onSelectionChanged: (selected) {
                        setSelection(selected);
                        _reportSelection(selected);
                      },
                      onTextTap: widget.onToggleImmersive == null
                          ? null
                          : _toggleReaderChrome,
                      contextMenuBuilder: (context, editable) => _flowSelection(
                        editable,
                        sliceChapter,
                        slice,
                        sourcePage,
                      ),
                      textStyleBuilder: textStyle,
                      annotationRanges: annotationRanges,
                      onOpenAnnotations: _inkEditing
                          ? null
                          : (ids) => unawaited(
                              _openMatchingAnnotations([
                                for (final entry in widget.annotations)
                                  if (ids.contains(entry.id)) entry,
                              ]),
                            ),
                    );
              final location = FlowReaderAnchor(
                sourceId: _sourceKey,
                chapterId: sourcePage == null
                    ? sliceChapter.id
                    : 'pdf-page-$sourcePage',
                blockId: origin?.blockId ?? slice.block.id,
                characterOffset: origin?.offset ?? slice.startOffset,
              );
              return Stack(
                children: [
                  block,
                  Positioned.fill(
                    child: _inkSurface(
                      location,
                      translation == null ? 'original' : 'ebook-translation',
                      text: displayText,
                      editable: false,
                      recoverOriginalText:
                          sourcePage != null &&
                          (_savedInk.isNotEmpty || _largeDrawings.isNotEmpty) &&
                          translation == null &&
                          displayText.isNotEmpty &&
                          slice.block.text.indexOf(displayText) ==
                              slice.block.text.lastIndexOf(displayText) &&
                          document.chapters.first.blocks
                                  .where(
                                    (block) =>
                                        block.originalPageLabel ==
                                            slice.block.originalPageLabel &&
                                        block.text.contains(displayText),
                                  )
                                  .take(2)
                                  .length ==
                              1,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
      page: originalPage ?? chapterIndex + 1,
      pageCount: originalPage == null ? chapters.length : _pdfPageCount,
      usesOriginalPages: originalPage != null,
      chapterTitle: chapter.title,
      onPageSelected: originalPage == null
          ? (page) => _chapter(chapters[page - 1])
          : (page) => unawaited(_openConvertedPage(page)),
      onRestoreFlow: originalPage != null
          ? null
          : (position) {
              final target = chapters
                  .where((chapter) => chapter.id == position.chapterId)
                  .firstOrNull;
              if (target != null) {
                _chapter(
                  target,
                  blockId: position.blockId,
                  characterOffset: position.characterOffset,
                );
              }
            },
      onOutline: originalPage != null
          ? _showPdfOutline
          : () => _showFlowOutline(
              document,
              chapterIndex,
              _flowPosition?.chapterId == chapter.id
                  ? _flowPosition?.blockId
                  : current?.blockId,
            ),
    );
  }

  Widget _displayPanel() {
    final pdf = _isPdfDocument;
    Widget setting(String label, Widget control, {double wideHeight = 54}) =>
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: _readerWide ? wideHeight : 48),
          child: Row(
            children: [
              Expanded(flex: _readerWide ? 28 : 22, child: Text(label)),
              Expanded(flex: _readerWide ? 72 : 78, child: control),
            ],
          ),
        );
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      double defaultValue,
      Widget start,
      Widget end,
      ValueChanged<double> onChanged, {
      VoidCallback? onReset,
      double wideHeight = 54,
    }) => setting(
      label,
      Row(
        children: [
          ExcludeSemantics(child: start),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: _readerWide ? 20 : 12),
              child: _readerSlider(
                value: value,
                min: min,
                max: max,
                onChanged: onChanged,
                description: label,
                defaultValue: defaultValue,
                onReset: onReset ?? () => onChanged(defaultValue),
                onDragChanged: label == '亮度'
                    ? null
                    : (active) {
                        if (_adjustingTypography != active) {
                          setState(() => _adjustingTypography = active);
                        }
                      },
              ),
            ),
          ),
          ExcludeSemantics(child: end),
        ],
      ),
      wideHeight: wideHeight,
    );
    Widget themeChoice(bool dark) {
      final selected = _dark == dark;
      final foreground = selected ? _readerChrome : _ink;
      return Semantics(
        selected: selected,
        child: TextButton(
          onPressed: () {
            if (selected) return;
            setState(() => _dark = dark);
            widget.onDarkChanged?.call(_dark);
            if (_pdf.isReady) _pdf.invalidate();
          },
          style: readerChoiceStyle(
            selected: selected,
            minimumSize: Size(_readerWide ? 110 : 67, 40),
            padding: EdgeInsets.symmetric(horizontal: _readerWide ? 15 : 8),
            textStyle: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontSize: _readerWide ? 18 : 14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _readerIcon(
                dark
                    ? 'assets/icons/chat_note_editor/moon.svg'
                    : 'assets/icons/chat_note_editor/sun.svg',
                _readerWide ? 19 : 15,
                color: foreground,
              ),
              const SizedBox(width: 6),
              Text(dark ? '暗夜' : '白天'),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_supportsReaderBrightness) ...[
            slider(
              '亮度',
              _brightness,
              .05,
              1,
              _defaultBrightness,
              _readerIcon('assets/icons/chat_note_editor/sun.svg', 20),
              _readerIcon('assets/icons/chat_note_editor/sun.svg', 26),
              (value) {
                setState(() {
                  _brightness = value;
                  _hasBrightnessOverride = true;
                });
                unawaited(_applyBrightness(value));
              },
              onReset: () {
                setState(() {
                  _brightness = _defaultBrightness;
                  _hasBrightnessOverride = false;
                });
                unawaited(_applyBrightness(null));
                unawaited(_clearSavedBrightness());
              },
              wideHeight: pdf ? 54 : 65,
            ),
            Divider(height: 1, thickness: 1, color: _readerRule),
          ],
          setting(
            '主题',
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: _readerWide ? 25 : 8,
                children: [themeChoice(false), themeChoice(true)],
              ),
            ),
            wideHeight: pdf ? 54 : 64,
          ),
          if (!pdf) ...[
            Divider(height: 1, thickness: 1, color: _readerRule),
            slider(
              '字号',
              _fontScale,
              .8,
              1.5,
              _defaultFontScale,
              const Text('A', style: TextStyle(fontSize: 17)),
              const Text('A', style: TextStyle(fontSize: 23)),
              (value) => setState(() => _fontScale = value),
            ),
            Divider(height: 1, thickness: 1, color: _readerRule),
            slider(
              '边距',
              _marginFraction,
              .025,
              .12,
              _defaultMarginFraction,
              const Text('小'),
              const Text('大'),
              (value) => setState(() => _marginFraction = value),
            ),
            Divider(height: 1, thickness: 1, color: _readerRule),
            slider(
              '行距',
              _lineScale,
              .85,
              1.35,
              _defaultLineScale,
              const Text('紧'),
              const Text('松'),
              (value) => setState(() => _lineScale = value),
              wideHeight: 65,
            ),
          ],
          Divider(height: 1, thickness: 1, color: _readerRule),
          setting(
            '翻页',
            Wrap(
              spacing: _readerWide ? 15 : 8,
              runSpacing: 6,
              children: [
                _pageTurnChoice(ReaderPaginationMode.vertical, '上下滑动'),
                _pageTurnChoice(
                  ReaderPaginationMode.horizontal,
                  _isPdfDocument ? '左右翻页' : '左右平移',
                ),
                if (!_isPdfDocument)
                  _pageTurnChoice(
                    ReaderPaginationMode.horizontal,
                    '仿真翻页',
                    paper: true,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  ButtonStyle readerChoiceStyle({
    required bool selected,
    required Size minimumSize,
    required EdgeInsetsGeometry padding,
    TextStyle? textStyle,
  }) => OutlinedButton.styleFrom(
    foregroundColor: selected ? _readerChrome : _ink,
    backgroundColor: selected ? _ink : Colors.transparent,
    side: BorderSide(color: _readerRule),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    minimumSize: minimumSize,
    padding: padding,
    textStyle: textStyle,
  );

  Widget _pageTurnChoice(
    ReaderPaginationMode mode,
    String label, {
    bool paper = false,
  }) {
    final pdf = _isPdfDocument;
    final selected =
        (pdf ? _pdfPageTurnMode : _ebookPageTurnMode) == mode &&
        paper == (!pdf && _ebookPaperTurn);
    return Semantics(
      selected: selected,
      child: OutlinedButton(
        style: readerChoiceStyle(
          selected: selected,
          minimumSize: const Size(64, 40),
          padding: EdgeInsets.symmetric(horizontal: _readerWide ? 14 : 10),
        ),
        onPressed: () => _changeReaderPageTurnMode(mode, paper: paper),
        child: Text(label),
      ),
    );
  }

  Future<void> _persistDisplaySettings() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setBool('reading-companion.dark', _dark),
      prefs.setDouble('reading-companion.font', _fontScale),
      prefs.setDouble('reading-companion.margin', _marginFraction),
      prefs.setDouble('reading-companion.line', _lineScale),
      prefs.setString('reading-companion.pdf-turn', _pdfPageTurnMode.name),
      prefs.setString(
        'reading-companion.ebook-turn',
        _ebookPaperTurn ? 'paper' : _ebookPageTurnMode.name,
      ),
      if (_hasBrightnessOverride)
        prefs.setDouble(_brightnessPreference, _brightness),
    ]);
  }

  Future<void> _clearSavedBrightness() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_hasBrightnessOverride) await prefs.remove(_brightnessPreference);
  }

  Widget _flowSelection(
    EditableTextState editable,
    XiaoqiDocumentChapter chapter,
    ReaderBlockSlice slice,
    int? originalPage,
  ) {
    final value = editable.textEditingValue;
    final range = value.selection;
    if (!range.isValid || range.isCollapsed) return const SizedBox.shrink();
    final anchor = editable.contextMenuAnchors;
    final text = range.textInside(value.text);
    if (text.trim().isEmpty) return const SizedBox.shrink();
    final translation = _visibleAlignedTranslation(slice, value.text);
    final translated = translation != null;
    final offset = value.text == slice.text ? slice.startOffset : 0;
    final annotationOffset =
        translated && _ebookPageTurnMode != ReaderPaginationMode.horizontal
        ? 0
        : slice.startOffset;
    final annotationStart = annotationOffset + range.start;
    final annotationEnd = annotationOffset + range.end;
    final originalRange = translation == null
        ? (slice.startOffset >= 0 &&
                  slice.startOffset + value.text.length <=
                      slice.block.text.length &&
                  slice.block.text.substring(
                        slice.startOffset,
                        slice.startOffset + value.text.length,
                      ) ==
                      value.text
              ? (start: annotationStart, end: annotationEnd)
              : null)
        : translation.sourceRange(annotationStart, annotationEnd);
    final document = _convertedDocument;
    final source = originalPage == null || document == null || translated
        ? null
        : CompanionReflowPage.sourcePosition(
            document,
            slice.block.id,
            offset + range.start,
          );
    final page =
        CompanionReflowPage.pageForBlock(source?.blockId) ?? originalPage;
    final location = page == null ? chapter.title : '第 $page 页';
    final passage = _passage(
      text,
      translated ? '$location · 译文' : location,
      page == null
          ? FlowReaderAnchor(
              sourceId: _sourceKey,
              chapterId: chapter.id,
              blockId: slice.block.id,
              characterOffset: translated ? 0 : offset + range.start,
            )
          : PdfReaderAnchor(sourceId: _sourceKey, pageNumber: page),
      startOffset: translated || originalPage != null
          ? null
          : offset + range.start,
      endOffset: translated || originalPage != null ? null : offset + range.end,
      annotationAnchor: FlowReaderAnchor(
        sourceId: _sourceKey,
        chapterId: chapter.id,
        blockId: slice.block.id,
      ),
      annotationStartOffset: annotationStart,
      annotationEndOffset: annotationEnd,
      annotationCanonicalRange: originalRange == null
          ? null
          : _flowSourceRange(
              chapter.id,
              slice.block,
              originalRange.start,
              originalRange.end,
            ),
      endAnchor: page == null
          ? null
          : PdfReaderAnchor(sourceId: _sourceKey, pageNumber: page),
      annotationView: translated ? 'flow-translation' : 'flow',
      translationSnapshot: translation?.text,
    );
    return _selectionToolbar(
      above: anchor.primaryAnchor,
      below: anchor.secondaryAnchor,
      onCopy: () {
        editable.hideToolbar(false);
        _copy(text);
      },
      onAnnotate: () {
        _collapseReaderTextSelection(editable);
        widget.onAnnotate(passage);
      },
      onAsk: () =>
          widget.onAsk(passage, anchor.secondaryAnchor ?? anchor.primaryAnchor),
    );
  }

  List<({int start, int end, String id})> _flowAnnotationRanges({
    required XiaoqiDocumentChapter chapter,
    required ReaderBlockSlice slice,
    required String visibleText,
  }) {
    if (widget.annotations.isEmpty) return const [];
    final aligned = _visibleAlignedTranslation(slice, visibleText);
    final offset =
        aligned != null && _ebookPageTurnMode != ReaderPaginationMode.horizontal
        ? 0
        : slice.startOffset;
    final blockText = aligned?.text ?? slice.block.text;
    // A pagination result from the preceding display revision can briefly be
    // visible while layout catches up. Wait for coordinates to agree.
    if (offset < 0 ||
        offset + visibleText.length > blockText.length ||
        blockText.substring(offset, offset + visibleText.length) !=
            visibleText) {
      return const [];
    }
    final revision = aligned == null ? null : companionTextHash(aligned.text);
    final projection = _isCompanionPdf(_source)
        ? CompanionReflowPage.sourceProjection(slice.block)
        : null;
    final blockHash = projection == null
        ? companionTextHash(slice.block.text)
        : null;
    final ranges = <({int start, int end, String id})>[];
    final visibleEnd = offset + visibleText.length;
    void addLocalRange(int start, int end, String id) {
      final from = math.max(offset, start);
      final to = math.min(visibleEnd, end);
      if (from < to) {
        ranges.add((start: from - offset, end: to - offset, id: id));
      }
    }

    for (final entry in widget.annotations) {
      final location = entry.selection;
      if (!_sourceMatches(location)) continue;
      final original = switch (location.canonicalRange) {
        CompanionPdfSourceRange range => projection?.displayRange(range),
        CompanionFlowSourceRange range
            when range.chapter == chapter.id &&
                range.block == slice.block.id &&
                range.textHash == blockHash =>
          (start: range.start, end: range.end),
        _ => null,
      };
      final projected = original == null || aligned == null
          ? original
          : aligned.translatedRange(original.start, original.end);
      if (projected != null &&
          projected.start >= 0 &&
          projected.end <= blockText.length) {
        addLocalRange(projected.start, projected.end, entry.id);
        continue;
      }
      final anchor = location.anchor;
      final start = location.startOffset;
      final end = location.endOffset;
      if (anchor is FlowReaderAnchor &&
          anchor.chapterId == chapter.id &&
          anchor.blockId == slice.block.id &&
          location.translationVersion == revision &&
          start != null &&
          end != null &&
          start >= 0 &&
          end > start &&
          end <= blockText.length &&
          blockText.substring(start, end) == location.quote) {
        addLocalRange(start, end, entry.id);
      }
    }
    return ranges;
  }

  CompanionTranslationText? _visibleAlignedTranslation(
    ReaderBlockSlice slice,
    String visibleText,
  ) {
    final aligned = _translationEnabled
        ? _alignedFlowTranslations[slice.block.id]
        : null;
    if (aligned == null || aligned.source != slice.block.text) return null;
    final start = _ebookPageTurnMode == ReaderPaginationMode.horizontal
        ? slice.startOffset
        : 0;
    final end = start + visibleText.length;
    return start >= 0 &&
            end <= aligned.text.length &&
            aligned.text.substring(start, end) == visibleText
        ? aligned
        : null;
  }

  CompanionSourceRange? _flowSourceRange(
    String chapter,
    XiaoqiDocumentBlock block,
    int start,
    int end,
  ) {
    if (_isCompanionPdf(_source)) {
      return CompanionReflowPage.sourceProjection(
        block,
      ).sourceRange(start, end);
    }
    final range = trimCompanionRange(block.text, start, end);
    return range == null
        ? null
        : CompanionFlowSourceRange(
            chapter: chapter,
            block: block.id,
            start: range.start,
            end: range.end,
            textHash: companionTextHash(block.text),
          );
  }

  ReadingCompanionPassage _passage(
    String text,
    String label,
    ReaderAnchor anchor, {
    int? startOffset,
    int? endOffset,
    String? translationSnapshot,
    ReaderAnchor? endAnchor,
    String annotationView = 'original',
    Map<int, String> pdfPageTextHashes = const {},
    ReaderAnchor? annotationAnchor,
    int? annotationStartOffset,
    int? annotationEndOffset,
    CompanionSourceRange? annotationCanonicalRange,
  }) => ReadingCompanionPassage(
    bookId: _source.bookId,
    sourceId: _source.id,
    text: text,
    sourceName: _source.displayName,
    locator: label,
    anchor: anchor,
    startOffset: startOffset,
    endOffset: endOffset,
    endAnchor: endAnchor,
    annotationView: annotationView,
    pdfPageTextHashes: pdfPageTextHashes,
    annotationAnchor: annotationAnchor,
    annotationStartOffset: annotationStartOffset,
    annotationEndOffset: annotationEndOffset,
    annotationCanonicalRange: annotationCanonicalRange,
    sourceRevision: _source.sourceVersionId.isEmpty
        ? _source.contentHash
        : _source.sourceVersionId,
    translationRevision: translationSnapshot == null
        ? null
        : sha256.convert(utf8.encode(translationSnapshot)).toString(),
  );

  void _changeReaderPageTurnMode(
    ReaderPaginationMode mode, {
    bool paper = false,
  }) {
    if (!_isPdfDocument) {
      final directionChanged = mode != _ebookPageTurnMode;
      if (!directionChanged && paper == _ebookPaperTurn) return;
      setState(() {
        _ebookPageTurnMode = mode;
        _ebookPaperTurn = paper;
        if (directionChanged && _preparedBook != null) {
          _ebookLayoutReady = false;
          final page = _pdfReadingAnchor?.pageNumber ?? _pdfPage;
          _targetEbook(page, previous: _pdfReadingAnchor, recenter: true);
        }
      });
      return;
    }
    if (mode == _pdfPageTurnMode) return;
    final page = _pdfReadingAnchor?.pageNumber ?? _pdfPage;
    ++_pdfSwipeRevision;
    _pdfSwipeStart = null;
    _pdfPanStart = null;
    _pdfGesturePage = null;
    _pdfSnapPending = _isPdfDocument && _pdf.isReady;
    setState(() => _pdfPageTurnMode = mode);
    final revision = _pdfSwipeRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Let pdfrx finish mapping its old viewport into the new layout first.
      scheduleMicrotask(() {
        if (!mounted || revision != _pdfSwipeRevision || !_isPdfDocument) {
          return;
        }
        unawaited(
          _goToPdfReaderPage(
            page,
            duration: Duration.zero,
            recordProgress: false,
          ),
        );
      });
    });
  }

  PdfPageLayout _layoutCompanionPdf(
    List<PdfPage> pages,
    PdfViewerParams params,
  ) {
    final viewport = _pdf.viewSize;
    final axis = _pdfPageTurnMode == ReaderPaginationMode.horizontal
        ? Axis.horizontal
        : Axis.vertical;
    final cached = _pdfViewportLayout;
    if (cached != null &&
        identical(cached.pages, pages) &&
        cached.viewport == viewport &&
        cached.margin == params.margin &&
        cached.axis == axis) {
      return cached.layout;
    }
    final layout = viewportPdfPageLayout(pages, viewport, params.margin, axis);
    _pdfViewportLayout = (
      pages: pages,
      viewport: viewport,
      margin: params.margin,
      axis: axis,
      layout: layout,
    );
    return layout;
  }

  Matrix4 _normalizeVerticalPdf(
    Matrix4 matrix,
    Size viewport,
    PdfPageLayout layout,
    PdfViewerController? controller,
  ) {
    if (controller == null || viewport.isEmpty || layout.pageLayouts.isEmpty) {
      return matrix;
    }
    final center = matrix.calcPosition(viewport);
    final zoom = matrix.zoom.clamp(1.0, controller.maxScale);
    final height = viewport.height;
    final last = layout.pageLayouts.length;
    final int nearest = (center.dy / height).floor().clamp(0, last - 1);
    final anchor =
        (_pdfGesturePage ?? (_pdfSnapPending ? nearest + 1 : _pdfPage)).clamp(
          1,
          last,
        );
    late final Offset position;
    if (zoom > 1.001) {
      final page = layout.pageLayouts[anchor - 1];
      final halfX = math.min(page.width / 2, viewport.width / zoom / 2);
      final halfY = math.min(page.height / 2, height / zoom / 2);
      position = Offset(
        center.dx.clamp(
          page.left + halfX,
          math.max(page.left + halfX, page.right - halfX),
        ),
        center.dy.clamp(
          page.top + halfY,
          math.max(page.top + halfY, page.bottom - halfY),
        ),
      );
    } else {
      final start = _pdfSwipeStart?.page;
      final firstSlot = start == null ? 1 : math.max(1, start - 1);
      final lastSlot = start == null ? last : math.min(last, start + 1);
      final y = start == null && !_pdfSnapPending
          ? ((_pdfGesturePage ?? nearest + 1) - .5) * height
          : center.dy.clamp(
              (firstSlot - .5) * height,
              (lastSlot - .5) * height,
            );
      position = Offset(viewport.width / 2, y);
    }
    return controller.calcMatrixFor(position, zoom: zoom, viewSize: viewport);
  }

  void _onPdfWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !_isPdfDocument ||
        !_pdf.isReady ||
        _pdfPageCount < 1 ||
        _inkEditing ||
        _hasActiveSelection ||
        HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    if (event.scrollDelta != Offset.zero) {
      CompanionPdfReflow.deferBackgroundPreparation();
    }
    final before = _pdf.centerPosition;
    final revision = _pdfSwipeRevision;
    if (_pdfPageTurnMode == ReaderPaginationMode.horizontal) {
      // pdfrx handles the wheel after pointer dispatch has finished.
      scheduleMicrotask(() => _recordPdfPan(before, revision));
      return;
    }
    if (_pdf.currentZoom > 1.001) {
      final delta = event.scrollDelta / _pdf.currentZoom;
      _pdf.value = _pdf.calcMatrixFor(_pdf.centerPosition + delta);
      _recordPdfPan(before, revision);
    } else if (!_pdfSnapPending && event.scrollDelta.dy != 0) {
      final next = (_pdfPage + event.scrollDelta.dy.sign.toInt())
          .clamp(1, _pdfPageCount)
          .toInt();
      if (next != _pdfPage) {
        _hideReaderChrome();
        unawaited(_goToPdfReaderPage(next));
      }
    }
  }

  bool? _onPdfKey(PdfViewerKeyHandlerParams _, LogicalKeyboardKey key, bool _) {
    if (!_isPdfDocument ||
        !_pdf.isReady ||
        _pdfPageCount < 1 ||
        _inkEditing ||
        _hasActiveSelection) {
      return null;
    }
    final vertical = _pdfPageTurnMode == ReaderPaginationMode.vertical;
    final destination = switch (key) {
      LogicalKeyboardKey.home => 1,
      LogicalKeyboardKey.end => _pdfPageCount,
      LogicalKeyboardKey.pageDown => _pdfPage + 1,
      LogicalKeyboardKey.pageUp => _pdfPage - 1,
      LogicalKeyboardKey.space =>
        _pdfPage + (HardwareKeyboard.instance.isShiftPressed ? -1 : 1),
      LogicalKeyboardKey.arrowDown when vertical && _pdf.currentZoom <= 1.001 =>
        _pdfPage + 1,
      LogicalKeyboardKey.arrowUp when vertical && _pdf.currentZoom <= 1.001 =>
        _pdfPage - 1,
      _ => null,
    };
    if (destination == null) {
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        final before = _pdf.centerPosition;
        final revision = _pdfSwipeRevision;
        scheduleMicrotask(() => _recordPdfPan(before, revision));
      }
      return null;
    }
    if (!_pdfSnapPending) {
      final next = destination.clamp(1, _pdfPageCount).toInt();
      if (next != _pdfPage) {
        _hideReaderChrome();
        unawaited(_goToPdfReaderPage(next));
      }
    }
    return true;
  }

  void _startPdfSwipe(ScaleStartDetails details) {
    ++_pdfSwipeRevision;
    // Cancel a settling animation at its currently visible position if the
    // reader catches the page with a new finger before it has come to rest.
    final interrupted = _pdfSnapPending;
    if (interrupted && _pdf.isReady) {
      unawaited(_pdf.goTo(_pdf.value, duration: Duration.zero));
    }
    _pdfSnapPending = false;
    _pdfSwipeStart = null;
    _pdfPanStart = null;
    if (!_isPdfDocument ||
        !_pdf.isReady ||
        _pdfPageCount == 0 ||
        _inkEditing ||
        _hasActiveSelection) {
      return;
    }
    final page = _pdfPageAtViewportCenter(
      _pdf.centerPosition,
      _pdf.layout.pageLayouts,
    );
    if (page < 1 || page > _pdf.layout.pageLayouts.length) return;
    _pdfGesturePage = page;
    if (details.pointerCount > 1) return;
    if (interrupted && page != (_pdfReadingAnchor?.pageNumber ?? _pdfPage)) {
      _onPdfReaderPageChanged(page, recordProgress: true);
    }
    _pdfPanStart = _pdf.centerPosition;
    final zoomTolerance = _pdfPageTurnMode == ReaderPaginationMode.horizontal
        ? 1.05
        : 1.001;
    if (_pdf.currentZoom > zoomTolerance) {
      return;
    }
    _pdfSwipeStart = (page: page, center: _pdf.centerPosition);
  }

  void _updatePdfSwipe(ScaleUpdateDetails details) {
    if (_isPdfDocument &&
        (details.focalPointDelta != Offset.zero || details.scale != 1)) {
      CompanionPdfReflow.deferBackgroundPreparation();
    }
    if (details.pointerCount > 1) {
      _pdfSwipeStart = null;
      _pdfPanStart = null;
      return;
    }
    final start = _pdfSwipeStart;
    if (start == null || widget.immersive) return;
    final delta = details.focalPointDelta;
    final horizontal = _pdfPageTurnMode == ReaderPaginationMode.horizontal;
    final main = horizontal ? delta.dx : delta.dy;
    final cross = horizontal ? delta.dy : delta.dx;
    if (main.abs() > cross.abs() &&
        (main < 0 ? start.page < _pdfPageCount : start.page > 1)) {
      _hideReaderChrome();
    }
  }

  void _endPdfSwipe(ScaleEndDetails details) {
    final start = _pdfSwipeStart;
    final panStart = _pdfPanStart;
    _pdfSwipeStart = null;
    _pdfPanStart = null;
    _pdfGesturePage = null;
    if (!_pdf.isReady) return;
    if (start == null) {
      if (panStart != null) {
        final revision = _pdfSwipeRevision;
        scheduleMicrotask(() {
          if (_recordPdfPan(panStart, revision)) {
            unawaited(_pdf.goTo(_pdf.value, duration: Duration.zero));
          }
        });
      }
      return;
    }

    final travel = (_pdf.centerPosition - start.center) * _pdf.currentZoom;
    final velocity = details.velocity.pixelsPerSecond;
    final horizontal = _pdfPageTurnMode == ReaderPaginationMode.horizontal;
    final distance = horizontal ? travel.dx : travel.dy;
    final fingerVelocity = horizontal ? velocity.dx : velocity.dy;
    final crossAxisDistance = horizontal ? travel.dy : travel.dx;
    final crossAxisVelocity = horizontal ? velocity.dy : velocity.dx;
    if (_inkEditing ||
        _hasActiveSelection ||
        (horizontal &&
            ((distance.abs() < 1 && fingerVelocity.abs() < 650) ||
                (crossAxisDistance.abs() > distance.abs() &&
                    crossAxisVelocity.abs() >= fingerVelocity.abs())))) {
      _recordPdfPan(start.center, _pdfSwipeRevision);
      return;
    }
    final target = horizontal
        ? horizontalPdfPageTarget(
            startPage: start.page,
            pageCount: _pdf.layout.pageLayouts.length,
            distance: distance,
            fingerVelocity: fingerVelocity,
            viewportWidth: _pdf.viewSize.width,
          )
        : verticalPdfPageTarget(
            startPage: start.page,
            pageCount: _pdf.layout.pageLayouts.length,
            distance: distance,
            fingerVelocity: fingerVelocity,
            viewportHeight: _pdf.viewSize.height,
          );
    final revision = _pdfSwipeRevision;
    _pdfSnapPending = true;
    // pdfrx starts inertia as this gesture callback returns. Cancel it in the
    // same event turn, before it can advance the view by even one frame.
    scheduleMicrotask(() {
      if (!mounted || revision != _pdfSwipeRevision) return;
      if (!_isPdfDocument || _inkEditing) {
        _pdfSnapPending = false;
        return;
      }
      unawaited(
        _goToPdfReaderPage(target, recordProgress: target != start.page),
      );
    });
  }

  int _pdfPageAtViewportCenter(Offset center, List<Rect> layouts) {
    final horizontal = _pdfPageTurnMode == ReaderPaginationMode.horizontal;
    final position = horizontal ? center.dx : center.dy;
    var first = 0;
    var last = layouts.length - 1;
    while (first < last) {
      final index = (first + last) ~/ 2;
      final before = layouts[index];
      final after = layouts[index + 1];
      final boundary = horizontal
          ? (before.center.dx + after.center.dx) / 2
          : (before.center.dy + after.center.dy) / 2;
      if (position < boundary) {
        last = index;
      } else {
        first = index + 1;
      }
    }
    return first + 1;
  }

  bool _recordPdfPan(Offset before, int revision) {
    if (!mounted ||
        !_isPdfDocument ||
        !_pdf.isReady ||
        _pdfPageCount == 0 ||
        _inkEditing ||
        _hasActiveSelection ||
        _pdfSnapPending ||
        _pdfSwipeRevision != revision) {
      return false;
    }
    final travel = (_pdf.centerPosition - before) * _pdf.currentZoom;
    if (travel.distanceSquared < 4) return false;
    final number = _pdfPageAtViewportCenter(
      _pdf.centerPosition,
      _pdf.layout.pageLayouts,
    );
    if (number != _pdfPage) {
      _hideReaderChrome();
      _onPdfReaderPageChanged(number, recordProgress: true);
    } else if (travel.dy.abs() >= 2) {
      final layout = _pdf.layout.pageLayouts[number - 1];
      if (_pdf.visibleRect.height < layout.height) {
        final fraction = (_pdf.visibleRect.top - layout.top) / layout.height;
        _rememberPdfPosition(
          number,
          pageFraction: fraction.clamp(0.0, 1.0).toDouble(),
        );
      }
    }
    return true;
  }

  Future<void> _goToPdfReaderPage(
    int number, {
    Duration duration = const Duration(milliseconds: 220),
    bool recordProgress = true,
  }) async {
    if (!_pdf.isReady) return;
    if ((number - _pdfPage).abs() > 1 ||
        MediaQuery.disableAnimationsOf(context)) {
      duration = Duration.zero;
    }
    if (number < 1 || number > _pdf.layout.pageLayouts.length) {
      _pdfSnapPending = false;
      return;
    }
    final revision = ++_pdfSwipeRevision;
    _pdfSwipeStart = null;
    _pdfPanStart = null;
    _pdfSnapPending = true;
    if (_isPdfDocument) CompanionPdfReflow.deferBackgroundPreparation();
    if (recordProgress) _rememberPdfPosition(number);
    final rect = _pdf.layout.pageLayouts[number - 1];
    final matrix = _pdf.calcMatrixFor(
      rect.center,
      zoom: 1,
      viewSize: _pdf.viewSize,
    );
    await _pdf.goTo(matrix, duration: duration);
    if (!mounted || !_pdf.isReady || revision != _pdfSwipeRevision) return;
    _pdfSnapPending = false;
    _pdf.setCurrentPageNumber(number);
    _onPdfReaderPageChanged(number);
  }

  void _onPdfReaderPageChanged(int next, {bool recordProgress = false}) {
    if (!mounted ||
        !_isPdfDocument ||
        _pdfSwipeStart != null ||
        _pdfSnapPending) {
      return;
    }
    if (recordProgress) {
      _releaseReturnPreview();
      _rememberPdfPosition(next);
    }
    if (next == _pdfPage) return;
    ++_pdfGestureRevision;
    setState(() {
      _pdfPage = next;
      _pdfTextAvailable = false;
      _translationPending = false;
      _translationError = null;
    });
    if (_requestedEbook && _requestedPdfPage != next) {
      unawaited(_openConvertedPage(next, fromPdf: true));
    }
    _reportSelection(false);
    _scheduleTranslation();
    _schedulePdfPageWork(probeText: true);
  }

  Widget _pdfDocument(ReaderAnchor? anchor) {
    final page = anchor is PdfReaderAnchor ? anchor.pageNumber : 1;
    final surround = _dark ? const Color(0xFF111315) : const Color(0xFFF2F3F5);
    final translation =
        _convertedPage == null &&
            _translationEnabled &&
            _translatedPdfNumber == _pdfPage
        ? _translatedPdfPage
        : null;
    final showsOriginalPage = _convertedPage == null && translation == null;
    final horizontal = _pdfPageTurnMode == ReaderPaginationMode.horizontal;
    return _footerWithBody(
      showChrome: _convertedPage == null,
      body: ColoredBox(
        color: surround,
        child: Padding(
          padding: EdgeInsets.zero,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Listener(
                onPointerSignal: _onPdfWheel,
                child: Theme(
                  data: _dark
                      ? Theme.of(context).copyWith(
                          textSelectionTheme: Theme.of(context)
                              .textSelectionTheme
                              .copyWith(selectionColor: Colors.transparent),
                        )
                      : Theme.of(context),
                  child: PdfViewer(
                    _selectablePdfReference,
                    controller: _pdf,
                    initialPageNumber: page,
                    params: PdfViewerParams(
                      backgroundColor: surround,
                      layoutPages: _layoutCompanionPdf,
                      sizeDelegateProvider:
                          const PdfViewerSizeDelegateProviderLegacy(
                            minScale: 1,
                            useAlternativeFitScaleAsMinScale: false,
                          ),
                      normalizeMatrix: horizontal
                          ? null
                          : _normalizeVerticalPdf,
                      // Handle deltas here while leaving pdfrx's Ctrl+wheel zoom active.
                      scrollByMouseWheel: horizontal ? 0.2 : 0,
                      onKey: _onPdfKey,
                      pageAnchor: PdfPageAnchor.center,
                      pageAnchorEnd: PdfPageAnchor.center,
                      panAxis: horizontal ? PanAxis.aligned : PanAxis.free,
                      onInteractionStart: _startPdfSwipe,
                      onInteractionUpdate: _updatePdfSwipe,
                      onInteractionEnd: _endPdfSwipe,
                      calculateCurrentPageNumber: (viewport, layouts, _) =>
                          layouts.isEmpty
                          ? null
                          : _pdfPageAtViewportCenter(viewport.center, layouts),
                      margin: 17,
                      pageDropShadow: _dark
                          ? null
                          : const BoxShadow(
                              color: Color(0x0E000000),
                              blurRadius: 7,
                              offset: Offset(0, 2),
                            ),
                      pageBackgroundPaintCallbacks: _dark
                          ? [_beginNightPage]
                          : null,
                      pagePaintCallbacks: [
                        if (_returnPreview != null) _paintReturnPreview,
                        if (_dark) ...[_endNightPage, _paintNightPdfSelection],
                        if (showsOriginalPage && _noteOriginPdfMark != null)
                          _paintNoteOriginPdfMark,
                      ],
                      pageOverlaysBuilder: (context, rect, page) => [
                        if (showsOriginalPage)
                          if (_pdfAnnotations(page.pageNumber)
                              case final entries when entries.isNotEmpty)
                            Positioned.fill(
                              child: CompanionPdfAnnotationOverlay(
                                key: ValueKey(('annotation', page.pageNumber)),
                                page: page,
                                pageSize: rect.size,
                                annotations: entries,
                                onOpen: _inkEditing || _hasActiveSelection
                                    ? null
                                    : (matches) => unawaited(
                                        _openMatchingAnnotations(matches),
                                      ),
                              ),
                            ),
                        if (showsOriginalPage &&
                            (_inkEditing ||
                                _savedInk.isNotEmpty ||
                                _largeDrawings.isNotEmpty))
                          Positioned.fill(
                            child: _inkSurface(
                              PdfReaderAnchor(
                                sourceId: _sourceKey,
                                pageNumber: page.pageNumber,
                              ),
                              'original',
                            ),
                          ),
                      ],
                      panEnabled: !_inkEditing,
                      scaleEnabled: !_inkEditing,
                      loadingBannerBuilder: (_, _, _) =>
                          const _ReadingPlaceholder(),
                      errorBannerBuilder: (_, _, _, _) => _ReaderStatus(
                        'PDF 无法打开',
                        action: widget.onChooseSource != null
                            ? '选择其他资料'
                            : '打开本书资料',
                        onAction: widget.onChooseSource ?? widget.onOpenLibrary,
                      ),
                      onViewerReady: (document, _) {
                        if (!mounted) return;
                        _pdfDocumentRef = document;
                        setState(() {
                          _pdfPageCount = document.pages.length;
                          _pdfPage = page
                              .clamp(1, math.max(1, _pdfPageCount))
                              .toInt();
                          if (_pdfReadingAnchor?.pageNumber != _pdfPage) {
                            _pdfReadingAnchor = null;
                          }
                        });
                        final initial = widget.initialAnnotationSelection;
                        final restoredPage = _pdfPage;
                        unawaited(() async {
                          if (initial != null &&
                              !_handledInitialPdfAnnotation) {
                            _handledInitialPdfAnnotation = true;
                            final opened = await _jumpPdfAnnotationOrigin(
                              document,
                              initial,
                            );
                            if (!mounted ||
                                !identical(_pdfDocumentRef, document)) {
                              return;
                            }
                            if (opened) {
                              _schedulePdfPageWork(probeText: true);
                              return;
                            }
                            _showMissingAnnotationOrigin();
                          }
                          await _goToPdfReaderPage(
                            restoredPage,
                            duration: Duration.zero,
                            recordProgress: false,
                          );
                          if (mounted && identical(_pdfDocumentRef, document)) {
                            _schedulePdfPageWork(probeText: true);
                          }
                        }());
                      },
                      textSelectionParams: PdfTextSelectionParams(
                        enabled: !_inkEditing,
                        showContextMenuAutomatically: false,
                        buildSelectionHandle: _buildPdfSelectionHandle,
                        calcSelectionHandleOffset: _pdfSelectionHandleOffset,
                        onTextSelectionChange: _onPdfTextSelection,
                        onSelectionHandlePanStart: (_) {
                          _pdfHandleMoving = true;
                          _updatePdfToolbar();
                        },
                        onSelectionHandlePanEnd: (_) {
                          _pdfHandleMoving = false;
                          _updatePdfToolbar();
                        },
                      ),
                      buildContextMenu: (_, _) => null,
                      onGeneralTap: (_, controller, details) {
                        if (!_inkEditing &&
                            details.type == PdfViewerGeneralTapType.longPress &&
                            details.tapOn == PdfViewerPart.background) {
                          unawaited(
                            _selectRecognizedText(details.documentPosition),
                          );
                          return true;
                        }
                        if (details.type == PdfViewerGeneralTapType.tap) {
                          ++_pdfGestureRevision;
                        }
                        if (details.type == PdfViewerGeneralTapType.tap &&
                            details.tapOn != PdfViewerPart.selectedText) {
                          _toggleReaderChrome();
                        }
                        return false;
                      },
                    ),
                  ),
                ),
              ),
              if (_pdfToolbarVisible && !_inkEditing && showsOriginalPage)
                ListenableBuilder(
                  listenable: _pdf,
                  builder: (context, _) => _pdfSelection(),
                ),
              if (translation != null) _pdfTranslationView(translation),
            ],
          ),
        ),
      ),
      page: _pdfPage,
      pageCount: _pdfPageCount,
      onPageSelected: (next) {
        if (!_inkEditing) unawaited(_goToPdfReaderPage(next));
      },
      onOutline: _pdfPageCount == 0 ? null : _showPdfOutline,
    );
  }

  void _onPdfTextSelection(PdfTextSelection selection) {
    if (_selectionActive != selection.hasSelectedText) {
      _reportSelection(selection.hasSelectedText);
    }
    if (!selection.hasSelectedText) _pdfHandleMoving = false;
    _updatePdfToolbar();
  }

  Future<void> _loadNightSelectionPage(PdfPage page) async {
    final document = _pdfDocumentRef;
    try {
      final text = await page.loadStructuredText();
      _nightSelectionLoadedText[page] = text;
      if (mounted && _dark && _pdf.isReady && _pdfDocumentRef == document) {
        _pdf.invalidate();
      }
    } on Exception {
      // The live selection on the endpoint pages remains available.
    }
  }

  void _paintNightPdfSelection(Canvas canvas, Rect pageRect, PdfPage page) {
    if (!_pdf.isReady || _inkEditing || !_isPdfDocument) return;
    final selection = _pdf.textSelectionDelegate;
    final range = selection.textSelectionPointRange;
    // pdfrx repaints during the gesture, while its change callback waits
    // until the selection settles. Read the live endpoints on that repaint.
    if (selection.hasSelectedText != _selectionActive &&
        !_pdfSelectionUiUpdateScheduled) {
      _pdfSelectionUiUpdateScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pdfSelectionUiUpdateScheduled = false;
        if (mounted && _isPdfDocument && _pdf.isReady) {
          _onPdfTextSelection(_pdf.textSelectionDelegate);
        }
      });
    }
    if (range == null) return;
    final first = range.start;
    final last = range.end;
    final number = page.pageNumber;
    if (number < first.text.pageNumber || number > last.text.pageNumber) {
      return;
    }
    final PdfPageText text;
    if (number == first.text.pageNumber) {
      text = first.text;
    } else if (number == last.text.pageNumber) {
      text = last.text;
    } else {
      final middle = _nightSelectionLoadedText[page];
      if (middle == null) {
        if (_nightSelectionTextRequested[page] != true) {
          _nightSelectionTextRequested[page] = true;
          unawaited(_loadNightSelectionPage(page));
        }
        return;
      }
      text = middle;
    }
    final start = number == first.text.pageNumber ? first.index : 0;
    final end = number == last.text.pageNumber
        ? last.index + 1
        : text.charRects.length;
    if (text.fragments.isEmpty || start >= end || end > text.charRects.length) {
      return;
    }
    final pageRange = PdfPageTextRange(pageText: text, start: start, end: end);
    for (final fragment in pageRange.enumerateFragmentBoundingRects()) {
      canvas.drawRect(
        fragment.bounds.toRectInDocument(page: page, pageRect: pageRect),
        _nightSelectionPaint,
      );
    }
  }

  void _updatePdfToolbar() {
    if (!mounted) return;
    final visible =
        _pdf.isReady &&
        !_pdfHandleMoving &&
        _pdf.textSelectionDelegate.isCopyAllowed &&
        _pdf.textSelectionDelegate.hasSelectedText;
    if (visible != _pdfToolbarVisible) {
      setState(() => _pdfToolbarVisible = visible);
    }
  }

  Widget _pdfTranslationView(CompanionTranslationText aligned) {
    final page = _pdfPage;
    final translation = aligned.text;
    final sourceHash = companionTextHash(aligned.source);
    final displayHash = companionTextHash(translation);
    final annotationRanges = <({int start, int end, String id})>[];
    for (final entry in widget.annotations) {
      final selection = entry.selection;
      if (!_sourceMatches(selection)) continue;
      final range = selection.canonicalRange;
      final span =
          _translatedPdfHasNativeSource && range is CompanionPdfSourceRange
          ? range.pages
                .where(
                  (span) => span.page == page && span.textHash == sourceHash,
                )
                .firstOrNull
          : null;
      final projected = span == null
          ? null
          : aligned.translatedRange(span.start, span.end);
      if (projected != null) {
        annotationRanges.add((
          start: projected.start,
          end: projected.end,
          id: entry.id,
        ));
        continue;
      }
      final anchor = selection.anchor;
      final start = selection.startOffset;
      final end = selection.endOffset;
      if (selection.view == 'translation' &&
          selection.translationVersion == displayHash &&
          anchor is PdfReaderAnchor &&
          anchor.pageNumber == page &&
          start != null &&
          end != null &&
          start >= 0 &&
          end > start &&
          end <= translation.length &&
          translation.substring(start, end) == selection.quote) {
        annotationRanges.add((start: start, end: end, id: entry.id));
      }
    }
    void turnPage(int delta) {
      final target = page + delta;
      if (!_selectionActive &&
          !_inkEditing &&
          target != page &&
          target >= 1 &&
          target <= _pdfPageCount &&
          _pdf.isReady) {
        unawaited(_goToPdfReaderPage(target));
      }
    }

    return Material(
      color: _dark ? _paperDark : Colors.white,
      child: GestureDetector(
        onHorizontalDragStart:
            _pdfPageTurnMode == ReaderPaginationMode.horizontal
            ? (_) => _pdfTranslationHorizontalDelta = 0
            : null,
        onHorizontalDragUpdate:
            _pdfPageTurnMode == ReaderPaginationMode.horizontal
            ? (details) {
                _pdfTranslationHorizontalDelta += details.delta.dx;
                if ((_pdfTranslationHorizontalDelta < 0 &&
                        page < _pdfPageCount) ||
                    (_pdfTranslationHorizontalDelta > 0 && page > 1)) {
                  _hideReaderChrome();
                }
              }
            : null,
        onHorizontalDragEnd: _pdfPageTurnMode == ReaderPaginationMode.horizontal
            ? (_) => turnPage(
                _pdfTranslationHorizontalDelta < -44
                    ? 1
                    : _pdfTranslationHorizontalDelta > 44
                    ? -1
                    : 0,
              )
            : null,
        child: NotificationListener<ScrollNotification>(
          onNotification: (event) {
            if (event is ScrollStartNotification && event.dragDetails != null) {
              _pdfTranslationOverscroll = 0;
            }
            if (event is OverscrollNotification &&
                event.dragDetails != null &&
                _pdfPageTurnMode == ReaderPaginationMode.vertical) {
              _pdfTranslationOverscroll += event.overscroll;
              if ((_pdfTranslationOverscroll > 0 && page < _pdfPageCount) ||
                  (_pdfTranslationOverscroll < 0 && page > 1)) {
                _hideReaderChrome();
              }
            }
            if (event is ScrollEndNotification) {
              turnPage(
                _pdfTranslationOverscroll > 56
                    ? 1
                    : _pdfTranslationOverscroll < -56
                    ? -1
                    : 0,
              );
              _pdfTranslationOverscroll = 0;
            }
            return false;
          },
          child: SingleChildScrollView(
            key: ValueKey(('translation', page)),
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            padding: const EdgeInsets.fromLTRB(32, 20, 32, 24),
            child: Stack(
              children: [
                CompanionAnnotationTextView(
                  text: translation,
                  annotations: annotationRanges,
                  onOpenAnnotations: _inkEditing
                      ? null
                      : (ids) => unawaited(
                          _openMatchingAnnotations([
                            for (final entry in widget.annotations)
                              if (ids.contains(entry.id)) entry,
                          ]),
                        ),
                  selectionControls: _companionTextSelectionControls,
                  onTap: widget.onToggleImmersive == null
                      ? null
                      : _toggleReaderChrome,
                  onSelectionChanged: (selection, _) =>
                      _reportSelection(!selection.isCollapsed),
                  style: TextStyle(
                    color: _ink,
                    fontSize: 20,
                    height: 1.6,
                    fontFamily: 'NotoSerifCJKSC',
                  ),
                  contextMenuBuilder: (context, editable) {
                    final selected = editable.textEditingValue.selection;
                    if (!selected.isValid || selected.isCollapsed) {
                      return const SizedBox.shrink();
                    }
                    final text = selected.textInside(translation);
                    final anchor = editable.contextMenuAnchors;
                    final original = aligned.sourceRange(
                      selected.start,
                      selected.end,
                    );
                    final passage = _passage(
                      text,
                      '第 $page 页 · 译文',
                      PdfReaderAnchor(sourceId: _sourceKey, pageNumber: page),
                      startOffset: selected.start,
                      endOffset: selected.end,
                      annotationView: 'translation',
                      translationSnapshot: translation,
                      annotationCanonicalRange:
                          original == null || !_translatedPdfHasNativeSource
                          ? null
                          : CompanionPdfSourceRange([
                              (
                                page: page,
                                start: original.start,
                                end: original.end,
                                textHash: sourceHash,
                              ),
                            ]),
                    );
                    return _selectionToolbar(
                      above: anchor.primaryAnchor,
                      below: anchor.secondaryAnchor,
                      onCopy: () {
                        editable.hideToolbar(false);
                        _copy(text);
                      },
                      onAnnotate: () {
                        _collapseReaderTextSelection(editable);
                        widget.onAnnotate(passage);
                      },
                      onAsk: () {
                        editable.hideToolbar();
                        widget.onAsk(
                          passage,
                          anchor.secondaryAnchor ?? anchor.primaryAnchor,
                        );
                      },
                    );
                  },
                ),
                Positioned.fill(
                  child: _inkSurface(
                    PdfReaderAnchor(sourceId: _sourceKey, pageNumber: page),
                    'pdf-translation',
                    text: translation,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showPdfOutline() {
    final catalog = _organizePdfOutline(_pdfCatalogEntries());
    final hasGroups = catalog.any((row) => row.level > 1);
    final bookmarks = hasGroups
        ? null
        : _pdfBookmarkOutline ??= _readPdfBookmarks();
    final readingPage = _convertedPage?.number ?? _pdfPage;
    Widget list(List<PdfCatalogEntry> entries) {
      final pages = entries.isEmpty
          ? List<int>.generate(_pdfPageCount, (index) => index + 1)
          : entries.map((entry) => entry.pdfPage).toList(growable: false);
      final titles = entries.isEmpty
          ? List.generate(_pdfPageCount, (index) => '第 ${index + 1} 页')
          : entries.map((entry) => entry.title).toList(growable: false);
      var current = -1;
      for (var index = 0; index < pages.length; index++) {
        final page = pages[index];
        if (page != null &&
            page <= readingPage &&
            (current == -1 || page >= pages[current]!)) {
          current = index;
        }
      }
      return _outlineList(
        key: ObjectKey(entries),
        titles: titles,
        current: current,
        onSelected: (index) {
          final target = pages[index]!;
          if (target != readingPage) {
            setState(() {
              _pageBeforeJump = readingPage;
              _pdfPositionBeforeJump = _pdfReadingAnchor;
              _flowPositionBeforeJump = null;
            });
          }
          if (_requestedEbook) {
            unawaited(_openConvertedPage(target));
          } else if (_pdf.isReady) {
            unawaited(_goToPdfReaderPage(target));
          }
        },
        levels: entries.map((entry) => entry.level - 1).toList(growable: false),
        groupLabels: {
          for (var index = 0; index < pages.length; index++)
            if (pages[index] == null) index,
        },
        pages: pages,
        readingPage: readingPage,
      );
    }

    _openReaderPanel(
      _ReaderPanel.outline,
      outline: (context) => bookmarks == null
          ? list(catalog)
          : FutureBuilder<List<PdfCatalogEntry>>(
              future: bookmarks,
              builder: (context, snapshot) {
                final native = snapshot.data;
                return list(
                  native != null &&
                          native.isNotEmpty &&
                          (catalog.isEmpty ||
                              native.any((entry) => entry.level > 1))
                      ? native
                      : catalog,
                );
              },
            ),
    );
  }

  List<PdfCatalogEntry> _organizePdfOutline(List<PdfCatalogEntry> catalog) {
    final earlier = <String, int>{};
    final children = <int?, List<int>>{};
    final depthStack = <int>[];
    for (var index = 0; index < catalog.length; index++) {
      final entry = catalog[index];
      while (depthStack.isNotEmpty &&
          catalog[depthStack.last].level >= entry.level) {
        depthStack.removeLast();
      }
      final parent = earlier[entry.parentId] ?? depthStack.lastOrNull;
      children.putIfAbsent(parent, () => []).add(index);
      if (entry.id.isNotEmpty) earlier[entry.id] = index;
      depthStack.add(index);
    }
    final rows = <PdfCatalogEntry>[];
    void append(int index, int level) {
      final entry = catalog[index];
      final title = entry.title.trim();
      final sourcePage = entry.pdfPage;
      final page =
          sourcePage != null && sourcePage > 0 && sourcePage <= _pdfPageCount
          ? sourcePage
          : null;
      final position = rows.length;
      final childLevel = title.isEmpty ? level : level + 1;
      for (final child in children[index] ?? const <int>[]) {
        append(child, childLevel);
      }
      if (title.isEmpty || (page == null && position == rows.length)) return;
      rows.insert(
        position,
        PdfCatalogEntry(
          id: entry.id,
          title: title,
          level: level,
          pdfPage: page,
          sourceKind: entry.sourceKind,
        ),
      );
    }

    for (final root in children[null] ?? const <int>[]) {
      append(root, 1);
    }
    return rows;
  }

  Future<List<PdfCatalogEntry>> _readPdfBookmarks() async {
    if (!_pdf.isReady) return const [];
    try {
      final nodes = await _pdf.useDocument(
        (document) => document.loadOutline(),
      );
      if (!mounted || nodes == null) return const [];
      final entries = <PdfCatalogEntry>[];
      void add(List<PdfOutlineNode> nodes, int depth) {
        for (final node in nodes) {
          entries.add(
            PdfCatalogEntry(
              id: 'bookmark:${entries.length}',
              title: node.title,
              level: depth,
              pdfPage: node.dest?.pageNumber,
              sourceKind: 'pdf_outline',
            ),
          );
          add(node.children, depth + 1);
        }
      }

      add(nodes, 1);
      return _organizePdfOutline(entries);
    } on Exception {
      // A broken optional outline must leave the page list usable.
      return const [];
    }
  }

  List<PdfCatalogEntry> _pdfCatalogEntries() {
    try {
      final value = jsonDecode(_source.catalogJson);
      if (value is! List) return const [];
      return [
        for (final entry in value.whereType<Map<String, dynamic>>())
          PdfCatalogEntry.fromJson(entry),
      ];
    } on FormatException {
      return const [];
    }
  }

  Widget _pdfSelection() {
    if (!_pdf.isReady) return const SizedBox.shrink();
    final delegate = _pdf.textSelectionDelegate;
    final range = delegate.textSelectionPointRange;
    if (!delegate.isCopyAllowed || range == null) {
      return const SizedBox.shrink();
    }
    final page = range.start.text.pageNumber;
    final endPage = range.end.text.pageNumber;
    final first = _pdf.calcRectForRectInsidePage(
      pageNumber: page,
      rect: range.start.text.charRects[range.start.index],
    );
    final last = _pdf.calcRectForRectInsidePage(
      pageNumber: endPage,
      rect: range.end.text.charRects[range.end.index],
    );
    final above = _pdf.documentToLocal(
      Offset((first.center.dx + last.center.dx) / 2, first.top),
    );
    final below = _pdf.documentToLocal(
      Offset((first.center.dx + last.center.dx) / 2, last.bottom),
    );
    if (below.dy < 0 || above.dy > _pdf.viewSize.height) {
      return const SizedBox.shrink();
    }
    final label = endPage == page ? '第 $page 页' : '第 $page–$endPage 页';
    final anchor = PdfReaderAnchor(sourceId: _sourceKey, pageNumber: page);

    Future<void> withText(bool ask) async {
      final globalAnchor = _pdf.localToGlobal(below) ?? below;
      final pages = _pdf.document.pages;
      final pieces = <String>[];
      final pageHashes = <int, String>{};
      final sourceRanges = <CompanionPdfRange>[];
      var nativeCoordinates = true;
      try {
        for (var number = page; number <= endPage; number++) {
          final selectedPage = pages[number - 1];
          nativeCoordinates =
              nativeCoordinates &&
              identical(selectedPage, companionNativePdfPage(selectedPage));
          final text = number == page
              ? range.start.text
              : number == endPage
              ? range.end.text
              : await selectedPage.loadStructuredText();
          final start = number == page ? range.start.index : 0;
          final end = number == endPage
              ? range.end.index + 1
              : text.fullText.length;
          if (start < 0 || start > end || end > text.fullText.length) return;
          pieces.add(text.fullText.substring(start, end));
          final hash = companionTextHash(text.fullText);
          pageHashes[number] = hash;
          final span = trimCompanionRange(text.fullText, start, end);
          if (span != null) {
            sourceRanges.add((
              page: number,
              start: span.start,
              end: span.end,
              textHash: hash,
            ));
          }
        }
      } catch (_) {
        if (mounted) AppToast.show(context, '无法读取所选原文，请重试');
        return;
      }
      final text = pieces.join('\n').trim();
      if (!mounted || text.isEmpty) return;
      await delegate.clearTextSelection();
      if (!mounted) return;
      final passage = _passage(
        text,
        label,
        anchor,
        startOffset: range.start.index,
        endOffset: range.end.index + 1,
        endAnchor: page == endPage
            ? null
            : PdfReaderAnchor(sourceId: _sourceKey, pageNumber: endPage),
        pdfPageTextHashes: pageHashes,
        annotationCanonicalRange: nativeCoordinates
            ? CompanionPdfSourceRange(sourceRanges)
            : null,
      );
      if (ask) {
        widget.onAsk(passage, globalAnchor);
      } else {
        widget.onAnnotate(passage);
      }
    }

    return _selectionToolbar(
      above: above,
      below: below,
      onCopy: () {
        unawaited(
          delegate.copyTextSelection().then(
            (_) => delegate.clearTextSelection(),
          ),
        );
      },
      onAnnotate: () => unawaited(withText(false)),
      onAsk: () => unawaited(withText(true)),
    );
  }

  void _copy(String text) {
    if (text.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    AppToast.show(context, '已复制');
  }

  bool get _readerPanelOpen => _activePanel != null;
  bool get _supportsReaderBrightness =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  bool get _readerWide => MediaQuery.sizeOf(context).width >= 600;
  double get _readerSideInset => _readerWide ? 34 : 16;
  double get _readerNavHeight => math.max(
    _readerWide ? 60.0 : 44.0,
    MediaQuery.textScalerOf(context).scale(_readerWide ? 18 : 14) + 20,
  );
  double get _readerFooterHeight =>
      _readerNavHeight + MediaQuery.paddingOf(context).bottom;
  Color get _readerChrome =>
      _dark ? const Color(0xFF16181A) : const Color(0xFFFCFCFC);
  Color get _readerPanelSurface =>
      _dark ? const Color(0xFF222426) : const Color(0xFFFCFCFC);
  Color get _readerRule =>
      _dark ? const Color(0xFF414345) : const Color(0xFFE1E2E3);
  Color get _readerSelected =>
      _dark ? const Color(0xFF353739) : const Color(0xFFEBEBEC);
  Color get _readerMuted =>
      _dark ? const Color(0xFFB8B5AE) : const Color(0xFF595959);

  Future<void> _openPdfObjectPreview(
    int page,
    CompanionPagePicture picture,
  ) async {
    final document = _pdfDocumentRef;
    if (document == null || _inkEditing || _selectionActive) return;
    if (document.permissions?.allowsCopying == false) {
      AppToast.show(context, '这份 PDF 限制复制内容');
      return;
    }
    final kind = picture.isTable ? 'table' : 'image';
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await showCompanionPdfObjectPreview(
      context: context,
      picture: picture,
      filename: 'xiaoqi-$kind-p$page-$stamp.png',
      loadPreview: () => _pdfReflow.renderPicture(document, page, picture),
      loadExport: () =>
          _pdfReflow.renderPicture(document, page, picture, forExport: true),
    );
  }

  void _openReaderPanel(_ReaderPanel panel, {WidgetBuilder? outline}) {
    if (_activePanel == panel) {
      _closeReaderPanel();
      return;
    }
    if (_activePanel == _ReaderPanel.display) {
      unawaited(_persistDisplaySettings());
    }
    _dismissFlowSelection();
    FocusManager.instance.primaryFocus?.unfocus();
    final route = ModalRoute.of(context);
    if (_panelHistory == null && route != null) {
      final history = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          if (_panelHistory == null) return;
          _panelHistory = null;
          _closeReaderPanel();
        },
      );
      route.addLocalHistoryEntry(history);
      _panelHistory = history;
    }
    setState(() {
      _activePanel = panel;
      _adjustingTypography = false;
      _outlineExtent = 0;
      _outlineDragging = false;
      _outlinePanel = outline;
      _progressPreview.value = null;
    });
  }

  bool _closeReaderPanel() {
    if (!mounted || !_readerPanelOpen) return false;
    final saveDisplay = _activePanel == _ReaderPanel.display;
    final history = _panelHistory;
    _panelHistory = null;
    history?.remove();
    setState(() {
      _activePanel = null;
      _adjustingTypography = false;
      _outlinePanel = null;
      _progressPreview.value = null;
    });
    if (saveDisplay) unawaited(_persistDisplaySettings());
    return true;
  }

  Widget _readerIcon(String asset, double size, {Color? color}) =>
      SvgPicture.asset(
        asset,
        width: size,
        height: size,
        excludeFromSemantics: true,
        colorFilter: ColorFilter.mode(color ?? _ink, BlendMode.srcIn),
      );

  Widget _readerSlider({
    required double value,
    required double min,
    required double max,
    required String description,
    required ValueChanged<double>? onChanged,
    ValueChanged<double>? onChangeEnd,
    SemanticFormatterCallback? formatValue,
    double? defaultValue,
    VoidCallback? onReset,
    ValueChanged<bool>? onDragChanged,
    bool compact = false,
  }) {
    const trackInset = 7.0;
    Widget slider(
      double shownValue,
      ValueChanged<double>? change,
      ValueChanged<double>? finish,
    ) => Semantics(
      label: description,
      child: SliderTheme(
        data: SliderThemeData(
          activeTrackColor: _dark
              ? const Color(0xFFC0BFBB)
              : const Color(0xFF4B4B4B),
          inactiveTrackColor: _dark
              ? const Color(0xFF606163)
              : const Color(0xFFD7D8D9),
          thumbColor: _dark ? const Color(0xFFF0ECE3) : const Color(0xFF363636),
          overlayColor: Colors.transparent,
          overlayShape: SliderComponentShape.noOverlay,
          trackShape: const RoundedRectSliderTrackShape(),
          trackHeight: compact ? 3.5 : 4.5,
          thumbShape: RoundSliderThumbShape(
            enabledThumbRadius: compact ? 5.5 : 7,
            elevation: 0,
            pressedElevation: 0,
          ),
          padding: const EdgeInsets.symmetric(horizontal: trackInset),
          showValueIndicator: ShowValueIndicator.never,
        ),
        child: Slider(
          value: shownValue.clamp(min, max).toDouble(),
          min: min,
          max: max,
          onChanged: change,
          onChangeEnd: finish,
          semanticFormatterCallback: formatValue,
        ),
      ),
    );
    if (defaultValue == null || onReset == null || onChanged == null) {
      return slider(value, onChanged, onChangeEnd);
    }
    return _ReaderDisplaySlider(
      key: ValueKey(description),
      value: value,
      defaultFraction: (defaultValue - min) / (max - min),
      trackInset: trackInset,
      label: '恢复默认$description',
      onChanged: onChanged,
      onDragChanged: onDragChanged,
      onReset: onReset,
      buildSlider: slider,
    );
  }

  Widget _footerWithBody({
    required Widget body,
    bool usesOriginalPages = false,
    bool showChrome = true,
    required int page,
    required int pageCount,
    String? chapterTitle,
    required ValueChanged<int> onPageSelected,
    required VoidCallback? onOutline,
    ValueChanged<FlowReaderAnchor>? onRestoreFlow,
  }) {
    final pdf = _isPdfDocument || usesOriginalPages;
    final section = chapterTitle?.trim() ?? '';
    final sectionNumber = RegExp(
      r'^第\s*[0-9零〇一二三四五六七八九十百千]+\s*[章节部卷篇回]',
    ).stringMatch(section);
    String locationLabel(int number) => pdf
        ? '$number / $pageCount'
        : number != page || section.isEmpty
        ? '第 $number 章'
        : sectionNumber ?? section;
    final maxPage = math.max(1, pageCount).toDouble();
    void jumpTo(int destination) {
      final closeProgress = _activePanel == _ReaderPanel.progress;
      if (closeProgress) _closeReaderPanel();
      if (destination != page || !closeProgress) {
        setState(() {
          _progressPreview.value = null;
          if (destination != page) {
            _pageBeforeJump = page;
            _flowPositionBeforeJump = _flowPosition;
            _pdfPositionBeforeJump = pdf ? _pdfReadingAnchor : null;
          }
        });
      }
      if (destination != page) onPageSelected(destination);
    }

    void restoreJump(int previous) {
      final position = _flowPositionBeforeJump;
      final original = _pdfPositionBeforeJump;
      _closeReaderPanel();
      setState(() {
        _pageBeforeJump = null;
        _flowPositionBeforeJump = null;
        _pdfPositionBeforeJump = null;
      });
      if (usesOriginalPages && original?.pageNumber == previous) {
        unawaited(_openConvertedPage(previous, position: original));
      } else if (_isPdfDocument &&
          original != null &&
          original.pageNumber == previous) {
        if (_inkEditing) return;
        _rememberPdfPosition(
          previous,
          blockId: original.blockId,
          characterOffset: original.characterOffset,
          pageFraction: original.pageFraction,
        );
        unawaited(_goToPdfReaderPage(previous, recordProgress: false));
      } else if (position != null && onRestoreFlow != null) {
        onRestoreFlow(position);
      } else {
        onPageSelected(previous);
      }
    }

    final size = _readerWide ? 18.0 : 14.0;
    Widget progressPanel() => SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<double?>(
            valueListenable: _progressPreview,
            builder: (context, preview, _) {
              final position = preview ?? page.toDouble();
              final shownPage = position.round();
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5, bottom: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            pdf
                                ? '第 $shownPage 页 / 共 $pageCount 页'
                                : '第 $shownPage 章 / 共 $pageCount 章',
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        Text('${(shownPage * 100 / pageCount).round()}%'),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 38,
                    child: _readerSlider(
                      value: position,
                      min: 1,
                      max: maxPage,
                      onChanged: pageCount > 1
                          ? (value) => _progressPreview.value = value
                          : null,
                      onChangeEnd: pageCount > 1
                          ? (value) => jumpTo(value.round())
                          : null,
                      description: '阅读进度',
                      formatValue: (value) => '${value.round()} / $pageCount',
                    ),
                  ),
                ],
              );
            },
          ),
          DefaultTextStyle.merge(
            style: TextStyle(color: _readerMuted, fontSize: size - 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(pdf ? '第 1 页' : '第 1 章'),
                Text('第 $pageCount ${pdf ? '页' : '章'}'),
              ],
            ),
          ),
          if (_pageBeforeJump case final previous?)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => restoreJump(previous),
                icon: _readerIcon('assets/icons/chat_note_editor/undo.svg', 21),
                label: Text(pdf ? '返回第 $previous 页' : '返回跳转前位置'),
                style: TextButton.styleFrom(
                  foregroundColor: _ink,
                  padding: const EdgeInsets.only(right: 14),
                  textStyle: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontSize: size),
                ),
              ),
            )
          else
            const SizedBox(height: 14),
        ],
      ),
    );
    final chromeVisible = showChrome && !widget.immersive && !_inkEditing;
    final panel = chromeVisible ? _activePanel : null;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final panelBottom = _readerNavHeight + bottomInset;
    return LayoutBuilder(
      builder: (context, dimensions) => Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: panel != null,
            child: ExcludeSemantics(
              excluding: panel != null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap:
                    showChrome &&
                        panel == null &&
                        !_inkEditing &&
                        widget.onToggleImmersive != null
                    ? _toggleReaderChrome
                    : null,
                child: body,
              ),
            ),
          ),
          if (chromeVisible)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Material(color: _readerChrome, child: _toolbar(context)),
            ),
          if (chromeVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Material(
                color: _readerChrome,
                child: Padding(
                  padding: EdgeInsets.only(bottom: bottomInset),
                  child: _readerBottomNavigation(
                    onOutline: onOutline,
                    onProgress: pageCount > 0
                        ? () => _openReaderPanel(_ReaderPanel.progress)
                        : null,
                  ),
                ),
              ),
            ),
          if (showChrome && widget.immersive && !_inkEditing && pageCount > 0)
            PositionedDirectional(
              end: _readerSideInset,
              bottom: bottomInset + 8,
              child: IgnorePointer(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    locationLabel(page),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: _readerMuted),
                  ),
                ),
              ),
            ),
          if (panel != null) ...[
            Positioned.fill(
              bottom: panelBottom,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeReaderPanel,
                excludeFromSemantics: true,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: panelBottom,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(0, dimensions.maxHeight - panelBottom),
                ),
                child: panel == _ReaderPanel.outline
                    ? _outlineSheet(
                        dimensions.maxHeight - panelBottom,
                        locationLabel(page),
                      )
                    : _readerPanel(panel, switch (panel) {
                        _ReaderPanel.outline => const SizedBox.shrink(),
                        _ReaderPanel.progress => progressPanel(),
                        _ReaderPanel.display => _displayPanel(),
                      }),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _outlineSheet(double availableHeight, String location) {
    final full = math.max(0.0, availableHeight);
    final surface = _dark ? _readerPanelSurface : const Color(0xFFF8F9FA);
    final bookTitle = _source.displayName.trim().isNotEmpty
        ? _source.displayName
        : widget.bookTitle;
    final compact = math.min(
      full,
      MediaQuery.sizeOf(context).height * .33 + (_readerWide ? 72 : 46),
    );
    final travel = full - compact;
    void snap(bool expand) => setState(() {
      _outlineDragging = false;
      _outlineExtent = expand ? 1 : 0;
    });
    return AnimatedContainer(
      duration: _outlineDragging
          ? Duration.zero
          : const Duration(milliseconds: 170),
      curve: Curves.easeOut,
      height: compact + travel * _outlineExtent,
      child: Material(
        color: surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: _readerRule),
        ),
        child: Column(
          children: [
            ColoredBox(
              color: surface,
              child: Semantics(
                button: true,
                label: _outlineExtent >= .5 ? '收起目录' : '展开目录',
                onTap: () => snap(_outlineExtent < .5),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => snap(_outlineExtent < .5),
                  onVerticalDragStart: (_) =>
                      setState(() => _outlineDragging = true),
                  onVerticalDragUpdate: (details) {
                    if (travel > 0) {
                      setState(
                        () => _outlineExtent =
                            (_outlineExtent - details.delta.dy / travel).clamp(
                              0.0,
                              1.0,
                            ),
                      );
                    }
                  },
                  onVerticalDragEnd: (details) {
                    final speed = details.primaryVelocity ?? 0;
                    snap(speed.abs() > 250 ? speed < 0 : _outlineExtent >= .5);
                  },
                  onVerticalDragCancel: () => snap(_outlineExtent >= .5),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      _readerSideInset,
                      10,
                      _readerSideInset,
                      9,
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: _readerRule,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 11),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '目录',
                                style: TextStyle(
                                  color: _ink,
                                  fontSize: _readerWide ? 23 : 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              location,
                              style: TextStyle(color: _readerMuted),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: _readerSideInset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Divider(height: 1, color: _readerRule),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: _readerWide ? 12 : 9,
                    ),
                    child: Semantics(
                      header: true,
                      child: Text(
                        bookTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _ink,
                          fontSize: _readerWide ? 18 : 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  Divider(height: 1, color: _readerRule),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: _readerSideInset),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () =>
                        setState(() => _outlineShowsAnnotations = false),
                    child: Text(
                      '章节',
                      style: TextStyle(
                        color: _outlineShowsAnnotations ? _readerMuted : _ink,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _outlineShowsAnnotations = true),
                    child: Text(
                      '本书注释',
                      style: TextStyle(
                        color: _outlineShowsAnnotations ? _ink : _readerMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ClipRect(
                child: Material(
                  color: surface,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: _readerSideInset * .6,
                    ),
                    child: Builder(
                      builder: _outlineShowsAnnotations
                          ? widget.annotationList
                          : _outlinePanel!,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readerBottomNavigation({
    required VoidCallback? onOutline,
    required VoidCallback? onProgress,
  }) {
    Widget action(
      _ReaderPanel panel,
      String icon,
      String label,
      VoidCallback? pressed,
    ) {
      final active = _activePanel == panel;
      final foreground = pressed == null ? _readerMuted : _ink;
      return Expanded(
        child: Semantics(
          selected: active,
          button: true,
          enabled: pressed != null,
          child: InkWell(
            onTap: pressed,
            child: Center(
              child: Ink(
                padding: EdgeInsets.symmetric(
                  horizontal: _readerWide ? 24 : 8,
                  vertical: _readerWide ? 7 : 4,
                ),
                decoration: active
                    ? BoxDecoration(
                        color: _readerSelected,
                        borderRadius: BorderRadius.circular(
                          _readerWide ? 13 : 10,
                        ),
                      )
                    : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _readerIcon(icon, _readerWide ? 25 : 18, color: foreground),
                    SizedBox(width: _readerWide ? 13 : 6),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: _readerWide ? 18 : 14,
                          fontWeight: FontWeight.w500,
                        ),
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

    Widget divider() =>
        Container(color: _readerRule, width: 1, height: _readerWide ? 24 : 18);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _readerRule)),
      ),
      child: SizedBox(
        height: _readerNavHeight,
        child: Row(
          children: [
            action(
              _ReaderPanel.outline,
              'assets/icons/note_format/format_list_bulleted.svg',
              '目录',
              onOutline,
            ),
            divider(),
            action(
              _ReaderPanel.progress,
              'assets/images/reading_companion_progress.svg',
              '进度',
              onProgress,
            ),
            divider(),
            action(
              _ReaderPanel.display,
              'assets/icons/chat_note_editor/text-aa.svg',
              '显示',
              () => _openReaderPanel(_ReaderPanel.display),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readerPanel(_ReaderPanel panel, Widget content) {
    final title = switch (panel) {
      _ReaderPanel.outline => '目录',
      _ReaderPanel.progress => '阅读进度',
      _ReaderPanel.display => '显示',
    };
    final outline = panel == _ReaderPanel.outline;
    return Material(
      color: _readerPanelSurface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: _readerRule),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: outline ? _readerSideInset - 12 : _readerSideInset,
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: _ink, fontSize: _readerWide ? 18 : 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: _readerWide
                      ? switch (panel) {
                          _ReaderPanel.outline => 72,
                          _ReaderPanel.display => _isPdfDocument ? 54 : 66,
                          _ReaderPanel.progress => 54,
                        }
                      : 46,
                ),
                child: Padding(
                  padding: EdgeInsetsDirectional.only(start: outline ? 9 : 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: _readerWide ? 23 : 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭$title',
                        onPressed: _closeReaderPanel,
                        icon: _readerIcon(
                          'assets/icons/extension_market/detail/close.svg',
                          _readerWide ? 25 : 21,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (panel != _ReaderPanel.progress)
                Divider(height: 1, thickness: 1, color: _readerRule),
              Flexible(child: content),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shortcut(String label, String tooltip, VoidCallback onPressed) {
    final diameter = MediaQuery.sizeOf(context).width >= 600 ? 46.0 : 44.0;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: _dark ? const Color(0xFF3B3C3F) : const Color(0xFF393A3C),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox.square(
            dimension: diameter,
            child: Center(
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFFFDFDFD),
                  fontWeight: FontWeight.w600,
                  fontSize: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context, {bool sourceFailed = false}) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final showDoodleLabel = MediaQuery.sizeOf(context).width >= 380;
    final showPdf = _isCompanionPdf(_source) || widget.onSwitchFormat != null;
    final selectedColor = _dark
        ? const Color(0xFFE6E3DC)
        : const Color(0xFF202020);
    final loadingColor = _dark
        ? const Color(0xFF3D3D3D)
        : const Color(0xFFE4E4E4);
    final selectedInk = _dark ? const Color(0xFF202020) : Colors.white;
    final library = widget.onChooseSource;
    Widget segment(
      bool pdf,
      String label, {
      required bool loading,
      bool available = true,
    }) {
      final selected = pdf != _isSelectingEbook;
      final retry = !pdf && _canRetryEbook;
      // A second tap can arrive before this toolbar rebuilds. Keep the
      // selected PDF/reflow segment listening even in a single-source book.
      final canActivate = selected
          ? library != null || _isCompanionPdf(_source)
          : !pdf || _isCompanionPdf(_source) || widget.onSwitchFormat != null;
      final VoidCallback? onTap = !loading && available && canActivate
          ? () => _activateFormatButton(pdf)
          : null;
      return Tooltip(
        message: loading
            ? '正在载入$label'
            : retry
            ? '$_ebookError，点此重试'
            : selected && _hasPendingFormatSwitch
            ? '取消切换，保留$label'
            : selected && library != null
            ? '切换阅读资料'
            : label,
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          selected: selected,
          enabled: onTap != null,
          value: loading ? '正在载入' : null,
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: onTap == null
                ? null
                : () {
                    _closeReaderPanel();
                    onTap();
                  },
            child: SizedBox(
              width: wide ? (pdf ? 64 : 80) : (pdf ? 48 : 70),
              height: 44,
              child: Center(
                child: SizedBox(
                  height: wide ? 30 : 28,
                  width: double.infinity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (loading || selected)
                        IgnorePointer(
                          child: SvgPicture.asset(
                            'assets/images/reading_companion_format_fill.svg',
                            fit: BoxFit.fill,
                            excludeFromSemantics: true,
                            colorFilter: ColorFilter.mode(
                              loading ? loadingColor : selectedColor,
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              retry ? '重试' : label,
                              maxLines: 1,
                              style: TextStyle(
                                color: selected && !loading
                                    ? selectedInk
                                    : _ink,
                                fontSize: wide ? 14 : 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (loading)
                        PositionedDirectional(
                          start: 4,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: SizedBox.square(
                              dimension: 8,
                              child: ExcludeSemantics(
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.4,
                                  color: _ink,
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
          ),
        ),
      );
    }

    Widget formats({
      bool pdfBusy = false,
      bool ebookBusy = false,
      bool ebookAvailable = true,
    }) => Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          top: wide ? 5 : 6,
          bottom: wide ? 5 : 6,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _dark ? _paperDark : Colors.white,
                border: Border.all(color: _ink),
                borderRadius: BorderRadius.circular(9),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showPdf) ...[
                segment(true, 'PDF', loading: pdfBusy),
                const SizedBox(width: 2),
              ],
              segment(
                false,
                '电子书',
                loading: ebookBusy,
                available: ebookAvailable,
              ),
            ],
          ),
        ),
      ],
    );
    final pdfLoad = _isCompanionPdf(_source)
        ? _selectablePdfReference.resolveListenable()
        : null;
    final tools = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!_inkEditing) ...[
          Material(
            type: MaterialType.transparency,
            child: pdfLoad != null
                ? ListenableBuilder(
                    listenable: pdfLoad,
                    builder: (context, _) {
                      final available = !sourceFailed && pdfLoad.error == null;
                      return formats(
                        pdfBusy:
                            available &&
                            (_returningToPdf || _pdfDocumentRef == null),
                        ebookBusy:
                            available &&
                            _isPdfDocument &&
                            _ebookError == null &&
                            (!_ebookLayoutReady || _ebookSwitchPending),
                        ebookAvailable: available,
                      );
                    },
                  )
                : formats(ebookBusy: !sourceFailed && !_ebookLayoutReady),
          ),
          if (wide) ...[
            const SizedBox(width: 16),
            SizedBox(
              height: 19,
              child: VerticalDivider(
                width: 1,
                color: _ink.withValues(alpha: .22),
              ),
            ),
            const SizedBox(width: 8),
          ],
          TextButton(
            onPressed: !_inkLoaded && !_inkLoadFailed ? null : _startInk,
            style: TextButton.styleFrom(
              foregroundColor: _ink,
              minimumSize: const Size(44, 44),
              padding: EdgeInsets.symmetric(horizontal: wide ? 8 : 4),
            ),
            child: Tooltip(
              message: '涂鸦',
              excludeFromSemantics: showDoodleLabel,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.asset(
                    'assets/images/reading_companion_doodle.svg',
                    width: wide ? 25 : 20,
                    height: wide ? 25 : 20,
                    colorFilter: ColorFilter.mode(
                      _ink.withValues(alpha: .73),
                      BlendMode.srcIn,
                    ),
                  ),
                  if (showDoodleLabel) ...[
                    const SizedBox(width: 6),
                    Text('涂鸦', style: TextStyle(fontSize: wide ? 16 : 13)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
    return widget.toolbarBuilder?.call(context, tools) ??
        SizedBox(
          height: readingCompanionToolbarHeight(context),
          child: Align(alignment: Alignment.centerRight, child: tools),
        );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: _readerTheme(context).copyWith(
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: _dark ? _darkSelectionColor : const Color(0x33212121),
        selectionHandleColor: _ink,
      ),
    ),
    child: FutureBuilder(
      future: _loading,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final document = data?.document;
        final Widget body;
        if (snapshot.connectionState != ConnectionState.done) {
          body = const _ReadingPlaceholder();
        } else if (data == null) {
          body = _ReaderStatus(
            '无法读取这份资料',
            action: widget.onChooseSource != null ? '选择其他资料' : '打开本书资料',
            onAction: widget.onChooseSource ?? widget.onOpenLibrary,
          );
        } else {
          body = document == null
              ? _readerBody(data.anchor)
              : _flow(document, data.anchor);
        }
        return Material(
          color: _dark ? _paperDark : Colors.white,
          child: Stack(
            fit: StackFit.expand,
            children: [
              body,
              if (data == null && !widget.immersive && !_inkEditing)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Material(
                    color: _readerChrome,
                    child: _toolbar(context, sourceFailed: snapshot.hasError),
                  ),
                ),
              if (data != null &&
                  !widget.immersive &&
                  !_readerPanelOpen &&
                  !_inkEditing)
                Positioned(
                  right: MediaQuery.sizeOf(context).width >= 600 ? 36 : 16,
                  bottom: _readerFooterHeight + 5,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 12,
                    children: [
                      if (_foreignSource)
                        _shortcut(
                          _translationEnabled ? '原' : '译',
                          _translationEnabled ? '还原当前正文' : '连续翻译',
                          _toggleTranslation,
                        ),
                      if (widget.onFreeChat case final openChat?)
                        _shortcut('AI', 'AI 问答', openChat),
                    ],
                  ),
                ),
              if (!widget.immersive &&
                  !_inkEditing &&
                  !_readerPanelOpen &&
                  (_translationPending || _translationError != null))
                Positioned(
                  left: 12,
                  bottom: _readerFooterHeight + 5,
                  child: _translationError == null
                      ? const Chip(label: Text('翻译中'))
                      : ActionChip(
                          label: Text(_translationError!),
                          onPressed: _scheduleTranslation,
                        ),
                ),
              if (_inkEditing) Positioned.fill(child: _buildDrawingControls()),
            ],
          ),
        );
      },
    ),
  );
}

class _ReaderDisplaySlider extends StatefulWidget {
  const _ReaderDisplaySlider({
    super.key,
    required this.value,
    required this.defaultFraction,
    required this.trackInset,
    required this.label,
    required this.onChanged,
    this.onDragChanged,
    required this.onReset,
    required this.buildSlider,
  });

  final double value;
  final double defaultFraction;
  final double trackInset;
  final String label;
  final ValueChanged<double> onChanged;
  final ValueChanged<bool>? onDragChanged;
  final VoidCallback onReset;
  final Widget Function(
    double value,
    ValueChanged<double> onChanged,
    ValueChanged<double> onChangeEnd,
  )
  buildSlider;

  @override
  State<_ReaderDisplaySlider> createState() => _ReaderDisplaySliderState();
}

class _ReaderDisplaySliderState extends State<_ReaderDisplaySlider> {
  int? _markerPointer;
  Offset? _markerDown;
  double? _lastValue;

  void _reset() {
    _lastValue = null;
    widget.onReset();
  }

  void _update(double value) {
    if (_markerPointer != null || value == (_lastValue ?? widget.value)) return;
    _lastValue = value;
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    const height = 48.0;
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fraction = Directionality.of(context) == TextDirection.rtl
              ? 1 - widget.defaultFraction
              : widget.defaultFraction;
          final marker = Offset(
            widget.trackInset +
                (constraints.maxWidth - 2 * widget.trackInset) * fraction,
            height / 2,
          );
          return Listener(
            onPointerDown: (event) {
              _lastValue = null;
              widget.onDragChanged?.call(true);
              final delta = event.localPosition - marker;
              if (_markerPointer == null &&
                  delta.dx.abs() <= 10 &&
                  delta.dy.abs() <= 16) {
                _markerPointer = event.pointer;
                _markerDown = event.localPosition;
              }
            },
            onPointerMove: (event) {
              if (_markerPointer == event.pointer &&
                  (event.localPosition - _markerDown!).distance > 6) {
                _markerPointer = null;
              }
            },
            onPointerUp: (event) {
              // Let the native slider finish this event before deciding whether
              // a tap on the default marker should replace its numeric value.
              scheduleMicrotask(() {
                if (!mounted) return;
                if (_markerPointer == event.pointer) {
                  _markerPointer = null;
                  _reset();
                }
                _lastValue = null;
                widget.onDragChanged?.call(false);
              });
            },
            onPointerCancel: (event) {
              if (_markerPointer == event.pointer) _markerPointer = null;
              _lastValue = null;
              widget.onDragChanged?.call(false);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                widget.buildSlider(widget.value, _update, _update),
                Positioned(
                  left: marker.dx - 22,
                  top: 0,
                  bottom: 0,
                  width: 44,
                  child: Semantics(
                    button: true,
                    label: widget.label,
                    onTap: _reset,
                    child: const IgnorePointer(
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xFFA8A8A8),
                            shape: BoxShape.circle,
                          ),
                          child: SizedBox.square(dimension: 4),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CompanionInkRecord {
  const _CompanionInkRecord(
    this.size,
    this.text,
    this.strokes, [
    this.document,
  ]);

  final Size size;
  final String? text;
  final List<PageStroke> strokes;

  final Map<String, Object?>? document;

  bool get isEmpty =>
      strokes.isEmpty && (document?['drawables'] as List?)?.isNotEmpty != true;

  DrawingAnnotationLayer createLayer() => DrawingAnnotationLayer(
    size: size,
    document: document,
    initial: [
      for (final stroke in strokes)
        if (stroke.points.isNotEmpty)
          FreeStyleDrawable(
            path: [
              for (final point in stroke.points)
                Offset(point.dx * size.width, point.dy * size.height),
            ],
            color: Color(stroke.colorValue).withValues(alpha: stroke.opacity),
            strokeWidth: stroke.width,
          ),
    ],
  );

  String encode() => jsonEncode({
    if (document != null) 'drawingDocument': document,
    'width': size.width,
    'height': size.height,
    'text': text,
    'strokes': strokes.map((item) => item.toJson()).toList(),
  });

  static _CompanionInkRecord? fromJson(String json) {
    try {
      final value = jsonDecode(json) as Map;
      return _CompanionInkRecord(
        Size(
          (value['width'] as num).toDouble(),
          (value['height'] as num).toDouble(),
        ),
        value['text'] as String?,
        (value['strokes'] as List)
            .whereType<Map>()
            .map(PageStroke.fromJson)
            .toList(),
        (value['drawingDocument'] as Map?)?.cast<String, Object?>(),
      );
    } on Object {
      return null;
    }
  }
}

TextSelectionHandleType _pdfSelectionHandleType(PdfTextSelectionAnchor anchor) {
  final isStart = anchor.type == PdfTextSelectionAnchorType.a;
  final rightToLeft =
      anchor.direction == PdfTextDirection.rtl ||
      anchor.direction == PdfTextDirection.vrtl;
  return isStart != rightToLeft
      ? TextSelectionHandleType.left
      : TextSelectionHandleType.right;
}

Widget _buildPdfSelectionHandle(
  BuildContext context,
  PdfTextSelectionAnchor anchor,
  PdfViewerTextSelectionAnchorHandleState state,
) => _companionTextSelectionControls.buildHandle(
  context,
  _pdfSelectionHandleType(anchor),
  0,
);

Offset _pdfSelectionHandleOffset(
  BuildContext context,
  PdfTextSelectionAnchor anchor,
  PdfViewerTextSelectionAnchorHandleState state,
) {
  final type = _pdfSelectionHandleType(anchor);
  final controls = _companionTextSelectionControls;
  final tip = controls.getHandleAnchor(type, 0);
  final size = controls.getHandleSize(0);
  return Offset(
    type == TextSelectionHandleType.left ? size.width - tip.dx : -tip.dx,
    anchor.type == PdfTextSelectionAnchorType.a
        ? size.height - tip.dy
        : -tip.dy,
  );
}

class _CompanionTextSelectionControls extends MaterialTextSelectionControls
    with TextSelectionHandleControls {}

final _companionTextSelectionControls = _CompanionTextSelectionControls();

Widget _selectionToolbar({
  required Offset above,
  required Offset? below,
  required VoidCallback onCopy,
  required VoidCallback onAnnotate,
  required VoidCallback onAsk,
}) => TextSelectionToolbar(
  anchorAbove: above,
  anchorBelow: below ?? above,
  toolbarBuilder: (context, child) => child,
  children: [
    Builder(
      builder: (context) => MessageSelectionActionCard(
        primaryLabel: 'AI',
        primaryAsset: 'assets/icons/chat_note_editor/sparkle.svg',
        copyFirst: true,
        dark: Theme.of(context).brightness == Brightness.dark,
        onPrimaryAction: onAsk,
        onCopy: onCopy,
        onAnnotate: onAnnotate,
      ),
    ),
  ],
);

class _CompanionHistory extends StatelessWidget {
  const _CompanionHistory({
    required this.controller,
    required this.messages,
    required this.streamingReply,
    required this.messageKeys,
  });

  final ScrollController controller;
  final List<AiConversationMessage> messages;
  final ValueListenable<String> streamingReply;
  final Map<String, GlobalKey> messageKeys;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: streamingReply,
    builder: (context, streamed, _) {
      final turns = messages
          .where((message) => !message.isDeletedMarker)
          .toList();
      return ChatMessageScrollView(
        controller: controller,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(5, 16, 5, 12),
            sliver: SliverList.builder(
              itemCount: turns.length + (streamed.isEmpty ? 0 : 1),
              itemBuilder: (context, index) {
                if (streamed.isNotEmpty && index == 0) {
                  return _answer(streamed);
                }
                final reverseIndex = index - (streamed.isEmpty ? 0 : 1);
                final turn = turns[turns.length - 1 - reverseIndex];
                final text = turn.displayText ?? turn.text;
                return KeyedSubtree(
                  key: messageKeys.putIfAbsent(turn.id, () => GlobalKey()),
                  child: turn.isUser
                      ? _question(turn, text)
                      : _assistantTurn(turn, text),
                );
              },
            ),
          ),
        ],
      );
    },
  );

  Widget _question(AiConversationMessage message, String text) => Align(
    alignment: Alignment.centerRight,
    child: FractionallySizedBox(
      widthFactor: .86,
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 13),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F1F1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final attachment in message.attachments)
                Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF555555),
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              if (text.isNotEmpty)
                Text(text, style: const TextStyle(fontSize: 16, height: 1.5)),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _assistantTurn(AiConversationMessage message, String text) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _answer(visibleChatAssistantText(text)),
      for (final artifact in message.outputArtifacts)
        if (artifact['media_type']?.toString().startsWith('image/') == true &&
            (artifact['task_id']?.toString() ?? '').isNotEmpty &&
            (artifact['id']?.toString() ?? '').isNotEmpty)
          _CompanionImageArtifact(
            key: ValueKey((artifact['task_id'], artifact['id'])),
            taskId: artifact['task_id'].toString(),
            artifactId: artifact['id'].toString(),
            name: artifact['name']?.toString() ?? '创建的图像',
          ),
    ],
  );

  Widget _answer(String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: GptMarkdown(
        text,
        style: const TextStyle(
          fontSize: 16,
          height: 1.65,
          color: Color(0xFF282828),
        ),
      ),
    );
  }
}

class _CompanionImageArtifact extends StatefulWidget {
  const _CompanionImageArtifact({
    super.key,
    required this.taskId,
    required this.artifactId,
    required this.name,
  });

  final String taskId;
  final String artifactId;
  final String name;

  @override
  State<_CompanionImageArtifact> createState() =>
      _CompanionImageArtifactState();
}

class _CompanionImageArtifactState extends State<_CompanionImageArtifact> {
  late Future<Uint8List> _preview = _download();

  Future<Uint8List> _download() => CapabilityCloudSync.instance
      .downloadTaskArtifact(widget.taskId, widget.artifactId, cacheImage: true);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: FutureBuilder(
      future: _preview,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return TextButton(
            onPressed: () {
              setState(() {
                _preview = _download();
              });
            },
            child: const Text('图片预览不可用，点击重试'),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return const SizedBox(
            height: 90,
            child: ColoredBox(color: Color(0xFFF1F1F1)),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(
            bytes,
            semanticLabel: widget.name,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Text('无法预览 ${widget.name}'),
          ),
        );
      },
    ),
  );
}

class _PassageQuote extends StatelessWidget {
  const _PassageQuote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      border: Border(left: BorderSide(color: Color(0xFFBBBBBB), width: 2)),
    ),
    padding: const EdgeInsets.only(left: 11),
    child: Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Color(0xFF515151),
        fontSize: 15,
        height: 1.65,
      ),
    ),
  );
}

Future<int?> _chooseReaderItem(
  BuildContext context, {
  required String title,
  required List<String> labels,
  required int activeIndex,
  List<int> levels = const [],
  Set<int> groupLabels = const {},
}) => showDialog<int>(
  context: context,
  builder: (context) => AlertDialog(
    backgroundColor: Colors.white,
    title: Text(title),
    contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
    content: SizedBox(
      width: 380,
      height: math.min(420.0, labels.length * 56.0),
      child: ListView.builder(
        itemCount: labels.length,
        itemBuilder: (context, index) => ListTile(
          title: Text(labels[index]),
          contentPadding: levels.isEmpty
              ? null
              : EdgeInsetsDirectional.only(
                  start: 16 + 12.0 * levels[index].clamp(0, 6),
                  end: 16,
                ),
          enabled: !groupLabels.contains(index),
          selected: index == activeIndex,
          selectedColor: const Color(0xFF262626),
          selectedTileColor: const Color(0xFFF1F1F1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          onTap: () => Navigator.pop(context, index),
        ),
      ),
    ),
  ),
);

class _ReaderOutlineList extends StatefulWidget {
  const _ReaderOutlineList({
    super.key,
    required this.titles,
    required this.current,
    required this.onSelected,
    required this.levels,
    required this.groupLabels,
    required this.pages,
    required this.readingPage,
    required this.wide,
    required this.ink,
    required this.rule,
    required this.selectedColor,
  });

  final List<String> titles;
  final int current;
  final ValueChanged<int> onSelected;
  final List<int> levels;
  final Set<int> groupLabels;
  final List<int?> pages;
  final int? readingPage;
  final bool wide;
  final Color ink;
  final Color rule;
  final Color selectedColor;

  @override
  State<_ReaderOutlineList> createState() => _ReaderOutlineListState();
}

class _ReaderOutlineListState extends State<_ReaderOutlineList> {
  ScrollController? _scroll;
  final _collapsed = <int>{};
  bool get _hasLevels => widget.levels.length == widget.titles.length;

  bool _hasChildren(int index) =>
      _hasLevels &&
      index + 1 < widget.levels.length &&
      widget.levels[index + 1] > widget.levels[index];

  @override
  void initState() {
    super.initState();
    if (!_hasLevels) return;
    final open = <int>{};
    final current = widget.current;
    if (current >= 0 && current < widget.levels.length) {
      open.add(current);
      var depth = widget.levels[current];
      for (var index = current - 1; index >= 0 && depth > 0; index--) {
        if (widget.levels[index] >= depth) continue;
        open.add(index);
        depth = widget.levels[index];
      }
    }
    for (var index = 0; index < widget.levels.length; index++) {
      if (_hasChildren(index) && !open.contains(index)) {
        _collapsed.add(index);
      }
    }
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final titleSize = widget.wide ? 18.0 : 14.0;
    final subtitleSize = titleSize - 3;
    final textScaler = MediaQuery.textScalerOf(context);
    final rowHeight = math.max(
      widget.wide ? 51.0 : 44.0,
      textScaler.scale(titleSize) + 22,
    );
    final selectedExtra = textScaler.scale(subtitleSize) + 9;
    final visible = <int>[];
    int? hiddenBelow;
    for (var index = 0; index < widget.titles.length; index++) {
      final level = _hasLevels ? widget.levels[index] : 0;
      if (hiddenBelow != null && level > hiddenBelow) continue;
      hiddenBelow = _collapsed.contains(index) ? level : null;
      visible.add(index);
    }
    final subtitle = switch (widget.readingPage) {
      final page? => '正在读 · 第 $page 页',
      null => '正在读',
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final currentIndex = visible.indexOf(widget.current);
        final targetOffset = currentIndex < 0
            ? 0.0
            : currentIndex * rowHeight -
                  (constraints.maxHeight - rowHeight - selectedExtra) / 2;
        final maxOffset = math.max(
          0.0,
          visible.length * rowHeight +
              (currentIndex < 0 ? 0 : selectedExtra) -
              constraints.maxHeight,
        );
        final scroll = _scroll ??= ScrollController(
          keepScrollOffset: false,
          initialScrollOffset: targetOffset.clamp(0.0, maxOffset).toDouble(),
        );
        return ListView.builder(
          controller: scroll,
          padding: EdgeInsets.zero,
          itemCount: visible.length,
          itemExtentBuilder: (row, _) =>
              rowHeight + (widget.current == visible[row] ? selectedExtra : 0),
          itemBuilder: (context, row) {
            final index = visible[row];
            final selected = widget.current == index;
            final group = widget.groupLabels.contains(index);
            final level = _hasLevels ? widget.levels[index] : 0;
            final hasChildren = _hasChildren(index);
            final page = widget.pages.isEmpty ? null : widget.pages[index];
            void toggleGroup() => setState(() {
              if (!_collapsed.remove(index)) _collapsed.add(index);
            });
            final foreground = group
                ? widget.ink.withValues(alpha: .68)
                : widget.ink;
            return Semantics(
              selected: selected,
              header: group,
              child: InkWell(
                onTap: group
                    ? (hasChildren ? toggleGroup : null)
                    : () => widget.onSelected(index),
                child: Ink(
                  decoration: selected
                      ? BoxDecoration(
                          color: widget.selectedColor,
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x1C000000),
                              blurRadius: 3,
                              offset: Offset(0, 1),
                            ),
                          ],
                          borderRadius: BorderRadius.circular(8),
                        )
                      : BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: widget.rule),
                          ),
                        ),
                  padding: EdgeInsetsDirectional.only(
                    start: 10 + (widget.wide ? 28.0 : 20.0) * level.clamp(0, 4),
                    end: 10,
                  ),
                  height: rowHeight + (selected ? selectedExtra : 0),
                  child: Row(
                    children: [
                      if (hasChildren || level > 0)
                        SizedBox(
                          width: 44,
                          child: hasChildren
                              ? IconButton(
                                  tooltip: _collapsed.contains(index)
                                      ? '展开章节'
                                      : '收起章节',
                                  onPressed: toggleGroup,
                                  icon: SvgPicture.asset(
                                    _collapsed.contains(index)
                                        ? 'assets/icons/extension_market/detail/caret-right.svg'
                                        : 'assets/icons/extension_market/detail/caret-down.svg',
                                    width: 15,
                                    height: 15,
                                    colorFilter: ColorFilter.mode(
                                      foreground,
                                      BlendMode.srcIn,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              widget.titles[index],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: titleSize,
                                fontWeight: selected || group
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                            if (selected) ...[
                              const SizedBox(height: 3),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: subtitleSize,
                                  color: foreground.withValues(alpha: .8),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (page != null) ...[
                        const SizedBox(width: 12),
                        Text(
                          '$page',
                          style: TextStyle(
                            color: foreground,
                            fontSize: titleSize,
                            fontWeight: selected
                                ? FontWeight.w500
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ReadingPlaceholder extends StatelessWidget {
  const _ReadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: '正在打开阅读资料',
      child: ColoredBox(
        color: dark ? const Color(0xFF191B1E) : Colors.white,
        child: ListView(
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 36),
          children: [
            for (final width in const [.36, .90, .95, .76, .88, .60])
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: FractionallySizedBox(
                  widthFactor: width,
                  alignment: Alignment.centerLeft,
                  child: ColoredBox(
                    color: dark
                        ? const Color(0xFF282B2E)
                        : const Color(0xFFF1F1F1),
                    child: const SizedBox(height: 9),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReaderStatus extends StatelessWidget {
  const _ReaderStatus(
    this.text, {
    this.action,
    this.onAction,
    this.secondaryAction,
    this.onSecondaryAction,
  });

  final String text;
  final String? action;
  final VoidCallback? onAction;
  final String? secondaryAction;
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: const TextStyle(color: Color(0xFF656565))),
        if (action != null && onAction != null)
          TextButton(onPressed: onAction, child: Text(action!)),
        if (secondaryAction != null && onSecondaryAction != null)
          TextButton(
            onPressed: onSecondaryAction,
            child: Text(secondaryAction!),
          ),
      ],
    ),
  );
}

class _ReaderButton extends StatelessWidget {
  const _ReaderButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final String icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    constraints: const BoxConstraints.tightFor(width: 44, height: 44),
    icon: _readerIcon(icon),
  );
}

Widget _readerIcon(String asset) => SvgPicture.asset(
  asset,
  width: 18,
  height: 18,
  excludeFromSemantics: true,
  colorFilter: const ColorFilter.mode(Color(0xFF4D4D4D), BlendMode.srcIn),
);
