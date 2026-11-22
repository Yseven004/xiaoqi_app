import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../models/pdf_catalog.dart';
import '../models/reader_pagination.dart';
import '../models/xiaoqi_document.dart';
import '../services/book_library_service.dart';
import '../services/database_service.dart';
import '../services/reader_pagination_preferences.dart';
import '../services/reading_task_context.dart';
import '../services/reading_companion_translation.dart';
import '../services/source_document_loader.dart';
import 'app_toast.dart';
import 'chat_annotation_navigation.dart';
import 'chat_message_scroll_view.dart';
import 'companion_ink_surface.dart';
import 'message_selection_action_card.dart';
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

/// Book source reader embedded beneath the reading-space toolbar.
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
  final AsyncCallback? onChooseBook;
  final AsyncCallback? onOpenLibrary;
  final Future<int?> Function(int bookId)? loadPreferredSourceId;
  final ReadingCompanionTarget? target;
  final Future<void> Function(BookSourceRecord source)? onSourceChanged;
  final bool immersive;
  final VoidCallback? onToggleImmersive;
  final VoidCallback? onFreeChat;
  final ValueChanged<bool>? onDarkChanged;

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
  (int, int, String)? _documentIdentity;
  GlobalKey<_CompanionDocumentState>? _documentKey;

  bool finishInkForBack() {
    final state = _documentKey?.currentState;
    if (state == null || !state._inkEditing) return false;
    unawaited(state._finishInk());
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
                  return const _ReadingPlaceholder();
                }
                if (snapshot.hasError) {
                  return _ReaderStatus(
                    '阅读资料暂时无法打开',
                    action: '重试',
                    onAction: _reloadBook,
                  );
                }
                final book = snapshot.requireData;
                final sources = book.sources;
                if (sources.isEmpty) {
                  final chooseBook = widget.bookId == null
                      ? widget.onChooseBook
                      : null;
                  return _ReaderStatus(
                    widget.bookId == null ? '选择一本书后开始伴读' : '这本书还没有阅读资料',
                    action: widget.bookId != null
                        ? '打开本书资料'
                        : chooseBook == null
                        ? '打开书库'
                        : '选择书籍',
                    onAction:
                        chooseBook ??
                        (widget.onOpenLibrary == null ? null : _openLibrary),
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
                );
                if (_documentIdentity != identity) {
                  _documentIdentity = identity;
                  _documentKey = GlobalKey<_CompanionDocumentState>();
                }
                return _CompanionDocument(
                  key: _documentKey,
                  source: current,
                  immersive: widget.immersive,
                  onToggleImmersive: _chatOpen
                      ? null
                      : widget.onToggleImmersive,
                  onFreeChat: _chatOpen ? null : widget.onFreeChat,
                  onDarkChanged: widget.onDarkChanged,
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
  });

  final BookSourceRecord source;
  final BookLibraryService library;
  final void Function(ReadingCompanionPassage, Offset) onAsk;
  final ValueChanged<ReadingCompanionPassage> onAnnotate;
  final VoidCallback? onChooseSource;
  final VoidCallback? onOpenLibrary;
  final bool immersive;
  final VoidCallback? onToggleImmersive;
  final VoidCallback? onSwitchFormat;
  final VoidCallback? onFreeChat;
  final ValueChanged<bool>? onDarkChanged;

  @override
  State<_CompanionDocument> createState() => _CompanionDocumentState();
}

bool _isCompanionPdf(BookSourceRecord source) =>
    normalizeBookSourceFormat(source.format) == 'pdf';

