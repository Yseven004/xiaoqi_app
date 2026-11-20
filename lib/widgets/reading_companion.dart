import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:pdfrx/pdfrx.dart';

import '../features/ai_study_annotation/data/ai_conversation_history.dart';
import '../features/ai_study_annotation/domain/ai_chat_process.dart';
import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/book_source.dart';
import '../models/note.dart';
import '../models/pdf_catalog.dart';
import '../models/reader_pagination.dart';
import '../models/xiaoqi_document.dart';
import '../services/book_library_service.dart';
import '../services/database_service.dart';
import '../services/reader_pagination_preferences.dart';
import '../services/source_document_loader.dart';
import 'app_toast.dart';
import 'chat_message_scroll_view.dart';
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
  });

  final int bookId;
  final int sourceId;
  final String text;
  final String sourceName;
  final String locator;
  final ReaderAnchor anchor;
  final int? startOffset;
  final int? endOffset;

  bool sameLocationAs(ReadingCompanionPassage other) =>
      bookId == other.bookId &&
      sourceId == other.sourceId &&
      anchor == other.anchor &&
      startOffset == other.startOffset &&
      endOffset == other.endOffset &&
      text == other.text;
}

typedef _ReaderSelection = ({ReadingCompanionPassage passage, Offset position});
typedef _CompanionBook = ({
  String title,
  List<BookSourceRecord> sources,
  int? preferredSourceId,
});

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
  });

  final int? bookId;
  final BookLibraryService library;
  final List<AiConversationMessage> messages;
  final ValueListenable<String> streamingReply;
  final Widget Function(Widget history) composerBuilder;
  final ValueChanged<ReadingCompanionPassage> onPassageOpened;
  final VoidCallback? onPassageClosed;
  final ValueChanged<bool>? onChatVisibilityChanged;
  final AsyncCallback? onChooseBook;
  final AsyncCallback? onOpenLibrary;
  final Future<int?> Function(int bookId)? loadPreferredSourceId;

  @override
  ReadingCompanionState createState() => ReadingCompanionState();
}

class ReadingCompanionState extends State<ReadingCompanion> {
  final _surface = GlobalKey();
  final _chatScroll = ScrollController();
  late Future<_CompanionBook> _book;
  _ReaderSelection? _selection;
  int? _sourceId;
  bool _minimized = false;

  @override
  void initState() {
    super.initState();
    _book = _loadBook();
  }

  @override
  void didUpdateWidget(covariant ReadingCompanion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId ||
        oldWidget.library != widget.library) {
      _selection = null;
      _sourceId = null;
      _minimized = false;
      _book = _loadBook();
    }
  }

  @override
  void dispose() {
    _chatScroll.dispose();
    super.dispose();
  }

  Future<_CompanionBook> _loadBook() async {
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
        .where(
          (source) =>
              normalizeBookSourceFormat(source.format) == 'pdf' ||
              SourceDocumentLoader.isStructuredFormat(source.format),
        )
        .toList(growable: false);
    return (
      title: item?.book.title ?? '',
      sources: sources,
      preferredSourceId: await loadPreferredSourceId?.call(bookId),
    );
  }

  bool closeChatForBack() {
    if (_selection == null) return false;
    _closeChat();
    return true;
  }

  void _closeChat() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selection = null;
      _minimized = false;
    });
    widget.onChatVisibilityChanged?.call(false);
    widget.onPassageClosed?.call();
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
    if (_selection != null) _closeChat();
    setState(() => _sourceId = sources[next].id);
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
                  return const _ReaderStatus('正在打开阅读资料');
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
                return _CompanionDocument(
                  key: ValueKey((current.bookId, current.id)),
                  source: current,
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
          if (_selection case final selection?)
            _positionChat(constraints, selection),
        ],
      ),
    ),
  );

  Widget _positionChat(BoxConstraints available, _ReaderSelection selection) {
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
    final top = (selection.position.dy + 12)
        .clamp(8.0, math.max(8.0, available.maxHeight - height - 8))
        .toDouble();
    return Positioned(
      right: right,
      top: top,
      width: width,
      height: height,
      child: _chatCard(selection.passage),
    );
  }

  Widget _chatCard(ReadingCompanionPassage passage) => Material(
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
                  child: _PassageQuote(text: passage.text),
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
  });

  final BookSourceRecord source;
  final BookLibraryService library;
  final void Function(ReadingCompanionPassage, Offset) onAsk;
  final ValueChanged<ReadingCompanionPassage> onAnnotate;
  final VoidCallback? onChooseSource;
  final VoidCallback? onOpenLibrary;

  @override
  State<_CompanionDocument> createState() => _CompanionDocumentState();
}

class _CompanionDocumentState extends State<_CompanionDocument> {
  static const _preferences = ReaderPaginationPreferences();
  late Future<({XiaoqiDocument? document, ReaderAnchor? anchor})> _loading;
  final _pdf = PdfViewerController();
  FlowReaderAnchor? _chapterNavigation;
  int _navigationRevision = 0;
  int _pdfPage = 1;
  int _pdfPageCount = 0;
  double? _pendingPage;
  double _fontScale = 1;

