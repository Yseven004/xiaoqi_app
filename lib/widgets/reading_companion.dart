import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_painter/flutter_painter.dart' show FreeStyleDrawable;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../features/ai_study_annotation/data/ai_conversation_history.dart';
import '../features/ai_study_annotation/domain/ai_chat_process.dart';
import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/book_source.dart';
import '../models/note.dart';
import '../models/page_annotation.dart';
import '../pages/drawing_board_page.dart';
import '../models/pdf_catalog.dart';
import '../models/reader_pagination.dart';
import '../models/xiaoqi_document.dart';
import '../services/book_library_service.dart';
import '../services/companion_pdf_reflow.dart';
import '../services/database_service.dart';
import '../services/reader_pagination_preferences.dart';
import '../services/reading_task_context.dart';
import '../services/reading_companion_translation.dart';
import '../services/source_document_loader.dart';
import 'app_toast.dart';
import 'book_text_selection_controls.dart';
import 'chat_annotation_navigation.dart';
import 'chat_message_scroll_view.dart';
import 'companion_ink_surface.dart';
import 'message_selection_action_card.dart';
import 'pdf_page_canvas.dart'
    show
        horizontalPdfPageLayout,
        horizontalPdfPageTarget,
        horizontalPdfPageWidthZoom;
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
    this.onFreeChat,
    this.onDarkChanged,
    this.toolbarBuilder,
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
  final VoidCallback? onFreeChat;
  final ValueChanged<bool>? onDarkChanged;
  final ReadingCompanionToolbarBuilder? toolbarBuilder;

  @override
  ReadingCompanionState createState() => ReadingCompanionState();
}

class ReadingCompanionState extends State<ReadingCompanion> {
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
  }

  @override
  void didUpdateWidget(covariant ReadingCompanion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId ||
        oldWidget.library != widget.library ||
        oldWidget.target?.source.id != widget.target?.source.id ||
        oldWidget.target?.source.contentHash !=
            widget.target?.source.contentHash) {
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
    _chatScroll.dispose();
    super.dispose();
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
    final sources = records
        .where(SourceDocumentLoader.isReadableSource)
        .toList(growable: false);
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

  Future<void> _annotate(
    ReadingCompanionPassage passage,
    String bookTitle,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _PassageAnnotation(passage: passage, bookTitle: bookTitle),
    );
    if (saved == true && mounted) AppToast.show(context, '已保存到本书笔记');
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
                  onAnnotate: (passage) => _annotate(passage, book.title),
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
    this.onChooseSource,
    this.onOpenLibrary,
    required this.immersive,
    this.onToggleImmersive,
    this.onSwitchFormat,
    this.onFreeChat,
    this.onDarkChanged,
    this.onInkEditingChanged,
    this.toolbarBuilder,
  });

  final BookSourceRecord source;
  final BookLibraryService library;
  final String bookTitle;
  final void Function(ReadingCompanionPassage, Offset) onAsk;
  final ValueChanged<ReadingCompanionPassage> onAnnotate;
  final VoidCallback? onChooseSource;
  final VoidCallback? onOpenLibrary;
  final bool immersive;
  final VoidCallback? onToggleImmersive;
  final VoidCallback? onSwitchFormat;
  final VoidCallback? onFreeChat;
  final ValueChanged<bool>? onDarkChanged;
  final ValueChanged<bool>? onInkEditingChanged;
  final ReadingCompanionToolbarBuilder? toolbarBuilder;

  @override
  State<_CompanionDocument> createState() => _CompanionDocumentState();
}

bool _isCompanionPdf(BookSourceRecord source) =>
    normalizeBookSourceFormat(source.format) == 'pdf';

enum _ReaderPanel { outline, progress, display }

class _CompanionDocumentState extends State<_CompanionDocument> {
  static const _preferences = ReaderPaginationPreferences();
  late Future<({XiaoqiDocument? document, ReaderAnchor? anchor})> _loading;
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
  bool _pdfSnapPending = false;
  int _pdfSwipeRevision = 0;
  late final _pdfReflow = CompanionPdfReflow(_source);
  CompanionReflowPage? _convertedPage;
  final _convertedPages = <int, CompanionReflowPage>{};
  int? _continuationRevision;
  int? _blockedBefore;
  int? _blockedAfter;
  XiaoqiDocument? _convertedDocument;
  FlowReaderAnchor? _convertedEntry;
  bool _requestedEbook = false;
  bool _ebookSwitchPending = false;
  int? _requestedPdfPage;
  int _ebookSwitchRevision = 0;
  FlowReaderAnchor? _chapterNavigation;
  FlowReaderAnchor? _flowPosition;
  FlowReaderAnchor? _flowPositionBeforeJump;
  int _navigationRevision = 0;
  int _pdfPage = 1;
  int _pdfPageCount = 0;
  int? _pageBeforeJump;
  _ReaderPanel? _activePanel;
  double _outlineExtent = 0;
  bool _outlineDragging = false;
  LocalHistoryEntry? _panelHistory;
  WidgetBuilder? _outlinePanel;
  Future<List<PdfCatalogEntry>>? _pdfBookmarkOutline;
  double? _progressPreview;
  double _fontScale = 1;
  double _marginFraction = .04;
  double _lineScale = 1;
  ReaderPaginationMode _pageTurnMode = ReaderPaginationMode.vertical;
  double _brightness = .65;
  bool _hasBrightnessOverride = false;
  bool _dark = false;
  PdfDocument? _pdfDocumentRef;
  final _monochromePages = <int, bool>{};
  final _classifyingPages = <int>{};
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
  String? _translatedPdfPage;
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
  double _previousPdfScale = 1;
  static const _brightnessChannel = MethodChannel('xiaoqi_app/runtime_config');
  static const _paperDark = Color(0xFF191B1E);
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
  bool get _isPdfDocument => _isCompanionPdf(_source) && _convertedPage == null;
  bool get _isSelectingEbook => !_isCompanionPdf(_source) || _requestedEbook;
  bool get _canRetryEbook =>
      _isPdfDocument && _requestedEbook && !_ebookSwitchPending;
  bool get _hasActiveSelection =>
      _selectionActive ||
      (_isPdfDocument &&
          _pdf.isReady &&
          _pdf.textSelectionDelegate.hasSelectedText);

  @override
  void initState() {
    super.initState();
    _loading = _loadDocument();
    unawaited(_restoreDisplay());
    unawaited(_restoreTranslation());
    unawaited(_loadInk());
  }

