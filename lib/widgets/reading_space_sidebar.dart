import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../features/ai_study_annotation/data/ai_conversation_history.dart';
import '../models/book_library_item.dart';
import '../models/book_recognition.dart';
import '../services/book_library_service.dart';
import 'app_toast.dart';

enum _ReadingSidebarBranch { toc, conversations }

enum _ConversationAction {
  rename,
  select,
  delete,
  associate,
  changeBook,
  detach,
}

enum _SidebarSelectionKind { conversations, books }

enum _ReadingBookAction { pin, select, remove }

/// 阅读空间专用侧栏。
///
/// 侧栏只在阅读空间模式下创建；学习空间入口继续由首页保持空回调。
class ReadingSpaceSidebar extends StatefulWidget {
  const ReadingSpaceSidebar({
    super.key,
    required this.onNewConversation,
    required this.onOpenBook,
    required this.onOpenChapter,
    required this.onOpenConversation,
    required this.onOpenLibrary,
    required this.onOpenExtensionMarket,
    this.onConversationChanged,
    this.onBeforeConversationDeleted,
    this.onConversationDeleted,
    this.bookLibraryService,
    this.historyService,
  });

  final VoidCallback onNewConversation;
  final ValueChanged<BookLibraryItem> onOpenBook;
  final void Function(BookLibraryItem item, BookTocEntry entry) onOpenChapter;
  final ValueChanged<AiConversationRecord> onOpenConversation;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenExtensionMarket;
  final ValueChanged<AiConversationRecord>? onConversationChanged;
  final ValueChanged<AiConversationRecord>? onBeforeConversationDeleted;
  final ValueChanged<AiConversationRecord>? onConversationDeleted;
  final BookLibraryService? bookLibraryService;
  final AiConversationHistoryService? historyService;

  @override
  State<ReadingSpaceSidebar> createState() => _ReadingSpaceSidebarState();
}

