import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/reader_pagination.dart';
import '../models/xiaoqi_document.dart';

typedef ReaderBlockSliceBuilder =
    Widget Function(
      BuildContext context,
      ReaderBlockSlice slice,
      ValueChanged<bool> onSelectionChanged,
    );

/// Displays a format-neutral document as horizontally paginated screen pages.
///
/// The source document stays immutable. Pagination only creates references to
/// blocks and text ranges so an anchor can be resolved again after a resize or
/// text-scale change.
class ReflowDocumentPager extends StatefulWidget {
  const ReflowDocumentPager({
    super.key,
    required this.document,
    required this.sourceId,
    required this.initialChapterId,
    required this.mode,
    required this.blockBuilder,
    this.initialAnchor,
    this.onAnchorChanged,
    this.onChapterChanged,
    this.onProgressChanged,
  });

  final XiaoqiDocument document;
  final String sourceId;
  final String? initialChapterId;
  final ReaderPaginationMode mode;
  final FlowReaderAnchor? initialAnchor;
  final ReaderBlockSliceBuilder blockBuilder;
  final ValueChanged<FlowReaderAnchor>? onAnchorChanged;
  final ValueChanged<String>? onChapterChanged;
  final ValueChanged<ReaderPaginationProgress>? onProgressChanged;

  @override
  State<ReflowDocumentPager> createState() => _ReflowDocumentPagerState();
}

class _ReflowDocumentPagerState extends State<ReflowDocumentPager> {
  late final PageController _pageController;
  late final ScrollController _verticalController;
  List<ReaderPageSlice> _pages = const [];
  Map<String, int> _chapterFirstPages = const {};
  Object? _layoutSignature;
  Object? _preparingSignature;
  FlowReaderAnchor? _requestedAnchor;
  int _currentPage = 0;
  bool _selectionActive = false;
  bool _isPreparing = false;
  int _dragStartPage = 0;
  final Map<String, GlobalKey> _verticalBlockKeys = {};
  bool _verticalRestoreScheduled = false;

  /// Chapter whose pages are currently published on their own, before the
  /// chapters in front of it have been paginated.
  String? _provisionalChapterId;

