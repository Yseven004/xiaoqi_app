import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../models/book_library_item.dart';
import '../services/book_library_service.dart';
import 'book_cover.dart';

const _taskMenuChromeHeight = 172.0;
const _taskMenuMinHeight = _taskMenuChromeHeight + 52.0;
const _taskBookRowHeight = 52.0;
const _taskBookRowGap = 3.0;
const _taskMenuMaxWidth = 240.0;

List<BookLibraryItem> _filterBooksByQuery(
  List<BookLibraryItem> books,
  String rawQuery,
) {
  final query = rawQuery.trim().toLowerCase();
  if (query.isEmpty) return books;
  return books
      .where((item) {
        final book = item.book;
        return book.title.toLowerCase().contains(query) ||
            book.authorLabel.toLowerCase().contains(query);
      })
      .toList(growable: false);
}

/// A compact book-task control and its two glass panels, anchored to the
/// composer edge so the list opens upward without changing the page layout.
class ReadingTaskSwitcher extends StatefulWidget {
  const ReadingTaskSwitcher({
    super.key,
    required this.library,
    required this.composerFocusNode,
    required this.selectedBookId,
    required this.selectedBookName,
    required this.onSelectBook,
    required this.onSearchFocusChanged,
    required this.onStartIndependent,
    required this.onAddBook,
  });

  final BookLibraryService library;
  final FocusNode composerFocusNode;
  final int? selectedBookId;
  final String selectedBookName;
  final ValueChanged<BookLibraryItem> onSelectBook;
  final ValueChanged<bool> onSearchFocusChanged;
  final VoidCallback onStartIndependent;
  final VoidCallback onAddBook;

  @override
  State<ReadingTaskSwitcher> createState() => _ReadingTaskSwitcherState();
}

