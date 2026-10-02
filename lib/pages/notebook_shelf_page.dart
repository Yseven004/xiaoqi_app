import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/notebook_theme.dart';
import '../models/notebook.dart';
import '../services/database_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/notebook_cover.dart';
import '../widgets/notebook_dialogs.dart';
import '../widgets/prototype_pressable.dart';
import 'notebook_directory_page.dart';

class NotebookShelfPage extends StatefulWidget {
  const NotebookShelfPage({super.key});

  @override
  State<NotebookShelfPage> createState() => _NotebookShelfPageState();
}

class _NotebookShelfPageState extends State<NotebookShelfPage> {
  final _db = DatabaseService();
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  List<Notebook> _notebooks = const [];
  Timer? _searchTimer;
  bool _loading = true;
  bool _gridView = true;
  bool _selectionMode = false;
  String _status = 'active';
  String _category = 'all';
  String _sort = 'updated';
  int _visibleCount = 40;
  final Set<int> _selectedIds = <int>{};

  static const _viewPreferenceKey = 'notebook_library_grid_view';
  static const _sortPreferenceKey = 'notebook_library_sort';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_loadDebounced);
    _scrollController.addListener(_loadMoreOnScroll);
    _restorePreferences();
  }

  @override
  void dispose() {
    _searchController.removeListener(_loadDebounced);
    _searchTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _restorePreferences() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _gridView = preferences.getBool(_viewPreferenceKey) ?? true;
      _sort = preferences.getString(_sortPreferenceKey) ?? 'updated';
    });
    await _load();
  }

  Future<void> _persistPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setBool(_viewPreferenceKey, _gridView),
      preferences.setString(_sortPreferenceKey, _sort),
    ]);
  }

  void _loadDebounced() {
    setState(() {});
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 120), () {
      if (mounted) _load(showLoading: false, resetVisible: true);
    });
  }

  void _loadMoreOnScroll() {
    if (!_scrollController.hasClients ||
        _visibleCount >= _notebooks.length ||
        _scrollController.position.extentAfter > 260) {
      return;
    }
    setState(() => _visibleCount += 40);
  }

  List<Notebook> get _visibleNotebooks =>
      _notebooks.take(_visibleCount).toList(growable: false);

  Future<void> _load({
    bool showLoading = true,
    bool resetVisible = false,
  }) async {
    try {
      if (showLoading && mounted) setState(() => _loading = true);
      final notebooks = await _db.queryNotebooks(
        status: _status,
        query: _searchController.text,
        category: _category,
        sort: _sort,
      );
      if (!mounted) return;
      setState(() {
        _notebooks = notebooks;
        if (resetVisible) _visibleCount = 40;
        _loading = false;
        _selectedIds.removeWhere(
          (id) => !_notebooks.any((notebook) => notebook.id == id),
        );
      });
    } catch (error) {
      debugPrint('[NotebookShelf] 加载失败: $error');
      if (!mounted) return;
      setState(() => _loading = false);
      AppToast.show(context, '书房加载失败，请重试');
    }
  }

  List<String> get _categories {
    final values = _notebooks.map((item) => item.category).toSet().toList()
      ..sort();
    return ['all', ...values];
  }

  Future<void> _openNotebook(Notebook notebook) async {
    if (_selectionMode) {
      _toggleSelected(notebook);
      return;
    }
    if (notebook.isDeleted) {
      _showNotebookMenu(notebook);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => NotebookDirectoryPage(notebookId: notebook.id!),
      ),
    );
    await _load();
  }

  void _toggleSelected(Notebook notebook) {
    final id = notebook.id;
    if (id == null) return;
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _showNotebookForm({Notebook? notebook}) async {
    final saved = await showNotebookEditor(
      context,
      notebook: notebook,
      database: _db,
    );
    if (saved != null) await _load(resetVisible: true);
  }

  // ignore: unused_element
  Future<void> _showNotebookFormLegacy({Notebook? notebook}) async {
    final name = TextEditingController(text: notebook?.name ?? '');
    final category = TextEditingController(text: notebook?.category ?? '随手记录');
    final description = TextEditingController(
      text: notebook?.description ?? '',
    );
    var coverIndex = notebook?.coverIndex ?? _notebooks.length;
    var showOnHome = notebook?.showsOnHome ?? false;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: NotebookTheme.lightSurface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 22,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SheetHeader(
                  title: notebook == null ? '新建笔记本' : '编辑笔记本',
                  subtitle: notebook == null ? '名称必填，其余以后也可以修改' : '修改会同步到首页和书房',
                  onClose: () => Navigator.pop(sheetContext, false),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const Key('notebook_name_field'),
                  controller: name,
                  autofocus: false,
                  maxLength: 40,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    hintText: '例如：当下的力量',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: category,
                  maxLength: 20,
                  decoration: const InputDecoration(
                    labelText: '类别',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: description,
                  maxLength: 160,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '描述',
                    hintText: '写下这本笔记本准备记录什么',
                    border: OutlineInputBorder(),
                  ),
                ),
                SwitchListTile(
                  value: showOnHome,
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: NotebookTheme.accent,
                  title: const Text('出现在首页书架'),
                  onChanged: (value) => setSheetState(() => showOnHome = value),
                ),
                const SizedBox(height: 8),
                const Text(
                  '封面颜色',
                  style: TextStyle(
                    color: NotebookTheme.lightMuted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: List.generate(
                    NotebookTheme.covers.length,
                    (index) => Semantics(
                      label: '封面 ${index + 1}',
                      selected:
                          coverIndex % NotebookTheme.covers.length == index,
                      button: true,
                      child: InkWell(
                        key: Key('notebook_cover_$index'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setSheetState(() => coverIndex = index),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            gradient: NotebookTheme.coverGradient(index),
                            borderRadius: BorderRadius.circular(12),
                            border:
                                coverIndex % NotebookTheme.covers.length ==
                                    index
                                ? Border.all(
                                    color: NotebookTheme.lightInk,
                                    width: 3,
                                  )
                                : null,
                          ),
                          child:
                              coverIndex % NotebookTheme.covers.length == index
                              ? const Icon(
                                  Icons.check,
                                  color: Colors.white,
                                  size: 22,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    key: const Key('save_notebook_button'),
                    onPressed: () async {
                      final trimmed = name.text.trim();
                      if (trimmed.isEmpty) {
                        AppToast.show(context, '请先给笔记本起一个名字');
                        return;
                      }
                      try {
                        final slot = showOnHome
                            ? notebook?.homeSlot ??
                                  await _db.firstFreeHomeSlot(
                                    excludingNotebookId: notebook?.id,
                                  )
                            : null;
                        if (!context.mounted) return;
                        if (showOnHome && slot == null) {
                          AppToast.show(context, '首页最多展示 7 本，请先移出一本');
                          return;
                        }
                        if (notebook == null) {
                          await _db.createNotebook(
                            name: trimmed,
                            category: category.text,
                            description: description.text,
                            coverIndex: coverIndex,
                            homeSlot: slot,
                          );
                        } else {
                          await _db.updateNotebook(
                            notebook.copyWith(
                              name: trimmed,
                              category: category.text,
                              description: description.text,
                              coverIndex: coverIndex,
                              homeSlot: slot,
                            ),
                          );
                        }
                        if (sheetContext.mounted) {
                          Navigator.pop(sheetContext, true);
                        }
                      } catch (error) {
                        if (context.mounted) {
                          AppToast.show(context, '保存失败，请重试');
                        }
                      }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: NotebookTheme.accent,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(notebook == null ? '创建' : '保存修改'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    name.dispose();
    category.dispose();
    description.dispose();
    if (saved == true) await _load();
  }

  Future<void> _togglePinned(Notebook notebook) async {
    await _db.setNotebookPinned(notebook.id!, !notebook.isPinned);
    await _load();
  }

  Future<void> _toggleHome(Notebook notebook) async {
    if (notebook.homeSlot != null) {
      await _db.setNotebookHomeSlot(notebook.id!, null);
      await _load();
      return;
    }
    final slot = await _db.firstFreeHomeSlot(excludingNotebookId: notebook.id);
    if (slot == null) {
      if (mounted) AppToast.show(context, '首页最多展示 7 本，请先移出一本');
      return;
    }
    await _db.setNotebookHomeSlot(notebook.id!, slot);
    await _load();
  }

  Future<void> _toggleArchive(Notebook notebook) async {
    await _db.setNotebookArchived(notebook.id!, !notebook.isArchived);
    await _load();
  }

  Future<void> _restoreNotebook(Notebook notebook) async {
    await _db.restoreNotebook(notebook.id!);
    await _load();
    if (mounted) AppToast.show(context, '已恢复「${notebook.name}」');
  }

  Future<void> _deleteNotebook(Notebook notebook) async {
    ScaffoldMessenger.of(context).clearSnackBars();
    await _db.deleteNotebook(notebook.id!);
    await _load();
  }

  List<Notebook> get _selectedNotebooks => _notebooks
      .where((notebook) => _selectedIds.contains(notebook.id))
      .toList(growable: false);

  Future<bool> _confirmBatch({
    required String title,
    required String message,
    required String action,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: FilledButton.styleFrom(
                  backgroundColor: NotebookTheme.danger,
                ),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _batchDelete() async {
    final targets = _selectedNotebooks;
    if (targets.isEmpty) return;
    final confirmed = await _confirmBatch(
      title: '删除 ${targets.length} 本笔记本？',
      message: '删除后会进入“最近删除”，其中的笔记也会暂时隐藏。',
      action: '删除',
    );
    if (!confirmed || !mounted) return;
    final ids = targets.map((item) => item.id).nonNulls.toList();
    ScaffoldMessenger.of(context).clearSnackBars();
    await _db.deleteNotebooks(ids);
    if (!mounted) return;
    _exitSelection();
    await _load(resetVisible: true);
  }

  Future<void> _batchPermanentDelete() async {
    final ids = _selectedNotebooks.map((item) => item.id).nonNulls.toList();
    if (ids.isEmpty) return;
    final confirmed = await _confirmBatch(
      title: '永久删除 ${ids.length} 本笔记本？',
      message: '笔记、封面和关联数据都会被清除，此操作无法撤销。',
      action: '永久删除',
    );
    if (!confirmed) return;
    await _db.permanentlyDeleteNotebooks(ids);
    _exitSelection();
    await _load(resetVisible: true);
  }

  Future<void> _batchRestore() async {
    final ids = _selectedNotebooks.map((item) => item.id).nonNulls.toList();
    await _db.restoreNotebooks(ids);
    _exitSelection();
    await _load(resetVisible: true);
    if (mounted) AppToast.show(context, '已恢复 ${ids.length} 本笔记本');
  }

  Future<void> _runTransactionalBatch(Future<void> Function() action) async {
    try {
      await action();
      _exitSelection();
      await _load(resetVisible: true);
    } catch (error) {
      if (mounted) {
        AppToast.show(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _showNotebookMenu(Notebook notebook) async {
    await showNotebookActions(
      context,
      notebook: notebook,
      database: _db,
      onChanged: () => _load(showLoading: false),
    );
    await _load(showLoading: false);
  }

  // ignore: unused_element
  void _showNotebookMenuLegacy(Notebook notebook) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: NotebookTheme.lightSurface,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetHeader(
              title: notebook.name,
              subtitle: notebook.isDeleted
                  ? '删除于 ${_formatDate(notebook.deletedAt ?? notebook.updatedAt)}'
                  : notebook.category,
              onClose: () => Navigator.pop(sheetContext),
            ),
            if (notebook.isDeleted)
              _MenuTile(
                icon: Icons.restore_outlined,
                label: '恢复笔记本',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _restoreNotebook(notebook);
                },
              )
            else ...[
              _MenuTile(
                icon: notebook.isPinned
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
                label: notebook.isPinned ? '取消置顶' : '置顶',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _togglePinned(notebook);
                },
              ),
              _MenuTile(
                icon: Icons.home_outlined,
                label: notebook.homeSlot == null ? '出现在首页书架' : '移出首页',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleHome(notebook);
                },
              ),
              _MenuTile(
                icon: Icons.edit_outlined,
                label: '编辑笔记本',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showNotebookForm(notebook: notebook);
                },
              ),
              _MenuTile(
                icon: Icons.archive_outlined,
                label: notebook.isArchived ? '取消归档' : '归档',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleArchive(notebook);
                },
              ),
              _MenuTile(
                icon: Icons.delete_outline,
                label: '删除笔记本',
                danger: true,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _deleteNotebook(notebook);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Scaffold(
        backgroundColor: NotebookTheme.lightBackground,
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton(
                key: const Key('create_notebook_button'),
                onPressed: _showNotebookForm,
                backgroundColor: NotebookTheme.accent,
                foregroundColor: Colors.white,
                child: const Icon(Icons.add),
              ),
        body: SafeArea(
          child: Stack(
            children: [
              CustomScrollView(
                controller: _scrollController,
                slivers: [
                  SliverToBoxAdapter(child: _buildHeader()),
                  SliverToBoxAdapter(child: _buildSearch()),
                  if (!_selectionMode)
                    SliverToBoxAdapter(child: _buildFilters()),
                  if (_loading)
                    const SliverFillRemaining(
                      child: SizedBox.shrink(),
                    )
                  else if (_notebooks.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _ShelfEmpty(
                        status: _status,
                        searching: _searchController.text.trim().isNotEmpty,
                        onCreate: _showNotebookForm,
                      ),
                    )
                  else if (_gridView)
                    _buildGrid()
                  else
                    _buildList(),
                  if (!_loading && _visibleCount < _notebooks.length)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 112),
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton(
                            onPressed: () =>
                                setState(() => _visibleCount += 40),
                            child: Text(
                              '加载更多（${_visibleCount.clamp(0, _notebooks.length)}/${_notebooks.length}）',
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (_selectionMode) _buildBatchBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: _selectionMode
          ? Row(
              children: [
                IconButton(
                  tooltip: '取消选择',
                  onPressed: _exitSelection,
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    '已选择 ${_selectedIds.length} 本',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_selectedIds.length == _notebooks.length) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds
                          ..clear()
                          ..addAll(_notebooks.map((item) => item.id).nonNulls);
                      }
                    });
                  },
                  child: const Text('全选'),
                ),
              ],
            )
          : Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                ),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '书房',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        '管理全部笔记本',
                        style: TextStyle(color: NotebookTheme.lightMuted),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _notebooks.isEmpty
                      ? null
                      : () => setState(() => _selectionMode = true),
                  child: const Text('选择'),
                ),
              ],
            ),
    );
  }

  Widget _buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: SearchBar(
        controller: _searchController,
        hintText: '搜索名称、类别或描述',
        leading: const Icon(Icons.search),
        trailing: [
          if (_searchController.text.isNotEmpty)
            IconButton(
              tooltip: '清除搜索',
              onPressed: _searchController.clear,
              icon: const Icon(Icons.close),
            ),
        ],
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: const WidgetStatePropertyAll(
          NotebookTheme.lightSurface,
        ),
        side: const WidgetStatePropertyAll(
          BorderSide(color: NotebookTheme.lightDivider),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterChip('active', '全部'),
                _buildFilterChip('home', '首页展示'),
                _buildFilterChip('archived', '已归档'),
                _buildFilterChip('deleted', '最近删除'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _SelectPill(
                  value: _category,
                  items: _categories,
                  labelFor: (value) => value == 'all' ? '全部类别' : value,
                  onChanged: (value) {
                    setState(() => _category = value ?? 'all');
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SelectPill(
                  value: _sort,
                  items: const ['updated', 'created', 'name'],
                  labelFor: (value) => switch (value) {
                    'created' => '最新创建',
                    'name' => '名称排序',
                    _ => '最近编辑',
                  },
                  onChanged: (value) {
                    setState(() => _sort = value ?? 'updated');
                    _persistPreferences();
                    _load(resetVisible: true);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Container(
                height: 48,
                decoration: BoxDecoration(
                  color: NotebookTheme.lightSurface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: NotebookTheme.lightDivider),
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '书架视图',
                      color: _gridView
                          ? NotebookTheme.accent
                          : NotebookTheme.lightMuted,
                      onPressed: () {
                        setState(() => _gridView = true);
                        _persistPreferences();
                      },
                      icon: const Icon(Icons.grid_view_rounded),
                    ),
                    IconButton(
                      tooltip: '列表视图',
                      color: !_gridView
                          ? NotebookTheme.accent
                          : NotebookTheme.lightMuted,
                      onPressed: () {
                        setState(() => _gridView = false);
                        _persistPreferences();
                      },
                      icon: const Icon(Icons.view_list_rounded),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String value, String label) {
    final active = _status == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: active,
        selectedColor: NotebookTheme.accentSoft,
        labelStyle: TextStyle(
          color: active ? NotebookTheme.accent : NotebookTheme.lightMuted,
          fontWeight: FontWeight.w700,
        ),
        onSelected: (_) {
          setState(() {
            _status = value;
            _selectedIds.clear();
            _selectionMode = false;
          });
          _load(resetVisible: true);
        },
      ),
    );
  }

  Widget _buildGrid() {
    final pinned = _visibleNotebooks
        .where((item) => item.isPinned)
        .toList(growable: false);
    final regular = _visibleNotebooks
        .where((item) => !item.isPinned)
        .toList(growable: false);
    return SliverMainAxisGroup(
      slivers: [
        if (pinned.isNotEmpty) _groupLabel('置顶笔记本', pinned.length),
        if (pinned.isNotEmpty) _gridSliver(pinned),
        if (pinned.isNotEmpty && regular.isNotEmpty)
          _groupLabel('全部笔记本', regular.length),
        if (regular.isNotEmpty) _gridSliver(regular),
        _contentBottomSpace(),
      ],
    );
  }

  Widget _buildList() {
    final pinned = _visibleNotebooks
        .where((item) => item.isPinned)
        .toList(growable: false);
    final regular = _visibleNotebooks
        .where((item) => !item.isPinned)
        .toList(growable: false);
    return SliverMainAxisGroup(
      slivers: [
        if (pinned.isNotEmpty) _groupLabel('置顶笔记本', pinned.length),
        if (pinned.isNotEmpty) _listSliver(pinned),
        if (pinned.isNotEmpty && regular.isNotEmpty)
          _groupLabel('全部笔记本', regular.length),
        if (regular.isNotEmpty) _listSliver(regular),
        _contentBottomSpace(),
      ],
    );
  }

  Widget _groupLabel(String label, int count) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
        child: Text(
          '$label · $count',
          style: const TextStyle(
            color: NotebookTheme.lightMuted,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _gridSliver(List<Notebook> notebooks) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 20,
          crossAxisSpacing: 16,
          childAspectRatio: 0.78,
        ),
        itemCount: notebooks.length,
        itemBuilder: (_, index) => _notebookGridCard(notebooks[index]),
      ),
    );
  }

  Widget _listSliver(List<Notebook> notebooks) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 18),
      sliver: SliverList.separated(
        itemCount: notebooks.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, index) {
          final notebook = notebooks[index];
          return _NotebookListCard(
            notebook: notebook,
            selected: _selectedIds.contains(notebook.id),
            selectionMode: _selectionMode,
            onTap: () => _openNotebook(notebook),
            onLongPress: () => _showNotebookMenu(notebook),
            onMore: () => _showNotebookMenu(notebook),
          );
        },
      ),
    );
  }

  Widget _notebookGridCard(Notebook notebook) {
    return _NotebookGridCard(
      notebook: notebook,
      selected: _selectedIds.contains(notebook.id),
      selectionMode: _selectionMode,
      onTap: () => _openNotebook(notebook),
      onLongPress: () => _showNotebookMenu(notebook),
      onMore: () => _showNotebookMenu(notebook),
    );
  }

  Widget _contentBottomSpace() {
    return SliverToBoxAdapter(
      child: SizedBox(
        height:
            MediaQuery.paddingOf(context).bottom + (_selectionMode ? 118 : 76),
      ),
    );
  }

  Widget _buildBatchBar() {
    final selected = _selectedNotebooks;
    final ids = selected.map((item) => item.id).nonNulls.toList();
    final allPinned =
        selected.isNotEmpty && selected.every((item) => item.isPinned);
    final allOnHome =
        selected.isNotEmpty && selected.every((item) => item.showsOnHome);
    final buttons = switch (_status) {
      'deleted' => <Widget>[
        _BatchButton(
          icon: Icons.restore_outlined,
          label: '恢复',
          onTap: _batchRestore,
        ),
        _BatchButton(
          icon: Icons.delete_forever_outlined,
          label: '永久删除',
          danger: true,
          onTap: _batchPermanentDelete,
        ),
      ],
      'archived' => <Widget>[
        _BatchButton(
          icon: Icons.unarchive_outlined,
          label: '恢复',
          onTap: () => _runTransactionalBatch(
            () => _db.setNotebooksArchived(ids, false),
          ),
        ),
        _BatchButton(
          icon: Icons.delete_outline,
          label: '删除',
          danger: true,
          onTap: _batchDelete,
        ),
      ],
      _ => <Widget>[
        _BatchButton(
          icon: allPinned ? Icons.push_pin : Icons.push_pin_outlined,
          label: allPinned ? '取消置顶' : '置顶',
          onTap: () => _runTransactionalBatch(
            () => _db.setNotebooksPinned(ids, !allPinned),
          ),
        ),
        _BatchButton(
          icon: allOnHome ? Icons.home : Icons.home_outlined,
          label: allOnHome ? '移出首页' : '首页',
          onTap: () => _runTransactionalBatch(
            () => _db.setNotebooksHome(ids, !allOnHome),
          ),
        ),
        _BatchButton(
          icon: Icons.archive_outlined,
          label: '归档',
          onTap: () =>
              _runTransactionalBatch(() => _db.setNotebooksArchived(ids, true)),
        ),
        _BatchButton(
          icon: Icons.delete_outline,
          label: '删除',
          danger: true,
          onTap: _batchDelete,
        ),
      ],
    };
    return Positioned(
      left: 12,
      right: 12,
      bottom: MediaQuery.paddingOf(context).bottom + 10,
      child: Material(
        color: const Color(0xFF26241F),
        borderRadius: BorderRadius.circular(26),
        elevation: 12,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: buttons,
            ),
          ),
        ),
      ),
    );
  }
}

class _NotebookGridCard extends StatelessWidget {
  const _NotebookGridCard({
    required this.notebook,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onMore,
  });

  final Notebook notebook;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${notebook.name}，${notebook.noteCount} 条笔记',
      child: PrototypePressable(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: NotebookCover(
                      notebook: notebook,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x22000000),
                          blurRadius: 14,
                          offset: Offset(0, 8),
                        ),
                      ],
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            _shortName(notebook.name, 4),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 25,
                              fontWeight: FontWeight.w900,
                              height: 1.1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (notebook.isPinned)
                    const Positioned(
                      left: 10,
                      top: 10,
                      child: Icon(Icons.push_pin, color: Colors.white),
                    ),
                  if (selectionMode)
                    Positioned(
                      right: 10,
                      top: 10,
                      child: _SelectionMark(selected: selected),
                    )
                  else
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        tooltip: '管理 ${notebook.name}',
                        onPressed: onMore,
                        color: Colors.white,
                        icon: Icon(
                          PhosphorIcons.dotsThree(PhosphorIconsStyle.bold),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 9),
            Text(
              notebook.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: NotebookTheme.lightInk,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${notebook.category} · ${notebook.noteCount} 条笔记',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: NotebookTheme.lightMuted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotebookListCard extends StatelessWidget {
  const _NotebookListCard({
    required this.notebook,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onMore,
  });

  final Notebook notebook;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NotebookTheme.lightSurface,
      borderRadius: BorderRadius.circular(14),
      child: PrototypePressable(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                height: 64,
                child: NotebookCover(
                  notebook: notebook,
                  borderRadius: BorderRadius.circular(8),
                  child: Center(
                    child: Text(
                      _shortName(notebook.name, 2),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            notebook.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: NotebookTheme.lightInk,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (notebook.isPinned)
                          const Icon(
                            Icons.push_pin,
                            size: 16,
                            color: NotebookTheme.accent,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      notebook.description.isEmpty
                          ? '还没有添加描述'
                          : notebook.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: NotebookTheme.lightMuted),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${notebook.category} · ${_formatDate(notebook.updatedAt)} · ${notebook.noteCount} 条笔记',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: NotebookTheme.lightMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              selectionMode
                  ? _SelectionMark(selected: selected)
                  : IconButton(
                      tooltip: '管理',
                      onPressed: onMore,
                      icon: const Icon(Icons.more_vert),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: selected ? NotebookTheme.accent : Colors.white,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? NotebookTheme.accent : NotebookTheme.lightDivider,
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, color: Colors.white, size: 18)
          : null,
    );
  }
}

class _SelectPill extends StatelessWidget {
  const _SelectPill({
    required this.value,
    required this.items,
    required this.labelFor,
    required this.onChanged,
  });

  final String value;
  final List<String> items;
  final String Function(String) labelFor;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: NotebookTheme.lightSurface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: NotebookTheme.lightDivider),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: items.contains(value) ? value : items.first,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          items: items
              .map(
                (item) => DropdownMenuItem(
                  value: item,
                  child: Text(
                    labelFor(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.title,
    this.subtitle,
    required this.onClose,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: NotebookTheme.lightMuted),
                ),
              ],
            ],
          ),
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: onClose,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 52,
      leading: Icon(icon, color: danger ? NotebookTheme.danger : null),
      title: Text(
        label,
        style: TextStyle(color: danger ? NotebookTheme.danger : null),
      ),
      onTap: onTap,
    );
  }
}

class _BatchButton extends StatelessWidget {
  const _BatchButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: danger ? const Color(0xFFFF9B91) : Colors.white,
        minimumSize: const Size(72, 48),
      ),
    );
  }
}