  /// Cancels the pagination pass that a widget update, a relayout or dispose
  /// made obsolete.
  int _paginationEpoch = 0;
  double _prepareWidth = 0;
  double _prepareHeight = 0;
  TextScaler _prepareTextScaler = TextScaler.noScaling;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _verticalController = ScrollController();
    _requestedAnchor = widget.initialAnchor;
  }

  @override
  void didUpdateWidget(covariant ReflowDocumentPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document ||
        oldWidget.sourceId != widget.sourceId) {
      _invalidatePagination(clearVerticalKeys: true);
      _isPreparing = false;
      _requestedAnchor = widget.initialAnchor;
    } else if (oldWidget.mode != widget.mode) {
      // A mode change makes the old screen-page pass obsolete. In particular,
      // do not let a horizontal pass keep measuring while vertical mode builds
      // its chapter, or let its later snapshots overwrite the new mode.
      final currentAnchor = _requestedAnchor;
      _invalidatePagination();
      _isPreparing = false;
      _requestedAnchor = currentAnchor ?? widget.initialAnchor;
      _verticalRestoreScheduled = widget.mode == ReaderPaginationMode.vertical;
    } else if (oldWidget.initialAnchor != widget.initialAnchor) {
      _requestedAnchor = widget.initialAnchor;
      final provisionalChapterId = _provisionalChapterId;
      if (_isPreparing &&
          provisionalChapterId != null &&
          provisionalChapterId != _preferredChapterId()) {
        // Only the previous anchor chapter has been published so far: restart
        // the pass so the newly requested chapter is paginated first.
        _restartPrepare();
      } else if (_pages.isNotEmpty) {
        final target = _resolveTargetPage();
        _currentPage = target;
        _scheduleJump(target);
      }
    }
  }

  @override
  void dispose() {
    _paginationEpoch++;
    _pageController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  void _invalidatePagination({bool clearVerticalKeys = false}) {
    _paginationEpoch++;
    _layoutSignature = null;
    _preparingSignature = null;
    _pages = const [];
    _chapterFirstPages = const {};
    _provisionalChapterId = null;
    _currentPage = 0;
    if (clearVerticalKeys) _verticalBlockKeys.clear();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScaler = MediaQuery.textScalerOf(context);
        final width = math.max(1.0, constraints.maxWidth - 48).toDouble();
        final height = math.max(1.0, constraints.maxHeight - 46).toDouble();
        final signature = Object.hash(
          widget.document,
          widget.sourceId,
          width.round(),
          height.round(),
          textScaler.hashCode,
        );
        if (widget.mode == ReaderPaginationMode.horizontal &&
            _layoutSignature != signature &&
            _preparingSignature != signature) {
          _schedulePrepare(
            signature,
            width: width,
            height: height,
            textScaler: textScaler,
          );
        }
        if (widget.mode == ReaderPaginationMode.vertical) {
          return _buildVertical(context);
        }

        if (_layoutSignature != signature || _pages.isEmpty) {
          return Center(
            child: Text(_isPreparing ? '正在准备阅读页面' : '资料暂时没有可读取的内容'),
          );
        }

        final safePage = _currentPage.clamp(0, _pages.length - 1).toInt();
        final canPage = !_isPreparing && !_selectionActive;
        return Semantics(
          container: true,
          label: _pageSemantics(_pages[safePage], safePage),
          onIncrease: canPage && safePage + 1 < _pages.length
              ? () => _goToPage(safePage + 1)
              : null,
          onDecrease: canPage && safePage > 0
              ? () => _goToPage(safePage - 1)
              : null,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.axis == Axis.horizontal &&
                  notification is ScrollStartNotification) {
                _dragStartPage =
                    (_pageController.page ?? _currentPage.toDouble()).round();
              }
              return false;
            },
            child: PageView.builder(
              key: const Key('book_body_document_pager'),
              controller: _pageController,
              // pageSnapping adds Flutter's PageScrollPhysics above the
              // supplied physics. The reader owns the threshold below.
              pageSnapping: false,
              allowImplicitScrolling: canPage,
              physics: !canPage
                  ? const NeverScrollableScrollPhysics()
                  : _ReaderPageScrollPhysics(
                      dragStartPage: () => _dragStartPage,
                    ),
              itemCount: _pages.length,
              onPageChanged: (index) {
                if (!mounted) return;
                setState(() => _currentPage = index);
                _emitAnchor(index);
                _emitProgress(index);
              },
              itemBuilder: (context, index) => _buildPage(
                context,
                _pages[index],
                index,
                pageHeight: constraints.maxHeight,
              ),
            ),
          ),
        );
      },
    );
  }

  void _schedulePrepare(
    Object signature, {
    required double width,
    required double height,
    required TextScaler textScaler,
  }) {
    _preparingSignature = signature;
    _prepareWidth = width;
    _prepareHeight = height;
    _prepareTextScaler = textScaler;
    _isPreparing = true;
    // Any pass that is still running belongs to an older layout or document.
    final epoch = ++_paginationEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _preparingSignature != signature) return;
      await _paginateWithEpoch(
        signature,
        epoch: epoch,
        width: width,
        height: height,
        textScaler: textScaler,
      );
    });
  }

  /// Re-runs the pass for the layout that is already being paginated.
  void _restartPrepare() {
    final signature = _preparingSignature;
    if (signature == null) return;
    _schedulePrepare(
      signature,
      width: _prepareWidth,
      height: _prepareHeight,
      textScaler: _prepareTextScaler,
    );
  }

  Future<void> _paginateWithEpoch(
    Object signature, {
    required int epoch,
    required double width,
    required double height,
    required TextScaler textScaler,
  }) async {
    bool isCancelled() => !mounted || epoch != _paginationEpoch;
    final gate = _PageYieldGate(isCancelled: isCancelled);
    await _paginateDocumentProgressive(
      widget.document,
      width: width,
      height: height,
      textScaler: textScaler,
      preferredChapterId: _preferredChapterId(),
      gate: gate,
      onPublish: (publish) => _applyPublish(signature, epoch, publish),
    );
  }

  /// Publishes one incremental snapshot of the pagination pass.
  ///
  /// Snapshots that still contain pages in front of the reader's position keep
  /// the current page; the snapshot that places the anchor chapter at its real
  /// index shifts the reader by that offset so the visible content does not
  /// change under a reader who already started reading.
  void _applyPublish(Object signature, int epoch, _PaginationPublish publish) {
    if (!mounted || epoch != _paginationEpoch) return;
    final anchorPage = _findAnchorPage(publish.pages);
    final shiftOffset = _shiftOffsetFor(publish);
    final int target;
    if (shiftOffset != null) {
      // The same content now lives at its final index.
      target = (shiftOffset + _currentPage)
          .clamp(0, publish.pages.length - 1)
          .toInt();
    } else {
      target =
          anchorPage ?? publish.chapterFirstPages[_preferredChapterId()] ?? 0;
    }
    // A page that is still ahead of the requested anchor can move again later,
    // so the parent is only told about a page that will not be replaced.
    final reportable =
        publish.complete || anchorPage != null || _anchorIsForeign;
    final moved = shiftOffset != null || target != _currentPage;
    setState(() {
      _pages = publish.pages;
      _chapterFirstPages = publish.chapterFirstPages;
      _provisionalChapterId = publish.provisionalChapterId;
      _layoutSignature = signature;
      _currentPage = target;
      _isPreparing = !publish.complete;
    });
    if (moved) {
      _scheduleJump(target, report: reportable);
    } else if (publish.complete) {
      _scheduleJump(target);
    }
    if (publish.complete) {
      // The finished pass always reports its final progress, also in vertical
      // mode where there is no page controller to jump.
      _emitProgress(target);
    }
  }

  /// Page offset the reader moves by when a provisionally published chapter is
  /// placed at its real index, or null when the snapshot moves no page.
  int? _shiftOffsetFor(_PaginationPublish publish) {
    final provisionalChapterId = _provisionalChapterId;
    final placedChapterFirstPage = publish.placedChapterFirstPage;
    if (provisionalChapterId == null ||
        placedChapterFirstPage == null ||
        publish.placedChapterId != provisionalChapterId) {
      return null;
    }
    return placedChapterFirstPage;
  }

  Widget _buildVertical(BuildContext context) {
    final chapterId = _requestedAnchor?.chapterId ?? widget.initialChapterId;
    final chapter = widget.document.chapters.firstWhere(
      (item) => item.id == chapterId,
      orElse: () => widget.document.chapters.first,
    );
    final blocks = chapter.blocks.isEmpty
        ? [
            XiaoqiDocumentBlock(
              id: '${chapter.id}:plain',
              kind: 'paragraph',
              text: chapter.plainText,
              sourceLocator: chapter.sourceLocator,
            ),
          ]
        : chapter.blocks;
    final blockKeys = <String, GlobalKey>{
      for (var index = 0; index < blocks.length; index++)
        _verticalKey(chapter.id, blocks[index].id, index): _verticalBlockKeys
            .putIfAbsent(
              _verticalKey(chapter.id, blocks[index].id, index),
              () => GlobalKey(),
            ),
    };
    final showTitle =
        blocks.isEmpty ||
        blocks.first.kind != 'heading' ||
        blocks.first.text != chapter.title;
    final result = ColoredBox(
      color: Colors.white,
      child: SingleChildScrollView(
        key: const Key('book_body_document_vertical_scroll'),
        controller: _verticalController,
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
        child: NotificationListener<ScrollEndNotification>(
          onNotification: (_) {
            _emitVerticalAnchor(chapter.id, blocks, blockKeys);
            return false;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showTitle) ...[
                Text(
                  chapter.title,
                  style: const TextStyle(
                    color: Color(0xFF252525),
                    fontSize: 22,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 18),
              ],
              for (var index = 0; index < blocks.length; index++)
                KeyedSubtree(
                  key:
                      blockKeys[_verticalKey(
                        chapter.id,
                        blocks[index].id,
                        index,
                      )],
                  child: widget.blockBuilder(
                    context,
                    ReaderBlockSlice(
                      block: blocks[index],
                      text: blocks[index].text,
                    ),
                    (active) {
                      if (!mounted || _selectionActive == active) return;
                      setState(() => _selectionActive = active);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (_verticalRestoreScheduled) {
      _verticalRestoreScheduled = false;
      _scheduleVerticalRestore(chapter.id, blocks, blockKeys);
    }
    return result;
  }

  String _verticalKey(String chapterId, String blockId, int index) =>
      '$chapterId::$index::$blockId';

  void _scheduleVerticalRestore(
    String chapterId,
    List<XiaoqiDocumentBlock> blocks,
    Map<String, GlobalKey> blockKeys,
  ) {
    final anchor = _requestedAnchor;
    final targetBlockId = anchor?.blockId;
    if (targetBlockId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final index = blocks.indexWhere((block) => block.id == targetBlockId);
      if (index < 0) return;
      final target = blockKeys[_verticalKey(chapterId, targetBlockId, index)]
          ?.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(target, duration: Duration.zero, alignment: .08);
    });
  }

  void _emitVerticalAnchor(
    String chapterId,
    List<XiaoqiDocumentBlock> blocks,
    Map<String, GlobalKey> blockKeys,
  ) {
    final viewport = context.findRenderObject();
    final viewportBox = viewport is RenderBox ? viewport : null;
    final viewportTop = viewportBox?.localToGlobal(Offset.zero).dy ?? 0;
    final viewportBottom =
        viewportTop + (viewportBox?.size.height ?? double.infinity);
    final targetLine = viewportTop + 80;
    XiaoqiDocumentBlock? closest;
    var closestDistance = double.infinity;
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      final render = blockKeys[_verticalKey(chapterId, block.id, index)]
          ?.currentContext
          ?.findRenderObject();
      if (render is! RenderBox) continue;
      final top = render.localToGlobal(Offset.zero).dy;
      final bottom = top + render.size.height;
      if (bottom < viewportTop || top > viewportBottom) continue;
      final distance = (top - targetLine).abs();
      if (distance < closestDistance) {
        closest = block;
        closestDistance = distance;
      }
    }
    if (closest == null) return;
    final anchor = FlowReaderAnchor(
      sourceId: widget.sourceId,
      chapterId: chapterId,
      blockId: closest.id,
    );
    _requestedAnchor = anchor;
    widget.onAnchorChanged?.call(anchor);
    widget.onChapterChanged?.call(chapterId);
  }

  Widget _buildPage(
    BuildContext context,
    ReaderPageSlice page,
    int index, {
    required double pageHeight,
  }) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (page.showChapterTitle) ...[
          Text(
            page.chapterTitle,
            style: const TextStyle(
              color: Color(0xFF252525),
              fontSize: 22,
              height: 1.3,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 18),
        ],
        for (final slice in page.blocks)
          widget.blockBuilder(context, slice, (active) {
            if (!mounted || _selectionActive == active) return;
            setState(() => _selectionActive = active);
          }),
      ],
    );

    return Semantics(
      key: Key('book_body_document_page_$index'),
      label: _pageSemantics(page, index),
      child: ColoredBox(
        color: Colors.white,
        child: SingleChildScrollView(
          physics: page.mayOverflow
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, pageHeight - 46).toDouble(),
            ),
            child: content,
          ),
        ),
      ),
    );
  }

  String _pageSemantics(ReaderPageSlice page, int index) =>
      '${page.chapterTitle}，第 ${index + 1} 页'
      '${page.originalPageLabel == null ? '' : '，原书第 ${page.originalPageLabel} 页'}';

  void _scheduleJump(int target, {bool report = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      final safe = target.clamp(0, _pages.length - 1).toInt();
      if ((_pageController.page ?? 0).round() != safe) {
        _pageController.jumpToPage(safe);
      }
      if (!report) return;
      _emitAnchor(safe);
      _emitProgress(safe);
    });
  }

  void _goToPage(int index) {
    if (index < 0 || index >= _pages.length || index == _currentPage) return;
    _pageController.animateToPage(
      index,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _emitAnchor(int index) {
    if (index < 0 || index >= _pages.length) return;
    final page = _pages[index];
    final first = page.blocks.isEmpty ? null : page.blocks.first;
    final anchor = FlowReaderAnchor(
      sourceId: widget.sourceId,
      chapterId: page.chapterId,
      blockId: first?.block.id,
      characterOffset: first?.startOffset ?? 0,
    );
    _requestedAnchor = anchor;
    widget.onAnchorChanged?.call(anchor);
    widget.onChapterChanged?.call(page.chapterId);
  }

  void _emitProgress(int index) {
    if (index < 0 || index >= _pages.length) return;
    final page = _pages[index];
    widget.onProgressChanged?.call(
      ReaderPaginationProgress(
        currentScreenPage: index + 1,
        screenPageCount: _pages.length,
        originalPageLabel: page.originalPageLabel,
        originalPageCount: widget.document.originalPageCount,
      ),
    );
  }

  int _resolveTargetPage() =>
      _findAnchorPage(_pages) ?? _chapterFirstPages[_preferredChapterId()] ?? 0;

  /// Page that holds [_requestedAnchor], or null while that block has not been
  /// paginated yet.
  int? _findAnchorPage(List<ReaderPageSlice> pages) {
    final anchor = _requestedAnchor;
    if (anchor == null || anchor.sourceId != widget.sourceId) return null;
    // A split block uses [startOffset, endOffset). Search from the end so an
    // offset exactly at a page boundary belongs to the new continuation page,
    // not the page that just ended. The inclusive check still keeps EOF
    // anchors resolvable to the final slice.
    for (var i = pages.length - 1; i >= 0; i--) {
      final page = pages[i];
      if (page.chapterId != anchor.chapterId) continue;
      for (final slice in page.blocks) {
        if (slice.block.id == anchor.blockId &&
            anchor.characterOffset >= slice.startOffset &&
            anchor.characterOffset <= (slice.endOffset ?? slice.startOffset)) {
          return i;
        }
      }
    }
    return null;
  }

  /// Chapter the reader asked for: the anchor chapter, else the initial one.
  String? _preferredChapterId() =>
      _requestedAnchor?.chapterId ?? widget.initialChapterId;

  /// True when [_requestedAnchor] can never be matched in this document, so the
  /// chapter fallback is already the final answer.
  bool get _anchorIsForeign {
    final anchor = _requestedAnchor;
    return anchor == null || anchor.sourceId != widget.sourceId;
  }
}

/// Snaps a reflowable page using the same distance/velocity rule as the PDF
/// reader instead of Flutter's default half-page threshold.
class _ReaderPageScrollPhysics extends ScrollPhysics {
  const _ReaderPageScrollPhysics({required this.dragStartPage, super.parent});

  final int Function() dragStartPage;

  static const _minDistance = 48.0;
  static const _distanceFraction = .16;
  static const _minVelocity = 650.0;

  @override
  _ReaderPageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _ReaderPageScrollPhysics(
        dragStartPage: dragStartPage,
        parent: buildParent(ancestor),
      );

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final viewport = position.viewportDimension;
    if (viewport <= 0) {
      return super.createBallisticSimulation(position, velocity);
    }

    final maxPage =
        ((position.maxScrollExtent - position.minScrollExtent) / viewport)
            .round();
    final startPage = dragStartPage().clamp(0, maxPage).toInt();
    final startPixels = position.minScrollExtent + startPage * viewport;
    final delta = position.pixels - startPixels;
    final distanceThreshold = math.max(
      _minDistance,
      viewport * _distanceFraction,
    );
    final shouldAdvance =
        delta.abs() >= distanceThreshold || velocity.abs() >= _minVelocity;

    var targetPage = startPage;
    if (shouldAdvance) {
      final direction = velocity.abs() >= _minVelocity
          ? velocity.sign
          : delta.sign;
      if (direction != 0) targetPage += direction.toInt();
    }
    targetPage = targetPage.clamp(0, maxPage).toInt();
    final targetPixels = position.minScrollExtent + targetPage * viewport;
    final tolerance = toleranceFor(position);
    if ((targetPixels - position.pixels).abs() <= tolerance.distance) {
      return null;
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      targetPixels,
      velocity,
      tolerance: tolerance,
    );
  }
}

