import 'dart:async';

import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';
import '../models/book_category.dart';
import '../models/book_library_item.dart';
import '../models/book_library_query.dart';
import '../models/book_recognition.dart';
import '../services/book_learning_preferences.dart';
import '../services/book_library_service.dart';
import '../widgets/book_spine_shading.dart';
import '../widgets/book_metadata_form_sheet.dart';
import '../widgets/book_paper_background.dart';
import '../widgets/app_toast.dart';

enum _FilterMenuActionType { all, category, create }

enum _CategoryManagementAction { rename, delete }

class _FilterMenuAction {
  const _FilterMenuAction(this.type, {this.categoryId});

  final _FilterMenuActionType type;
  final int? categoryId;
}

class BookLearningSpacePage extends StatefulWidget {
  const BookLearningSpacePage({
    super.key,
    required this.onOpenBook,
    required this.onCreateBook,
    this.bookLibraryService,
    this.preferences,
  });

  final ValueChanged<int> onOpenBook;
  final VoidCallback onCreateBook;
  final BookLibraryService? bookLibraryService;
  final BookLearningPreferences? preferences;

  @override
  State<BookLearningSpacePage> createState() => _BookLearningSpacePageState();
}

class _BookLearningSpacePageState extends State<BookLearningSpacePage> {
  late final BookLibraryService _library;
  late final BookLearningPreferences _preferences;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final LayerLink _libraryFilterMenuLink = LayerLink();
  Timer? _searchDebounce;
  OverlayEntry? _filterMenuOverlay;
  LayerLink? _activeFilterMenuLink;
  final Set<int> _selectedBookIds = <int>{};
  bool _selectionMode = false;
  List<BookLibraryItem> _items = const [];
  List<BookCategory> _categories = const [];
  BookLibraryQuery _query = const BookLibraryQuery();
  BookLibraryViewMode _viewMode = BookLibraryViewMode.grid;
  bool _loading = true;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(_handleSearchFocusChanged);
    _library = widget.bookLibraryService ?? BookLibraryService();
    _preferences = widget.preferences ?? BookLearningPreferences();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _filterMenuOverlay?.remove();
    _filterMenuOverlay = null;
    _searchDebounce?.cancel();
    _searchFocusNode.removeListener(_handleSearchFocusChanged);
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final state = await _preferences.load();
    final categories = await _library.listCategories();
    if (!mounted) return;
    final categoryStillExists =
        !state.query.uncategorizedOnly &&
        (state.query.categoryId == null ||
            categories.any(
              (category) => category.id == state.query.categoryId,
            ));
    setState(() {
      _viewMode = state.viewMode;
      _query = categoryStillExists
          ? state.query
          : state.query.copyWith(clearCategory: true);
      _categories = categories;
    });
    if (!categoryStillExists) await _preferences.saveQuery(_query);
    await _loadBooks();
  }

  Future<void> refresh() async {
    _categories = await _library.listCategories();
    if (mounted) setState(() {});
    await _loadBooks();
  }

  Future<void> _loadBooks({bool showLoading = true}) async {
    final requestId = ++_requestId;
    if (showLoading && mounted) setState(() => _loading = true);
    try {
      final items = await _library.listBooks(query: _query);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = '书籍暂时无法加载：$error';
      });
    }
  }

  Future<void> _changeViewMode(BookLibraryViewMode value) async {
    _clearInputFocus();
    if (_viewMode == value) return;
    setState(() => _viewMode = value);
    await _preferences.saveViewMode(value);
  }

  Future<void> _changeQuery(BookLibraryQuery value) async {
    setState(() {
      _query = value;
      _selectionMode = false;
      _selectedBookIds.clear();
    });
    await Future.wait<void>([
      _preferences.saveQuery(value),
      _loadBooks(showLoading: false),
    ]);
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 260), () {
      unawaited(_changeQuery(_query.copyWith(searchText: value)));
    });
  }

  Future<void> _applyFilterAction(_FilterMenuAction action) async {
    _clearInputFocus();
    switch (action.type) {
      case _FilterMenuActionType.all:
        await _changeQuery(_query.copyWith(clearCategory: true));
      case _FilterMenuActionType.category:
        await _changeQuery(
          _query.copyWith(
            categoryId: action.categoryId,
            uncategorizedOnly: false,
          ),
        );
      case _FilterMenuActionType.create:
        await _createCategory();
    }
  }

  Future<void> _deleteCategory(BookCategory category) async {
    int bookCount;
    try {
      bookCount = await _library.countBooksInCategory(category.id!);
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '无法读取分类信息：$error');
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除分类'),
        content: Text(
          '“${category.name}”目前包含 $bookCount 本书。\n\n'
          '删除分类不会删除这些书籍，是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB94A45),
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await _library.deleteCustomCategory(category.id!);
      _categories = await _library.listCategories();
      if (!mounted) return;
      if (_query.categoryId == category.id) {
        await _changeQuery(_query.copyWith(clearCategory: true));
      } else {
        setState(() {});
      }
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '删除分类失败：$error');
    }
  }

  Future<void> _showCategoryActions(BookCategory category) async {
    final action = await showDialog<_CategoryManagementAction>(
      context: context,
      requestFocus: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(category.name),
        contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重新命名'),
              onTap: () => Navigator.pop(
                dialogContext,
                _CategoryManagementAction.rename,
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Color(0xFFCB3D36),
              ),
              title: const Text(
                '删除分类',
                style: TextStyle(color: Color(0xFFCB3D36)),
              ),
              onTap: () => Navigator.pop(
                dialogContext,
                _CategoryManagementAction.delete,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == _CategoryManagementAction.rename) {
      await _renameCategory(category);
    } else {
      await _deleteCategory(category);
    }
  }

  Future<void> _renameCategory(BookCategory category) async {
    _clearInputFocus();
    final value = await showDialog<String>(
      context: context,
      requestFocus: false,
      builder: (_) => _CategoryNameDialog(
        title: '重新命名分类',
        initialValue: category.name,
        confirmLabel: '保存',
      ),
    );
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _clearInputFocus();
      });
    }
    if (!mounted || value == null || value.isEmpty || value == category.name) {
      return;
    }
    try {
      await _library.renameCustomCategory(category.id!, value);
      _categories = await _library.listCategories();
      if (!mounted) return;
      setState(() {});
      await _loadBooks(showLoading: false);
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '分类重命名失败：$error');
    }
  }

  /*
    final result = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                '筛选分类',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: Icon(
                _query.categoryId == null && !_query.uncategorizedOnly
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: _query.categoryId == null && !_query.uncategorizedOnly
                    ? BookFlowTheme.primary
                    : BookFlowTheme.muted,
              ),
              title: const Text('全部书籍'),
              onTap: () => Navigator.pop(sheetContext, -1),
            ),
            ListTile(
              leading: Icon(
                _query.uncategorizedOnly
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: _query.uncategorizedOnly
                    ? BookFlowTheme.primary
                    : BookFlowTheme.muted,
              ),
              title: const Text('未分类'),
              onTap: () => Navigator.pop(sheetContext, -3),
            ),
            for (final category in _categories)
              ListTile(
                leading: Icon(
                  _query.categoryId == category.id
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: _query.categoryId == category.id
                      ? BookFlowTheme.primary
                      : BookFlowTheme.muted,
                ),
                title: Text(category.name),
                trailing: category.isSystem
                    ? null
                    : IconButton(
                        tooltip: '重命名分类',
                        icon: const Icon(Icons.more_horiz_rounded),
                        onPressed: () =>
                            Navigator.pop(sheetContext, -100 - category.id!),
                      ),
                onTap: () => Navigator.pop(sheetContext, category.id),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('新建分类'),
              onTap: () => Navigator.pop(sheetContext, -2),
            ),
          ],
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result == -2) {
      await _createCategory();
      return;
    }
    if (result <= -100) {
      final categoryId = -100 - result;
      final category = _categories
          .where((item) => item.id == categoryId)
          .firstOrNull;
      if (category != null) await _renameCategory(category);
      return;
    }
    await _changeQuery(
      result == -1
          ? _query.copyWith(clearCategory: true)
          : result == -3
          ? _query.copyWith(clearCategory: true, uncategorizedOnly: true)
          : _query.copyWith(categoryId: result, uncategorizedOnly: false),
    );
  }

  */

  void _clearInputFocus() {
    _searchFocusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _handleSearchFocusChanged() {
    if (mounted) setState(() {});
  }

  void _activateSearch() {
    if (!_searchFocusNode.hasFocus) _searchFocusNode.requestFocus();
  }

  void _openBook(int bookId) {
    _clearInputFocus();
    widget.onOpenBook(bookId);
  }

  Future<void> _createCategory() async {
    _clearInputFocus();
    final value = await showDialog<String>(
      context: context,
      requestFocus: false,
      builder: (_) => const _CategoryNameDialog(),
    );
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _clearInputFocus();
      });
    }
    if (!mounted || value == null || value.isEmpty) return;
    try {
      await _library.saveCustomCategory(value);
      _categories = await _library.listCategories();
      if (!mounted) return;
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '分类保存失败：$error');
    }
  }

  Future<void> _showCategoryManager() async {
    _clearInputFocus();
    final changed = await showDialog<bool>(
      context: context,
      requestFocus: false,
      builder: (_) => _CategoryManagementDialog(library: _library),
    );
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _clearInputFocus();
      });
    }
    if (!mounted || changed != true) return;

    final categories = await _library.listCategories();
    if (!mounted) return;
    final selectedCategoryStillExists =
        _query.categoryId == null ||
        categories.any((category) => category.id == _query.categoryId);
    setState(() => _categories = categories);
    if (!selectedCategoryStillExists) {
      await _changeQuery(_query.copyWith(clearCategory: true));
    } else {
      await _loadBooks(showLoading: false);
    }
  }

  /*
  Future<void> _renameCategory(BookCategory category) async {
    final controller = TextEditingController(text: category.name);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名分类'),
        content: TextField(
          controller: controller,
          autofocus: false,
          maxLength: 20,
          decoration: const InputDecoration(labelText: '分类名称'),
          onSubmitted: (text) => Navigator.pop(dialogContext, text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || value == null || value.isEmpty || value == category.name) {
      return;
    }
    try {
      await _library.renameCustomCategory(category.id!, value);
      await refresh();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '分类重命名失败：$error');
    }
  }

  }
  */

  Future<void> _togglePinned(BookLibraryItem item) async {
    _clearInputFocus();
    final id = item.book.id;
    if (id == null) return;
    await _library.setBookPinned(id, !item.isPinned);
    await _loadBooks(showLoading: false);
  }

  Future<void> _addToReadingSpace(BookLibraryItem item) async {
    final id = item.book.id;
    if (id == null) return;
    try {
      await _library.setBookInReadingSpace(id, true);
      await _loadBooks(showLoading: false);
      if (!mounted) return;
      AppToast.show(context, '已加入在读书籍');
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '加入在读书籍失败：$error');
    }
  }

  Future<void> _editBookCategories(BookLibraryItem item) async {
    final bookId = item.book.id;
    if (bookId == null) return;
    final selected = item.categories.map((category) => category.id!).toSet();
    final result = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text(
                    '调整分类',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text('最多选择 3 个分类'),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final category in _categories)
                        CheckboxListTile(
                          value: selected.contains(category.id),
                          title: Text(category.name),
                          onChanged: (checked) {
                            if (checked == true && selected.length >= 3) {
                              AppToast.show(context, '一本书最多选择 3 个分类');
                              return;
                            }
                            setSheetState(() {
                              if (checked == true) {
                                selected.add(category.id!);
                              } else {
                                selected.remove(category.id);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(
                      sheetContext,
                      selected.toList(growable: false),
                    ),
                    style: BookFlowTheme.primaryButtonStyle(),
                    child: const Text('保存分类'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null) return;
    await _library.setBookCategories(bookId, result);
    await _loadBooks(showLoading: false);
  }

  Future<void> _editBookMetadata(BookLibraryItem item) async {
    final book = item.book;
    if (book.id == null) return;
    final updated = await showModalBottomSheet<BookRecord>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Material(
        color: BookFlowTheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BookMetadataFormSheet(initial: book),
      ),
    );
    if (updated == null) return;
    try {
      await _library.updateBookMetadata(updated);
      await _loadBooks(showLoading: false);
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '书籍资料保存失败：$error');
    }
  }

  void _enterSelectionMode() {
    _clearInputFocus();
    setState(() {
      _selectionMode = true;
      _selectedBookIds.clear();
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedBookIds.clear();
    });
  }

  void _toggleBookSelection(BookLibraryItem item) {
    final id = item.book.id;
    if (id == null) return;
    setState(() {
      if (!_selectedBookIds.add(id)) _selectedBookIds.remove(id);
    });
  }

  Future<void> _deleteSelectedBooks() async {
    if (_selectedBookIds.isEmpty) return;
    await _deleteBooksWithConfirmation(
      _selectedBookIds,
      exitSelectionMode: true,
    );
  }

  Future<void> _deleteBookItem(BookLibraryItem item) async {
    final id = item.book.id;
    if (id == null) return;
    await _deleteBooksWithConfirmation([id]);
  }

  Future<void> _deleteBooksWithConfirmation(
    Iterable<int> bookIds, {
    bool exitSelectionMode = false,
  }) async {
    final ids = bookIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final count = ids.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(count == 1 ? '删除这本书？' : '删除$count本书籍？'),
        content: const Text('书籍、关联笔记和原图都会被删除，此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB94A45),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await _library.deleteBooks(ids);
      if (!mounted) return;
      if (exitSelectionMode) _exitSelectionMode();
      await _loadBooks(showLoading: false);
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '删除书籍失败：$error');
    }
  }

  Future<void> _editSelectedBooks() async {
    final selectedItems = _items
        .where((item) => _selectedBookIds.contains(item.book.id))
        .toList(growable: false);
    if (selectedItems.isEmpty) return;
    if (selectedItems.length == 1) {
      await _editBookMetadata(selectedItems.single);
      return;
    }

    final selectedCategories = selectedItems.first.categories
        .map((category) => category.id!)
        .toSet();
    for (final item in selectedItems.skip(1)) {
      selectedCategories.retainAll(
        item.categories.map((category) => category.id),
      );
    }
    final result = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text('批量编辑 ${selectedItems.length} 本书籍'),
                subtitle: const Text('统一设置分类，最多选择 3 个'),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final category in _categories)
                      CheckboxListTile(
                        value: selectedCategories.contains(category.id),
                        title: Text(category.name),
                        onChanged: (checked) {
                          if (checked == true &&
                              selectedCategories.length >= 3) {
                            AppToast.show(context, '最多选择 3 个分类');
                            return;
                          }
                          setSheetState(() {
                            if (checked == true) {
                              selectedCategories.add(category.id!);
                            } else {
                              selectedCategories.remove(category.id);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: FilledButton(
                  style: BookFlowTheme.primaryButtonStyle(),
                  onPressed: () => Navigator.pop(
                    sheetContext,
                    selectedCategories.toList(growable: false),
                  ),
                  child: const Text('保存修改'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || result == null) return;
    for (final item in selectedItems) {
      await _library.setBookCategories(item.book.id!, result);
    }
    if (!mounted) return;
    await _loadBooks(showLoading: false);
  }

  void _showBookActions(BookLibraryItem item) {
    _clearInputFocus();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Wrap(
          children: [
            if (!item.isInReadingSpace)
              ListTile(
                leading: const Icon(Icons.add_to_photos_outlined),
                title: const Text('加入在读书籍'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _addToReadingSpace(item);
                },
              ),
            if (item.isInReadingSpace)
              ListTile(
                leading: Icon(
                  item.isPinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin_rounded,
                ),
                title: Text(item.isPinned ? '取消置顶' : '置顶书籍'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _togglePinned(item);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑书籍资料'),
              onTap: () {
                Navigator.pop(sheetContext);
                _editBookMetadata(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.category_outlined),
              title: const Text('调整分类'),
              subtitle: Text(
                item.categories.isEmpty
                    ? '未分类'
                    : item.categories
                          .map((category) => category.name)
                          .join('、'),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _editBookCategories(item);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Color(0xFFB94A45),
              ),
              title: const Text(
                '删除该书籍',
                style: TextStyle(color: Color(0xFFB94A45)),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _deleteBookItem(item);
              },
            ),
          ],
        ),
      ),
    );
  }

  /*
  String get _directionLabel => switch (_query.sortMode) {
    BookLibrarySortMode.recentStudy =>
      _query.direction == BookLibrarySortDirection.descending ? '近→远' : '远→近',
    BookLibrarySortMode.recentCreated =>
      _query.direction == BookLibrarySortDirection.descending ? '新→旧' : '旧→新',
    BookLibrarySortMode.studyFrequency =>
      _query.direction == BookLibrarySortDirection.descending ? '高→低' : '低→高',
  };
  */

  String? get _activeCategoryName {
    if (_query.uncategorizedOnly) return '未分类';
    final id = _query.categoryId;
    if (id == null) return null;
    return _categories.where((category) => category.id == id).firstOrNull?.name;
  }

  Widget? _buildActiveCategoryChip() {
    final categoryName = _activeCategoryName;
    if (categoryName == null) return null;
    return Align(
      alignment: Alignment.centerLeft,
      child: InputChip(
        visualDensity: VisualDensity.compact,
        backgroundColor: Colors.transparent,
        side: const BorderSide(color: BookFlowTheme.primary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        label: Text(
          categoryName,
          style: const TextStyle(
            color: BookFlowTheme.ink,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        deleteIconColor: BookFlowTheme.inkSecondary,
        onDeleted: () {
          _clearInputFocus();
          unawaited(_changeQuery(_query.copyWith(clearCategory: true)));
        },
      ),
    );
  }

  Widget _buildActiveCategoryBarSlot() => AnimatedSize(
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOutCubic,
    alignment: Alignment.topCenter,
    child: _activeCategoryName == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: _buildActiveCategoryChip(),
          ),
  );

  bool get _hasActiveCategoryFilter =>
      _query.categoryId != null || _query.uncategorizedOnly;

  void _closeFilterMenu() {
    _filterMenuOverlay?.remove();
    _filterMenuOverlay = null;
    _activeFilterMenuLink = null;
  }

  void _toggleFilterMenu(LayerLink link) {
    if (_filterMenuOverlay != null) {
      final shouldReopen = !identical(_activeFilterMenuLink, link);
      _closeFilterMenu();
      if (shouldReopen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _toggleFilterMenu(link);
        });
      }
      return;
    }
    _clearInputFocus();
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closeFilterMenu,
            ),
          ),
          CompositedTransformFollower(
            link: link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomRight,
            followerAnchor: Alignment.topRight,
            offset: const Offset(0, 8),
            child: _FilterMenuPanel(
              categories: _categories,
              selectedCategoryId: _query.categoryId,
              showAllSelected:
                  _query.categoryId == null && !_query.uncategorizedOnly,
              onSelected: (action) {
                _closeFilterMenu();
                unawaited(_applyFilterAction(action));
              },
              onCreate: () {
                _closeFilterMenu();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) unawaited(_createCategory());
                });
              },
              onManageCategories: () {
                _closeFilterMenu();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) unawaited(_showCategoryManager());
                });
              },
              onManage: (category) {
                _closeFilterMenu();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) unawaited(_showCategoryActions(category));
                });
              },
            ),
          ),
        ],
      ),
    );
    _activeFilterMenuLink = link;
    _filterMenuOverlay = entry;
    overlay.insert(entry);
  }

  Widget _buildFilterMenuButton({
    required LayerLink link,
    double dimension = 46,
  }) {
    final active = _query.categoryId != null || _query.uncategorizedOnly;
    return CompositedTransformTarget(
      link: link,
      child: Tooltip(
        message: '筛选分类',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _toggleFilterMenu(link),
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: dimension,
              height: dimension,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.filter_alt_outlined,
                    color: active ? BookFlowTheme.primary : BookFlowTheme.ink,
                    size: 22,
                  ),
                  if (active)
                    const Positioned(
                      top: 5,
                      right: 5,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: BookFlowTheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: SizedBox(width: 7, height: 7),
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

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop:
        !_selectionMode &&
        !_hasActiveCategoryFilter &&
        !_searchFocusNode.hasFocus,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      if (_searchFocusNode.hasFocus) {
        _clearInputFocus();
      } else if (_selectionMode) {
        _exitSelectionMode();
      } else if (_hasActiveCategoryFilter) {
        unawaited(_changeQuery(_query.copyWith(clearCategory: true)));
      }
    },
    child: BookPaperBackground(
      showTexture: false,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: _buildToolbar(),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeIn,
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ...previousChildren,
                    currentChild ?? const SizedBox.shrink(),
                  ],
                ),
                child: KeyedSubtree(
                  key: ValueKey(
                    '${_loading
                        ? 'loading'
                        : _error != null
                        ? 'error'
                        : _items.isEmpty
                        ? 'empty'
                        : 'content'}-${_viewMode.name}',
                  ),
                  child: _buildContent(),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildToolbar() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: 46,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    '阅读空间',
                    style: TextStyle(
                      color: BookFlowTheme.ink,
                      fontSize: 21,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.5,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: Text(
                      '${_items.length} 本',
                      style: const TextStyle(
                        color: BookFlowTheme.muted,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<BookLibraryViewMode>(
              tooltip: '展示方式',
              position: PopupMenuPosition.under,
              offset: const Offset(0, 5),
              constraints: const BoxConstraints(minWidth: 120, maxWidth: 132),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              color: BookFlowTheme.surface,
              elevation: 8,
              onOpened: _clearInputFocus,
              onSelected: _changeViewMode,
              itemBuilder: (_) => [
                _popupOption(
                  value: BookLibraryViewMode.grid,
                  label: '双列展示',
                  icon: Icons.grid_view_rounded,
                  selected: _viewMode == BookLibraryViewMode.grid,
                ),
                _popupOption(
                  value: BookLibraryViewMode.learningList,
                  label: '列表展示',
                  icon: Icons.view_list_rounded,
                  selected: _viewMode == BookLibraryViewMode.learningList,
                ),
              ],
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(
                  _viewMode == BookLibraryViewMode.grid
                      ? Icons.grid_view_rounded
                      : Icons.view_list_rounded,
                  color: BookFlowTheme.inkSecondary,
                  size: 21,
                ),
              ),
            ),
            const SizedBox(width: 4),
            _CreateBookButton(
              onTap: () {
                _clearInputFocus();
                widget.onCreateBook();
              },
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 46,
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          autofocus: false,
          onTap: _activateSearch,
          onTapOutside: (_) => _clearInputFocus(),
          onChanged: _onSearchChanged,
          style: const TextStyle(color: BookFlowTheme.ink, fontSize: 14),
          decoration: InputDecoration(
            hintText: '搜索书名、作者或 ISBN',
            hintStyle: const TextStyle(
              color: BookFlowTheme.muted,
              fontSize: 14,
            ),
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: BookFlowTheme.inkSecondary,
              size: 23,
            ),
            filled: true,
            fillColor: BookFlowTheme.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: BookFlowTheme.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: BookFlowTheme.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(
                color: BookFlowTheme.primary,
                width: 1.3,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 0),
          ),
        ),
      ),
    ],
  );

  /*
  Future<void> _chooseSort() async {
    final selected = await showModalBottomSheet<BookLibraryQuery>(
      context: context,
      showDragHandle: true,
      backgroundColor: BookFlowTheme.surface,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  '书籍排序',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              for (final mode in BookLibrarySortMode.values)
                ListTile(
                  selected: mode == _query.sortMode,
                  selectedColor: BookFlowTheme.primary,
                  title: Text(_sortModeLabel(mode)),
                  trailing: mode == _query.sortMode
                      ? const Icon(
                          Icons.check_rounded,
                          color: BookFlowTheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.pop(
                    sheetContext,
                    _query.copyWith(sortMode: mode),
                  ),
                ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  _query.direction == BookLibrarySortDirection.descending
                      ? Icons.south_rounded
                      : Icons.north_rounded,
                  color: BookFlowTheme.primary,
                ),
                title: Text('当前顺序：$_directionLabel'),
                trailing: const Text(
                  '切换',
                  style: TextStyle(
                    color: BookFlowTheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () => Navigator.pop(
                  sheetContext,
                  _query.copyWith(
                    direction:
                        _query.direction == BookLibrarySortDirection.descending
                        ? BookLibrarySortDirection.ascending
                        : BookLibrarySortDirection.descending,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) await _changeQuery(selected);
  }

  */

  Future<void> _applySortMode(BookLibrarySortMode mode) async {
    _clearInputFocus();
    await _changeQuery(
      _query.copyWith(
        sortMode: mode,
        direction: BookLibrarySortDirection.descending,
      ),
    );
  }

  Widget _buildLibraryActionBar() {
    if (_selectionMode) {
      final hasSelection = _selectedBookIds.isNotEmpty;
      return SizedBox(
        height: 40,
        child: Row(
          children: [
            TextButton(
              onPressed: _exitSelectionMode,
              style: TextButton.styleFrom(
                foregroundColor: BookFlowTheme.inkSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              child: const Text('取消'),
            ),
            const SizedBox(width: 7),
            Text(
              '已选 ${_selectedBookIds.length} 本',
              style: const TextStyle(
                color: BookFlowTheme.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: _selectedBookIds.length > 1 ? '批量编辑分类' : '编辑书籍',
              onPressed: hasSelection ? _editSelectedBooks : null,
              color: BookFlowTheme.primary,
              disabledColor: BookFlowTheme.muted,
              icon: const Icon(Icons.edit_outlined, size: 21),
            ),
            IconButton(
              tooltip: '删除所选书籍',
              onPressed: hasSelection ? _deleteSelectedBooks : null,
              color: const Color(0xFFCB3D36),
              disabledColor: BookFlowTheme.muted,
              icon: const Icon(Icons.delete_outline_rounded, size: 22),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          const Text(
            '全部书籍',
            style: TextStyle(
              color: BookFlowTheme.ink,
              fontSize: 17,
              height: 1.3,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          _buildFilterMenuButton(link: _libraryFilterMenuLink, dimension: 38),
          const SizedBox(width: 4),
          _SortMenuButton(
            sortMode: _query.sortMode,
            onSortChanged: _applySortMode,
            onOpened: _clearInputFocus,
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: '多选编辑',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _enterSelectionMode,
                customBorder: const CircleBorder(),
                child: const SizedBox(
                  width: 38,
                  height: 38,
                  child: Icon(
                    Icons.checklist_rounded,
                    size: 24,
                    color: BookFlowTheme.ink,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /*
  String _sortModeLabel(BookLibrarySortMode mode) => switch (mode) {
    BookLibrarySortMode.recentStudy => '最新阅读',
    BookLibrarySortMode.recentCreated => '最新创建',
    BookLibrarySortMode.studyFrequency => '阅读频率',
  };
  */

  Widget _buildContent() {
    if (_loading) {
      return const SizedBox.shrink();
    }
    if (_error != null) {
      return _StatusView(
        icon: Icons.cloud_off_outlined,
        title: '书籍暂时无法加载',
        message: _error!,
        actionLabel: '重试',
        onAction: _loadBooks,
      );
    }
    if (_items.isEmpty) {
      final hasFilter =
          _query.searchText.trim().isNotEmpty ||
          _query.categoryId != null ||
          _query.uncategorizedOnly;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: _buildLibraryActionBar(),
          ),
          _buildActiveCategoryBarSlot(),
          Expanded(
            child: _StatusView(
              icon: hasFilter
                  ? Icons.search_off_rounded
                  : Icons.menu_book_outlined,
              title: hasFilter ? '没有找到这本书' : '还没有建立书籍',
              message: hasFilter ? '试试调整搜索词或分类条件。' : '点击右上角“新建”，开始建立阅读空间。',
              actionLabel: hasFilter ? '清除筛选' : null,
              onAction: hasFilter
                  ? () async {
                      _searchController.clear();
                      await _changeQuery(const BookLibraryQuery());
                    }
                  : null,
            ),
          ),
        ],
      );
    }
    return RefreshIndicator(
      color: BookFlowTheme.primary,
      onRefresh: refresh,
      child: _viewMode == BookLibraryViewMode.grid
          ? _BookGrid(
              items: _items,
              onOpen: _openBook,
              onLongPress: _showBookActions,
              actionBar: _buildLibraryActionBar(),
              categoryBar: _buildActiveCategoryBarSlot(),
              selectionMode: _selectionMode,
              selectedBookIds: _selectedBookIds,
              onToggleSelection: _toggleBookSelection,
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: _buildLibraryActionBar(),
                ),
                _buildActiveCategoryBarSlot(),
                Expanded(
                  child: _BookLearningList(
                    items: _items,
                    onOpen: _openBook,
                    onTogglePin: _togglePinned,
                    onMore: _showBookActions,
                    selectionMode: _selectionMode,
                    selectedBookIds: _selectedBookIds,
                    onToggleSelection: _toggleBookSelection,
                  ),
                ),
              ],
            ),
    );
  }
}

class _CategoryNameDialog extends StatefulWidget {
  const _CategoryNameDialog({
    this.title = '新建分类',
    this.initialValue = '',
    this.confirmLabel = '保存',
  });

  final String title;
  final String initialValue;
  final String confirmLabel;

  @override
  State<_CategoryNameDialog> createState() => _CategoryNameDialogState();
}

class _CategoryNameDialogState extends State<_CategoryNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: false,
      maxLength: 20,
      decoration: const InputDecoration(labelText: '分类名称', hintText: '例如：教育学'),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
    ],
  );
}

class _CategoryManagementDialog extends StatefulWidget {
  const _CategoryManagementDialog({required this.library});

  final BookLibraryService library;

  @override
  State<_CategoryManagementDialog> createState() =>
      _CategoryManagementDialogState();
}

class _CategoryManagementDialogState extends State<_CategoryManagementDialog> {
  List<BookCategory> _categories = const [];
  Map<int, int> _bookCounts = const {};
  bool _loading = true;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCategories());
  }

  Future<void> _loadCategories() async {
    final allCategories = await widget.library.listCategories();
    final categories = allCategories
        .where((category) => category.name != '其他')
        .toList(growable: false);
    final entries = await Future.wait(
      categories.map((category) async {
        final id = category.id!;
        return MapEntry(id, await widget.library.countBooksInCategory(id));
      }),
    );
    if (!mounted) return;
    setState(() {
      _categories = categories;
      _bookCounts = Map<int, int>.fromEntries(entries);
      _loading = false;
    });
  }

  Future<void> _rename(BookCategory category) async {
    final value = await showDialog<String>(
      context: context,
      requestFocus: false,
      builder: (_) => _CategoryNameDialog(
        title: '重新命名分类',
        initialValue: category.name,
        confirmLabel: '保存',
      ),
    );
    if (!mounted || value == null || value.isEmpty || value == category.name) {
      return;
    }
    try {
      await widget.library.renameCustomCategory(category.id!, value);
      _changed = true;
      await _loadCategories();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '分类重命名失败：$error');
    }
  }

  Future<void> _delete(BookCategory category) async {
    final bookCount = _bookCounts[category.id] ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      requestFocus: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除分类'),
        content: Text(
          '“${category.name}”目前包含 $bookCount 本书。\n\n'
          '删除分类不会删除这些书籍，是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB94A45),
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await widget.library.deleteCustomCategory(category.id!);
      _changed = true;
      await _loadCategories();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '删除分类失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('管理分类'),
    contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
    content: SizedBox(
      width: 320,
      height: 360,
      child: _loading
          ? const SizedBox.shrink()
          : _categories.isEmpty
          ? const Center(
              child: Text(
                '还没有可管理的自定义分类',
                style: TextStyle(color: BookFlowTheme.muted),
              ),
            )
          : ListView.separated(
              itemCount: _categories.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: BookFlowTheme.line),
              itemBuilder: (context, index) {
                final category = _categories[index];
                final count = _bookCounts[category.id] ?? 0;
                return SizedBox(
                  height: 58,
                  child: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                category.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '$count 本书',
                                style: const TextStyle(
                                  color: BookFlowTheme.muted,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '重新命名',
                        onPressed: () => unawaited(_rename(category)),
                        icon: const Icon(Icons.edit_outlined, size: 20),
                      ),
                      IconButton(
                        tooltip: '删除分类',
                        color: const Color(0xFFB94A45),
                        onPressed: () => unawaited(_delete(category)),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 21,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, _changed),
        child: const Text('完成'),
      ),
    ],
  );
}

class _FilterMenuPanel extends StatefulWidget {
  const _FilterMenuPanel({
    required this.categories,
    required this.selectedCategoryId,
    required this.showAllSelected,
    required this.onSelected,
    required this.onCreate,
    required this.onManageCategories,
    required this.onManage,
  });

  final List<BookCategory> categories;
  final int? selectedCategoryId;
  final bool showAllSelected;
  final ValueChanged<_FilterMenuAction> onSelected;
  final VoidCallback onCreate;
  final VoidCallback onManageCategories;
  final ValueChanged<BookCategory> onManage;

  @override
  State<_FilterMenuPanel> createState() => _FilterMenuPanelState();
}

class _FilterMenuPanelState extends State<_FilterMenuPanel>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late final AnimationController _animationController;
  late final Animation<double> _animation;
  late final Animation<double> _scaleAnimation;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    final curve = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    );
    _animation = curve;
    _scaleAnimation = Tween<double>(begin: .96, end: 1).animate(curve);
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -.06),
      end: Offset.zero,
    ).animate(curve);
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rowCount = widget.categories.length + 1;
    final visibleRows = rowCount.clamp(1, 4);
    final hasOverflow = rowCount > 4;
    return FadeTransition(
      opacity: _animation,
      child: SlideTransition(
        position: _slideAnimation,
        child: ScaleTransition(
          alignment: Alignment.topRight,
          scale: _scaleAnimation,
          child: Material(
            color: BookFlowTheme.surface,
            elevation: 10,
            shadowColor: const Color(0x2E173226),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: BookFlowTheme.line),
                borderRadius: BorderRadius.circular(14),
              ),
              child: SizedBox(
                width: 164,
                height: visibleRows * 44.0 + 98,
                child: Column(
                  children: [
                    SizedBox(
                      height: visibleRows * 44.0,
                      child: Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: hasOverflow,
                        radius: const Radius.circular(3),
                        thickness: 3,
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.zero,
                          itemExtent: 44,
                          itemCount: rowCount,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return _FilterMenuRow(
                                label: '全部书籍',
                                selected: widget.showAllSelected,
                                onTap: () => widget.onSelected(
                                  const _FilterMenuAction(
                                    _FilterMenuActionType.all,
                                  ),
                                ),
                              );
                            }
                            final category = widget.categories[index - 1];
                            return _FilterMenuRow(
                              label: category.name,
                              selected:
                                  widget.selectedCategoryId == category.id,
                              onTap: () => widget.onSelected(
                                _FilterMenuAction(
                                  _FilterMenuActionType.category,
                                  categoryId: category.id,
                                ),
                              ),
                              onLongPress: category.name == '其他'
                                  ? null
                                  : () => widget.onManage(category),
                            );
                          },
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: BookFlowTheme.line),
                    SizedBox(
                      height: 48,
                      child: InkWell(
                        onTap: widget.onCreate,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 14),
                          child: Row(
                            children: [
                              Icon(
                                Icons.add_rounded,
                                size: 19,
                                color: BookFlowTheme.primary,
                              ),
                              SizedBox(width: 9),
                              Text(
                                '自定义分类',
                                style: TextStyle(
                                  color: BookFlowTheme.primary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: BookFlowTheme.line),
                    SizedBox(
                      height: 48,
                      child: InkWell(
                        onTap: widget.onManageCategories,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 14),
                          child: Row(
                            children: [
                              Icon(
                                Icons.settings_outlined,
                                size: 18,
                                color: BookFlowTheme.inkSecondary,
                              ),
                              SizedBox(width: 10),
                              Text(
                                '管理分类',
                                style: TextStyle(
                                  color: BookFlowTheme.ink,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
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
}

class _FilterMenuRow extends StatelessWidget {
  const _FilterMenuRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? const Color(0xFFF0F5F2) : Colors.transparent,
    child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? BookFlowTheme.primary : BookFlowTheme.ink,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

PopupMenuItem<T> _popupOption<T>({
  required T value,
  required String label,
  required IconData icon,
  required bool selected,
}) => PopupMenuItem<T>(
  value: value,
  height: 44,
  padding: const EdgeInsets.symmetric(horizontal: 4),
  child: DecoratedBox(
    decoration: BoxDecoration(
      color: selected ? const Color(0xFFE7F0EB) : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Icon(
            icon,
            size: 19,
            color: selected
                ? BookFlowTheme.primary
                : BookFlowTheme.inkSecondary,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? BookFlowTheme.primary : BookFlowTheme.ink,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    ),
  ),
);

/*
class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({required this.value, required this.onChanged});

  final BookLibraryViewMode value;
  final ValueChanged<BookLibraryViewMode> onChanged;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: value == BookLibraryViewMode.grid ? '切换到学习列表' : '切换到书架',
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: () => onChanged(
          value == BookLibraryViewMode.grid
              ? BookLibraryViewMode.learningList
              : BookLibraryViewMode.grid,
        ),
        borderRadius: BorderRadius.circular(11),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            value == BookLibraryViewMode.grid
                ? Icons.grid_view_rounded
                : Icons.view_list_rounded,
            size: 21,
            color: BookFlowTheme.inkSecondary,
          ),
        ),
      ),
    ),
  );
}

}
*/

class _CreateBookButton extends StatelessWidget {
  const _CreateBookButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '新建书籍',
    child: Material(
      color: BookFlowTheme.primary,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: const SizedBox(
          height: 40,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 17, color: Colors.white),
                SizedBox(width: 4),
                Text(
                  '新建',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    height: 1,
                    fontWeight: FontWeight.w600,
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

class _SortMenuButton extends StatelessWidget {
  const _SortMenuButton({
    required this.sortMode,
    required this.onSortChanged,
    required this.onOpened,
  });

  final BookLibrarySortMode sortMode;
  final ValueChanged<BookLibrarySortMode> onSortChanged;
  final VoidCallback onOpened;

  @override
  Widget build(BuildContext context) => PopupMenuButton<BookLibrarySortMode>(
    tooltip: '书籍排序',
    position: PopupMenuPosition.under,
    offset: const Offset(0, 5),
    constraints: const BoxConstraints(minWidth: 120, maxWidth: 132),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    color: BookFlowTheme.surface,
    elevation: 7,
    onOpened: onOpened,
    onSelected: onSortChanged,
    itemBuilder: (_) => [
      for (final mode in BookLibrarySortMode.values)
        _popupOption(
          value: mode,
          label: _sortLabel(mode),
          icon: Icons.sort_rounded,
          selected: mode == sortMode,
        ),
    ],
    child: const SizedBox(
      width: 38,
      height: 38,
      child: Icon(Icons.swap_vert_rounded, size: 24, color: BookFlowTheme.ink),
    ),
  );

  static String _sortLabel(BookLibrarySortMode mode) => switch (mode) {
    BookLibrarySortMode.recentStudy => '最新阅读',
    BookLibrarySortMode.recentCreated => '最新创建',
    BookLibrarySortMode.studyFrequency => '阅读频率',
  };
}

class _BookGrid extends StatelessWidget {
  const _BookGrid({
    required this.items,
    required this.onOpen,
    required this.onLongPress,
    required this.actionBar,
    required this.categoryBar,
    required this.selectionMode,
    required this.selectedBookIds,
    required this.onToggleSelection,
  });

  final List<BookLibraryItem> items;
  final ValueChanged<int> onOpen;
  final ValueChanged<BookLibraryItem> onLongPress;
  final Widget actionBar;
  final Widget categoryBar;
  final bool selectionMode;
  final Set<int> selectedBookIds;
  final ValueChanged<BookLibraryItem> onToggleSelection;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 720
          ? 4
          : constraints.maxWidth >= 560
          ? 3
          : 2;
      final horizontalPadding = columns == 2 ? 20.0 : 24.0;
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            sliver: SliverToBoxAdapter(child: actionBar),
          ),
          SliverToBoxAdapter(child: categoryBar),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              8,
              horizontalPadding,
              28,
            ),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
                childAspectRatio: .63,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) => _CompactBookCard(
                item: items[index],
                onOpen: onOpen,
                onLongPress: onLongPress,
                selectionMode: selectionMode,
                selected: selectedBookIds.contains(items[index].book.id),
                onToggleSelection: onToggleSelection,
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 150),
    width: 23,
    height: 23,
    decoration: BoxDecoration(
      color: selected ? BookFlowTheme.primary : BookFlowTheme.surface,
      shape: BoxShape.circle,
      border: Border.all(
        color: selected ? BookFlowTheme.primary : BookFlowTheme.muted,
        width: 1.5,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x1A173226),
          blurRadius: 5,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: selected
        ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
        : null,
  );
}

class _CompactBookCard extends StatelessWidget {
  const _CompactBookCard({
    required this.item,
    required this.onOpen,
    required this.onLongPress,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelection,
  });

  final BookLibraryItem item;
  final ValueChanged<int> onOpen;
  final ValueChanged<BookLibraryItem> onLongPress;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<BookLibraryItem> onToggleSelection;

  @override
  Widget build(BuildContext context) {
    final id = item.book.id;
    return Semantics(
      button: true,
      label:
          '${item.book.title}，${item.noteCount} 篇笔记${item.isPinned ? '，已置顶' : ''}',
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: BookFlowTheme.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: BookFlowTheme.line),
                boxShadow: BookFlowTheme.cardShadow,
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: id == null
                      ? null
                      : () => selectionMode
                            ? onToggleSelection(item)
                            : onOpen(id),
                  onLongPress: selectionMode ? null : () => onLongPress(item),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 9),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SizedBox(
                            width: double.infinity,
                            child: BookCoverStyled(
                              book: item.book,
                              borderRadius: 7,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item.book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: BookFlowTheme.ink,
                            fontSize: 13,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _BookGridMetaRow(
                          noteCount: item.noteCount,
                          lastStudiedAt: item.lastStudiedAt,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (item.isPinned && !selectionMode)
            const Positioned(
              top: -7,
              right: -3,
              child: _BookPinMarker(active: true, size: 27),
            ),
          if (selectionMode)
            Positioned(
              left: 6,
              top: 6,
              child: _SelectionMark(selected: selected),
            ),
        ],
      ),
    );
  }
}

class _BookGridMetaRow extends StatelessWidget {
  const _BookGridMetaRow({
    required this.noteCount,
    required this.lastStudiedAt,
  });

  final int noteCount;
  final String lastStudiedAt;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _BookGridMetaItem(
        icon: Icons.article_outlined,
        iconColor: BookFlowTheme.bookGold,
        label: '$noteCount 篇笔记',
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Align(
          alignment: Alignment.centerRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: _BookGridMetaItem(
              icon: Icons.schedule_rounded,
              iconColor: BookFlowTheme.muted,
              label: _bookLastStudyLabel(lastStudiedAt),
            ),
          ),
        ),
      ),
    ],
  );
}

class _BookGridMetaItem extends StatelessWidget {
  const _BookGridMetaItem({
    required this.icon,
    required this.iconColor,
    required this.label,
  });

  final IconData icon;
  final Color iconColor;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ExcludeSemantics(child: Icon(icon, size: 14, color: iconColor)),
      const SizedBox(width: 5),
      Text(
        label,
        maxLines: 1,
        style: const TextStyle(
          color: BookFlowTheme.inkSecondary,
          fontSize: 11.5,
          height: 1.35,
        ),
      ),
    ],
  );
}

class _BookPinMarker extends StatelessWidget {
  const _BookPinMarker({required this.active, this.size = 26});

  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: .58,
    child: Icon(
      active ? Icons.push_pin_rounded : Icons.push_pin_outlined,
      size: size,
      color: active ? BookFlowTheme.bookGold : BookFlowTheme.inkSecondary,
      shadows: active
          ? const [
              Shadow(
                color: Color(0x36000000),
                blurRadius: 3,
                offset: Offset(1, 2),
              ),
            ]
          : null,
    ),
  );
}

class _BookLearningList extends StatelessWidget {
  const _BookLearningList({
    required this.items,
    required this.onOpen,
    required this.onTogglePin,
    required this.onMore,
    required this.selectionMode,
    required this.selectedBookIds,
    required this.onToggleSelection,
  });

  final List<BookLibraryItem> items;
  final ValueChanged<int> onOpen;
  final ValueChanged<BookLibraryItem> onTogglePin;
  final ValueChanged<BookLibraryItem> onMore;
  final bool selectionMode;
  final Set<int> selectedBookIds;
  final ValueChanged<BookLibraryItem> onToggleSelection;

  @override
  Widget build(BuildContext context) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
    itemCount: items.length,
    separatorBuilder: (_, _) => const SizedBox(height: 14),
    itemBuilder: (context, index) {
      final item = items[index];
      final id = item.book.id;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: BookFlowTheme.surfaceElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BookFlowTheme.line),
          boxShadow: BookFlowTheme.cardShadow,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: id == null
                ? null
                : () => selectionMode ? onToggleSelection(item) : onOpen(id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 80,
                    height: 116,
                    child: Center(
                      child: SizedBox(
                        width: 80,
                        height: 110,
                        child: BookCoverStyled(
                          book: item.book,
                          borderRadius: 8,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 116),
                      child: Stack(
                        children: [
                          Transform.translate(
                            offset: const Offset(0, 8),
                            child: Padding(
                              padding: const EdgeInsets.only(right: 50),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.book.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: BookFlowTheme.ink,
                                      fontSize: 17,
                                      height: 1.25,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  if (item.book.authorLabel.isNotEmpty)
                                    Text(
                                      item.book.authorLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: BookFlowTheme.inkSecondary,
                                        fontSize: 14,
                                        height: 1.35,
                                      ),
                                    )
                                  else
                                    const SizedBox(height: 19),
                                  const SizedBox(height: 12),
                                  _BookListInfoRow(
                                    icon: Icons.article_outlined,
                                    label: '${item.noteCount} 篇笔记',
                                  ),
                                  const SizedBox(height: 7),
                                  _BookListInfoRow(
                                    icon: Icons.schedule_rounded,
                                    label: _bookLastStudyLabel(
                                      item.lastStudiedAt,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (selectionMode)
                            Positioned(
                              top: 0,
                              right: -4,
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: _SelectionMark(
                                    selected: selectedBookIds.contains(id),
                                  ),
                                ),
                              ),
                            )
                          else ...[
                            Positioned(
                              top: 0,
                              right: -4,
                              child: IconButton(
                                tooltip: item.isPinned ? '取消置顶' : '置顶书籍',
                                onPressed: () => onTogglePin(item),
                                icon: Icon(
                                  item.isPinned
                                      ? Icons.push_pin_rounded
                                      : Icons.push_pin_outlined,
                                ),
                                iconSize: 26,
                                color: item.isPinned
                                    ? BookFlowTheme.primaryStrong
                                    : BookFlowTheme.inkSecondary,
                                constraints: const BoxConstraints.tightFor(
                                  width: 48,
                                  height: 48,
                                ),
                                padding: EdgeInsets.zero,
                                alignment: Alignment.topCenter,
                              ),
                            ),
                            Positioned(
                              right: -4,
                              bottom: 0,
                              child: IconButton(
                                tooltip: '书籍操作',
                                onPressed: () => onMore(item),
                                icon: const Icon(Icons.more_vert_rounded),
                                iconSize: 26,
                                color: BookFlowTheme.inkSecondary,
                                constraints: const BoxConstraints.tightFor(
                                  width: 48,
                                  height: 48,
                                ),
                                padding: EdgeInsets.zero,
                                alignment: Alignment.bottomCenter,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

String _bookLastStudyLabel(String timestamp) {
  if (timestamp.isEmpty) return '尚未阅读';
  final value = DateTime.tryParse(timestamp);
  if (value == null) return '最近阅读';
  final today = DateTime.now();
  final date = DateTime(value.year, value.month, value.day);
  final todayDate = DateTime(today.year, today.month, today.day);
  final difference = todayDate.difference(date).inDays;
  if (difference == 0) return '今天';
  if (difference == 1) return '昨天';
  return '${value.month}月${value.day}日';
}

class _BookListInfoRow extends StatelessWidget {
  const _BookListInfoRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      ExcludeSemantics(child: Icon(icon, size: 16, color: BookFlowTheme.muted)),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: BookFlowTheme.inkSecondary,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ),
    ],
  );
}

class _StatusView extends StatelessWidget {
  const _StatusView({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 46, color: BookFlowTheme.primary),
          const SizedBox(height: 14),
          Text(title, style: BookFlowTheme.heading),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center, style: BookFlowTheme.body),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