class _ShelfEmpty extends StatelessWidget {
  const _ShelfEmpty({
    required this.status,
    required this.searching,
    required this.onCreate,
  });

  final String status;
  final bool searching;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final title = searching
        ? '没有找到笔记本'
        : switch (status) {
            'archived' => '还没有归档笔记本',
            'deleted' => '最近没有删除内容',
            'home' => '首页还没有笔记本',
            _ => '还没有笔记本',
          };
    final description = searching
        ? '换个关键词或筛选条件试试'
        : switch (status) {
            'archived' => '归档的笔记本会安全保存在这里',
            'deleted' => '删除的笔记本会在这里等待恢复',
            'home' => '把常用笔记本加入首页，打开更快',
            _ => '创建第一本笔记本，开始收纳你的想法',
          };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              searching ? Icons.search : Icons.menu_book_outlined,
              color: NotebookTheme.lightMuted,
              size: 46,
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: NotebookTheme.lightInk,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(color: NotebookTheme.lightMuted),
            ),
            if (!searching && status == 'active') ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onCreate,
                icon: const Icon(Icons.add),
                label: const Text('新建笔记本'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(160, 48),
                  backgroundColor: NotebookTheme.accent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _shortName(String value, int maxLength) {
  final chars = value.trim().characters.toList();
  if (chars.isEmpty) return '笔记';
  return chars.take(maxLength).join();
}

String _formatDate(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return value;
  final now = DateTime.now();
  if (date.year == now.year && date.month == now.month && date.day == now.day) {
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
  return '${date.month}/${date.day}';
}