/// Pages that may accumulate before another incremental snapshot is published.
///
/// The first snapshot of a pass is always published once a single page exists,
/// so the reader paints the anchor chapter instead of a loading placeholder.
const int _pagesPerPublish = 8;

/// Hands the event loop a chance to run input and frames between slices of
/// pagination work.
///
/// [tick] counts text measurements and only creates a zero-duration timer once
/// a small budget is spent: a small document therefore still paginates in one
/// go without extra scheduling, while a huge chapter can no longer hold the
/// platform thread for seconds. Awaiting that timer returns control to the
/// event loop; it is a scheduler hand-off, not a delay.
class _PageYieldGate {
  _PageYieldGate({required this.isCancelled});

  /// Whether the pass that owns this gate has been superseded or disposed.
  final bool Function() isCancelled;

  /// Text measurements allowed between two event loop turns.
  static const int _unitsPerYield = 4;

  /// Block iterations allowed between two event loop turns without measuring.
  static const int _blocksPerYield = 128;

  int _units = 0;
  int _blocks = 0;

  bool get cancelled => isCancelled();

  Future<void> tick() async {
    if (++_units < _unitsPerYield) return;
    _units = 0;
    await Future<void>.delayed(Duration.zero);
  }

  /// Safety valve for blocks that measure no text (page breaks, dividers, empty
  /// paragraphs) so a chapter made of them cannot hold the thread either.
  Future<void> tickBlock() async {
    if (++_blocks < _blocksPerYield) return;
    _blocks = 0;
    await Future<void>.delayed(Duration.zero);
  }
}