class _CompanionDocumentState extends State<_CompanionDocument> {
  static const _preferences = ReaderPaginationPreferences();
  late Future<({XiaoqiDocument? document, ReaderAnchor? anchor})> _loading;
  final _pdf = PdfViewerController();
  FlowReaderAnchor? _chapterNavigation;
  FlowReaderAnchor? _flowPosition;
  FlowReaderAnchor? _flowPositionBeforeJump;
  int _navigationRevision = 0;
  int _pdfPage = 1;
  int _pdfPageCount = 0;
  int? _pageBeforeJump;
  double _fontScale = 1;
  double _marginFraction = .04;
  double _lineScale = 1;
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
  final _draftInk = <String, _CompanionInkRecord>{};
  final _inkUndo = <({String key, _CompanionInkRecord? previous})>[];
  bool _inkEditing = false;
  bool _inkErasing = false;
  bool _inkSaving = false;
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
    return Theme.of(context).copyWith(colorScheme: scheme);
  }

  bool _renderedChapter = false;

  BookSourceRecord get _source => widget.source;
  String get _sourceKey => _source.id.toString();

  @override
  void initState() {
    super.initState();
    _loading = _loadDocument();
    unawaited(_restoreDisplay());
    unawaited(_restoreTranslation());
    unawaited(_loadInk());
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
      final rows = await db.query(
        'companion_ink',
        where: 'source_id = ?',
        whereArgs: [_source.id],
      );
      if (!mounted) return;
      setState(() {
        for (final row in rows) {
          final record = _CompanionInkRecord.fromJson(
            row['drawing']! as String,
          );
          if (record != null) _savedInk[row['location']! as String] = record;
        }
        _inkLoaded = true;
        _inkLoadFailed = false;
      });
    } on Exception {
      if (mounted) setState(() => _inkLoadFailed = true);
    }
  }

  Future<void> _finishInk() async {
    if (_inkSaving) return;
    setState(() => _inkSaving = true);
    try {
      if (_draftInk.isNotEmpty) {
        final db = await DatabaseService().database;
        final batch = db.batch();
        for (final entry in _draftInk.entries) {
          if (entry.value.strokes.isEmpty) {
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
        for (final entry in _draftInk.entries) {
          if (entry.value.strokes.isEmpty) {
            _savedInk.remove(entry.key);
          } else {
            _savedInk[entry.key] = entry.value;
          }
        }
        _draftInk.clear();
        _inkUndo.clear();
        _inkEditing = false;
        _inkSaving = false;
      });
      _reportSelection(false);
    } on Exception {
      if (!mounted) return;
      setState(() => _inkSaving = false);
      AppToast.show(context, '涂鸦保存失败，请重试');
    }
  }

  void _undoInk() {
    if (_inkUndo.isEmpty || _inkSaving) return;
    setState(() {
      final undo = _inkUndo.removeLast();
      final previous = undo.previous;
      if (previous == null) {
        _draftInk.remove(undo.key);
      } else {
        _draftInk[undo.key] = previous;
      }
    });
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
      final record = _draftInk[key] ?? _savedInk[key];
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
      final surface = CompanionInkSurface(
        enabled: _inkEditing && !_inkSaving,
        erasing: _inkErasing,
        color: _dark ? const Color(0xFFFFB76A) : const Color(0xFF9B3028),
        strokes: record?.strokes ?? const [],
        onChanged: (strokes) => setState(() {
          _inkUndo.add((key: key, previous: _draftInk[key]));
          _draftInk[key] = _CompanionInkRecord(size, text, strokes);
        }),
        onNavigate: text == null
            ? _navigatePdfInk
            : (details) {
                final position = Scrollable.maybeOf(overlayContext)?.position;
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
              () => _fontScale = (_fontScale * scale).clamp(.8, 1.5).toDouble(),
            );
          }
        },
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
                  CustomPaint(painter: CompanionInkPainter(record.strokes)),
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
    final pdf = _pdfDocumentRef;
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
      if (_selectionActive || _inkEditing) {
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
    if (active || _inkEditing || _applyDeferredTranslation == null) return;
    final apply = _applyDeferredTranslation;
    _applyDeferredTranslation = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_selectionActive && !_inkEditing && _translationEnabled) {
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
    if (defaultTargetPlatform != TargetPlatform.android) return;
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
    _translationDelay?.cancel();
    ++_translationRevision;
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
        ..blendMode = BlendMode.difference,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = _paperDark
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

  Future<void> _showOutline(
    List<String> titles,
    int current,
    ValueChanged<int> onSelected, {
    List<int> levels = const [],
    Set<int> groupLabels = const {},
    List<int> pages = const [],
    int? readingPage,
  }) async {
    final theme = _readerTheme(context);
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.colorScheme.surface,
      builder: (context) => Theme(
        data: theme,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .54,
            child: Column(
              children: [
                ListTile(
                  title: const Text('目录'),
                  trailing: IconButton(
                    tooltip: '关闭目录',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: titles.length,
                    itemBuilder: (context, index) => ListTile(
                      title: Text(titles[index]),
                      contentPadding: EdgeInsetsDirectional.only(
                        start: levels.isEmpty
                            ? 16
                            : 16 + 12.0 * levels[index].clamp(0, 6),
                        end: 16,
                      ),
                      enabled: !groupLabels.contains(index),
                      selected: index == current,
                      selectedTileColor: theme.colorScheme.surfaceContainerHigh,
                      subtitle: index == current
                          ? Text(
                              readingPage == null
                                  ? '正在读'
                                  : '正在读 · 第 $readingPage 页',
                            )
                          : null,
                      trailing: pages.isEmpty ? null : Text('${pages[index]}'),
                      onTap: groupLabels.contains(index)
                          ? null
                          : () => Navigator.pop(context, index),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted && selected != null) onSelected(selected);
  }

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
      _navigationRevision++;
    });
    unawaited(_preferences.saveAnchor(bookId: _source.bookId, anchor: next));
  }

  Future<void> _showFlowOutline(
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
      return _showOutline(
        chapters.map((chapter) => chapter.title).toList(growable: false),
        chapterIndex,
        (index) => _chapter(chapters[index]),
      );
    }

    final currentChapterId = chapters[chapterIndex].id;
    final currentEntry = entries.indexWhere(
      (entry) =>
          entry.chapterId == currentChapterId && entry.blockId == blockId,
    );
    return _showOutline(
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

  Widget _flow(XiaoqiDocument document, ReaderAnchor? anchor) {
    final current =
        _chapterNavigation ?? (anchor is FlowReaderAnchor ? anchor : null);
    final chapters = document.chapters;
    final chapterIndex = math.max(
      0,
      chapters.indexWhere((chapter) => chapter.id == current?.chapterId),
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
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, dimensions) {
              return ReflowDocumentPager(
                verticalPadding: EdgeInsets.fromLTRB(
                  dimensions.maxWidth * _marginFraction,
                  16,
                  dimensions.maxWidth * _marginFraction,
                  28,
                ),
                key: ValueKey(_navigationRevision),
                sourceId: _sourceKey,
                document: document,
                initialChapterId: chapter.id,
                initialAnchor: current,
                mode: ReaderPaginationMode.vertical,
                verticalBackground: _dark ? _paperDark : Colors.white,
                onVisibleBlocksChanged: _onVisibleBlocks,
                verticalChapterTitleStyle: TextStyle(
                  fontFamily: 'NotoSerifCJKSC',
                  fontSize: dimensions.maxWidth >= 600 ? 36 : 26,
                  height: 1.4,
                  fontWeight: FontWeight.w700,
                  color: _ink,
                ),
                onAnchorChanged: (value) {
                  _flowPosition = value;
                  unawaited(
                    _preferences.saveAnchor(
                      bookId: _source.bookId,
                      anchor: value,
                    ),
                  );
                },
                blockBuilder: (context, slice, setSelection) {
                  final translation = _translationEnabled
                      ? _flowTranslations[slice.block.id]
                      : null;
                  final block = XiaoqiDocumentBlockView(
                    block: slice.block,
                    asset: assets[slice.block.assetId],
                    textOverride: translation ?? slice.text,
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
                        _flowSelection(editable, chapter, slice),
                    textStyleBuilder: (style) => style.copyWith(
                      fontFamily: slice.block.kind == 'code'
                          ? 'monospace'
                          : 'NotoSerifCJKSC',
                      color: _ink,
                      height: (style.height ?? 1.5) * _lineScale,
                      fontSize:
                          (_fontScale * (style.fontSize ?? 17)) +
                          (dimensions.maxWidth >= 600 ? 3 : 0),
                    ),
                  );
                  final location = FlowReaderAnchor(
                    sourceId: _sourceKey,
                    chapterId: chapter.id,
                    blockId: slice.block.id,
                    characterOffset: slice.startOffset,
                  );
                  return Stack(
                    children: [
                      block,
                      Positioned.fill(
                        child: _inkSurface(
                          location,
                          translation == null
                              ? 'original'
                              : 'ebook-translation',
                          text: translation ?? slice.text,
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
        _footer(
          title: chapter.title,
          page: chapterIndex + 1,
          pageCount: chapters.length,
          onPageSelected: (page) => _chapter(chapters[page - 1]),
          onRestoreFlow: (position) {
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
          onOutline: () =>
              _showFlowOutline(document, chapterIndex, current?.blockId),
        ),
      ],
    );
  }

  Future<void> _showDisplaySettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, updatePanel) {
          final theme = _readerTheme(context);
          void update(VoidCallback change) {
            if (!mounted) return;
            setState(change);
            updatePanel(() {});
          }

          Widget slider(
            String label,
            double value,
            double min,
            double max,
            ValueChanged<double> onChanged,
          ) => Row(
            children: [
              SizedBox(width: 56, child: Text(label)),
              Expanded(
                child: Slider(
                  label: label,
                  value: value.clamp(min, max).toDouble(),
                  min: min,
                  max: max,
                  onChanged: onChanged,
                ),
              ),
            ],
          );

          return Theme(
            data: theme,
            child: Material(
              color: theme.colorScheme.surface,
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('显示', style: theme.textTheme.titleMedium),
                      if (defaultTargetPlatform == TargetPlatform.android)
                        slider('亮度', _brightness, .05, 1, (value) {
                          update(() {
                            _brightness = value;
                            _hasBrightnessOverride = true;
                          });
                          unawaited(_applyBrightness(value));
                        }),
                      Row(
                        children: [
                          const SizedBox(width: 56, child: Text('主题')),
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: false, label: Text('默认')),
                              ButtonSegment(value: true, label: Text('深色')),
                            ],
                            selected: {_dark},
                            onSelectionChanged: (value) {
                              update(() => _dark = value.single);
                              widget.onDarkChanged?.call(_dark);
                              _classifyNearbyPages();
                              if (_pdf.isReady) _pdf.invalidate();
                            },
                          ),
                        ],
                      ),
                      if (!_isCompanionPdf(_source)) ...[
                        slider(
                          '字号',
                          _fontScale,
                          .8,
                          1.5,
                          (value) => update(() => _fontScale = value),
                        ),
                        slider(
                          '边距',
                          _marginFraction,
                          .025,
                          .12,
                          (value) => update(() => _marginFraction = value),
                        ),
                        slider(
                          '行距',
                          _lineScale,
                          .85,
                          1.35,
                          (value) => update(() => _lineScale = value),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setBool('reading-companion.dark', _dark),
      prefs.setDouble('reading-companion.font', _fontScale),
      prefs.setDouble('reading-companion.margin', _marginFraction),
      prefs.setDouble('reading-companion.line', _lineScale),
      if (_hasBrightnessOverride)
        prefs.setDouble('reading-companion.brightness', _brightness),
    ]);
  }

  Widget _flowSelection(
    EditableTextState editable,
    XiaoqiDocumentChapter chapter,
    ReaderBlockSlice slice,
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
    final passage = _passage(
      text,
      translated ? '${chapter.title} · 译文' : chapter.title,
      FlowReaderAnchor(
        sourceId: _sourceKey,
        chapterId: chapter.id,
        blockId: slice.block.id,
        characterOffset: translated ? slice.startOffset : offset + range.start,
      ),
      startOffset: translated ? null : offset + range.start,
      endOffset: translated ? null : offset + range.end,
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

  Widget _pdfDocument(ReaderAnchor? anchor) {
    final page = anchor is PdfReaderAnchor ? anchor.pageNumber : 1;
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              PdfViewer.file(
                _source.filePath,
                controller: _pdf,
                initialPageNumber: page,
                params: PdfViewerParams(
                  backgroundColor: _dark
                      ? const Color(0xFF111315)
                      : Colors.grey,
                  pagePaintCallbacks: [_paintDarkPage],
                  pageOverlaysBuilder: (context, rect, page) => [
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
                    _classifyNearbyPages();
                    unawaited(_detectPdfPage(document, _pdfPage));
                  },
                  onPageChanged: (next) {
                    if (!mounted || next == null) return;
                    setState(() {
                      _pdfPage = next;
                      _pdfTextAvailable = false;
                      _translationPending = false;
                      _translationError = null;
                    });
                    _reportSelection(false);
                    _scheduleTranslation();
                    final document = _pdfDocumentRef;
                    if (document != null) {
                      unawaited(_detectPdfPage(document, next));
                    }
                    _classifyNearbyPages();
                    unawaited(
                      _preferences.saveAnchor(
                        bookId: _source.bookId,
                        anchor: PdfReaderAnchor(
                          sourceId: _sourceKey,
                          pageNumber: next,
                        ),
                      ),
                    );
                  },
                  textSelectionParams: PdfTextSelectionParams(
                    enabled: !_inkEditing,
                    showContextMenuAutomatically: true,
                    buildSelectionHandle: _buildPdfSelectionHandle,
                    calcSelectionHandleOffset: _pdfSelectionHandleOffset,
                    onTextSelectionChange: _onPdfTextSelection,
                  ),
                  buildContextMenu: _pdfSelection,
                  onGeneralTap: (_, controller, details) {
                    if (!_inkEditing &&
                        details.type == PdfViewerGeneralTapType.longPress &&
                        details.tapOn == PdfViewerPart.background &&
                        !_pdfTextAvailable) {
                      AppToast.show(
                        context,
                        _pdfDocumentRef?.permissions?.allowsCopying == false
                            ? '这份 PDF 限制复制文字'
                            : '此页没有可选文字',
                      );
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
              if (_translationEnabled &&
                  _translatedPdfNumber == _pdfPage &&
                  _translatedPdfPage != null)
                _pdfTranslationView(_translatedPdfPage!),
            ],
          ),
        ),
        _footer(
          title: _source.displayName,
          page: _pdfPage,
          pageCount: _pdfPageCount,
          onPageSelected: (next) {
            if (_pdf.isReady) unawaited(_pdf.goToPage(pageNumber: next));
          },
          onOutline: _pdfPageCount == 0 ? null : _showPdfOutline,
        ),
      ],
    );
  }

  void _onPdfTextSelection(PdfTextSelection selection) {
    _reportSelection(selection.hasSelectedText);
  }

  Widget _pdfTranslationView(String translation) {
    final page = _pdfPage;
    var overscroll = 0.0;
    return Material(
      color: _dark ? _paperDark : Colors.white,
      child: NotificationListener<ScrollNotification>(
        onNotification: (event) {
          if (event is OverscrollNotification && event.dragDetails != null) {
            overscroll += event.overscroll;
          }
          if (event is ScrollEndNotification) {
            final target =
                page +
                (overscroll > 56
                    ? 1
                    : overscroll < -56
                    ? -1
                    : 0);
            overscroll = 0;
            if (!_selectionActive &&
                target != page &&
                target >= 1 &&
                target <= _pdfPageCount &&
                _pdf.isReady) {
              unawaited(_pdf.goToPage(pageNumber: target));
            }
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
    );
  }

  void _showPdfOutline() {
    final entries = _pdfCatalogEntries()
        .where((entry) {
          final page = entry.pdfPage;
          return page != null && page > 0 && page <= _pdfPageCount;
        })
        .toList(growable: false);
    final pages = entries.isEmpty
        ? List<int>.generate(_pdfPageCount, (index) => index + 1)
        : entries.map((entry) => entry.pdfPage!).toList(growable: false);
    final titles = entries.isEmpty
        ? pages.map((page) => '第 $page 页').toList(growable: false)
        : entries.map((entry) => entry.title).toList(growable: false);
    unawaited(
      _showOutline(
        titles,
        pages.lastIndexWhere((page) => page <= _pdfPage),
        (index) {
          if (pages[index] != _pdfPage)
            setState(() => _pageBeforeJump = _pdfPage);
          if (_pdf.isReady) unawaited(_pdf.goToPage(pageNumber: pages[index]));
        },
        pages: pages,
        readingPage: _pdfPage,
      ),
    );
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

  Widget? _pdfSelection(
    BuildContext context,
    PdfViewerContextMenuBuilderParams params,
  ) {
    final delegate = params.textSelectionDelegate;
    if (!delegate.isCopyAllowed || !delegate.hasSelectedText) return null;
    final localAnchor = params.anchorB ?? params.anchorA;
    final page = params.a?.page.pageNumber ?? _pdfPage;
    final endPage = params.b?.page.pageNumber ?? page;
    final label = endPage == page ? '第 $page 页' : '第 $page–$endPage 页';
    final anchor = PdfReaderAnchor(sourceId: _sourceKey, pageNumber: page);

    Future<void> withText(bool ask) async {
      final box = context.findRenderObject();
      final globalAnchor = box is RenderBox && box.attached
          ? box.localToGlobal(localAnchor)
          : localAnchor;
      final text = (await delegate.getSelectedText()).trim();
      if (!mounted || text.isEmpty) return;
      params.dismissContextMenu();
      final passage = _passage(
        text,
        label,
        anchor,
        startOffset: params.a?.index,
        endOffset: params.b == null ? null : params.b!.index + 1,
      );
      if (ask) {
        widget.onAsk(passage, globalAnchor);
      } else {
        widget.onAnnotate(passage);
      }
    }

    return Align(
      alignment: Alignment.topLeft,
      child: _selectionToolbar(
        above: params.anchorA,
        below: params.anchorB,
        onCopy: () {
          unawaited(delegate.copyTextSelection());
          params.dismissContextMenu();
        },
        onAnnotate: () => unawaited(withText(false)),
        onAsk: () => unawaited(withText(true)),
      ),
    );
  }

  void _copy(String text) {
    if (text.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    AppToast.show(context, '已复制');
  }

  Widget _footer({
    required String title,
    required int page,
    required int pageCount,
    required ValueChanged<int> onPageSelected,
    required VoidCallback? onOutline,
    ValueChanged<FlowReaderAnchor>? onRestoreFlow,
  }) {
    if (widget.immersive) {
      return SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 2, 16, 5),
        child: Align(
          alignment: Alignment.centerRight,
          child: Text(
            pageCount > 0 ? '$page / $pageCount' : '',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    void jumpTo(int destination) {
      if (destination == page) return;
      setState(() {
        _pageBeforeJump = page;
        _flowPositionBeforeJump = _flowPosition;
      });
      onPageSelected(destination);
    }

    Future<void> showProgress() async {
      var preview = page.toDouble();
      final previous = _pageBeforeJump;
      final destination = await showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('阅读进度', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Text('${preview.round()} / $pageCount'),
                  Slider(
                    value: preview,
                    min: 1,
                    max: math.max(1, pageCount).toDouble(),
                    onChanged: pageCount > 1
                        ? (value) => update(() => preview = value)
                        : null,
                    onChangeEnd: (value) =>
                        Navigator.pop(context, value.round()),
                  ),
                  if (previous != null)
                    TextButton.icon(
                      onPressed: () => Navigator.pop(context, previous),
                      icon: const Icon(Icons.undo),
                      label: const Text('返回跳转前位置'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      if (!mounted || destination == null) return;
      if (destination == previous) {
        final position = _flowPositionBeforeJump;
        setState(() {
          _pageBeforeJump = null;
          _flowPositionBeforeJump = null;
        });
        if (position != null && onRestoreFlow != null) {
          onRestoreFlow(position);
        } else {
          onPageSelected(destination);
        }
      } else {
        jumpTo(destination);
      }
    }

    final colors = _readerTheme(context).colorScheme;
    Widget action(IconData icon, String label, VoidCallback? pressed) =>
        Expanded(
          child: TextButton.icon(
            onPressed: pressed,
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        );
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pageCount > 0)
              TextButton(
                onPressed: showProgress,
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (page / pageCount).clamp(0, 1).toDouble(),
                        minHeight: 2,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text('$page / $pageCount'),
                  ],
                ),
              ),
            Row(
              children: [
                action(Icons.format_list_bulleted, '目录', onOutline),
                action(Icons.tune, '进度', pageCount > 0 ? showProgress : null),
                action(Icons.text_fields, '显示', _showDisplaySettings),
              ],
            ),
          ],
        ),
      ),
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
        if (snapshot.connectionState != ConnectionState.done) {
          return const _ReadingPlaceholder();
        }
        if (snapshot.hasError) {
          return _ReaderStatus(
            '无法读取这份资料',
            action: widget.onChooseSource != null ? '选择其他资料' : '打开本书资料',
            onAction: widget.onChooseSource ?? widget.onOpenLibrary,
          );
        }
        final data = snapshot.requireData;
        final document = data.document;
        return Material(
          color: _dark ? _paperDark : Colors.white,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                children: [
                  if (!widget.immersive)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!_inkEditing && widget.onSwitchFormat != null)
                            SegmentedButton<bool>(
                              showSelectedIcon: false,
                              segments: const [
                                ButtonSegment(value: true, label: Text('PDF')),
                                ButtonSegment(value: false, label: Text('电子书')),
                              ],
                              selected: {document == null},
                              onSelectionChanged: (selection) {
                                if (selection.single != (document == null)) {
                                  widget.onSwitchFormat?.call();
                                }
                              },
                            ),
                          if ((_inkEditing ? null : widget.onChooseSource)
                              case final choose?)
                            _ReaderButton(
                              label: '切换阅读资料',
                              icon: 'assets/images/reading_task_book.svg',
                              onPressed: choose,
                            ),
                          if (!_inkEditing)
                            TextButton.icon(
                              icon: SvgPicture.asset(
                                'assets/images/reading_companion_doodle.svg',
                                width: 18,
                                height: 18,
                                colorFilter: ColorFilter.mode(
                                  _ink,
                                  BlendMode.srcIn,
                                ),
                              ),
                              label: const Text('涂鸦'),
                              onPressed: !_inkLoaded && !_inkLoadFailed
                                  ? null
                                  : () {
                                      if (_inkLoadFailed) {
                                        unawaited(_loadInk());
                                        return;
                                      }
                                      setState(() {
                                        _inkEditing = true;
                                        _inkErasing = false;
                                      });
                                    },
                            )
                          else ...[
                            IconButton(
                              tooltip: '画笔',
                              icon: const Icon(Icons.edit_outlined),
                              isSelected: !_inkErasing,
                              onPressed: _inkSaving
                                  ? null
                                  : () => setState(() => _inkErasing = false),
                            ),
                            IconButton(
                              tooltip: '橡皮',
                              icon: const Icon(Icons.auto_fix_normal_outlined),
                              isSelected: _inkErasing,
                              onPressed: _inkSaving
                                  ? null
                                  : () => setState(() => _inkErasing = true),
                            ),
                            IconButton(
                              tooltip: '撤销涂鸦',
                              icon: const Icon(Icons.undo),
                              onPressed: _inkSaving || _inkUndo.isEmpty
                                  ? null
                                  : _undoInk,
                            ),
                            FilledButton(
                              onPressed: _inkSaving ? null : _finishInk,
                              child: Text(_inkSaving ? '保存中' : '完成'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  Expanded(
                    child: document == null
                        ? _pdfDocument(data.anchor)
                        : _flow(document, data.anchor),
                  ),
                ],
              ),
              if (!widget.immersive && _foreignSource && !_inkEditing)
                Positioned(
                  right: 74,
                  bottom: 110,
                  child: IconButton.filled(
                    tooltip: _translationEnabled ? '还原当前正文' : '连续翻译',
                    onPressed: _toggleTranslation,
                    icon: Text(_translationEnabled ? '原' : '译'),
                  ),
                ),
              if (!widget.immersive &&
                  !_inkEditing &&
                  widget.onFreeChat != null)
                Positioned(
                  right: 20,
                  bottom: 110,
                  child: IconButton.filled(
                    tooltip: 'AI 问答',
                    onPressed: widget.onFreeChat,
                    icon: const Text('AI'),
                  ),
                ),
              if (!widget.immersive &&
                  (_translationPending || _translationError != null))
                Positioned(
                  left: 12,
                  bottom: 110,
                  child: _translationError == null
                      ? const Chip(label: Text('翻译中'))
                      : ActionChip(
                          label: Text(_translationError!),
                          onPressed: _scheduleTranslation,
                        ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

class _CompanionInkRecord {
  const _CompanionInkRecord(this.size, this.text, this.strokes);

  final Size size;
  final String? text;
  final List<PageStroke> strokes;

  String encode() => jsonEncode({
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
) => materialTextSelectionHandleControls.buildHandle(
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
  final controls = materialTextSelectionHandleControls;
  final tip = controls.getHandleAnchor(type, 0);
  final size = controls.getHandleSize(0);
  return Offset(
    type == TextSelectionHandleType.left ? size.width - tip.dx : -tip.dx,
    anchor.type == PdfTextSelectionAnchorType.a
        ? size.height - tip.dy
        : -tip.dy,
  );
}

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
    MessageSelectionActionCard(
      primaryLabel: 'AI',
      primaryAsset: 'assets/icons/chat_note_editor/sparkle.svg',
      copyFirst: true,
      onPrimaryAction: onAsk,
      onCopy: onCopy,
      onAnnotate: onAnnotate,
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