  void _switchReaderFormat(bool pdf) {
    if (!_isCompanionPdf(_source)) {
      if (pdf) widget.onSwitchFormat?.call();
      return;
    }
    if (pdf) {
      _returnToPdf();
    } else if (!_requestedEbook || _canRetryEbook) {
      unawaited(_openConvertedPage(_pdfPage, fromPdf: !_requestedEbook));
    }
  }

  Future<void> _openConvertedPage(int number, {bool fromPdf = false}) async {
    if (!_pdf.isReady || number < 1 || number > _pdfPageCount || _inkEditing) {
      return;
    }
    if (_pdfDocumentRef?.permissions?.allowsCopying == false) {
      AppToast.show(context, '这份 PDF 限制复制文字');
      return;
    }
    final visible = _visiblePdfPageFraction(number);
    if (_pdf.textSelectionDelegate.hasSelectedText) {
      unawaited(_pdf.textSelectionDelegate.clearTextSelection());
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final revision = ++_ebookSwitchRevision;
    ++_pdfGestureRevision;
    _pdfReflow.cancel(exceptPage: number);
    final cached = _pdfReflow.cached(number);
    setState(() {
      _requestedEbook = true;
      _ebookSwitchPending = cached == null;
      _requestedPdfPage = number;
    });
    CompanionReflowPage? result;
    try {
      result = cached ?? await _pdfReflow.load(_pdf, number);
    } on Exception {
      // A failed page remains available in its original layout.
    }
    if (!mounted || revision != _ebookSwitchRevision || !_requestedEbook) {
      return;
    }
    if (result == null || result.keepOriginal) {
      setState(() {
        _ebookSwitchPending = false;
        _convertedPage = null;
        _convertedPages.clear();
        _convertedDocument = null;
        _convertedEntry = null;
        if (fromPdf) _requestedEbook = false;
      });
      if (_pdf.pageNumber != number) {
        await _goToPdfReaderPage(number, duration: Duration.zero);
      }
      if (!mounted || revision != _ebookSwitchRevision) return;
      AppToast.show(context, '第 $number 页保留 PDF 原页');
      _scheduleTranslation();
      return;
    }
    final entry = result.entryNear(visible ?? 0);
    setState(() {
      _ebookSwitchPending = false;
      _convertedPage = result;
      _convertedPages.clear();
      _convertedPages[number] = result!;
      _blockedBefore = null;
      _blockedAfter = null;
      _rebuildConvertedDocument();
      _convertedEntry = FlowReaderAnchor(
        sourceId: _sourceKey,
        chapterId: CompanionReflowPage.readingChapterId,
        blockId: entry?.blockId,
        characterOffset: entry?.offset ?? 0,
      );
      _chapterNavigation = null;
      _flowPosition = _convertedEntry;
      _visibleBlocks = const [];
      _foreignSource =
          _foreignSource || ReadingCompanionTranslation.isForeign(result.text);
      _navigationRevision++;
    });
    unawaited(_savePdfAnchor(number));
    _scheduleTranslation();
    _prepareEbookNeighbors();
  }

  double? _visiblePdfPageFraction(int number) {
    if (_pdf.pageNumber != number) return null;
    final layout = _pdf.layout.pageLayouts[number - 1];
    if (layout.isEmpty) return null;
    return ((_pdf.visibleRect.top - layout.top) / layout.height)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  void _rebuildConvertedDocument() {
    final numbers = _convertedPages.keys.toList()..sort();
    _convertedDocument = CompanionReflowPage.readingWindow(
      numbers.map((number) => _convertedPages[number]!),
      _pdfPageCount,
    );
  }

  int get _firstConvertedPage => _convertedPages.keys.reduce(math.min);
  int get _lastConvertedPage => _convertedPages.keys.reduce(math.max);

  void _prepareEbookNeighbors() {
    final revision = _ebookSwitchRevision;
    if (_continuationRevision == revision ||
        _convertedPage == null ||
        _inkEditing ||
        _hasActiveSelection ||
        _ebookSwitchPending) {
      return;
    }
    _continuationRevision = revision;
    unawaited(_extendEbook(revision));
  }

  Future<void> _extendEbook(int revision) async {
    try {
      while (mounted &&
          revision == _ebookSwitchRevision &&
          _convertedPage != null) {
        final current = _convertedPage!.number;
        final after = _lastConvertedPage + 1;
        final before = _firstConvertedPage - 1;
        final append =
            after <= _pdfPageCount &&
            after != _blockedAfter &&
            after <= current + 3;
        final prepend =
            before >= 1 && before != _blockedBefore && before >= current - 2;
        if ((!append && !prepend) ||
            _inkEditing ||
            _hasActiveSelection ||
            _ebookSwitchPending) {
          break;
        }
        final target = append ? after : before;
        CompanionReflowPage? page;
        try {
          page = await _pdfReflow.load(_pdf, target, prefetch: true);
        } on Exception {
          // An unavailable neighboring page can still be retried on demand.
        }
        if (!mounted ||
            revision != _ebookSwitchRevision ||
            _convertedPage == null ||
            _hasActiveSelection ||
            _inkEditing) {
          return;
        }
        if (page == null || page.keepOriginal) {
          if (append) {
            _blockedAfter = target;
          } else {
            _blockedBefore = target;
          }
          continue;
        }
        final available = page;
        setState(() {
          _convertedPages[target] = available;
          if (_convertedPages.length > 12) {
            final obsolete = append ? _firstConvertedPage : _lastConvertedPage;
            _convertedPages.remove(obsolete);
          }
          _rebuildConvertedDocument();
        });
      }
    } finally {
      if (_continuationRevision == revision) _continuationRevision = null;
    }
  }

  void _returnToPdf() {
    if (!_requestedEbook) return;
    ++_ebookSwitchRevision;
    _pdfReflow.cancel();
    final converted = _convertedPage;
    final anchor = _flowPosition;
    if (converted != null) _installPdfText(converted);
    if (converted != null && _pdf.isReady) {
      final top = converted.originalTop(
        anchor?.blockId,
        anchor?.characterOffset,
      );
      final layout = _pdf.layout.pageLayouts[converted.number - 1];
      final current = _pdf.visibleRect;
      final alreadyOnPage = _pdf.pageNumber == converted.number;
      if (_pageTurnMode == ReaderPaginationMode.horizontal) {
        if (!alreadyOnPage) {
          unawaited(
            _goToPdfReaderPage(converted.number, duration: Duration.zero),
          );
        }
      } else if (top != null) {
        final line = layout.top + top * layout.height;
        if (!alreadyOnPage || line < current.top || line > current.bottom) {
          final halfViewport = current.height / 2;
          final inset = math.min(halfViewport, layout.height / 2);
          final center = (line + current.height / 6)
              .clamp(layout.top + inset, layout.bottom - inset)
              .toDouble();
          final left = alreadyOnPage
              ? current.left
              : layout.center.dx - current.width / 2;
          unawaited(
            _pdf.goToPosition(
              documentOffset: Offset(left, center - halfViewport),
            ),
          );
        }
      } else if (!alreadyOnPage) {
        unawaited(
          _pdf.goToPage(pageNumber: converted.number, duration: Duration.zero),
        );
      }
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _requestedEbook = false;
      _requestedPdfPage = null;
      _ebookSwitchPending = false;
      _convertedPage = null;
      _convertedPages.clear();
      _convertedDocument = null;
      _convertedEntry = null;
      _visibleBlocks = const [];
    });
    _reportSelection(false);
    _scheduleTranslation();
  }

  Future<void> _savePdfAnchor(int page) => _preferences.saveAnchor(
    bookId: _source.bookId,
    anchor: PdfReaderAnchor(sourceId: _sourceKey, pageNumber: page),
  );

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
        _pdfDocument(anchor),
        if (converted != null && document != null)
          _flow(document, _convertedEntry, originalPage: converted.number)
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
    if (_ebookSwitchPending) {
      ++_ebookSwitchRevision;
      _pdfReflow.cancel();
    }
    ++_pdfGestureRevision;
    if (_pdf.isReady) {
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
      final afterSave = _afterInkSave;
      _afterInkSave = null;
      afterSave?.call();
    } catch (_) {
      if (!mounted) return;
      setState(() => _inkSaving = false);
      AppToast.show(context, '涂鸦保存失败，请重试');
    }
  }