/// Reports a chapter's finished pages while the chapter is still being
/// paginated. [chapterPages] is the live chapter list, so a listener has to copy
/// what it keeps.
typedef _ChapterPageListener =
    void Function(List<ReaderPageSlice> chapterPages, int chapterPageCount);

/// One incremental pagination snapshot.
///
/// The final snapshot of a pass always holds exactly the pages a plain
/// sequential pass would have produced; earlier snapshots only exist so the
/// reader can paint pages while the rest of the document is still measured.
class _PaginationPublish {
  const _PaginationPublish({
    required this.pages,
    required this.chapterFirstPages,
    required this.complete,
    this.provisionalChapterId,
    this.placedChapterId,
    this.placedChapterFirstPage,
  });

  final List<ReaderPageSlice> pages;
  final Map<String, int> chapterFirstPages;
  final bool complete;

  /// Set when [pages] hold only this chapter, starting at page 0, because the
  /// chapters in front of it have not been paginated yet.
  final String? provisionalChapterId;

  /// Set on the snapshot that first places a provisional chapter at its real
  /// position in the document.
  final String? placedChapterId;
  final int? placedChapterFirstPage;
}

class _ChapterPaginationResult {
  const _ChapterPaginationResult(this.pages, this.trailingOriginalPageLabel);

