import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../config/notebook_theme.dart';
import '../models/chat_note_capture.dart';
import '../models/note.dart';
import '../models/notebook.dart';
import '../services/database_service.dart';
import '../utils/date_formatter.dart';
import 'notebook_cover.dart';

const _sheetInk = Color(0xFF20242A);
const _sheetMuted = Color(0xFF9296A0);
const _sheetDivider = Color(0xFFE9EBEF);
const _sheetChip = Color(0xFFE9ECF1);
const _sheetAccent = Color(0xFF4964B8);

class AddChatNoteSheet extends StatefulWidget {
  const AddChatNoteSheet({
    super.key,
    required this.notebooks,
    required this.defaultNotebook,
    required this.onSelect,
    this.bookId,
    this.bookName = '',
    this.initialNotebookId,
    this.captureMode = true,
    this.active = true,
    this.expanded = false,
    this.scrollController,
    this.reloadToken = 0,
    this.onToggleExpanded,
    this.onClose,
    this.onOpenTrash,
    this.onNoteActions,
    this.onHeaderDragStart,
    this.onHeaderDragUpdate,
    this.onHeaderDragEnd,
  });

  final List<Notebook> notebooks;
  final Notebook defaultNotebook;
  final Future<void> Function(ChatNoteCaptureSelection) onSelect;
  final int? bookId;
  final String bookName;
  final int? initialNotebookId;
  final bool captureMode;
  final bool active;
  final bool expanded;
  final ScrollController? scrollController;
  final int reloadToken;
  final VoidCallback? onToggleExpanded;
  final VoidCallback? onClose;
  final Future<void> Function()? onOpenTrash;
  final Future<void> Function(Note)? onNoteActions;
  final GestureDragStartCallback? onHeaderDragStart;
  final GestureDragUpdateCallback? onHeaderDragUpdate;
  final GestureDragEndCallback? onHeaderDragEnd;

  @override
  State<AddChatNoteSheet> createState() => _AddChatNoteSheetState();
}

class _AddChatNoteSheetState extends State<AddChatNoteSheet> {
  final _db = DatabaseService();
  final _newNotebookController = TextEditingController();
  final _searchController = TextEditingController();
  final _newNotebookFocusNode = FocusNode();
  final _ownedListScrollController = ScrollController();

  ScrollController get _listScrollController =>
      widget.scrollController ?? _ownedListScrollController;

  late List<Notebook> _notebooks = List.of(widget.notebooks);
  List<Note> _notes = const [];
  int? _filteredNotebookId;
  int _coverIndex = 0;
  int _loadRevision = 0;
  bool _loading = true;
  bool _failed = false;
  bool _showNewNotebook = false;
  bool _savingNotebook = false;
  bool _openingEditor = false;
  bool _searchOpen = false;
  String? _newNotebookError;
  Notebook? _editingNotebook;
  bool _associateNewNotebook = true;
  bool _filterAutomaticNotebook = false;

  @override
  void initState() {
    super.initState();
    _filteredNotebookId = widget.initialNotebookId;
    if (_filteredNotebookId == null && widget.bookId != null) {
      final linked = _notebooks.where((item) => item.bookId == widget.bookId);
      if (linked.isNotEmpty) {
        _filteredNotebookId = linked.first.id;
        _filterAutomaticNotebook = linked.first.id == null;
      }
    }
    _loadNotes();
  }

  @override
  void didUpdateWidget(covariant AddChatNoteSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final notebooksChanged = oldWidget.notebooks != widget.notebooks;
    if (notebooksChanged) {
      _notebooks = List.of(widget.notebooks);
      if (_filterAutomaticNotebook) {
        final linked = _notebooks.where((item) => item.bookId == widget.bookId);
        if (linked.isNotEmpty && linked.first.id != null) {
          _filteredNotebookId = linked.first.id;
          _filterAutomaticNotebook = false;
        }
      }
      if (!_notebooks.any((item) => item.id == _filteredNotebookId)) {
        _filteredNotebookId = null;
      }
    }
    if (notebooksChanged || oldWidget.reloadToken != widget.reloadToken) {
      _loadNotes(showLoading: false);
    }
  }