  BookSourceRecord get _source => widget.source;
  String get _sourceKey => _source.id.toString();

  @override
  void initState() {
    super.initState();
    _loading = _loadDocument();
  }

  Future<({XiaoqiDocument? document, ReaderAnchor? anchor})>
  _loadDocument() async {
    final source = _source;
    final anchor = await _preferences.loadAnchor(
      bookId: source.bookId,
      sourceId: source.id,
    );
    if (normalizeBookSourceFormat(source.format) == 'pdf') {
      if (!await File(source.filePath).exists()) {
        throw const FileSystemException('找不到原始 PDF');
      }
      return (document: null, anchor: anchor);
    }
    final document =
        await widget.library.loadBookSourceRevision(source) ??
        await const SourceDocumentLoader().parseFile(
          source.filePath,
          format: source.format,
        );
    if (document.chapters.isEmpty) {
      throw const FormatException('电子资料没有可读章节');
    }
    return (document: document, anchor: anchor);
  }

  Future<void> _showOutline(
    List<String> titles,
    int current,
    ValueChanged<int> onSelected,
  ) async {
    final selected = await _chooseReaderItem(
      context,
      title: '目录',
      labels: titles,
      activeIndex: current,
    );
    if (mounted && selected != null) onSelected(selected);
  }

  void _chapter(XiaoqiDocumentChapter chapter) {
    FocusManager.instance.primaryFocus?.unfocus();
    final next = FlowReaderAnchor(sourceId: _sourceKey, chapterId: chapter.id);
    setState(() {
      _chapterNavigation = next;
      _navigationRevision++;
    });
    unawaited(_preferences.saveAnchor(bookId: _source.bookId, anchor: next));
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
    final assets = {for (final asset in document.assets) asset.id: asset};
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, dimensions) {
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: math.max(0, dimensions.maxWidth * .062 - 24),
                ),
                child: ReflowDocumentPager(
                  key: ValueKey(_navigationRevision),
                  sourceId: _sourceKey,
                  document: document,
                  initialChapterId: chapter.id,
                  initialAnchor: current,
                  mode: ReaderPaginationMode.vertical,
                  verticalChapterTitleStyle: TextStyle(
                    fontFamily: 'NotoSerifCJKSC',
                    fontSize: dimensions.maxWidth >= 600 ? 36 : 26,
                    height: 1.4,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF212121),
                  ),
                  onAnchorChanged: (value) => unawaited(
                    _preferences.saveAnchor(
                      bookId: _source.bookId,
                      anchor: value,
                    ),
                  ),
                  blockBuilder: (context, slice, setSelection) =>
                      XiaoqiDocumentBlockView(
                        block: slice.block,
                        asset: assets[slice.block.assetId],
                        textOverride: slice.text,
                        tableRowsOverride: slice.tableRows,
                        continuation: slice.continuation,
                        onSelectionChanged: setSelection,
                        contextMenuBuilder: (context, editable) =>
                            _flowSelection(editable, chapter, slice),
                        textStyleBuilder: (style) => style.copyWith(
                          fontFamily: slice.block.kind == 'code'
                              ? 'monospace'
                              : 'NotoSerifCJKSC',
                          color: const Color(0xFF262626),
                          fontSize:
                              (_fontScale * (style.fontSize ?? 17)) +
                              (dimensions.maxWidth >= 600 ? 3 : 0),
                        ),
                      ),
                ),
              );
            },
          ),
        ),
        _footer(
          title: chapter.title,
          page: chapterIndex + 1,
          pageCount: chapters.length,
          onPageSelected: (page) => _chapter(chapters[page - 1]),
          onOutline: () => _showOutline(
            chapters.map((chapter) => chapter.title).toList(growable: false),
            chapterIndex,
            (index) => _chapter(chapters[index]),
          ),
          onTextSize: _changeTextSize,
        ),
      ],
    );
  }

  Future<void> _changeTextSize() async {
    const scales = [.9, 1.0, 1.15, 1.3];
    final next = await _chooseReaderItem(
      context,
      title: '文字大小',
      labels: const ['小', '默认', '大', '特大'],
      activeIndex: scales.indexOf(_fontScale),
    );
    if (mounted && next != null) setState(() => _fontScale = scales[next]);
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
    final offset = value.text == slice.text ? slice.startOffset : 0;
    final passage = _passage(
      text,
      chapter.title,
      FlowReaderAnchor(
        sourceId: _sourceKey,
        chapterId: chapter.id,
        blockId: slice.block.id,
        characterOffset: offset + range.start,
      ),
      startOffset: offset + range.start,
      endOffset: offset + range.end,
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
  }) => ReadingCompanionPassage(
    bookId: _source.bookId,
    sourceId: _source.id,
    text: text,
    sourceName: _source.displayName,
    locator: label,
    anchor: anchor,
    startOffset: startOffset,
    endOffset: endOffset,
  );

  Widget _pdfDocument(ReaderAnchor? anchor) {
    final page = anchor is PdfReaderAnchor ? anchor.pageNumber : 1;
    return Column(
      children: [
        Expanded(
          child: PdfViewer.file(
            _source.filePath,
            controller: _pdf,
            initialPageNumber: page,
            params: PdfViewerParams(
              loadingBannerBuilder: (_, _, _) =>
                  const _ReaderStatus('正在打开 PDF'),
              errorBannerBuilder: (_, _, _, _) => _ReaderStatus(
                'PDF 无法打开',
                action: widget.onChooseSource != null ? '选择其他资料' : '打开本书资料',
                onAction: widget.onChooseSource ?? widget.onOpenLibrary,
              ),
              onViewerReady: (document, controller) {
                if (!mounted) return;
                setState(() {
                  _pdfPageCount = document.pages.length;
                  _pdfPage = controller.pageNumber ?? 1;
                });
              },
              onPageChanged: (next) {
                if (!mounted || next == null) return;
                setState(() => _pdfPage = next);
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
              textSelectionParams: const PdfTextSelectionParams(
                showContextMenuAutomatically: true,
              ),
              buildContextMenu: _pdfSelection,
            ),
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
      _showOutline(titles, pages.indexOf(_pdfPage), (index) {
        if (_pdf.isReady) unawaited(_pdf.goToPage(pageNumber: pages[index]));
      }),
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

    return _selectionToolbar(
      above: params.anchorA,
      below: params.anchorB,
      onCopy: () {
        unawaited(delegate.copyTextSelection());
        params.dismissContextMenu();
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

  Widget _footer({
    required String title,
    required int page,
    required int pageCount,
    required ValueChanged<int> onPageSelected,
    required VoidCallback? onOutline,
    VoidCallback? onTextSize,
  }) {
    final selected = (_pendingPage ?? page.toDouble())
        .clamp(1.0, math.max(1, pageCount).toDouble())
        .toDouble();
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.symmetric(horizontal: 16),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFE3E3E3))),
        ),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: onOutline,
              icon: _readerIcon(
                'assets/icons/note_format/format_list_bulleted.svg',
              ),
              label: const Text('目录'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF303030),
              ),
            ),
            if (MediaQuery.sizeOf(context).width >= 600)
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFF666666)),
                ),
              ),
            Expanded(
              flex: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 4,
                  ),
                  activeTrackColor: const Color(0xFF454545),
                  inactiveTrackColor: const Color(0xFFDDDDDD),
                  thumbColor: const Color(0xFF454545),
                  overlayColor: const Color(0x15454545),
                ),
                child: Slider(
                  value: selected,
                  min: 1,
                  max: math.max(1, pageCount).toDouble(),
                  onChanged: pageCount > 1
                      ? (value) => setState(() => _pendingPage = value)
                      : null,
                  onChangeEnd: pageCount > 1
                      ? (value) {
                          setState(() => _pendingPage = null);
                          onPageSelected(value.round());
                        }
                      : null,
                  semanticFormatterCallback: (value) =>
                      '第 ${value.round()} 项，共 $pageCount 项',
                ),
              ),
            ),
            if (pageCount > 0)
              Text(
                '${selected.round()} / $pageCount',
                style: const TextStyle(color: Color(0xFF666666), fontSize: 13),
              ),
            if (onTextSize != null)
              _ReaderButton(
                label: '文字大小',
                icon: 'assets/icons/chat_note_editor/text-aa.svg',
                onPressed: onTextSize,
              ),
            if (widget.onChooseSource case final choose?)
              _ReaderButton(
                label: '切换阅读资料',
                icon: 'assets/images/reading_task_book.svg',
                onPressed: choose,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(
      textSelectionTheme: const TextSelectionThemeData(
        selectionColor: Color(0x33212121),
        selectionHandleColor: Color(0xFF353535),
      ),
    ),
    child: FutureBuilder(
      future: _loading,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _ReaderStatus('正在打开阅读资料');
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
        return document == null
            ? _pdfDocument(data.anchor)
            : _flow(document, data.anchor);
      },
    ),
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
  toolbarBuilder: (context, child) => Material(
    type: MaterialType.card,
    color: const Color(0xFF262626),
    borderRadius: BorderRadius.circular(10),
    elevation: 3,
    clipBehavior: Clip.antiAlias,
    child: child,
  ),
  children: [
    _SelectionAction('复制', onCopy),
    _SelectionAction('注释', onAnnotate, divider: true),
    _SelectionAction('AI', onAsk, divider: true),
  ],
);

class _SelectionAction extends StatelessWidget {
  const _SelectionAction(this.label, this.onPressed, {this.divider = false});

  final String label;
  final VoidCallback onPressed;
  final bool divider;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: divider
          ? const Border(left: BorderSide(color: Color(0xFF626262)))
          : null,
    ),
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 40),
        padding: const EdgeInsets.symmetric(horizontal: 13),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: const RoundedRectangleBorder(),
      ),
      child: Text(label),
    ),
  );
}

class _CompanionHistory extends StatelessWidget {
  const _CompanionHistory({
    required this.controller,
    required this.messages,
    required this.streamingReply,
  });

  final ScrollController controller;
  final List<AiConversationMessage> messages;
  final ValueListenable<String> streamingReply;

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
                  key: ValueKey(turn.id),
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