class _ReadingSpaceSidebarState extends State<ReadingSpaceSidebar> {
  static const _ink = Color(0xFF252932);
  static const _mutedInk = Color(0xFF737A84);
  static const _line = Color(0xFFE9EBEE);
  static const _selected = Color(0xFFF1F3F5);
  static final _dialogShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(18),
    side: const BorderSide(color: Color(0xFFE6E8EB)),
  );

  late final BookLibraryService _library =
      widget.bookLibraryService ?? BookLibraryService();
  late final AiConversationHistoryService _history =
      widget.historyService ?? AiConversationHistoryService.instance;

  List<BookLibraryItem> _books = const [];
  Map<int, List<AiConversationRecord>> _bookConversations = const {};
  List<AiConversationRecord> _independentConversations = const [];
  bool _selectionMode = false;
  _SidebarSelectionKind _selectionKind = _SidebarSelectionKind.conversations;
  int? _selectionBookId;
  String _selectionTitle = '';
  final Set<String> _selectedConversationIds = {};
  final Set<int> _selectedBookIds = {};
  final GlobalKey _sidebarKey = GlobalKey();
  int? _expandedBookId;
  _ReadingSidebarBranch? _expandedBranch;
  String? _infoTitle;
  bool _loading = true;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool showLoading = true}) async {
    final generation = ++_loadGeneration;
    if (mounted && showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait<Object>([
        _library.listBooks(),
        _history.list(allBooks: true),
      ]);
      if (!mounted || generation != _loadGeneration) return;
      final allBooks = results[0] as List<BookLibraryItem>;
      final books = allBooks
          .where((item) => item.isInReadingSpace)
          .toList(growable: false);
      final records = results[1] as List<AiConversationRecord>;
      final byId = <int, List<AiConversationRecord>>{};
      final byTitle = <String, int>{
        for (final item in allBooks)
          if (item.book.id != null && item.book.title.trim().isNotEmpty)
            item.book.title.trim(): item.book.id!,
      };
      final independent = <AiConversationRecord>[];
      for (final record in records) {
        final id = record.bookId ?? byTitle[record.bookName.trim()];
        if (id == null || !allBooks.any((item) => item.book.id == id)) {
          independent.add(record);
          continue;
        }
        (byId[id] ??= <AiConversationRecord>[]).add(record);
      }
      for (final conversations in byId.values) {
        _sortConversations(conversations);
      }
      _sortConversations(independent);
      setState(() {
        _books = books;
        _bookConversations = byId;
        _independentConversations = independent;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = '侧栏内容暂时无法加载：$error';
      });
    }
  }

  static void _sortConversations(List<AiConversationRecord> records) {
    records.sort((a, b) {
      final updated = b.updatedAt.compareTo(a.updatedAt);
      if (updated != 0) return updated;
      final created = b.createdAt.compareTo(a.createdAt);
      return created != 0 ? created : a.id.compareTo(b.id);
    });
  }

  void _showInfo(String title) => setState(() => _infoTitle = title);

  void _toggleBook(BookLibraryItem item) {
    final id = item.book.id;
    if (id == null) return;
    setState(() {
      if (_expandedBookId == id) {
        _expandedBookId = null;
        _expandedBranch = null;
      } else {
        _expandedBookId = id;
        _expandedBranch = null;
      }
    });
  }

  void _toggleBranch(BookLibraryItem item, _ReadingSidebarBranch branch) {
    final id = item.book.id;
    if (id == null) return;
    setState(() {
      _expandedBookId = id;
      _expandedBranch = _expandedBranch == branch ? null : branch;
    });
  }

  RelativeRect _menuPosition(
    BuildContext anchorContext, {
    required double menuHeight,
  }) {
    final anchor = anchorContext.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(anchorContext).context.findRenderObject()! as RenderBox;
    final sidebar = _sidebarKey.currentContext!.findRenderObject()! as RenderBox;
    final anchorRect = Rect.fromPoints(
      anchor.localToGlobal(Offset.zero, ancestor: overlay),
      anchor.localToGlobal(
        anchor.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    );
    final sidebarRect = Rect.fromPoints(
      sidebar.localToGlobal(Offset.zero, ancestor: overlay),
      sidebar.localToGlobal(
        sidebar.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    );
    const menuWidth = 210.0;
    final left = anchorRect.left
        .clamp(sidebarRect.left + 8, sidebarRect.right - menuWidth - 8)
        .toDouble();
    final safeTop = sidebarRect.top + 8;
    final safeBottom = sidebarRect.bottom - 8;
    final below = anchorRect.bottom + 4;
    final top = below + menuHeight <= safeBottom
        ? below
        : (anchorRect.top - menuHeight - 4).clamp(
            safeTop,
            safeBottom - menuHeight,
          ).toDouble();
    return RelativeRect.fromRect(
      Rect.fromLTWH(left, top, 0, 0),
      Offset.zero & overlay.size,
    );
  }

  Future<void> _showReadingBookMenu(BuildContext anchorContext) async {
    final action = await showMenu<_ReadingBookAction>(
      context: anchorContext,
      position: _menuPosition(anchorContext, menuHeight: 156),
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      constraints: const BoxConstraints(maxWidth: 210),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: const BorderSide(color: Color(0xFFE7E9EC)),
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      items: [
        PopupMenuItem<_ReadingBookAction>(
          value: _ReadingBookAction.pin,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _MenuLabel(
            icon: PhosphorIconsRegular.pushPin,
            label: '置顶 / 取消置顶',
            showDivider: true,
          ),
        ),
        PopupMenuItem<_ReadingBookAction>(
          value: _ReadingBookAction.select,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _MenuLabel(
            icon: PhosphorIconsRegular.checkCircle,
            label: '多选',
            showDivider: true,
          ),
        ),
        PopupMenuItem<_ReadingBookAction>(
          value: _ReadingBookAction.remove,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _MenuLabel(
            icon: PhosphorIconsRegular.trash,
            label: '移出在读书籍',
            color: const Color(0xFFB94A45),
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _ReadingBookAction.pin:
        _enterBookSelection();
        break;
      case _ReadingBookAction.select:
        _enterBookSelection();
        break;
      case _ReadingBookAction.remove:
        _enterBookSelection();
        break;
      case null:
        break;
    }
  }

  Future<BookLibraryItem?> _chooseBook({int? excludingBookId}) async {
    final candidates = _books
        .where((item) => item.book.id != excludingBookId)
        .toList(growable: false);
    if (candidates.isEmpty) {
      _showActionError(excludingBookId == null ? '请先在书库中添加书籍' : '没有可更换的书籍');
      return null;
    }
    return showModalBottomSheet<BookLibraryItem>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                '关联到书籍',
                style: TextStyle(
                  color: _ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final item in candidates)
              ListTile(
                minTileHeight: 52,
                leading: _BookCover(book: item.book, size: const Size(30, 42)),
                title: Text(
                  item.book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(sheetContext, item),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _associateConversation(
    AiConversationRecord record, {
    int? currentBookId,
  }) async {
    final selected = await _chooseBook(excludingBookId: currentBookId);
    if (!mounted || selected?.book.id == null) return;
    try {
      await _history.attachToBook(
        record.id,
        bookId: selected!.book.id!,
        bookName: selected.book.title,
      );
      widget.onConversationChanged?.call(
        await _history.get(record.id) ?? record,
      );
      await _load();
    } catch (error) {
      _showActionError('关联书籍失败：$error');
    }
  }

  Future<void> _detachConversation(AiConversationRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: _dialogShape,
        title: const Text('解除书籍关联？'),
        content: const Text('会话会移到“独立会话”，消息内容会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _ink,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('解除关联'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await _history.detachFromBook(record.id);
      widget.onConversationChanged?.call(
        await _history.get(record.id) ?? record,
      );
      await _load();
    } catch (error) {
      _showActionError('解除关联失败：$error');
    }
  }

  void _showActionError(String message) {
    if (!mounted) return;
    AppToast.show(context, message);
  }

  void _enterSelection(
    AiConversationRecord record, {
    required int? bookId,
    required String groupTitle,
  }) {
    setState(() {
      _selectionMode = true;
      _selectionKind = _SidebarSelectionKind.conversations;
      _selectionBookId = bookId;
      _selectionTitle = groupTitle;
      _selectedBookIds.clear();
      _selectedConversationIds
        ..clear()
        ..add(record.id);
    });
  }

  void _enterBookSelection() {
    setState(() {
      _selectionMode = true;
      _selectionKind = _SidebarSelectionKind.books;
      _selectionBookId = null;
      _selectionTitle = '在读书籍';
      _selectedConversationIds.clear();
      _selectedBookIds.clear();
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectionKind = _SidebarSelectionKind.conversations;
      _selectionBookId = null;
      _selectionTitle = '';
      _selectedConversationIds.clear();
      _selectedBookIds.clear();
    });
  }

  List<AiConversationRecord> get _selectionRecords => _selectionBookId == null
      ? _independentConversations
      : _bookConversations[_selectionBookId] ?? const [];

  void _toggleSelection(AiConversationRecord record) {
    setState(() {
      if (!_selectedConversationIds.add(record.id)) {
        _selectedConversationIds.remove(record.id);
      }
    });
  }

  void _toggleBookSelection(BookLibraryItem item) {
    final id = item.book.id;
    if (id == null) return;
    setState(() {
      if (!_selectedBookIds.add(id)) _selectedBookIds.remove(id);
    });
  }

  Future<void> _applyBookPinSelection() async {
    final selected = _books
        .where((item) => _selectedBookIds.contains(item.book.id))
        .toList(growable: false);
    if (selected.isEmpty) return;
    final shouldPin = selected.any((item) => !item.isPinned);
    try {
      await _library.setBooksPinned(
        selected.map((item) => item.book.id).whereType<int>(),
        shouldPin,
      );
      if (!mounted) return;
      _exitSelection();
      await _load(showLoading: false);
    } catch (error) {
      _showActionError('更新置顶状态失败：$error');
    }
  }

  Future<void> _removeSelectedBooksFromReadingSpace() async {
    final ids = _selectedBookIds.toList(growable: false);
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: _dialogShape,
        title: Text('移出 ${ids.length} 本书？'),
        content: const Text('只会从“在读书籍”移除，书库、笔记和书籍资料都会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB94A45),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await _library.setBooksInReadingSpace(ids, false);
      if (!mounted) return;
      _exitSelection();
      await _load(showLoading: false);
    } catch (error) {
      _showActionError('移出失败：$error');
    }
  }

  Set<int> get _selectableBookIds => _books
      .map((item) => item.book.id)
      .whereType<int>()
      .toSet();

  void _toggleAllBooks() {
    final ids = _selectableBookIds;
    final allSelected = ids.isNotEmpty && ids.every(_selectedBookIds.contains);
    setState(() {
      if (allSelected) {
        _selectedBookIds.clear();
      } else {
        _selectedBookIds
          ..clear()
          ..addAll(ids);
      }
    });
  }

  void _toggleSelectAll() {
    final records = _selectionRecords;
    final allSelected =
        records.isNotEmpty &&
        records.every((record) => _selectedConversationIds.contains(record.id));
    setState(() {
      if (allSelected) {
        _selectedConversationIds.clear();
      } else {
        _selectedConversationIds
          ..clear()
          ..addAll(records.map((record) => record.id));
      }
    });
  }

  Future<void> _showConversationMenu(
    BuildContext anchorContext,
    AiConversationRecord record, {
    required int? bookId,
    required String groupTitle,
  }) async {
    final action = await showMenu<_ConversationAction>(
      context: anchorContext,
      position: _menuPosition(
        anchorContext,
        menuHeight: bookId == null ? 204 : 252,
      ),
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      constraints: const BoxConstraints(maxWidth: 210),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: const BorderSide(color: Color(0xFFE7E9EC)),
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      items: [
        _menuItem(
          _ConversationAction.rename,
          PhosphorIconsRegular.pencilSimple,
          '重命名',
        ),
        _menuItem(
          _ConversationAction.select,
          PhosphorIconsRegular.checkCircle,
          '多选',
        ),
        if (bookId == null)
          _menuItem(
            _ConversationAction.associate,
            PhosphorIconsRegular.books,
            '关联书籍',
          )
        else ...[
          _menuItem(
            _ConversationAction.changeBook,
            PhosphorIconsRegular.arrowsLeftRight,
            '更换关联书籍',
          ),
          _menuItem(
            _ConversationAction.detach,
            PhosphorIconsRegular.linkBreak,
            '解除关联',
          ),
        ],
        _menuItem(
          _ConversationAction.delete,
          PhosphorIconsRegular.trash,
          '删除',
          destructive: true,
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _ConversationAction.rename:
        await _renameConversation(record);
        break;
      case _ConversationAction.select:
        _enterSelection(record, bookId: bookId, groupTitle: groupTitle);
        break;
      case _ConversationAction.delete:
        await _deleteConversations([record]);
        break;
      case _ConversationAction.associate:
        await _associateConversation(record);
        break;
      case _ConversationAction.changeBook:
        await _associateConversation(record, currentBookId: bookId);
        break;
      case _ConversationAction.detach:
        await _detachConversation(record);
        break;
      case null:
        break;
    }
  }

  PopupMenuItem<_ConversationAction> _menuItem(
    _ConversationAction action,
    IconData icon,
    String label, {
    bool destructive = false,
  }) => PopupMenuItem(
    value: action,
    height: 48,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: _MenuLabel(
      icon: icon,
      label: label,
      color: destructive ? const Color(0xFFB94A45) : _ink,
      showDivider: !destructive,
    ),
  );

  Future<void> _renameConversation(AiConversationRecord record) async {
    var dialogTitle = record.displayTitle;
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: _dialogShape,
        title: const Text('重命名会话'),
        content: TextFormField(
          initialValue: record.displayTitle,
          autofocus: true,
          maxLength: 60,
          decoration: InputDecoration(
            labelText: '会话名称',
            labelStyle: const TextStyle(color: _mutedInk),
            counterStyle: const TextStyle(color: _mutedInk),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: _line),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: _ink, width: 1.5),
            ),
          ),
          onChanged: (value) => dialogTitle = value,
          onFieldSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _ink,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, dialogTitle),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    final normalized = title?.trim() ?? '';
    if (!mounted || normalized.isEmpty) return;
    try {
      await _history.rename(record.id, normalized);
      widget.onConversationChanged?.call(
        await _history.get(record.id) ?? record,
      );
      await _load();
    } catch (error) {
      _showActionError('重命名失败：$error');
    }
  }

  Future<void> _deleteConversations(
    Iterable<AiConversationRecord> conversations,
  ) async {
    final selected = conversations.toList(growable: false);
    if (selected.isEmpty) return;
    final ids = selected.map((record) => record.id).toSet();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: _dialogShape,
        title: Text('删除 ${ids.length} 个会话？'),
        content: const Text('删除后无法恢复。书籍和笔记不会受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB94A45),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    for (final record in selected) {
      widget.onBeforeConversationDeleted?.call(record);
    }
    try {
      await _history.delete(ids);
      if (!mounted) return;
      for (final record in selected) {
        widget.onConversationDeleted?.call(record);
      }
      if (_selectionMode) _exitSelection();
      await _load();
    } catch (error) {
      _showActionError('删除失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final infoTitle = _infoTitle;
    final child = infoTitle != null
        ? _buildInfoView(infoTitle)
        : Stack(
            children: [
              Column(
                children: [
                  _buildHeader(),
                  Expanded(child: _buildBody()),
                ],
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 10,
                child: _buildAccountCapsule(),
              ),
            ],
          );
    return PopScope<void>(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Material(
        key: _sidebarKey,
        color: Colors.white,
        child: SafeArea(right: false, child: child),
      ),
    );
  }

  Widget _buildSelectionHeader() {
    final allSelected = _selectionKind == _SidebarSelectionKind.books
        ? _selectableBookIds.isNotEmpty &&
              _selectableBookIds.every(_selectedBookIds.contains)
        : _selectionRecords.isNotEmpty &&
              _selectionRecords.every(
                (record) => _selectedConversationIds.contains(record.id),
              );
    final selectedCount = _selectionKind == _SidebarSelectionKind.books
        ? _selectedBookIds.length
        : _selectedConversationIds.length;
    return SizedBox(
      height: 62,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: _selectionKind == _SidebarSelectionKind.books
                  ? _toggleAllBooks
                  : _toggleSelectAll,
              icon: Icon(
                allSelected
                    ? PhosphorIconsFill.checkSquare
                    : PhosphorIconsRegular.square,
                size: 19,
              ),
              label: const Text('全选'),
              style: TextButton.styleFrom(foregroundColor: _ink),
            ),
            Expanded(
              child: Center(
                child: Text(
                  '${_selectionTitle} · 已选 ($selectedCount)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: _exitSelection,
              style: TextButton.styleFrom(foregroundColor: _ink),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 78,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 10, 6),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '阅读空间',
                style: TextStyle(
                  color: _ink,
                  fontFamily: 'NotoSansCJKSC',
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .2,
                ),
              ),
            ),
            Semantics(
              button: true,
              label: '搜索阅读空间',
              child: InkResponse(
                onTap: () => _showInfo('搜索'),
                radius: 24,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: SvgPicture.asset(
                      'assets/images/reading_sidebar_search.svg',
                      width: 30,
                      height: 30,
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

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(11, 0, 11, 120),
      children: [
        _buildQuickActions(),
        const Divider(height: 1, color: _line),
        if (_loading)
          _buildLoadingSkeleton()
        else if (_error != null)
          _buildErrorState()
        else ...[
          if (_books.any((item) => item.isPinned)) _buildPinnedSection(),
          _buildReadingSection(),
          if (_independentConversations.isNotEmpty) _buildIndependentSection(),
        ],
      ],
    );
  }

  Widget _buildQuickActions() {
    return Column(
      children: [
        _QuickAction(
          label: '新建会话',
          asset: 'assets/images/home_new_conversation_icon.svg',
          onTap: widget.onNewConversation,
        ),
        _QuickAction(
          label: '技能·插件',
          asset: 'assets/images/reading_sidebar_wrench.svg',
          onTap: widget.onOpenExtensionMarket,
        ),
        _QuickAction(
          label: '书库',
          asset: 'assets/images/reading_sidebar_library.svg',
          onTap: widget.onOpenLibrary,
        ),
        _QuickAction(
          label: '社区',
          asset: 'assets/images/reading_sidebar_community.svg',
          onTap: () => _showInfo('社区'),
        ),
        const SizedBox(height: 5),
      ],
    );
  }

  Widget _buildPinnedSection() {
    final pinned = _books
        .where((item) => item.isPinned)
        .toList(growable: false);
    return _buildSection(
      title: '置顶',
      children: [for (final item in pinned) _buildBookGroup(item)],
    );
  }

  Widget _buildReadingSection() {
    final reading = _books
        .where((item) => !item.isPinned)
        .toList(growable: false);
    return _buildSection(
      title: '在读书籍',
      trailing: _selectionMode
          ? null
          : Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(
            builder: (context) => _SmallAction(
              label: '更多在读书籍操作',
              icon: PhosphorIconsBold.dotsThree,
              onTap: () => _showReadingBookMenu(context),
            ),
          ),
          _SmallAction(
            label: '从书库添加',
            icon: PhosphorIconsRegular.plus,
            onTap: widget.onOpenLibrary,
          ),
        ],
      ),
      children: [
        if (_selectionMode && _selectionKind == _SidebarSelectionKind.books)
          _buildSelectionHeader(),
        if (reading.isEmpty)
          _EmptyRow(
            text: _books.isEmpty ? '暂无在读书籍' : '所有在读书籍已置顶',
            icon: PhosphorIconsRegular.bookOpen,
          )
        else
          for (final item in reading) _buildBookGroup(item),
        if (_selectionMode && _selectionKind == _SidebarSelectionKind.books)
          _buildBookSelectionActions(),
      ],
    );
  }

  Widget _buildIndependentSection() {
    return _buildSection(
      title: '独立会话',
      dividerBefore: true,
      children: [
        if (_isSelectingConversationGroup(null)) _buildSelectionHeader(),
        ..._buildDatedConversationRows(
          _independentConversations,
          groupTitle: '独立会话',
        ),
        if (_isSelectingConversationGroup(null))
          _buildConversationSelectionActions(_selectionRecords),
      ],
    );
  }

  bool _isSelectingConversationGroup(int? bookId) =>
      _selectionMode &&
      _selectionKind == _SidebarSelectionKind.conversations &&
      _selectionBookId == bookId;

  Widget _buildConversationSelectionActions(
    List<AiConversationRecord> records,
  ) {
    final selected = records
        .where((record) => _selectedConversationIds.contains(record.id))
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: SizedBox(
        height: 50,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: _line)),
          ),
          child: TextButton.icon(
            onPressed: selected.isEmpty
                ? null
                : () => _deleteConversations(selected),
            icon: Icon(
              PhosphorIconsRegular.trash,
              size: 19,
            ),
            label: const Text('删除'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFB94A45),
              disabledForegroundColor: const Color(0xFFB7BBC1),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBookSelectionActions() {
    final selected = _books
        .where((item) => _selectedBookIds.contains(item.book.id))
        .toList(growable: false);
    final shouldPin = selected.isEmpty || selected.any((item) => !item.isPinned);
    final enabled = selected.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: SizedBox(
        height: 52,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: _line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: enabled ? _applyBookPinSelection : null,
                  icon: Icon(
                    PhosphorIconsRegular.pushPin,
                    size: 19,
                  ),
                  label: Text(shouldPin ? '置顶' : '取消置顶'),
                  style: TextButton.styleFrom(
                    foregroundColor: _ink,
                    disabledForegroundColor: const Color(0xFFB7BBC1),
                  ),
                ),
              ),
              const SizedBox(
                height: 24,
                child: VerticalDivider(width: 1, color: _line),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: enabled ? _removeSelectedBooksFromReadingSpace : null,
                  icon: Icon(
                    PhosphorIconsRegular.trash,
                    size: 19,
                  ),
                  label: const Text('移出在读'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFB94A45),
                    disabledForegroundColor: const Color(0xFFB7BBC1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<Widget> children,
    Widget? trailing,
    bool dividerBefore = false,
  }) {
    return Container(
      margin: EdgeInsets.only(top: dividerBefore ? 13 : 0),
      padding: EdgeInsets.only(top: dividerBefore ? 13 : 13, bottom: 5),
      decoration: BoxDecoration(
        border: dividerBefore
            ? const Border(top: BorderSide(color: _line))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 9),
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: _mutedInk,
                        fontFamily: 'NotoSansCJKSC',
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _buildBookGroup(BookLibraryItem item) {
    final bookId = item.book.id;
    final expanded = bookId != null && _expandedBookId == bookId;
    final branch = expanded ? _expandedBranch : null;
    final selecting = _selectionMode &&
        _selectionKind == _SidebarSelectionKind.books;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BookRow(
            item: item,
            expanded: expanded,
            selectionMode: selecting,
            selected: bookId != null && _selectedBookIds.contains(bookId),
            onSelect: () => _toggleBookSelection(item),
            onOpen: () => widget.onOpenBook(item),
            onToggle: () => _toggleBook(item),
          ),
          if (expanded && !selecting)
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: Column(
                children: [
                  _BranchRow(
                    label: '目录',
                    icon: PhosphorIconsRegular.listBullets,
                    expanded: branch == _ReadingSidebarBranch.toc,
                    onTap: () => _toggleBranch(item, _ReadingSidebarBranch.toc),
                  ),
                  if (branch == _ReadingSidebarBranch.toc)
                    _buildTocChildren(item),
                  _BranchRow(
                    label: '对话记录',
                    icon: PhosphorIconsRegular.chatCircle,
                    expanded: branch == _ReadingSidebarBranch.conversations,
                    onTap: () => _toggleBranch(
                      item,
                      _ReadingSidebarBranch.conversations,
                    ),
                  ),
                  if (branch == _ReadingSidebarBranch.conversations &&
                      _isSelectingConversationGroup(item.book.id))
                    _buildSelectionHeader(),
                  if (branch == _ReadingSidebarBranch.conversations)
                    _buildConversationChildren(item),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTocChildren(BookLibraryItem item) {
    final entries = item.book.tableOfContents
        .where((entry) => entry.title.trim().isNotEmpty)
        .toList(growable: false);
    return _ChildList(
      children: [
        const _SourceRow(label: '主资料'),
        if (entries.isEmpty)
          const _ChildTextRow(text: '暂无目录', selected: false)
        else
          for (final entry in entries)
            _ChildTextRow(
              text: entry.title,
              indent: entry.level > 1 ? (entry.level - 1) * 10 : 0,
              selected: false,
              onTap: () => widget.onOpenChapter(item, entry),
            ),
      ],
    );
  }

  Widget _buildConversationChildren(BookLibraryItem item) {
    final conversations = _bookConversations[item.book.id] ?? const [];
    return _ChildList(
      children: [
        if (conversations.isEmpty)
          const _ChildTextRow(text: '暂无对话记录', selected: false)
        else
          ..._buildDatedConversationRows(
            conversations,
            bookId: item.book.id,
            groupTitle: item.book.title,
            compact: true,
          ),
        if (_isSelectingConversationGroup(item.book.id))
          _buildConversationSelectionActions(_selectionRecords),
      ],
    );
  }

  List<Widget> _buildDatedConversationRows(
    List<AiConversationRecord> source, {
    int? bookId,
    required String groupTitle,
    bool compact = false,
  }) {
    final records = [...source];
    _sortConversations(records);
    final children = <Widget>[];
    String? previousDate;
    for (final record in records) {
      final date = _conversationDateLabel(record.updatedAt);
      if (date != previousDate) {
        previousDate = date;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 10, 8, 3),
            child: SizedBox(
              height: 22,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  date,
                  style: const TextStyle(
                    color: Color(0xFF969CA4),
                    fontFamily: 'NotoSansCJKSC',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        );
      }
      children.add(
        _buildConversationRow(
          record,
          bookId: bookId,
          groupTitle: groupTitle,
          compact: compact,
        ),
      );
    }
    return children;
  }

  String _conversationDateLabel(DateTime dateTime) {
    if (dateTime.millisecondsSinceEpoch == 0) return '日期未知';
    final date = dateTime.toLocal();
    return '${date.year}年${date.month}月${date.day}日';
  }

  Widget _buildConversationRow(
    AiConversationRecord record, {
    required int? bookId,
    required String groupTitle,
    bool compact = false,
  }) {
    final selecting = _isSelectingConversationGroup(bookId);
    final selected = _selectedConversationIds.contains(record.id);
    return Builder(
      builder: (anchorContext) => Semantics(
        button: true,
        selected: selecting ? selected : null,
        label: record.displayTitle,
        hint: selecting ? '点击切换选择状态' : '长按打开会话管理菜单',
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: selecting
              ? () => _toggleSelection(record)
              : _selectionMode
              ? null
              : () => widget.onOpenConversation(record),
          onLongPress: _selectionMode
              ? null
              : () => _showConversationMenu(
                  anchorContext,
                  record,
                  bookId: bookId,
                  groupTitle: groupTitle,
                ),
          child: SizedBox(
            height: 48,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selecting && selected ? _selected : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 10),
                child: Row(
                  children: [
                    if (selecting)
                      SizedBox(
                        width: 38,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _SidebarCheck(selected: selected),
                        ),
                      )
                    else if (bookId == null) ...[
                      Icon(
                        PhosphorIconsRegular.chatCircle,
                        size: 19,
                        color: _mutedInk,
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Text(
                        record.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _ink,
                          fontFamily: 'NotoSansCJKSC',
                          fontSize: selecting
                              ? 14
                              : compact
                              ? 13
                              : 15,
                          height: 1.35,
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

  Widget _buildLoadingSkeleton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 18, 9, 0),
      child: Column(
        children: [
          for (var index = 0; index < 4; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F1F2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      height: 15,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F1F2),
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _error!,
            style: const TextStyle(color: _mutedInk, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: _load,
            icon: Icon(
              PhosphorIconsRegular.arrowClockwise,
              size: 17,
            ),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoView(String title) {
    final description = switch (title) {
      '社区' => '社区入口已保留。社区动态、发帖、评论和互动功能将在后续版本开放。',
      '技能·插件' => '技能与插件入口已保留。安装、配置和权限管理将在后续版本开放。',
      '通知' => '通知功能正在筹备中，当前没有未读消息。',
      '设置' => '设置功能正在筹备中。',
      '搜索' => '搜索功能正在筹备中。',
      _ => '$title 功能正在筹备中。',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 62,
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _infoTitle = null),
              icon: Icon(
                PhosphorIconsRegular.arrowLeft,
                size: 19,
              ),
              label: const Text('返回'),
              style: TextButton.styleFrom(
                foregroundColor: _ink,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 30, 20, 0),
          child: Text(
            title,
            style: const TextStyle(
              color: _ink,
              fontFamily: 'NotoSansCJKSC',
              fontSize: 23,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text(
            description,
            style: const TextStyle(color: _mutedInk, fontSize: 15, height: 1.7),
          ),
        ),
      ],
    );
  }

  Widget _buildAccountCapsule() {
    return SizedBox(
      height: 70,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(26)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFFFFF), Color(0xFFFCFDFE), Color(0xFFF4F7FA)],
            stops: [0, 0.48, 1],
          ),
          border: Border.fromBorderSide(
            BorderSide(color: Color(0xFFE8EDF3), width: 0.7),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: '用户账号',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _showInfo('账号'),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: Color(0xFFDCE4EA),
                            shape: BoxShape.circle,
                          ),
                          child: const Text(
                            '用',
                            style: TextStyle(
                              color: Color(0xFF3E5363),
                              fontSize: 18,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            '用户名',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _ink,
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _SmallAction(
                label: '通知',
                icon: PhosphorIconsRegular.bell,
                onTap: () => _showInfo('通知'),
              ),
              _SmallAction(
                label: '设置',
                icon: PhosphorIconsRegular.gear,
                onTap: () => _showInfo('设置'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel({
    required this.icon,
    required this.label,
    this.color = const Color(0xFF252932),
    this.showDivider = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 164,
      height: 48,
      decoration: BoxDecoration(
        border: showDivider
            ? const Border(bottom: BorderSide(color: Color(0xFFE9EBEE)))
            : null,
      ),
      padding: EdgeInsets.only(bottom: showDivider ? 1 : 0),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontFamily: 'NotoSansCJKSC',
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.label,
    required this.asset,
    required this.onTap,
  });

  final String label;
  final String asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(
              children: [
                SizedBox(
                  width: 27,
                  height: 27,
                  child: SvgPicture.asset(asset, fit: BoxFit.contain),
                ),
                const SizedBox(width: 17),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Color(0xFF303238),
                      fontFamily: 'NotoSansCJKSC',
                      fontSize: 19,
                      height: 1.3,
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

class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            icon,
            size: 24,
            color: _ReadingSpaceSidebarState._mutedInk,
          ),
        ),
      ),
    );
  }
}

class _BookRow extends StatelessWidget {
  const _BookRow({
    required this.item,
    required this.expanded,
    required this.selectionMode,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    required this.onToggle,
  });

  final BookLibraryItem item;
  final bool expanded;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final title = item.book.title.trim().isEmpty ? '未命名书籍' : item.book.title;
    return SizedBox(
      height: 60,
      child: Row(
        children: [
          if (selectionMode)
            SizedBox(
              width: 38,
              child: Center(
                child: _SidebarCheck(selected: selected, onTap: onSelect),
              ),
            ),
          Expanded(
            child: Semantics(
              button: true,
              selected: selectionMode ? selected : null,
              label: title,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: selectionMode ? onSelect : onOpen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  child: Row(
                    children: [
                      _BookCover(book: item.book),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF303238),
                            fontFamily: 'NotoSansCJKSC',
                            fontSize: 15,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (!selectionMode)
            Semantics(
              button: true,
              expanded: expanded,
              label: expanded ? '折叠$title' : '展开$title',
              child: InkResponse(
                onTap: onToggle,
                radius: 22,
                child: SizedBox(
                  width: 36,
                  height: 48,
                  child: Icon(
                    expanded
                        ? PhosphorIconsRegular.caretDown
                        : PhosphorIconsRegular.caretRight,
                    size: 17,
                    color: const Color(0xFF737A84),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SidebarCheck extends StatelessWidget {
  const _SidebarCheck({required this.selected, this.onTap});

  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? _ReadingSpaceSidebarState._ink : Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: selected ? _ReadingSpaceSidebarState._ink : const Color(0xFFB8BDC4),
          width: 1.3,
        ),
      ),
      child: selected
          ? Icon(
              PhosphorIconsBold.check,
              size: 14,
              color: Colors.white,
            )
          : null,
    );
    if (onTap == null) return mark;
    return Semantics(
      button: true,
      checked: selected,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox(width: 44, height: 44, child: Center(child: mark)),
      ),
    );
  }
}

class _BranchRow extends StatelessWidget {
  const _BranchRow({
    required this.label,
    required this.icon,
    required this.expanded,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      expanded: expanded,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFF69717B)),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Color(0xFF555B65),
                      fontFamily: 'NotoSansCJKSC',
                      fontSize: 15,
                    ),
                  ),
                ),
                Icon(
                  expanded
                      ? PhosphorIconsRegular.caretDown
                      : PhosphorIconsRegular.caretRight,
                  size: 16,
                  color: const Color(0xFF737A84),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChildList extends StatelessWidget {
  const _ChildList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 23, bottom: 6),
      padding: const EdgeInsets.fromLTRB(16, 2, 0, 6),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: Color(0xFFE1E4E8))),
      ),
      child: Column(children: children),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF7A8089), fontSize: 12),
            ),
          ),
          Icon(
            PhosphorIconsRegular.caretDown,
            size: 13,
            color: const Color(0xFF858B94),
          ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }
}

class _ChildTextRow extends StatelessWidget {
  const _ChildTextRow({
    required this.text,
    this.indent = 0,
    required this.selected,
    this.onTap,
  });

  final String text;
  final double indent;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = SizedBox(
      height: 40,
      child: Padding(
        padding: EdgeInsets.only(left: indent, right: 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF30343B),
              fontFamily: 'NotoSansCJKSC',
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFEEF0F2) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: const Color(0xFF9AA0A8)),
            const SizedBox(width: 12),
            Text(
              text,
              style: const TextStyle(color: Color(0xFF7A8089), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookCover extends StatelessWidget {
  const _BookCover({required this.book, this.size = const Size(38, 52)});

  final BookRecord book;
  final Size size;

  @override
  Widget build(BuildContext context) {
    final path = book.coverPath.trim();
    final url = book.coverUrl.trim();
    final fallback = _fallback();
    final image = path.isNotEmpty
        ? Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback,
          )
        : url.isNotEmpty
        ? Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback,
          )
        : fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(width: size.width, height: size.height, child: image),
    );
  }

  Widget _fallback() {
    final title = book.title.trim();
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFE6E8EA), Color(0xFFD4D9DE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Text(
            title.isEmpty ? '书' : title.characters.first,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: const TextStyle(
              color: Color(0xFF48525D),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