  final List<ReaderPageSlice> pages;
  final String? trailingOriginalPageLabel;
}

/// Paginates [document] chapter by chapter, publishing snapshots as they are
/// ready.
///
/// The chapter that holds the reader's position is paginated first so its first
/// page can be shown without waiting for the whole document. Until the chapters
/// in front of it are paginated it is published on its own
/// ([_PaginationPublish.provisionalChapterId]); it then moves to its real index
/// without being measured a second time, so page breaks, page count and page
/// order stay identical to a sequential pass.
Future<void> _paginateDocumentProgressive(
  XiaoqiDocument document, {
  required double width,
  required double height,
  required TextScaler textScaler,
  required String? preferredChapterId,
  required _PageYieldGate gate,
  required void Function(_PaginationPublish publish) onPublish,
}) async {
  final chapters = document.chapters;
  final pages = <ReaderPageSlice>[];
  final chapterFirstPages = <String, int>{};
  String? pendingOriginalPageLabel;

  // Page count of the last published snapshot, -1 before the first one.
  var publishedPageCount = -1;

  final preferredIndex = preferredChapterId == null
      ? -1
      : chapters.indexWhere((chapter) => chapter.id == preferredChapterId);
  // Whether the published pages start at the document's first chapter. The
  // chapters in front of the reader's chapter are paginated without publishing
  // because their page indexes are not final yet.
  var prefixPlaced = preferredIndex <= 0;

  // The reader's chapter is measured before the chapters in front of it.
  _ChapterPaginationResult? head;
  if (preferredIndex > 0) {
    final headChapter = chapters[preferredIndex];
    final headResult = await _paginateChapter(
      headChapter,
      width: width,
      height: height,
      textScaler: textScaler,
      gate: gate,
      onPageFlushed: (List<ReaderPageSlice> chapterPages, int count) {
        if (gate.cancelled) return;
        if (publishedPageCount >= 0 &&
            count - publishedPageCount < _pagesPerPublish) {
          return;
        }
        publishedPageCount = count;
        onPublish(
          _PaginationPublish(
            pages: List.unmodifiable(chapterPages.take(count)),
            chapterFirstPages: Map.unmodifiable(<String, int>{
              headChapter.id: 0,
            }),
            provisionalChapterId: headChapter.id,
            complete: false,
          ),
        );
      },
    );
    if (headResult == null) return;
    head = headResult;
    if (gate.cancelled) return;
    if (publishedPageCount < 0) {
      // The chapter only produced its empty fallback page.
      publishedPageCount = headResult.pages.length;
      onPublish(
        _PaginationPublish(
          pages: headResult.pages,
          chapterFirstPages: Map.unmodifiable(<String, int>{headChapter.id: 0}),
          provisionalChapterId: headChapter.id,
          complete: false,
        ),
      );
    }
  }

  for (var index = 0; index < chapters.length; index++) {
    if (gate.cancelled) return;
    final chapter = chapters[index];
    final base = pages.length;
    chapterFirstPages[chapter.id] = base;
    final placingHead = head != null && index == preferredIndex;
    // The reader's chapter is reused when it was measured with the same page
    // label state, so it is never paginated twice.
    final reuseHead = placingHead && pendingOriginalPageLabel == null;
    final _ChapterPaginationResult result;
    if (reuseHead) {
      result = head;
    } else {
      final chapterResult = await _paginateChapter(
        chapter,
        width: width,
        height: height,
        textScaler: textScaler,
        gate: gate,
        initialOriginalPageLabel: pendingOriginalPageLabel,
        onPageFlushed: prefixPlaced
            ? (List<ReaderPageSlice> chapterPages, int count) {
                if (gate.cancelled) return;
                final total = base + count;
                if (publishedPageCount >= 0 &&
                    total - publishedPageCount < _pagesPerPublish) {
                  return;
                }
                publishedPageCount = total;
                onPublish(
                  _PaginationPublish(
                    pages: List.unmodifiable(<ReaderPageSlice>[
                      ...pages,
                      ...chapterPages.take(count),
                    ]),
                    chapterFirstPages: Map.unmodifiable(chapterFirstPages),
                    complete: false,
                  ),
                );
              }
            : null,
      );
      if (chapterResult == null || gate.cancelled) return;
      result = chapterResult;
    }
    pages.addAll(result.pages);
    pendingOriginalPageLabel = result.trailingOriginalPageLabel;
    if (placingHead) {
      // Placing the anchor chapter turns the provisional slice into a normal
      // document prefix; the widget shifts the reader onto the same content.
      prefixPlaced = true;
    }
    final needsPublish =
        placingHead ||
        publishedPageCount < 0 ||
        pages.length - publishedPageCount >= _pagesPerPublish;
    if (prefixPlaced && needsPublish) {
      publishedPageCount = pages.length;
      onPublish(
        _PaginationPublish(
          pages: List.unmodifiable(pages),
          chapterFirstPages: Map.unmodifiable(chapterFirstPages),
          placedChapterId: placingHead ? chapter.id : null,
          placedChapterFirstPage: placingHead ? base : null,
          complete: false,
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);
  }

  if (pages.isEmpty) {
    final fallback = XiaoqiDocumentChapter(
      id: 'document:empty',
      title: document.title.isEmpty ? '全文' : document.title,
      href: '',
      html: '',
      plainText: '暂无识别内容',
      order: 0,
    );
    final fallbackResult = await _paginateChapter(
      fallback,
      width: width,
      height: height,
      textScaler: textScaler,
      gate: gate,
      initialOriginalPageLabel: pendingOriginalPageLabel,
    );
    if (fallbackResult == null) return;
    pages.addAll(fallbackResult.pages);
  }
  if (gate.cancelled) return;
  onPublish(
    _PaginationPublish(
      pages: List.unmodifiable(pages),
      chapterFirstPages: Map.unmodifiable(chapterFirstPages),
      complete: true,
    ),
  );
}

/// Paginates one chapter, yielding between measurements.
///
/// Returns null once the pass that owns [gate] was superseded, so an obsolete
/// pass stops measuring instead of competing with its replacement.
Future<_ChapterPaginationResult?> _paginateChapter(
  XiaoqiDocumentChapter chapter, {
  required double width,
  required double height,
  required TextScaler textScaler,
  required _PageYieldGate gate,
  String? initialOriginalPageLabel,
  _ChapterPageListener? onPageFlushed,
}) async {
  final blocks = chapter.blocks.isEmpty
      ? [
          XiaoqiDocumentBlock(
            id: '${chapter.id}:plain',
            kind: 'paragraph',
            text: chapter.plainText,
            sourceLocator: chapter.sourceLocator,
          ),
        ]
      : chapter.blocks;
  final showTitle =
      blocks.isEmpty ||
      blocks.first.kind != 'heading' ||
      blocks.first.text != chapter.title;
  final pages = <ReaderPageSlice>[];
  var current = <ReaderBlockSlice>[];
  var used = showTitle
      ? _headingHeight(chapter.title, width, textScaler) + 18
      : 0;
  var mayOverflow = false;
  var firstPage = true;
  var currentOriginalPageLabel = initialOriginalPageLabel;

  void flush() {
    if (current.isEmpty) return;
    pages.add(
      ReaderPageSlice(
        chapterId: chapter.id,
        chapterTitle: chapter.title.isEmpty ? '全文' : chapter.title,
        blocks: List.unmodifiable(current),
        showChapterTitle: firstPage && showTitle,
        mayOverflow: mayOverflow,
        originalPageLabel: currentOriginalPageLabel,
      ),
    );
    current = <ReaderBlockSlice>[];
    used = 0;
    mayOverflow = false;
    firstPage = false;
    onPageFlushed?.call(pages, pages.length);
  }

  void put(ReaderBlockSlice slice, double blockHeight) {
    if (current.isNotEmpty && used + blockHeight > height) flush();
    if (used + blockHeight > height) mayOverflow = true;
    current.add(slice);
    used += blockHeight;
  }

  for (final block in blocks) {
    // Blocks without text (page breaks, dividers, images, empty paragraphs)
    // never measure anything, so they need their own cheap way to yield.
    await gate.tickBlock();
    if (gate.cancelled) return null;
    final text = block.text;
    if (block.kind == 'page_break') {
      flush();
      currentOriginalPageLabel = block.originalPageLabel;
      continue;
    }
    final tableRows = _decodeTableRows(block);
    if (block.kind == 'table' && tableRows != null && tableRows.isNotEmpty) {
      var rowStart = 0;
      while (rowStart < tableRows.length) {
        if (gate.cancelled) return null;
        var rowEnd = rowStart + 1;
        while (rowEnd < tableRows.length) {
          final candidate = tableRows.sublist(rowStart, rowEnd + 1);
          final candidateHeight = await _tableHeight(
            candidate,
            width,
            textScaler,
            gate,
          );
          if (used + candidateHeight > height) break;
          rowEnd++;
        }
        final rows = tableRows.sublist(rowStart, rowEnd);
        final blockHeight = await _tableHeight(rows, width, textScaler, gate);
        if (current.isNotEmpty && used + blockHeight > height) {
          flush();
          continue;
        }
        put(
          ReaderBlockSlice(
            block: block,
            text: text,
            startOffset: rowStart,
            endOffset: rowEnd,
            tableRows: rows,
            continuation: rowStart > 0,
          ),
          blockHeight,
        );
        rowStart = rowEnd;
      }
      continue;
    }

    if (block.kind == 'image') {
      put(ReaderBlockSlice(block: block, text: text), 430);
      continue;
    }
    if (block.kind == 'divider') {
      put(ReaderBlockSlice(block: block, text: text), 18);
      continue;
    }
    if (text.trim().isEmpty) continue;

    var start = 0;
    while (start < text.length) {
      if (gate.cancelled) return null;
      final continuation = start > 0;
      final overhead = _blockOverhead(block, continuation);
      final available = math.max(1.0, height - used - overhead).toDouble();
      var count = await _fitTextPrefix(
        text.substring(start),
        block,
        width,
        available,
        textScaler,
        gate: gate,
        continuation: continuation,
      );
      if (count <= 0) {
        if (current.isNotEmpty) {
          flush();
          continue;
        }
        count = await _fitTextPrefix(
          text.substring(start),
          block,
          width,
          math.max(1.0, height - overhead).toDouble(),
          textScaler,
          gate: gate,
          continuation: continuation,
        );
        if (count <= 0) count = 1;
        mayOverflow = true;
      }
      final end = math.min(text.length, start + count).toInt();
      final part = text.substring(start, end);
      final blockHeight =
          _measureText(
            _textForMeasure(block, part, continuation),
            block,
            width,
            textScaler,
          ) +
          overhead;
      put(
        ReaderBlockSlice(
          block: block,
          text: part,
          startOffset: start,
          endOffset: end,
          continuation: continuation,
        ),
        blockHeight,
      );
      start = end;
    }
  }
  flush();
  if (pages.isEmpty) {
    pages.add(
      ReaderPageSlice(
        chapterId: chapter.id,
        chapterTitle: chapter.title.isEmpty ? '全文' : chapter.title,
        blocks: const [],
        showChapterTitle: showTitle,
        originalPageLabel: currentOriginalPageLabel,
      ),
    );
  }
  return _ChapterPaginationResult(
    List.unmodifiable(pages),
    currentOriginalPageLabel,
  );
}

List<List<String>>? _decodeTableRows(XiaoqiDocumentBlock block) {
  final raw = block.attributes['rows'];
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    final rows = decoded
        .whereType<List>()
        .map(
          (row) => row.map((cell) => cell.toString()).toList(growable: false),
        )
        .where((row) => row.isNotEmpty)
        .toList(growable: false);
    return rows.isEmpty ? null : rows;
  } catch (_) {
    return null;
  }
}

double _headingHeight(String text, double width, TextScaler scaler) =>
    _measureText(text, _headingBlock, width, scaler) + 6;

final _headingBlock = XiaoqiDocumentBlock(
  id: 'reader:heading',
  kind: 'heading',
  text: '',
);

TextStyle _styleForBlock(XiaoqiDocumentBlock block) {
  switch (block.kind) {
    case 'heading':
      return TextStyle(
        color: const Color(0xFF252525),
        fontSize: block.level <= 1 ? 21 : 18,
        height: 1.35,
        fontWeight: FontWeight.w700,
      );
    case 'list_item':
      return const TextStyle(
        color: Color(0xFF343434),
        fontSize: 17,
        height: 1.6,
      );
    case 'quote':
      return const TextStyle(
        color: Color(0xFF343434),
        fontSize: 16,
        height: 1.6,
      );
    case 'code':
      return const TextStyle(
        color: Color(0xFF252525),
        fontFamily: 'monospace',
        fontSize: 14,
        height: 1.5,
      );
    default:
      return const TextStyle(
        color: Color(0xFF343434),
        fontSize: 17,
        height: 1.7,
      );
  }
}

String _textForMeasure(
  XiaoqiDocumentBlock block,
  String text,
  bool continuation,
) => block.kind == 'list_item' && !continuation ? '• $text' : text;

double _measureText(
  String text,
  XiaoqiDocumentBlock block,
  double width,
  TextScaler scaler,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: _styleForBlock(block)),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout(maxWidth: width);
  return painter.height;
}