  void _navigatePdfInk(ScaleUpdateDetails details) {
    if (!_pdf.isReady) return;
    final factor = _previousPdfScale == 0
        ? 1.0
        : details.scale / _previousPdfScale;
    _previousPdfScale = details.scale;
    final next = _pdf.value.clone();
    final zoom = _pdf.currentZoom;
    final ratio = (zoom * factor).clamp(_pdf.minScale, _pdf.maxScale) / zoom;
    final translation = next.getTranslation();
    final focal = _pdf.globalToLocal(details.focalPoint);
    if (focal == null) return;
    final dx =
        focal.dx +
        (translation.x - focal.dx) * ratio +
        details.focalPointDelta.dx;
    final dy =
        focal.dy +
        (translation.y - focal.dy) * ratio +
        details.focalPointDelta.dy;
    next.scaleByDouble(ratio, ratio, 1, 1);
    next.setTranslationRaw(dx, dy, translation.z);
    unawaited(
      _pdf.goTo(_pdf.makeMatrixInSafeRange(next), duration: Duration.zero),
    );
  }

  Widget _inkSurface(
    ReaderAnchor anchor,
    String view, {
    String? text,
  }) => LayoutBuilder(
    builder: (overlayContext, bounds) {
      final size = bounds.biggest;
      if (size.isEmpty || !size.isFinite) return const SizedBox.shrink();
      final location = _inkLocation(anchor, view);
      final layout = text == null
          ? 'fixed'
          : jsonEncode([
              size.width.round(),
              size.height.round(),
              _fontScale,
              _marginFraction,
              _lineScale,
              sha256.convert(utf8.encode(text)).toString(),
            ]);
      final key = '$location/$layout';
      final record = _savedInk[key];
      final pendingKey = _largeDrawings.contains(key)
          ? key
          : record == null && !_inkEditing
          ? _largeDrawings
                .where((other) => other.startsWith('$location/'))
                .lastOrNull
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
      final archived = record == null && !_inkEditing
          ? _savedInk.entries
                .where(
                  (entry) =>
                      entry.key.startsWith('$location/') &&
                      entry.value.text != null,
                )
                .lastOrNull
                ?.value
          : null;
      if (!_inkEditing && record == null && archived == null) {
        return const SizedBox.shrink();
      }
      final initial = record ?? _CompanionInkRecord(size, text, const []);
      final layer = _drawingLayers
          .putIfAbsent(key, () => (layer: initial.createLayer(), text: text))
          .layer;
      final viewLayer = !_inkEditing && record?.document == null
          ? IgnorePointer(
              child: CustomPaint(painter: CompanionInkPainter(initial.strokes)),
            )
          : DrawingBoardPage.annotation(
              key: ValueKey(key),
              layer: layer,
              annotationTools: _inkEditing ? _drawingTools : null,
            );
      final surface = !_inkEditing
          ? viewLayer
          : AbsorbPointer(
              absorbing: _inkSaving,
              child: CompanionInkNavigation(
                onNavigate: text == null
                    ? _navigatePdfInk
                    : (details) {
                        final position = Scrollable.maybeOf(
                          overlayContext,
                        )?.position;
                        if (position != null && position.hasContentDimensions) {
                          position.jumpTo(
                            (position.pixels - details.focalPointDelta.dy)
                                .clamp(
                                  position.minScrollExtent,
                                  position.maxScrollExtent,
                                )
                                .toDouble(),
                          );
                        }
                      },
                onNavigationEnd: (scale) {
                  _previousPdfScale = 1;
                  if (text != null &&
                      view != 'pdf-translation' &&
                      (scale - 1).abs() > .06) {
                    setState(
                      () => _fontScale = (_fontScale * scale)
                          .clamp(.8, 1.5)
                          .toDouble(),
                    );
                  }
                },
                child: viewLayer,
              ),
            );
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
      _visibleBlocks.map((item) => item.id).toList(),
      available.map((item) => item.id).toList(),
    )) {
      return;
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
      if (page == null || !mounted || _pdfPage != number) return;
      final text = (await page.loadText())?.fullText.trim() ?? '';
      if (!mounted || _pdfPage != number) return;
      final foreign = ReadingCompanionTranslation.isForeign(text);
      setState(() {
        _pdfTextAvailable = text.isNotEmpty;
        _foreignSource = _foreignSource || foreign;
      });
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
      final List<String> paragraphs;
      if (pdf == null) {
        paragraphs = blocks.map((block) => block.text.trim()).toList();
      } else {
        final text = await pdf.pages[number - 1].loadText();
        paragraphs = (text?.fullText ?? '')
            .split(RegExp(r'\n\s*\n'))
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList();
      }
      if (!mounted || revision != _translationRevision) return;
      final translated = await ReadingCompanionTranslation(
        _source,
      ).translate(paragraphs);
      if (!mounted || revision != _translationRevision) return;
      void apply() => setState(() {
        _translationPending = false;
        if (pdf == null) {
          for (var index = 0; index < blocks.length; index++) {
            _flowTranslations[blocks[index].id] = translated[index];
          }
        } else {
          _translatedPdfPage = translated.join('\n\n');
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
      _fontScale = prefs.getDouble('reading-companion.font') ?? 1;
      _marginFraction = prefs.getDouble('reading-companion.margin') ?? .04;
      _lineScale = prefs.getDouble('reading-companion.line') ?? 1;
      _pageTurnMode = prefs.getString('reading-companion.turn') == 'horizontal'
          ? ReaderPaginationMode.horizontal
          : ReaderPaginationMode.vertical;
      final brightness = prefs.getDouble('reading-companion.brightness');
      if (brightness != null) {
        _brightness = brightness;
        _hasBrightnessOverride = true;
      }
    });
    if (_hasBrightnessOverride) unawaited(_applyBrightness(_brightness));
    widget.onDarkChanged?.call(_dark);
    _classifyNearbyPages();
  }

  Future<void> _applyBrightness(double? value) async {
    if (!_supportsReaderBrightness) return;
    try {
      await _brightnessChannel.invokeMethod<void>('setCompanionBrightness', {
        'brightness': value,
      });
    } on PlatformException {
      if (mounted) AppToast.show(context, '阅读亮度暂时无法调整');
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

  void _classifyNearbyPages() {
    final document = _pdfDocumentRef;
    if (!_dark || document == null) return;
    for (final number in [_pdfPage, _pdfPage + 1, _pdfPage - 1]) {
      if (number < 1 ||
          number > document.pages.length ||
          _monochromePages.containsKey(number) ||
          !_classifyingPages.add(number)) {
        continue;
      }
      unawaited(_classifyPage(document.pages[number - 1]));
    }
  }

  Future<void> _classifyPage(PdfPage page) async {
    final number = page.pageNumber;
    PdfImage? preview;
    try {
      final loaded = await page.waitForLoaded(
        timeout: const Duration(seconds: 6),
      );
      if (loaded == null || !mounted) return;
      final scale = 180 / math.max(loaded.width, loaded.height);
      preview = await loaded.render(
        fullWidth: math.max(1, (loaded.width * scale).round()).toDouble(),
        fullHeight: math.max(1, (loaded.height * scale).round()).toDouble(),
      );
      if (!mounted || preview == null) return;
      final pixels = preview.pixels;
      var monochrome = true;
      for (var index = 0; index + 3 < pixels.length; index += 4) {
        final b = pixels[index];
        final g = pixels[index + 1];
        final r = pixels[index + 2];
        if (math.max(r, math.max(g, b)) - math.min(r, math.min(g, b)) > 3) {
          monochrome = false;
          break;
        }
      }
      _monochromePages[number] = monochrome;
      if (monochrome && _dark && _pdf.isReady) _pdf.invalidate();
    } on Exception {
      // Unclassified pages retain the source colors.
    } finally {
      preview?.dispose();
      _classifyingPages.remove(number);
    }
  }

  void _paintDarkPage(Canvas canvas, Rect rect, PdfPage page) {
    if (!_dark || _monochromePages[page.pageNumber] != true) return;
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..isAntiAlias = false
        ..blendMode = BlendMode.difference,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = _paperDark
        ..isAntiAlias = false
        ..blendMode = BlendMode.plus,
    );
  }

  Future<({XiaoqiDocument? document, ReaderAnchor? anchor})>
  _loadDocument() async {
    final source = _source;
    final anchor = _preferences.loadAnchor(
      bookId: source.bookId,
      sourceId: source.id,
    );
    if (normalizeBookSourceFormat(source.format) == 'pdf') {
      return (document: null, anchor: await anchor);
    }
    final document =
        await widget.library.loadBookSourceRevision(source) ??
        await SourceDocumentLoader.parseBookSourceInBackground(source);
    if (document.chapters.isEmpty) {
      throw const FormatException('电子资料没有可读章节');
    }
    _foreignSource = ReadingCompanionTranslation.isForeign(
      document.chapters.first.plainText,
      language: document.language,
    );
    final saved = await anchor;
    if (saved is FlowReaderAnchor) _flowPosition = saved;
    return (document: document, anchor: saved);
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
            key: ValueKey(_navigationRevision),
            sourceId: _sourceKey,
            document: document,
            initialChapterId: chapter.id,
            initialAnchor: current,
            mode: _pageTurnMode,
            textStyleBuilder: textStyle,
            translations: _translationEnabled ? _flowTranslations : null,
            onPreviousDocument: _inkEditing || _ebookSwitchPending
                ? null
                : originalPage != null
                ? _firstConvertedPage > 1
                      ? () => unawaited(
                          _openConvertedPage(_firstConvertedPage - 1),
                        )
                      : null
                : _pageTurnMode == ReaderPaginationMode.vertical &&
                      chapterIndex > 0
                ? () => _chapter(chapters[chapterIndex - 1])
                : null,
            onNextDocument: _inkEditing || _ebookSwitchPending
                ? null
                : originalPage != null
                ? _lastConvertedPage < _pdfPageCount
                      ? () => unawaited(
                          _openConvertedPage(_lastConvertedPage + 1),
                        )
                      : null
                : _pageTurnMode == ReaderPaginationMode.vertical &&
                      chapterIndex + 1 < chapters.length
                ? () => _chapter(chapters[chapterIndex + 1])
                : null,
            verticalBackground: _dark ? _paperDark : Colors.white,
            onVisibleBlocksChanged: _onVisibleBlocks,
            chapterTitleAlign: TextAlign.center,
            verticalChapterTitleStyle: TextStyle(
              fontFamily: 'NotoSerifCJKSC',
              fontSize: dimensions.maxWidth >= 600 ? 36 : 26,
              height: 1.4,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
            onAnchorChanged: (value) {
              if (originalPage != null) {
                _flowPosition = value;
                final number = CompanionReflowPage.pageForBlock(value.blockId);
                final page = _convertedPages[number];
                if (page != null && page.number != _convertedPage?.number) {
                  setState(() => _convertedPage = page);
                  unawaited(_savePdfAnchor(page.number));
                }
                _prepareEbookNeighbors();
                return;
              }
              if (value.chapterId == _flowPosition?.chapterId) {
                _flowPosition = value;
              } else {
                setState(() => _flowPosition = value);
              }
              unawaited(
                _preferences.saveAnchor(bookId: _source.bookId, anchor: value),
              );
            },
            blockBuilder: (context, slice, setSelection) {
              final sliceChapter = chaptersById[slice.chapterId] ?? chapter;
              final sourcePage = originalPage == null
                  ? null
                  : int.tryParse(slice.block.originalPageLabel ?? '') ??
                        originalPage;
              final translation = _translationEnabled
                  ? _flowTranslations[slice.block.id]
                  : null;
              final displayText =
                  _pageTurnMode == ReaderPaginationMode.horizontal
                  ? slice.text
                  : translation ?? slice.text;
              final block = XiaoqiDocumentBlockView(
                block: slice.block,
                selectionControls: _companionTextSelectionControls,
                asset: assets[slice.block.assetId],
                textOverride: displayText,
                tableRowsOverride: slice.tableRows,
                continuation: slice.continuation,
                onSelectionChanged: (selected) {
                  setSelection(selected);
                  _reportSelection(selected);
                },
                onTextTap: () {
                  if (!_selectionActive && !_inkEditing) {
                    widget.onToggleImmersive?.call();
                  }
                },
                contextMenuBuilder: (context, editable) =>
                    _flowSelection(editable, sliceChapter, slice, sourcePage),
                textStyleBuilder: textStyle,
              );
              final location = FlowReaderAnchor(
                sourceId: _sourceKey,
                chapterId: sourcePage == null
                    ? sliceChapter.id
                    : 'pdf-page-$sourcePage',
                blockId: slice.block.id,
                characterOffset: slice.startOffset,
              );
              return Stack(
                children: [
                  block,
                  Positioned.fill(
                    child: _inkSurface(
                      location,
                      translation == null ? 'original' : 'ebook-translation',
                      text: displayText,
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
      Widget start,
      Widget end,
      ValueChanged<double> onChanged, {
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
      final background = selected
          ? Colors.transparent
          : dark
          ? const Color(0xFF333333)
          : const Color(0xFFEEEEEE);
      final foreground = selected
          ? _ink
          : dark
          ? const Color(0xFFF7F5F1)
          : const Color(0xFF262626);
      return Semantics(
        selected: selected,
        child: TextButton(
          onPressed: () {
            if (selected) return;
            setState(() => _dark = dark);
            widget.onDarkChanged?.call(_dark);
            _classifyNearbyPages();
            if (_pdf.isReady) _pdf.invalidate();
          },
          style: TextButton.styleFrom(
            foregroundColor: foreground,
            backgroundColor: background,
            minimumSize: Size(_readerWide ? 110 : 67, 40),
            padding: EdgeInsets.symmetric(horizontal: _readerWide ? 15 : 8),
            side: selected ? BorderSide(color: foreground, width: 1.4) : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontSize: _readerWide ? 18 : 14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                _readerIcon(
                  'assets/icons/drawing/check.svg',
                  _readerWide ? 20 : 15,
                  color: foreground,
                ),
                const SizedBox(width: 6),
              ],
              Text(dark ? '深色' : '默认'),
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
              _readerIcon('assets/icons/chat_note_editor/sun.svg', 20),
              _readerIcon('assets/icons/chat_note_editor/sun.svg', 26),
              (value) {
                setState(() {
                  _brightness = value;
                  _hasBrightnessOverride = true;
                });
                unawaited(_applyBrightness(value));
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
              children: [
                for (final mode in [
                  ReaderPaginationMode.vertical,
                  ReaderPaginationMode.horizontal,
                ])
                  Semantics(
                    selected: _pageTurnMode == mode,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _pageTurnMode == mode
                            ? _readerChrome
                            : _ink,
                        backgroundColor: _pageTurnMode == mode
                            ? _ink
                            : Colors.transparent,
                        side: BorderSide(color: _readerRule),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        minimumSize: const Size(64, 40),
                        padding: EdgeInsets.symmetric(
                          horizontal: _readerWide ? 14 : 10,
                        ),
                      ),
                      onPressed: () {
                        if (_pageTurnMode == mode) return;
                        setState(() => _pageTurnMode = mode);
                      },
                      child: Text(
                        mode == ReaderPaginationMode.vertical ? '上下滑动' : '左右翻页',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (pdf) ...[
            Divider(height: 1, thickness: 1, color: _readerRule),
            setting(
              '排版',
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('字号、边距、行距可在电子书中调整。'),
                  TextButton(
                    onPressed: () {
                      _closeReaderPanel();
                      _switchReaderFormat(false);
                    },
                    child: const Text('打开电子书'),
                  ),
                ],
              ),
            ),
          ],
        ],
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
      prefs.setString('reading-companion.turn', _pageTurnMode.name),
      if (_hasBrightnessOverride)
        prefs.setDouble('reading-companion.brightness', _brightness),
    ]);
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
    final translated =
        _translationEnabled && _flowTranslations.containsKey(slice.block.id);
    final offset = value.text == slice.text ? slice.startOffset : 0;
    final location = originalPage == null ? chapter.title : '第 $originalPage 页';
    final passage = _passage(
      text,
      translated ? '$location · 译文' : location,
      originalPage == null
          ? FlowReaderAnchor(
              sourceId: _sourceKey,
              chapterId: chapter.id,
              blockId: slice.block.id,
              characterOffset: translated ? 0 : offset + range.start,
            )
          : PdfReaderAnchor(sourceId: _sourceKey, pageNumber: originalPage),
      startOffset: translated || originalPage != null
          ? null
          : offset + range.start,
      endOffset: translated || originalPage != null ? null : offset + range.end,
      translationSnapshot: translated ? value.text : null,
    );
    return _selectionToolbar(
      above: anchor.primaryAnchor,
      below: anchor.secondaryAnchor,
      onCopy: () {
        editable.hideToolbar(false);
        _copy(text);
      },
      onAnnotate: () {
        editable.hideToolbar();
        widget.onAnnotate(passage);
      },
      onAsk: () =>
          widget.onAsk(passage, anchor.secondaryAnchor ?? anchor.primaryAnchor),
    );
  }

  ReadingCompanionPassage _passage(
    String text,
    String label,
    ReaderAnchor anchor, {
    int? startOffset,
    int? endOffset,
    String? translationSnapshot,
  }) => ReadingCompanionPassage(
    bookId: _source.bookId,
    sourceId: _source.id,
    text: text,
    sourceName: _source.displayName,
    locator: label,
    anchor: anchor,
    startOffset: startOffset,
    endOffset: endOffset,
    sourceRevision: _source.sourceVersionId.isEmpty
        ? _source.contentHash
        : _source.sourceVersionId,
    translationRevision: translationSnapshot == null
        ? null
        : sha256.convert(utf8.encode(translationSnapshot)).toString(),
  );

  void _changeReaderPageTurnMode(ReaderPaginationMode mode) {
    if (mode == _pageTurnMode) return;
    final page = _pdfPage;
    ++_pdfSwipeRevision;
    _pdfSwipeStart = null;
    _pdfSnapPending = false;
    setState(() => _pageTurnMode = mode);
    if (mode != ReaderPaginationMode.horizontal || !_isPdfDocument) return;
    final revision = _pdfSwipeRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Let pdfrx finish mapping its old viewport into the new layout first.
      scheduleMicrotask(() {
        if (!mounted || revision != _pdfSwipeRevision || !_isPdfDocument) {
          return;
        }
        unawaited(_goToPdfReaderPage(page, duration: Duration.zero));
      });
    });
  }

  void _startPdfSwipe(ScaleStartDetails details) {
    ++_pdfSwipeRevision;
    _pdfSnapPending = false;
    _pdfSwipeStart = null;
    if (details.pointerCount > 1 ||
        !_pdf.isReady ||
        _inkEditing ||
        _hasActiveSelection) {
      return;
    }
    final page = _pdf.pageNumber ?? _pdfPage;
    if (page < 1 ||
        page > _pdf.layout.pageLayouts.length ||
        _pdf.currentZoom > horizontalPdfPageWidthZoom(_pdf, page) * 1.05) {
      return;
    }
    _pdfSwipeStart = (page: page, center: _pdf.centerPosition);
  }

  void _updatePdfSwipe(ScaleUpdateDetails details) {
    if (details.pointerCount > 1) _pdfSwipeStart = null;
  }

  void _endPdfSwipe(ScaleEndDetails details) {
    final start = _pdfSwipeStart;
    _pdfSwipeStart = null;
    if (start == null || !_pdf.isReady) return;

    final travel = (_pdf.centerPosition - start.center) * _pdf.currentZoom;
    final velocity = details.velocity.pixelsPerSecond;
    if (_inkEditing ||
        _hasActiveSelection ||
        (travel.dx.abs() < 1 && velocity.dx.abs() < 650) ||
        (travel.dy.abs() > travel.dx.abs() &&
            velocity.dy.abs() >= velocity.dx.abs())) {
      _onPdfReaderPageChanged(_pdf.pageNumber);
      return;
    }
    final target = horizontalPdfPageTarget(
      startPage: start.page,
      pageCount: _pdf.layout.pageLayouts.length,
      distance: travel.dx,
      fingerVelocity: velocity.dx,
      viewportWidth: _pdf.viewSize.width,
    );
    final revision = _pdfSwipeRevision;
    _pdfSnapPending = true;
    // pdfrx starts its inertia after this end callback. The page snap starts
    // after that so goTo can cancel the inertia instead of competing with it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _pdfSwipeRevision) return;
      if (!_isPdfDocument || _inkEditing) {
        _pdfSnapPending = false;
        return;
      }
      unawaited(
        _goToPdfReaderPage(target, keepVerticalPosition: target == start.page),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _goToPdfReaderPage(
    int number, {
    Duration duration = const Duration(milliseconds: 220),
    bool keepVerticalPosition = false,
  }) async {
    if (!_pdf.isReady) return;
    if (MediaQuery.disableAnimationsOf(context)) duration = Duration.zero;
    if (_pageTurnMode != ReaderPaginationMode.horizontal) {
      await _pdf.goToPage(pageNumber: number, duration: duration);
      return;
    }
    if (number < 1 || number > _pdf.layout.pageLayouts.length) {
      _pdfSnapPending = false;
      return;
    }
    final revision = ++_pdfSwipeRevision;
    _pdfSwipeStart = null;
    _pdfSnapPending = true;
    final rect = _pdf.layout.pageLayouts[number - 1];
    final zoom = horizontalPdfPageWidthZoom(_pdf, number);
    final inset = math.min(rect.height / 2, _pdf.viewSize.height / zoom / 2);
    final y = keepVerticalPosition
        ? _pdf.centerPosition.dy.clamp(rect.top + inset, rect.bottom - inset)
        : rect.top + inset;
    final matrix = _pdf.calcMatrixFor(
      Offset(rect.center.dx, y.toDouble()),
      zoom: zoom,
      viewSize: _pdf.viewSize,
    );
    await _pdf.goTo(matrix, duration: duration);
    if (!mounted || revision != _pdfSwipeRevision) return;
    _pdfSnapPending = false;
    _onPdfReaderPageChanged(number);
  }

  void _onPdfReaderPageChanged(int? next) {
    if (!mounted ||
        next == null ||
        next == _pdfPage ||
        _pdfSwipeStart != null ||
        _pdfSnapPending) {
      return;
    }
    ++_pdfGestureRevision;
    setState(() {
      _pdfPage = next;
      if (_convertedPage != null) return;
      _pdfTextAvailable = false;
      _translationPending = false;
      _translationError = null;
    });
    if (_convertedPage != null) return;
    if (_requestedEbook && _requestedPdfPage != next) {
      unawaited(_openConvertedPage(next));
    }
    _reportSelection(false);
    _scheduleTranslation();
    final document = _pdfDocumentRef;
    if (document != null) unawaited(_detectPdfPage(document, next));
    _classifyNearbyPages();
    unawaited(_savePdfAnchor(next));
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
    final horizontal = _pageTurnMode == ReaderPaginationMode.horizontal;
    return _footerWithBody(
      showChrome: _convertedPage == null,
      body: ColoredBox(
        color: surround,
        child: Padding(
          padding: EdgeInsets.zero,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PdfViewer(
                _selectablePdfReference,
                controller: _pdf,
                initialPageNumber: page,
                params: PdfViewerParams(
                  backgroundColor: surround,
                  layoutPages: horizontal ? horizontalPdfPageLayout : null,
                  pageAnchor: horizontal
                      ? PdfPageAnchor.center
                      : PdfPageAnchor.top,
                  pageAnchorEnd: horizontal
                      ? PdfPageAnchor.center
                      : PdfPageAnchor.bottom,
                  panAxis: horizontal ? PanAxis.aligned : PanAxis.free,
                  onInteractionStart: horizontal ? _startPdfSwipe : null,
                  onInteractionUpdate: horizontal ? _updatePdfSwipe : null,
                  onInteractionEnd: horizontal ? _endPdfSwipe : null,
                  margin: 17,
                  pageDropShadow: _dark
                      ? null
                      : const BoxShadow(
                          color: Color(0x0E000000),
                          blurRadius: 7,
                          offset: Offset(0, 2),
                        ),
                  pagePaintCallbacks: [_paintDarkPage],
                  pageOverlaysBuilder: (context, rect, page) => [
                    if (showsOriginalPage)
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
                    action: widget.onChooseSource != null ? '选择其他资料' : '打开本书资料',
                    onAction: widget.onChooseSource ?? widget.onOpenLibrary,
                  ),
                  onViewerReady: (document, controller) {
                    if (!mounted) return;
                    _pdfDocumentRef = document;
                    setState(() {
                      _pdfPageCount = document.pages.length;
                      _pdfPage = controller.pageNumber ?? 1;
                    });
                    if (horizontal) {
                      unawaited(
                        _goToPdfReaderPage(_pdfPage, duration: Duration.zero),
                      );
                    }
                    _classifyNearbyPages();
                    unawaited(_detectPdfPage(document, _pdfPage));
                  },
                  onPageChanged: _onPdfReaderPageChanged,
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
                    if (!_inkEditing &&
                        !_selectionActive &&
                        details.type == PdfViewerGeneralTapType.tap &&
                        details.tapOn != PdfViewerPart.selectedText) {
                      widget.onToggleImmersive?.call();
                    }
                    return false;
                  },
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
      onPageSelected: (next) => unawaited(_goToPdfReaderPage(next)),
      onOutline: _pdfPageCount == 0 ? null : _showPdfOutline,
    );
  }

  void _onPdfTextSelection(PdfTextSelection selection) {
    _reportSelection(selection.hasSelectedText);
    if (!selection.hasSelectedText) _pdfHandleMoving = false;
    _updatePdfToolbar();
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

  Widget _pdfTranslationView(String translation) {
    final page = _pdfPage;
    var overscroll = 0.0;
    var horizontalDelta = 0.0;
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
        onHorizontalDragStart: _pageTurnMode == ReaderPaginationMode.horizontal
            ? (_) => horizontalDelta = 0
            : null,
        onHorizontalDragUpdate: _pageTurnMode == ReaderPaginationMode.horizontal
            ? (details) => horizontalDelta += details.delta.dx
            : null,
        onHorizontalDragEnd: _pageTurnMode == ReaderPaginationMode.horizontal
            ? (_) => turnPage(
                horizontalDelta < -44
                    ? 1
                    : horizontalDelta > 44
                    ? -1
                    : 0,
              )
            : null,
        child: NotificationListener<ScrollNotification>(
          onNotification: (event) {
            if (event is OverscrollNotification &&
                event.dragDetails != null &&
                _pageTurnMode == ReaderPaginationMode.vertical) {
              overscroll += event.overscroll;
            }
            if (event is ScrollEndNotification) {
              turnPage(
                overscroll > 56
                    ? 1
                    : overscroll < -56
                    ? -1
                    : 0,
              );
              overscroll = 0;
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
                SelectableText(
                  translation,
                  selectionControls: _companionTextSelectionControls,
                  onTap: _selectionActive || _inkEditing
                      ? null
                      : widget.onToggleImmersive,
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
                    final passage = _passage(
                      text,
                      '第 $page 页 · 译文',
                      PdfReaderAnchor(sourceId: _sourceKey, pageNumber: page),
                      translationSnapshot: translation,
                    );
                    return _selectionToolbar(
                      above: anchor.primaryAnchor,
                      below: anchor.secondaryAnchor,
                      onCopy: () {
                        editable.hideToolbar(false);
                        _copy(text);
                      },
                      onAnnotate: () {
                        editable.hideToolbar();
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
            setState(() => _pageBeforeJump = readingPage);
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
      final text = (await delegate.getSelectedText()).trim();
      if (!mounted || text.isEmpty) return;
      await delegate.clearTextSelection();
      if (!mounted) return;
      final passage = _passage(
        text,
        label,
        anchor,
        startOffset: range.start.index,
        endOffset: page == endPage ? range.end.index + 1 : null,
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

  void _openReaderPanel(_ReaderPanel panel, {WidgetBuilder? outline}) {
    if (_activePanel == panel) {
      _closeReaderPanel();
      return;
    }
    if (_activePanel == _ReaderPanel.display) {
      unawaited(_persistDisplaySettings());
    }
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
      _outlineExtent = 0;
      _outlineDragging = false;
      _outlinePanel = outline;
      _progressPreview = null;
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
      _outlinePanel = null;
      _progressPreview = null;
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
    bool compact = false,
  }) => Semantics(
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
        padding: const EdgeInsets.symmetric(horizontal: 7),
        showValueIndicator: ShowValueIndicator.never,
      ),
      child: Slider(
        value: value.clamp(min, max).toDouble(),
        min: min,
        max: max,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
        semanticFormatterCallback: formatValue,
      ),
    ),
  );

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
    final shownPage = (_progressPreview ?? page.toDouble()).round();
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
          _progressPreview = null;
          if (destination != page) {
            _pageBeforeJump = page;
            _flowPositionBeforeJump = _flowPosition;
          }
        });
      }
      if (destination != page) onPageSelected(destination);
    }

    void restoreJump(int previous) {
      final position = _flowPositionBeforeJump;
      _closeReaderPanel();
      setState(() {
        _pageBeforeJump = null;
        _flowPositionBeforeJump = null;
      });
      if (position != null && onRestoreFlow != null) {
        onRestoreFlow(position);
      } else {
        onPageSelected(previous);
      }
    }

    Widget progressSlider({bool compact = false}) => _readerSlider(
      value: shownPage.toDouble(),
      min: 1,
      max: maxPage,
      onChanged: pageCount > 1
          ? (value) => setState(() => _progressPreview = value)
          : null,
      onChangeEnd: pageCount > 1 ? (value) => jumpTo(value.round()) : null,
      description: '阅读进度',
      formatValue: (value) => '${value.round()} / $pageCount',
      compact: compact,
    );

    final size = _readerWide ? 18.0 : 14.0;
    Widget progressPanel() => SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          SizedBox(height: 38, child: progressSlider()),
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
            child: ExcludeSemantics(excluding: panel != null, child: body),
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
    final bookTitle = widget.bookTitle.trim().isEmpty
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
            Expanded(
              child: ClipRect(
                child: Material(
                  color: surface,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: _readerSideInset * .6,
                    ),
                    child: Builder(builder: _outlinePanel!),
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

  Widget _toolbar(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final showDoodleLabel = MediaQuery.sizeOf(context).width >= 380;
    final controlColor = _dark
        ? const Color(0xFF27292B)
        : const Color(0xFFF0F1F2);
    final selectedColor = _dark ? const Color(0xFF48494B) : Colors.white;
    final library = widget.onChooseSource;
    Widget segment(bool pdf, String label) {
      final selected = pdf != _isSelectingEbook;
      final loading = !pdf && _ebookSwitchPending;
      final retry = !pdf && _canRetryEbook;
      final VoidCallback? onTap = loading
          ? null
          : retry
          ? () => _switchReaderFormat(false)
          : selected
          ? library
          : (pdf && !_isCompanionPdf(_source) && widget.onSwitchFormat == null
                ? null
                : () => _switchReaderFormat(pdf));
      return Tooltip(
        message: loading
            ? '正在准备电子书'
            : retry
            ? '重试电子书'
            : selected && library != null
            ? '切换阅读资料'
            : label,
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          selected: selected,
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: onTap == null
                ? null
                : () {
                    _closeReaderPanel();
                    onTap();
                  },
            child: SizedBox(
              width: wide ? (pdf ? 61 : 80) : (pdf ? 36 : 68),
              height: 44,
              child: Center(
                child: Ink(
                  height: wide ? 29 : 28,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: selected ? selectedColor : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (loading) ...[
                          SizedBox.square(
                            dimension: wide ? 12 : 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: _ink,
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          label,
                          maxLines: 1,
                          style: TextStyle(
                            color: selected || onTap != null
                                ? _ink
                                : _ink.withValues(alpha: .48),
                            fontSize: wide ? 14 : 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final tools = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!_inkEditing) ...[
          Material(
            color: controlColor,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [segment(true, 'PDF'), segment(false, '电子书')],
              ),
            ),
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
        selectionColor: _dark
            ? const Color(0x55FFFFFF)
            : const Color(0x33212121),
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
                    child: _toolbar(context),
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
) => _handleControlsForPdf(
  anchor,
).buildHandle(context, _pdfSelectionHandleType(anchor), 0);

Offset _pdfSelectionHandleOffset(
  BuildContext context,
  PdfTextSelectionAnchor anchor,
  PdfViewerTextSelectionAnchorHandleState state,
) {
  final type = _pdfSelectionHandleType(anchor);
  final controls = _handleControlsForPdf(anchor);
  final tip = controls.getHandleAnchor(type, 0);
  final size = controls.getHandleSize(0);
  return Offset(
    type == TextSelectionHandleType.left ? size.width - tip.dx : -tip.dx,
    anchor.type == PdfTextSelectionAnchorType.a
        ? size.height - tip.dy
        : -tip.dy,
  );
}

class _CompanionTextSelectionControls extends BookPencilTextSelectionControls
    with TextSelectionHandleControls {
  _CompanionTextSelectionControls({super.textDirection})
    : super(tintForDarkTheme: true);
}

final _companionTextSelectionControls = _CompanionTextSelectionControls();

BookPencilTextSelectionControls _handleControlsForPdf(
  PdfTextSelectionAnchor anchor,
) =>
    anchor.direction == PdfTextDirection.rtl ||
        anchor.direction == PdfTextDirection.vrtl
    ? _CompanionTextSelectionControls(textDirection: TextDirection.rtl)
    : _companionTextSelectionControls;

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

class _PassageAnnotation extends StatefulWidget {
  const _PassageAnnotation({required this.passage, required this.bookTitle});

  final ReadingCompanionPassage passage;
  final String bookTitle;

  @override
  State<_PassageAnnotation> createState() => _PassageAnnotationState();
}

class _PassageAnnotationState extends State<_PassageAnnotation>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _focus = FocusNode();
  double _lastInset = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final inset = View.of(context).viewInsets.bottom;
    if (_lastInset > 0 && inset == 0 && _text.text.isEmpty) _focus.unfocus();
    _lastInset = inset;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final comment = _text.text.trim();
    if (comment.isEmpty || _saving) return;
    _focus.unfocus();
    setState(() => _saving = true);
    final now = DateTime.now().toIso8601String();
    final passage = widget.passage;
    final anchor = passage.anchor;
    try {
      await DatabaseService().insertNote(
        Note(
          type: 'text',
          title: passage.locator,
          content: '${passage.text}\n\n$comment',
          bookId: passage.bookId,
          bookName: widget.bookTitle,
          bookPage: anchor is PdfReaderAnchor ? '${anchor.pageNumber}' : '',
          createdAt: now,
          updatedAt: now,
        ),
        companionSource: (
          sourceId: passage.sourceId,
          locator: {
            'anchor': readerAnchorJson(anchor),
            'source_revision': passage.sourceRevision,
            'translation_revision': passage.translationRevision,
            'start_offset': passage.startOffset,
            'end_offset': passage.endOffset,
            'quote': passage.text,
          },
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.show(context, '注释保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      backgroundColor: Colors.white,
      title: const Text('注释'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PassageQuote(text: widget.passage.text),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              focusNode: _focus,
              minLines: 3,
              maxLines: 6,
              enabled: !_saving,
              decoration: const InputDecoration(
                hintText: '写下注释',
                border: OutlineInputBorder(),
              ),
              onTapOutside: (_) => _focus.unfocus(),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF262626),
          ),
          onPressed: _saving || _text.text.trim().isEmpty ? null : _save,
          child: Text(_saving ? '保存中' : '保存'),
        ),
      ],
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
  Widget build(BuildContext context) => Semantics(
    label: '正在打开阅读资料',
    child: ColoredBox(
      color: Colors.white,
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
                child: const ColoredBox(
                  color: Color(0xFFF1F1F1),
                  child: SizedBox(height: 9),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _ReaderStatus extends StatelessWidget {
  const _ReaderStatus(this.text, {this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: const TextStyle(color: Color(0xFF656565))),
        if (action != null && onAction != null)
          TextButton(onPressed: onAction, child: Text(action!)),
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
