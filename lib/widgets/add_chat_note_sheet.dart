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
  });

  final List<Notebook> notebooks;
  final Notebook defaultNotebook;
  final Future<void> Function(ChatNoteCaptureSelection) onSelect;
  final int? bookId;
  final String bookName;

  @override
  State<AddChatNoteSheet> createState() => _AddChatNoteSheetState();
}

class _AddChatNoteSheetState extends State<AddChatNoteSheet> {
  final _db = DatabaseService();
  final _newNotebookController = TextEditingController();
  final _newNotebookFocusNode = FocusNode();
  final _listScrollController = ScrollController();

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
  String? _newNotebookError;

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  @override
  void dispose() {
    _newNotebookController.dispose();
    _newNotebookFocusNode.dispose();
    _listScrollController.dispose();
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
      final notes = await _db.queryNotesForChatCapture(
        preferredBookId: widget.bookId,
        notebookId: _filteredNotebookId,
      );
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _notes = notes;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || revision != _loadRevision) return;
      if (!showLoading) return;
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
      final id = await _db.createNotebook(
        name: name,
        coverIndex: _coverIndex,
      );
      final createdAt = DateTime.now().toIso8601String();
      final notebook = Notebook(
        id: id,
        name: name,
        coverIndex: _coverIndex,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      if (!mounted) return;

      setState(() {
        _notebooks = [
          notebook,
          ..._notebooks.where((item) => item.id != notebook.id),
        ];
        _filteredNotebookId = notebook.id;
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

  Notebook get _newNoteNotebook => _filteredNotebookId == null
      ? widget.defaultNotebook
      : _notebooks.firstWhere(
          (notebook) => notebook.id == _filteredNotebookId,
          orElse: () => widget.defaultNotebook,
        );

  void _selectNotebook(Notebook notebook) {
    setState(() {
      _filteredNotebookId = _filteredNotebookId == notebook.id
          ? null
          : notebook.id;
      if (_filteredNotebookId != null &&
          _listScrollController.hasClients) {
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
          keepBookAssociation: widget.bookId != null,
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

  String _noteTitle(Note note) {
    final title = note.title.trim();
    return title.isEmpty ? '未命名笔记' : title;
  }

  String _noteDate(Note note) {
    final date = DateTime.tryParse(note.updatedAt);
    return date == null ? '' : DateFormatter.formatRelativeTime(date);
  }

  List<Note> get _visibleNotes {
    if (_filteredNotebookId == null) return _notes;
    return _notes
        .where((note) => note.notebookId == _filteredNotebookId)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final cardTransition = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 220);

    return PopScope<void>(
      canPop: !_showNewNotebook,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showNewNotebook) _closeNewNotebook();
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
                      _buildDragHandle(),
                      _buildHeader(),
                      _buildNotebookRail(),
                      Expanded(child: _buildNoteList()),
                    ],
                  ),
                  Positioned(
                    right: 22,
                    bottom: 34,
                    child: _buildAddButton(),
                  ),
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
                    : const SizedBox.shrink(
                        key: ValueKey('no-new-notebook'),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDragHandle() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onVerticalDragEnd: (details) {
      if ((details.primaryVelocity ?? 0) > 350) Navigator.maybePop(context);
    },
    child: SizedBox(
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
    ),
  );

  Widget _buildHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
    child: SizedBox(
      height: 48,
      child: Center(
        child: Text(
          '添加到笔记',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _sheetInk,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
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
    final selected = _filteredNotebookId == notebook.id;
    return Semantics(
      button: true,
      selected: selected,
      label: notebook.name,
      child: Material(
        color: selected ? _sheetChip : Colors.white,
        elevation: selected ? 2 : 1,
        shadowColor: const Color(0x18000000),
        surfaceTintColor: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _selectNotebook(notebook),
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
                  _filteredNotebookId == null
                      ? '还没有文字笔记'
                      : '这个笔记本还没有文字笔记',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _sheetMuted, fontSize: 15),
                ),
              ),
            ),
          ),
        );
      } else {
        final pinnedNotes = visibleNotes.where((note) => note.isPinned).toList();
        final otherNotes = visibleNotes.where((note) => !note.isPinned).toList();
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
        _sectionTitle('所有笔记'),
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
    onTap: () => _selectExisting(note),
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
    label: '添加到新笔记',
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0xFFF9FAFC)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white),
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
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _selectNew,
          child: SizedBox(
            width: 80,
            height: 80,
            child: Tooltip(
              message: '添加到新笔记',
              child: Center(
                child: SvgPicture.asset(
                  'assets/images/reading_task_plus.svg',
                  width: 44,
                  height: 44,
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
            const Expanded(
              child: Text(
                '新增笔记本',
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
                      gradient: NotebookTheme.coverGradient(index),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? _sheetAccent : Colors.transparent,
                        width: selected ? 2.5 : 1,
                      ),
                    ),
                    child: selected
                        ? Align(
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
                          )
                        : null,
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