class _ReadingTaskSwitcherState extends State<ReadingTaskSwitcher>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _anchorLink = LayerLink();
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _searchFieldKey = GlobalKey();
  late final AnimationController _searchTransitionController;
  Rect? _searchOriginRect;
  OverlayEntry? _taskMenu;
  List<BookLibraryItem> _libraryBooks = const [];
  List<BookLibraryItem> _readingBooks = const [];
  bool _loading = false;
  bool _searchTransitionStarted = false;
  bool _searchKeyboardWasVisible = false;
  String? _loadError;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchTransitionController = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 240),
    )..addListener(() => _taskMenu?.markNeedsBuild());
    _searchFocusNode.addListener(_onSearchFocusChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _taskMenu?.remove();
    _taskMenu?.dispose();
    _searchTransitionController.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (_searchFocusNode.hasFocus &&
        _currentKeyboardInset > 0 &&
        !_searchTransitionStarted) {
      _searchTransitionStarted = true;
      _searchTransitionController.forward(from: 0);
    }
    _taskMenu?.markNeedsBuild();
  }

  double get _currentKeyboardInset {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return 0;
    final view = views.first;
    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  List<BookLibraryItem> get _filteredBooks {
    if (_query.trim().isEmpty) return _readingBooks;
    return _filterBooksByQuery(_libraryBooks, _query);
  }

  Future<void> _loadReadingBooks() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
      _taskMenu?.markNeedsBuild();
    }
    try {
      final books = await widget.library.listBooks();
      if (!mounted) return;
      setState(() {
        _libraryBooks = books;
        _readingBooks = books
            .where((item) => item.isInReadingSpace)
            .toList(growable: false);
        _loading = false;
        _loadError = null;
      });
      _taskMenu?.markNeedsBuild();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '暂时无法读取书籍';
      });
      _taskMenu?.markNeedsBuild();
    }
  }

  void _toggleTaskMenu() {
    if (_taskMenu != null) {
      _closeTaskMenu();
      return;
    }
    final composerKeyboardIsOpen =
        widget.composerFocusNode.hasFocus && _currentKeyboardInset > 0;
    if (!composerKeyboardIsOpen) {
      widget.composerFocusNode.unfocus();
    }
    _searchOriginRect = null;
    _searchKeyboardWasVisible = false;
    _searchTransitionStarted = false;
    _query = '';
    _searchController.clear();
    _searchTransitionController.value = 1;
    _taskMenu = OverlayEntry(builder: _buildTaskOverlay);
    Overlay.of(context, rootOverlay: true).insert(_taskMenu!);
    unawaited(_loadReadingBooks());
  }

  void _closeTaskMenu() {
    if (_searchFocusNode.hasFocus) _searchFocusNode.unfocus();
    _searchKeyboardWasVisible = false;
    _searchTransitionStarted = false;
    final entry = _taskMenu;
    if (entry == null) return;
    _taskMenu = null;
    entry.remove();
    entry.dispose();
    if (mounted) setState(() {});
  }

  void _onSearchFocusChanged() {
    if (_searchFocusNode.hasFocus) {
      _searchTransitionStarted = false;
      final renderObject = _searchFieldKey.currentContext?.findRenderObject();
      if (renderObject is RenderBox && renderObject.hasSize) {
        final globalOrigin = renderObject.localToGlobal(Offset.zero);
        final overlayObject = Overlay.of(
          context,
          rootOverlay: true,
        ).context.findRenderObject();
        final localOrigin = overlayObject is RenderBox
            ? overlayObject.globalToLocal(globalOrigin)
            : globalOrigin;
        _searchOriginRect = localOrigin & renderObject.size;
      }
      widget.onSearchFocusChanged(true);
      if (_currentKeyboardInset > 0) {
        _searchTransitionStarted = true;
        _searchTransitionController.forward(from: 0);
      }
    } else {
      _searchTransitionStarted = false;
      widget.onSearchFocusChanged(false);
    }
    _taskMenu?.markNeedsBuild();
  }

  Rect _floatingSearchRect(Size size, double keyboardInset) {
    final width = math.max(1.0, size.width - 24).toDouble();
    final fallback = Rect.fromLTWH(
      12,
      size.height - keyboardInset - 58,
      width,
      46,
    );
    final origin = _searchOriginRect ?? fallback;
    final target = Rect.fromLTWH(
      12,
      math.max(8.0, size.height - keyboardInset - 58),
      width,
      46,
    );
    return Rect.lerp(origin, target, _searchTransitionController.value)!;
  }

  Widget _buildTaskOverlay(BuildContext overlayContext) {
    final media = MediaQuery.of(overlayContext);
    final size = media.size;
    final keyboardInset = media.viewInsets.bottom;
    final width = math
        .max(1.0, math.min(_taskMenuMaxWidth, size.width - 24))
        .toDouble();
    final maxHeight = math
        .max(_taskMenuMinHeight, math.min(430.0, size.height * .58))
        .toDouble();
    final books = _filteredBooks;
    final bookListHeight = !_loading && _loadError == null && books.isNotEmpty
        ? books.length * (_taskBookRowHeight + _taskBookRowGap) -
              _taskBookRowGap
        : _taskBookRowHeight;
    final listHeight = math
        .min(bookListHeight, maxHeight - _taskMenuChromeHeight)
        .toDouble();
    final height = _taskMenuChromeHeight + listHeight;
    final searchIsFloating = _searchFocusNode.hasFocus && keyboardInset > 0;
    if (searchIsFloating) _searchKeyboardWasVisible = true;
    if (_searchFocusNode.hasFocus &&
        _searchKeyboardWasVisible &&
        keyboardInset == 0) {
      _searchKeyboardWasVisible = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchFocusNode.hasFocus) _searchFocusNode.unfocus();
      });
    }
    final searchQuery = _query.trim();
    final hasSearchQuery = searchQuery.isNotEmpty;
    final resultListHeight = books.isNotEmpty && !_loading && _loadError == null
        ? books.length * (_taskBookRowHeight + _taskBookRowGap) -
              _taskBookRowGap
        : 42.0;
    final searchResultsHeight = hasSearchQuery
        ? math
              .min(
                300.0,
                math.min(
                  resultListHeight + 20,
                  math.max(0.0, size.height - keyboardInset - 72),
                ),
              )
              .toDouble()
        : 0.0;
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeTaskMenu,
              child: const SizedBox.expand(),
            ),
          ),
          if (searchIsFloating) ...[
            if (hasSearchQuery && searchResultsHeight > 0)
              Positioned(
                left: 12,
                right: 12,
                bottom: keyboardInset + 64,
                height: searchResultsHeight,
                child: _GlassPanel(
                  radius: 18,
                  padding: const EdgeInsets.all(10),
                  fillColor: const Color(0xD9FFFFFF),
                  child: _buildTaskBookList(books),
                ),
              ),
            Positioned.fromRect(
              rect: _floatingSearchRect(size, keyboardInset),
              child: _SearchField(
                key: _searchFieldKey,
                controller: _searchController,
                focusNode: _searchFocusNode,
                hintText: '搜索阅读任务',
                height: 46,
                expanded: true,
                onChanged: (value) {
                  _query = value;
                  _taskMenu?.markNeedsBuild();
                },
              ),
            ),
          ] else
            CompositedTransformFollower(
              link: _anchorLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topLeft,
              followerAnchor: Alignment.bottomLeft,
              offset: const Offset(0, -1),
              child: Material(
                type: MaterialType.transparency,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: _buildTaskMenu(overlayContext, books, listHeight),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTaskMenu(
    BuildContext context,
    List<BookLibraryItem> books,
    double listHeight,
  ) {
    return _GlassPanel(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        children: [
          _SearchField(
            key: _searchFieldKey,
            controller: _searchController,
            focusNode: _searchFocusNode,
            hintText: '搜索阅读任务',
            onChanged: (value) {
              _query = value;
              _taskMenu?.markNeedsBuild();
            },
          ),
          const SizedBox(height: 8),
          SizedBox(height: listHeight, child: _buildTaskBookList(books)),
          const Padding(
            padding: EdgeInsets.only(top: 7),
            child: Divider(height: 1, color: Color(0x557D858F)),
          ),
          _TaskActionRow(
            icon: 'assets/images/reading_task_plus.svg',
            label: '新建阅读任务',
            onTap: () {
              _closeTaskMenu();
              unawaited(_showNewTaskDialog());
            },
          ),
          _TaskActionRow(
            icon: 'assets/images/home_new_conversation_icon.svg',
            label: '不关联书籍',
            onTap: () {
              _closeTaskMenu();
              widget.onStartIndependent();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTaskBookList(List<BookLibraryItem> books) {
    if (_loading) {
      return const Center(
        child: Text(
          '正在整理在读书籍…',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: _mutedInk, fontSize: 13),
        ),
      );
    }
    if (_loadError != null) {
      return Center(
        child: TextButton(
          onPressed: () => unawaited(_loadReadingBooks()),
          child: Text(
            _loadError!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    if (books.isEmpty) {
      return Center(
        child: Text(
          _query.trim().isEmpty ? '还没有在读书籍' : '没有找到相关书籍',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _mutedInk, fontSize: 13),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: books.length,
      separatorBuilder: (_, _) => const SizedBox(height: _taskBookRowGap),
      itemBuilder: (context, index) {
        final item = books[index];
        return _TaskBookRow(
          item: item,
          selected: _isSelected(item),
          onTap: () {
            _closeTaskMenu();
            widget.onSelectBook(item);
          },
        );
      },
    );
  }

  bool _isSelected(BookLibraryItem item) {
    if (widget.selectedBookId != null) {
      return item.book.id == widget.selectedBookId;
    }
    return widget.selectedBookName.trim().isNotEmpty &&
        item.book.title.trim() == widget.selectedBookName.trim();
  }

  Future<void> _showNewTaskDialog() async {
    widget.composerFocusNode.unfocus();
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭新建阅读任务',
      barrierColor: const Color(0x4032363C),
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (dialogContext, _, _) => _NewReadingTaskDialog(
        library: widget.library,
        selectedBookId: widget.selectedBookId,
        onSearchFocusChanged: widget.onSearchFocusChanged,
        onSelectBook: (item) {
          Navigator.of(dialogContext).pop();
          widget.onSelectBook(item);
        },
        onAddBook: () {
          Navigator.of(dialogContext).pop();
          widget.onAddBook();
        },
      ),
      transitionBuilder: (context, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );
    if (mounted) widget.composerFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final expanded = _taskMenu != null;
    final title = widget.selectedBookName.trim().isEmpty
        ? '阅读任务'
        : '《${widget.selectedBookName.trim()}》';
    final maxWidth = math
        .max(
          1.0,
          math.min(_taskMenuMaxWidth, MediaQuery.sizeOf(context).width - 24),
        )
        .toDouble();
    return CompositedTransformTarget(
      link: _anchorLink,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Semantics(
              button: true,
              expanded: expanded,
              label: '$title，切换阅读任务',
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(13),
                  radius: 16,
                  splashColor: const Color(0x12252932),
                  highlightColor: Colors.transparent,
                  onTap: _toggleTaskMenu,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: _GlassPanel(
                      radius: 13,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 8,
                      ),
                      child: AnimatedOpacity(
                        opacity: expanded ? .55 : 1,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeInOut,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SvgPicture.asset(
                              'assets/images/reading_task_book.svg',
                              width: 18,
                              height: 18,
                            ),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _ink,
                                  fontSize: 13,
                                  height: 1.1,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            AnimatedRotation(
                              turns: expanded ? .5 : 0,
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeInOut,
                              child: Icon(
                                PhosphorIcons.caretDown(
                                  PhosphorIconsStyle.regular,
                                ),
                                size: 14,
                                color: _mutedInk,
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
          ),
        ),
      ),
    );
  }
}

class _NewReadingTaskDialog extends StatefulWidget {
  const _NewReadingTaskDialog({
    required this.library,
    required this.selectedBookId,
    required this.onSearchFocusChanged,
    required this.onSelectBook,
    required this.onAddBook,
  });

  final BookLibraryService library;
  final int? selectedBookId;
  final ValueChanged<bool> onSearchFocusChanged;
  final ValueChanged<BookLibraryItem> onSelectBook;
  final VoidCallback onAddBook;

  @override
  State<_NewReadingTaskDialog> createState() => _NewReadingTaskDialogState();
}

class _NewReadingTaskDialogState extends State<_NewReadingTaskDialog> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _booksScrollController = ScrollController();
  List<BookLibraryItem> _books = const [];
  bool _loading = true;
  String? _loadError;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(_onSearchFocusChanged);
    unawaited(_loadBooks());
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    if (_searchFocusNode.hasFocus) widget.onSearchFocusChanged(false);
    _searchFocusNode.dispose();
    _searchController.dispose();
    _booksScrollController.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    widget.onSearchFocusChanged(_searchFocusNode.hasFocus);
  }

  Future<void> _loadBooks() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final books = await widget.library.listBooks();
      if (!mounted) return;
      setState(() {
        _books = books;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '书库暂时无法读取';
      });
    }
  }

  List<BookLibraryItem> get _filteredBooks {
    return _filterBooksByQuery(_books, _query);
  }

  @override
  Widget build(BuildContext context) {
    final viewportSize = MediaQuery.sizeOf(context);
    final maxHeight = math
        .max(
          220.0,
          math.min(viewportSize.height * .82, viewportSize.height - 32),
        )
        .toDouble();
    final width = math
        .max(180.0, math.min(560.0, viewportSize.width - 32))
        .toDouble();
    final books = _filteredBooks;
    final coverWidth = ((width - 36 - 24) / 4).clamp(30.0, 106.0).toDouble();
    final coverHeight = coverWidth * 1.3;
    final rowExtent = coverHeight + 50;
    const gridRowSpacing = 10.0;
    final gridMaxHeight = math.max(76.0, maxHeight - 232).toDouble();
    final gridHeight = math
        .min(rowExtent * 2 + gridRowSpacing, gridMaxHeight)
        .toDouble();

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        maintainBottomViewPadding: true,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
            child: SizedBox(
              width: width,
              child: _GlassPanel(
                radius: 20,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '新建阅读任务',
                            style: TextStyle(
                              color: _ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(
                            PhosphorIcons.x(PhosphorIconsStyle.regular),
                            size: 18,
                            color: _mutedInk,
                          ),
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                            width: 48,
                            height: 48,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _SearchField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      hintText: '搜索书库中的书',
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: 12),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '从书库选择',
                        style: TextStyle(
                          color: _mutedInk,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_loading)
                      SizedBox(
                        height: gridHeight,
                        child: Center(
                          child: Text(
                            '正在整理书库…',
                            style: TextStyle(color: _mutedInk, fontSize: 13),
                          ),
                        ),
                      )
                    else if (_loadError != null)
                      SizedBox(
                        height: gridHeight,
                        child: Center(
                          child: TextButton(
                            onPressed: () => unawaited(_loadBooks()),
                            child: Text(_loadError!),
                          ),
                        ),
                      )
                    else if (books.isEmpty)
                      SizedBox(
                        height: gridHeight,
                        child: Center(
                          child: Text(
                            _query.isEmpty ? '当前暂无书籍' : '没有找到符合条件的书',
                            style: const TextStyle(
                              color: _mutedInk,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        height: gridHeight,
                        child: ScrollbarTheme(
                          data: ScrollbarThemeData(
                            thumbColor: const WidgetStatePropertyAll<Color?>(
                              Color(0x80949CA3),
                            ),
                            trackColor: const WidgetStatePropertyAll<Color?>(
                              Colors.transparent,
                            ),
                            trackBorderColor:
                                const WidgetStatePropertyAll<Color?>(
                                  Colors.transparent,
                                ),
                            thickness: const WidgetStatePropertyAll<double?>(4),
                            radius: const Radius.circular(4),
                          ),
                          child: Scrollbar(
                            controller: _booksScrollController,
                            thumbVisibility: false,
                            trackVisibility: false,
                            interactive: true,
                            child: GridView.builder(
                              controller: _booksScrollController,
                              padding: EdgeInsets.zero,
                              itemCount: books.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 4,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: gridRowSpacing,
                                    mainAxisExtent: rowExtent,
                                  ),
                              itemBuilder: (context, index) {
                                final item = books[index];
                                final selected =
                                    widget.selectedBookId == item.book.id;
                                return _BookGridTile(
                                  item: item,
                                  selected: selected,
                                  coverWidth: coverWidth * .78,
                                  coverHeight: coverHeight,
                                  onTap: () => widget.onSelectBook(item),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Divider(height: 1, color: Color(0x557D858F)),
                    ),
                    const SizedBox(height: 8),
                    _AddBookButton(onPressed: widget.onAddBook),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BookGridTile extends StatelessWidget {
  const _BookGridTile({
    required this.item,
    required this.selected,
    required this.coverWidth,
    required this.coverHeight,
    required this.onTap,
  });

  final BookLibraryItem item;
  final bool selected;
  final double coverWidth;
  final double coverHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${item.book.title}，${item.book.authorLabel}',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
            child: Column(
              children: [
                SizedBox(
                  width: coverWidth,
                  height: coverHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      BookCover(
                        book: item.book,
                        borderRadius: 6,
                        builtInSpineShading: false,
                      ),
                      if (selected)
                        Align(
                          alignment: Alignment.topRight,
                          child: Container(
                            margin: const EdgeInsets.all(3),
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                              color: Color(0xEFFFFFFF),
                              shape: BoxShape.circle,
                            ),
                            child: SvgPicture.asset(
                              'assets/images/reading_task_check.svg',
                              width: 16,
                              height: 16,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  item.book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 11,
                    height: 1.15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.book.authorLabel.isEmpty
                      ? '作者未知'
                      : item.book.authorLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _mutedInk,
                    fontSize: 9,
                    height: 1.1,
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

class _TaskBookRow extends StatelessWidget {
  const _TaskBookRow({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final BookLibraryItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '切换到《${item.book.title}》',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            height: _taskBookRowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? const Color(0x56DCE1E7) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  height: 42,
                  child: BookCover(
                    book: item.book,
                    borderRadius: 4,
                    builtInSpineShading: false,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (selected)
                  SvgPicture.asset(
                    'assets/images/reading_task_check.svg',
                    width: 20,
                    height: 20,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskActionRow extends StatelessWidget {
  const _TaskActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 5),
                SvgPicture.asset(icon, width: 20, height: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
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

class _SearchField extends StatelessWidget {
  const _SearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    this.focusNode,
    this.height = 38,
    this.expanded = false,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;
  final double height;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final radius = expanded ? 15.0 : 11.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: expanded
            ? const [
                BoxShadow(
                  color: Color(0x16000000),
                  blurRadius: 16,
                  offset: Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: expanded ? 14 : 0,
            sigmaY: expanded ? 14 : 0,
          ),
          child: Container(
            height: height,
            padding: EdgeInsets.symmetric(horizontal: expanded ? 13 : 10),
            decoration: BoxDecoration(
              color: expanded
                  ? const Color(0xD9FFFFFF)
                  : const Color(0x60E9EDF1),
              borderRadius: BorderRadius.circular(radius),
              border: expanded
                  ? Border.all(color: const Color(0xDFFFFFFF))
                  : null,
            ),
            child: Row(
              children: [
                SvgPicture.asset(
                  'assets/images/reading_sidebar_search.svg',
                  width: 16,
                  height: 16,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: onChanged,
                    style: TextStyle(
                      color: _ink,
                      fontSize: expanded ? 14 : 12,
                      height: 1.2,
                    ),
                    decoration: InputDecoration(
                      hintText: hintText,
                      hintStyle: TextStyle(
                        color: _mutedInk,
                        fontSize: expanded ? 14 : 12,
                        height: 1.2,
                      ),
                      isCollapsed: true,
                      border: InputBorder.none,
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

class _AddBookButton extends StatelessWidget {
  const _AddBookButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '添加新书',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(15),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0x55FFFFFF),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: const Color(0xAFFFFFFF)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SvgPicture.asset(
                    'assets/images/reading_task_plus.svg',
                    width: 18,
                    height: 18,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '添加新书',
                    style: TextStyle(
                      color: _ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
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

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({
    required this.child,
    required this.radius,
    this.padding = EdgeInsets.zero,
    this.fillColor = const Color(0xEFFFFFFF),
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color fillColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1B17212B),
            blurRadius: 22,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: const Color(0xDFFFFFFF)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

const _ink = Color(0xFF252932);
const _mutedInk = Color(0xFF737A84);