double _blockOverhead(XiaoqiDocumentBlock block, bool continuation) {
  switch (block.kind) {
    case 'heading':
      return continuation ? 6 : 20;
    case 'list_item':
      return 8;
    case 'quote':
      return 32;
    case 'code':
      return 40;
    default:
      return 12;
  }
}

Future<int> _fitTextPrefix(
  String text,
  XiaoqiDocumentBlock block,
  double width,
  double maxHeight,
  TextScaler scaler, {
  required _PageYieldGate gate,
  required bool continuation,
}) async {
  if (text.isEmpty) return 0;
  await gate.tick();
  final full = _measureText(
    _textForMeasure(block, text, continuation),
    block,
    width,
    scaler,
  );
  if (full <= maxHeight) return text.length;
  var low = 1;
  var high = text.length;
  var best = 0;
  while (low <= high) {
    await gate.tick();
    final middle = (low + high) ~/ 2;
    final candidate = text.substring(0, middle);
    final measured = _measureText(
      _textForMeasure(block, candidate, continuation),
      block,
      width,
      scaler,
    );
    if (measured <= maxHeight) {
      best = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  if (best <= 0) return 0;
  while (best > 1 &&
      best < text.length &&
      _isLowSurrogate(text.codeUnitAt(best))) {
    best--;
  }
  if (block.kind == 'code') {
    final lineBreak = text.substring(0, best).lastIndexOf('\n');
    if (lineBreak > 0) return lineBreak + 1;
  }
  final whitespace = text.substring(0, best).lastIndexOf(RegExp(r'\s'));
  if (whitespace > best * .65) return whitespace + 1;
  return best;
}

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

Future<double> _tableHeight(
  List<List<String>> rows,
  double width,
  TextScaler scaler,
  _PageYieldGate gate,
) async {
  var height = 20.0;
  for (final row in rows) {
    var rowHeight = 42.0;
    for (final cell in row) {
      await gate.tick();
      rowHeight = math
          .max(
            rowHeight,
            _measureText(
                  cell,
                  const XiaoqiDocumentBlock(
                    id: 'reader:table',
                    kind: 'table',
                    text: '',
                  ),
                  width / math.max(1, row.length),
                  scaler,
                ) +
                20,
          )
          .toDouble();
    }
    height += rowHeight;
  }
  return height + 14;
}