  @override
  void dispose() {
    _newNotebookController.dispose();
    _searchController.dispose();
    _newNotebookFocusNode.dispose();
    _ownedListScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadNotes({bool showLoading = true}) async {
    final revision = ++_loadRevision;
    if (showLoading) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final notebooks = await _db.queryNotebooks();
      final notes = widget.captureMode
          ? await _db.queryNotesForChatCapture(
              preferredBookId: widget.bookId,
              notebookId: _filteredNotebookId,
            )
          : await _db.queryAllNotes(notebookId: _filteredNotebookId);
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _notebooks = [
          ..._notebooks.where(
            (item) =>
                item.id == null &&
                !notebooks.any((saved) => saved.bookId == item.bookId),
          ),
          ...notebooks,
        ];
        if (_filterAutomaticNotebook) {
          final linked = notebooks.where(
            (item) => item.bookId == widget.bookId,
          );
          if (linked.isNotEmpty) {
            _filteredNotebookId = linked.first.id;
            _filterAutomaticNotebook = false;
          }
        }
        _notes = notes;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  void _openNewNotebook() {
    _newNotebookController.clear();
    _newNotebookFocusNode.unfocus();
    setState(() {
      _coverIndex = 0;
      _editingNotebook = null;
      _associateNewNotebook = widget.bookId != null;
      _newNotebookError = null;
      _showNewNotebook = true;
    });
  }

  void _editNotebook(Notebook notebook) {
    if (_openingEditor || _savingNotebook || notebook.isDefault) return;
    _newNotebookController.text = notebook.name;
    _newNotebookFocusNode.unfocus();
    setState(() {
      _editingNotebook = notebook;
      _coverIndex = notebook.coverIndex;
      _associateNewNotebook = notebook.bookId != null;
      _newNotebookError = null;
      _showNewNotebook = true;
    });
  }

  void _closeNewNotebook() {
    if (_savingNotebook) return;
    _newNotebookFocusNode.unfocus();
    setState(() {
      _showNewNotebook = false;
      _newNotebookError = null;
    });
  }

  Future<void> _saveNewNotebook() async {
    if (_savingNotebook) return;
    final name = _newNotebookController.text.trim();
    if (name.isEmpty) {
      setState(() => _newNotebookError = '请输入笔记本名称');
      _newNotebookFocusNode.requestFocus();
      return;
    }

    setState(() {
      _savingNotebook = true;
      _newNotebookError = null;
    });
    try {
      final editing = _editingNotebook;
      final bookId = editing != null
          ? editing.bookId
          : (_associateNewNotebook ? widget.bookId : null);
      final int id;
      if (editing?.id != null) {
        id = editing!.id!;
        final changed = await _db.updateNotebook(
          editing.copyWith(name: name, coverIndex: _coverIndex),
        );
        if (changed != 1) throw StateError('笔记本不可用');
      } else {
        id = await _db.createNotebook(
          name: name,
          coverIndex: _coverIndex,
          bookId: bookId,
        );
      }
      final createdAt = DateTime.now().toIso8601String();
      final notebook = Notebook(
        id: id,
        name: name,
        coverIndex: _coverIndex,
        bookId: bookId,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      if (!mounted) return;

      setState(() {
        _notebooks = [
          notebook,
          ..._notebooks.where(
            (item) =>
                item.id != notebook.id &&
                !(item.id == null && item.bookId == bookId),
          ),
        ];
        _filteredNotebookId = notebook.id;
        _filterAutomaticNotebook = false;
        _savingNotebook = false;
        _showNewNotebook = false;
      });
      _loadNotes();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _savingNotebook = false;
        _newNotebookError = '保存失败，请重试';
      });
    }
  }

  Notebook _notebookFor(Note note) => _notebooks.firstWhere(
    (notebook) => notebook.id == note.notebookId,
    orElse: () => widget.defaultNotebook,
  );

  Notebook get _newNoteNotebook => _filterAutomaticNotebook
      ? _notebooks.firstWhere((item) => item.bookId == widget.bookId)
      : _filteredNotebookId == null
      ? _notebooks.firstWhere(
          (item) => widget.bookId != null && item.bookId == widget.bookId,
          orElse: () => widget.defaultNotebook,
        )
      : _notebooks.firstWhere(
          (notebook) => notebook.id == _filteredNotebookId,
          orElse: () => widget.defaultNotebook,
        );

  void _selectNotebook(Notebook notebook) {
    setState(() {
      _filterAutomaticNotebook = notebook.id == null;
      _filteredNotebookId = _filteredNotebookId == notebook.id
          ? null
          : notebook.id;
      if (_filteredNotebookId != null && _listScrollController.hasClients) {
        _listScrollController.jumpTo(0);
      }
    });
    _loadNotes();
  }

  Future<void> _openEditor(ChatNoteCaptureSelection selection) async {
    if (_openingEditor) return;
    setState(() => _openingEditor = true);
    try {
      await widget.onSelect(selection);
    } finally {
      if (mounted) {
        setState(() => _openingEditor = false);
        unawaited(_loadNotes(showLoading: false));
      }
    }
  }

  void _selectNew() {
    unawaited(
      _openEditor(
        ChatNoteCaptureSelection(
          notebook: _newNoteNotebook,
          keepBookAssociation: _newNoteNotebook.bookId != null,
        ),
      ),
    );
  }

  void _selectExisting(Note note) {
    unawaited(
      _openEditor(
        ChatNoteCaptureSelection(
          notebook: _notebookFor(note),
          keepBookAssociation: note.bookId != null,
          existingNote: note,
        ),
      ),
    );
  }

  Future<void> _showNoteActions(Note note) async {
    if (_openingEditor) return;
    setState(() => _openingEditor = true);
    try {
      await widget.onNoteActions?.call(note);
    } finally {
      if (mounted) {
        setState(() => _openingEditor = false);
        await _loadNotes(showLoading: false);
      }
    }
  }

  Future<void> _openTrash() async {
    if (_openingEditor) return;
    setState(() => _openingEditor = true);
    try {
      await widget.onOpenTrash?.call();
    } finally {
      if (mounted) setState(() => _openingEditor = false);
    }
  }

  String _noteTitle(Note note) {
    final title = note.title.trim();
    return title.isEmpty ? '未命名笔记' : title;
  }

  String _noteDate(Note note) {
    final date = DateTime.tryParse(note.updatedAt);
    return date == null ? '' : DateFormatter.formatRelativeTime(date);
  }

  List<Note> get _visibleNotes {
    if (_filterAutomaticNotebook) return const [];
    final query = _searchController.text.trim().toLowerCase();
    return _notes
        .where((note) {
          if (_filteredNotebookId != null &&
              note.notebookId != _filteredNotebookId)
            return false;
          return query.isEmpty ||
              note.title.toLowerCase().contains(query) ||
              note.content.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final cardTransition = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 220);

    return PopScope<void>(
      canPop:
          !widget.active ||
          (!_showNewNotebook &&
              (widget.onToggleExpanded == null || !widget.expanded)),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !widget.active) return;
        if (_showNewNotebook) {
          _closeNewNotebook();
        } else if (widget.expanded) {
          widget.onToggleExpanded?.call();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            SafeArea(
              top: false,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragStart: widget.onHeaderDragStart,
                        onVerticalDragUpdate: widget.onHeaderDragUpdate,
                        onVerticalDragEnd: widget.onHeaderDragEnd,
                        child: Column(
                          children: [
                            if (widget.onToggleExpanded != null)
                              _buildDragHandle(),
                            _buildHeader(),
                          ],
                        ),
                      ),
                      _buildNotebookRail(),
                      Expanded(child: _buildNoteList()),
                    ],
                  ),
                  Positioned(right: 22, bottom: 34, child: _buildAddButton()),
                ],
              ),
            ),
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: cardTransition,
                reverseDuration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 160),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.025),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: _showNewNotebook
                    ? _buildNewNotebookOverlay(
                        constraints,
                        key: const ValueKey('new-notebook'),
                      )
                    : const SizedBox.shrink(key: ValueKey('no-new-notebook')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDragHandle() => SizedBox(
    height: 28,
    child: Center(
      child: Container(
        width: 72,
        height: 6,
        decoration: BoxDecoration(
          color: const Color(0xFFD0D2D6),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
  );

  Widget _buildHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          if (widget.onClose != null)
            IconButton(
              tooltip: '返回',
              onPressed: widget.onClose,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: SvgPicture.asset(
                'assets/icons/extensions/market_back.svg',
                width: 24,
                height: 24,
                colorFilter: const ColorFilter.mode(_sheetInk, BlendMode.srcIn),
              ),
            ),
          Expanded(
            child: Text(
              widget.captureMode ? '添加到笔记' : '笔记',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _sheetInk,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (widget.onOpenTrash != null)
            IconButton(
              tooltip: '回收站',
              onPressed: _openingEditor ? null : _openTrash,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: SvgPicture.asset(
                'assets/icons/chat_note_editor/trash.svg',
                width: 24,
                height: 24,
                colorFilter: const ColorFilter.mode(_sheetInk, BlendMode.srcIn),
              ),
            ),
          if (widget.onToggleExpanded != null)
            if (widget.expanded)
              TextButton(
                onPressed: widget.onToggleExpanded,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.black,
                  minimumSize: const Size(56, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('收起'),
              )
            else
              IconButton(
                tooltip: '展开笔记面板',
                onPressed: widget.onToggleExpanded,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: SvgPicture.asset(
                  'assets/images/home_composer_expand.svg',
                  width: 20,
                  height: 20,
                  excludeFromSemantics: true,
                ),
              ),
        ],
      ),
    ),
  );

  Widget _buildNotebookRail() => SizedBox(
    height: 66,
    child: Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 8),
          child: Material(
            color: Colors.white,
            elevation: 1.5,
            shadowColor: const Color(0x18000000),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _openNewNotebook,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Tooltip(
                  message: '新增笔记本',
                  child: Center(
                    child: SvgPicture.asset(
                      'assets/images/material_dock_to_right.svg',
                      width: 24,
                      height: 24,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(right: 20),
            child: Row(
              children: [
                for (final notebook in _notebooks)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _notebookChip(notebook),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _notebookChip(Notebook notebook) {
    final selected = notebook.id == null
        ? _filterAutomaticNotebook
        : !_filterAutomaticNotebook && _filteredNotebookId == notebook.id;
    return Semantics(
      button: true,
      selected: selected,
      label: notebook.name,
      hint: notebook.isDefault ? '全局默认笔记本，不关联书籍' : '长按编辑笔记本',
      onLongPress: notebook.isDefault ? null : () => _editNotebook(notebook),
      child: Material(
        color: selected ? _sheetChip : Colors.white,
        elevation: selected ? 2 : 1,
        shadowColor: const Color(0x18000000),
        surfaceTintColor: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _selectNotebook(notebook),
          onLongPress: notebook.isDefault
              ? null
              : () => _editNotebook(notebook),
          child: SizedBox(
            height: 48,
            child: Container(
              constraints: const BoxConstraints(minWidth: 48),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              child: Text(
                notebook.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _sheetInk,
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNoteList() {
    final slivers = <Widget>[];
    if (_loading) {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => Container(
                height: 94,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: _sheetChip,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              childCount: 3,
            ),
          ),
        ),
      );
    } else if (_failed) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: TextButton.icon(
              onPressed: _loadNotes,
              icon: const Icon(Icons.refresh),
              label: const Text('笔记加载失败，点此重试'),
            ),
          ),
        ),
      );
    } else {
      final visibleNotes = _visibleNotes;
      if (visibleNotes.isEmpty) {
        slivers.add(
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  _searchController.text.trim().isNotEmpty
                      ? '没有找到相关笔记'
                      : _filteredNotebookId == null
                      ? '还没有笔记'
                      : '这个笔记本还没有笔记',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _sheetMuted, fontSize: 15),
                ),
              ),
            ),
          ),
        );
      } else {
        final pinnedNotes = visibleNotes
            .where((note) => note.isPinned)
            .toList();
        final otherNotes = visibleNotes
            .where((note) => !note.isPinned)
            .toList();
        pinnedNotes.sort(
          (a, b) => (b.pinnedAt ?? '').compareTo(a.pinnedAt ?? ''),
        );

        if (pinnedNotes.isNotEmpty) {
          slivers.add(
            SliverToBoxAdapter(child: _sectionTitle('置顶', inCard: true)),
          );
          slivers.add(_noteRows(pinnedNotes, pinned: true));
        }
        if (otherNotes.isNotEmpty) {
          if (pinnedNotes.isNotEmpty) {
            slivers.add(
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Divider(height: 1, thickness: 1, color: _sheetDivider),
                ),
              ),
            );
          }
          slivers.add(_noteRows(otherNotes));
        }
        slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 150)));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _sectionTitle('所有笔记')),
            Padding(
              padding: const EdgeInsets.only(right: 22),
              child: IconButton(
                tooltip: _searchOpen ? '关闭搜索' : '搜索笔记',
                onPressed: () => setState(() {
                  _searchOpen = !_searchOpen;
                  if (!_searchOpen) _searchController.clear();
                }),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: SvgPicture.asset(
                  _searchOpen
                      ? 'assets/icons/chat_note_editor/x.svg'
                      : 'assets/images/reading_sidebar_search.svg',
                  width: 20,
                  height: 20,
                  colorFilter: const ColorFilter.mode(
                    _sheetInk,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_searchOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: '搜索标题或正文',
                isDense: true,
              ),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
            child: Material(
              color: Colors.white,
              elevation: 2.5,
              shadowColor: const Color(0x1A000000),
              surfaceTintColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: Color(0xFFEFF0F3)),
              ),
              clipBehavior: Clip.antiAlias,
              child: CustomScrollView(
                controller: _listScrollController,
                slivers: slivers,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, {bool inCard = false}) => Padding(
    padding: EdgeInsets.fromLTRB(inCard ? 8 : 30, 10, 22, 12),
    child: Text(
      title,
      style: const TextStyle(
        color: _sheetInk,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _noteRows(List<Note> notes, {bool pinned = false}) => SliverList(
    delegate: SliverChildBuilderDelegate((context, index) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (index > 0)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Divider(height: 1, thickness: 1, color: _sheetDivider),
            ),
          _noteTile(notes[index], pinned: pinned),
        ],
      );
    }, childCount: notes.length),
  );

  Widget _noteTile(Note note, {bool pinned = false}) => InkWell(
    onTap: _openingEditor ? null : () => _selectExisting(note),
    onLongPress: widget.onNoteActions == null || _openingEditor
        ? null
        : () => _showNoteActions(note),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (pinned) ...[
                const Icon(Icons.push_pin_outlined, size: 20, color: _sheetInk),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  _noteTitle(note),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _sheetInk,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _noteDate(note),
                style: const TextStyle(color: _sheetMuted, fontSize: 12),
              ),
              if (widget.onNoteActions != null)
                IconButton(
                  tooltip: '笔记操作',
                  onPressed: _openingEditor
                      ? null
                      : () => _showNoteActions(note),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: SvgPicture.asset(
                    'assets/icons/chat_note_editor/dots-three-vertical.svg',
                    width: 20,
                    height: 20,
                    colorFilter: const ColorFilter.mode(
                      _sheetInk,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
            ],
          ),
          if (note.content.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              note.content.trim().replaceAll(RegExp(r'\s+'), ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _sheetMuted,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _buildAddButton() => Semantics(
    button: true,
    label: '新建笔记',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x23000000),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 6,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openingEditor ? null : _selectNew,
          child: SizedBox(
            width: 56,
            height: 56,
            child: Tooltip(
              message: '新建笔记',
              child: Center(
                child: SvgPicture.asset(
                  'assets/images/reading_task_plus.svg',
                  width: 24,
                  height: 24,
                  colorFilter: const ColorFilter.mode(
                    Colors.white,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildNewNotebookOverlay(
    BoxConstraints constraints, {
    required Key key,
  }) {
    final availableWidth = constraints.maxWidth;
    final width = availableWidth >= 500
        ? math.min(availableWidth * 0.65, 620.0).toDouble()
        : availableWidth - 32;

    return Stack(
      key: key,
      fit: StackFit.expand,
      children: [
        ModalBarrier(
          color: const Color(0x14000000),
          dismissible: !_savingNotebook,
          onDismiss: _closeNewNotebook,
          semanticsLabel: '关闭新增笔记本',
        ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: width,
              maxHeight: constraints.maxHeight - 28,
            ),
            child: Material(
              color: Colors.white,
              elevation: 12,
              shadowColor: const Color(0x26000000),
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: _buildNewNotebookCard(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNewNotebookCard() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _editingNotebook == null ? '新增笔记本' : '编辑笔记本',
                style: TextStyle(
                  color: _sheetInk,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: _savingNotebook ? null : _closeNewNotebook,
              icon: const Icon(Icons.close, color: _sheetInk),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '笔记本名称',
          style: TextStyle(
            color: _sheetInk,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 7),
        TextField(
          controller: _newNotebookController,
          enabled: !_savingNotebook,
          focusNode: _newNotebookFocusNode,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _newNotebookFocusNode.unfocus(),
          onChanged: (_) {
            if (_newNotebookError != null) {
              setState(() => _newNotebookError = null);
            }
          },
          decoration: InputDecoration(
            hintText: '输入笔记本名称',
            hintStyle: const TextStyle(color: _sheetMuted),
            filled: true,
            fillColor: _sheetChip,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 17,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: _sheetAccent, width: 1.4),
            ),
          ),
        ),
        if (_newNotebookError != null) ...[
          const SizedBox(height: 6),
          Text(
            _newNotebookError!,
            style: const TextStyle(color: Color(0xFFB5473D), fontSize: 13),
          ),
        ],
        if (_editingNotebook == null && widget.bookId != null)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '关联书籍：${widget.bookName}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            value: _associateNewNotebook,
            onChanged: _savingNotebook
                ? null
                : (value) => setState(() => _associateNewNotebook = value),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _editingNotebook?.bookId != null ? '改名不改变书籍关联' : '不关联书籍',
              style: const TextStyle(color: _sheetMuted, fontSize: 13),
            ),
          ),
        const SizedBox(height: 18),
        const Divider(height: 1, color: _sheetDivider),
        const SizedBox(height: 14),
        const Text(
          '选择封面样式',
          style: TextStyle(
            color: _sheetInk,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: NotebookTheme.covers.length,
            separatorBuilder: (context, index) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final selected = _coverIndex == index;
              return Semantics(
                button: true,
                selected: selected,
                label: '封面样式 ${index + 1}',
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _savingNotebook
                      ? null
                      : () => setState(() => _coverIndex = index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 64,
                    height: 88,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected ? _sheetAccent : Colors.transparent,
                        width: selected ? 2.5 : 1,
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        NotebookCover(
                          notebook: Notebook(
                            name: '',
                            coverIndex: index,
                            createdAt: '',
                            updatedAt: '',
                          ),
                          showTitle: false,
                        ),
                        if (selected)
                          Align(
                            alignment: Alignment.bottomRight,
                            child: Container(
                              width: 23,
                              height: 23,
                              margin: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: _sheetAccent,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _savingNotebook ? null : _closeNewNotebook,
                  style: FilledButton.styleFrom(
                    backgroundColor: _sheetChip,
                    foregroundColor: _sheetInk,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('取消'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _savingNotebook ? null : _saveNewNotebook,
                  style: FilledButton.styleFrom(
                    backgroundColor: _sheetAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _savingNotebook
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.3,
                            color: Colors.white,
                          ),
                        )
                      : const Text('保存'),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
