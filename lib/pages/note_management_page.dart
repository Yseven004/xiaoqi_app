import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/chat_note_capture.dart';
import '../models/note.dart';
import '../models/note_editor_result.dart';
import '../models/notebook.dart';
import '../services/database_service.dart';
import '../widgets/add_chat_note_sheet.dart';
import '../widgets/app_toast.dart';
import 'note_editor_page.dart';

/// One note panel: a resizable dialog in chat, or expanded inside the library.
class NoteManagementPage extends StatefulWidget {
  const NoteManagementPage({
    super.key,
    this.initialBookId,
    this.initialBookName = '',
    this.initialNotebookId,
    this.chatSource,
    this.asPanel = false,
    this.active = true,
    this.onClose,
  });

  final int? initialBookId;
  final String initialBookName;
  final int? initialNotebookId;
  final ChatNoteSourceRecord? chatSource;
  final bool asPanel;
  final bool active;
  final VoidCallback? onClose;

  @override
  State<NoteManagementPage> createState() => _NoteManagementPageState();
}

class _NoteManagementPageState extends State<NoteManagementPage> {
  final _db = DatabaseService();
  final _sheetController = DraggableScrollableController();
  late Future<List<Notebook>> _notebooksFuture;
  int _reloadToken = 0;
  bool _expanded = false;
  double _compactSize = 0.6;
  double _availableHeight = 1;
  double _headerDragStartSize = 0.6;

  @override
  void initState() {
    super.initState();
    _notebooksFuture = _loadNotebooks();
  }

  Future<List<Notebook>> _loadNotebooks() async {
    final notebooks = await _db.queryNotebooks();
    final bookId = widget.initialBookId;
    if (bookId != null && !notebooks.any((item) => item.bookId == bookId)) {
      final now = DateTime.now().toIso8601String();
      return [
        Notebook(
          name: widget.initialBookName,
          bookId: bookId,
          createdAt: now,
          updatedAt: now,
        ),
        ...notebooks,
      ];
    }
    return notebooks;
  }

  @override
  void didUpdateWidget(covariant NoteManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _notebooksFuture = _loadNotebooks();
      _reloadToken++;
    }
  }

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _reloadToken++);
  }

  void _setExpanded(bool expanded) {
    if (!_sheetController.isAttached) return;
    final target = expanded ? 1.0 : _compactSize;
    if (MediaQuery.disableAnimationsOf(context)) {
      _sheetController.jumpTo(target);
    } else {
      unawaited(
        _sheetController.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOutCubic,
        ),
      );
    }
  }

  void _beginHeaderDrag(DragStartDetails details) {
    if (_sheetController.isAttached) {
      _headerDragStartSize = _sheetController.size;
    }
  }

  void _dragHeader(DragUpdateDetails details) {
    if (!_sheetController.isAttached) return;
    final next =
        _sheetController.size - (details.primaryDelta ?? 0) / _availableHeight;
    _sheetController.jumpTo(next.clamp(_compactSize, 1.0).toDouble());
  }

  void _endHeaderDrag(DragEndDetails details) {
    if (!_sheetController.isAttached) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 350 &&
        _headerDragStartSize <= _compactSize + 0.01 &&
        _sheetController.size <= _compactSize + 0.01) {
      Navigator.of(context).maybePop();
      return;
    }
    final distance =
        (_sheetController.size - _headerDragStartSize) * _availableHeight;
    _setExpanded(
      velocity.abs() > 350
          ? velocity < 0
          : distance.abs() >= 48
          ? distance > 0
          : _sheetController.size >= (_compactSize + 1) / 2,
    );
  }

  Future<void> _openEditor(ChatNoteCaptureSelection selection) async {
    final existing = selection.existingNote;
    try {
      await showModalBottomSheet<NoteEditorResult>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        useRootNavigator: true,
        useSafeArea: true,
        backgroundColor: Colors.white,
        barrierColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width),
        builder: (_) => SizedBox.expand(
          child: NoteEditorPage(
            notebookId: existing?.notebookId ?? selection.notebook.id,
            autoNotebookBookId:
                existing == null && selection.notebook.id == null
                ? selection.notebook.bookId
                : null,
            existingNote: existing,
            bookId: widget.initialBookId ?? existing?.bookId,
            bookName: widget.initialBookId != null
                ? widget.initialBookName
                : existing?.bookName ?? '',
            chatSource: widget.chatSource,
          ),
        ),
      );
      if (mounted)
        setState(() {
          _notebooksFuture = _loadNotebooks();
          _reloadToken++;
        });
    } catch (_) {
      if (mounted) AppToast.show(context, '笔记暂时无法打开，请重试');
    }
  }

  Future<void> _openTrash() async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const NoteTrashPage()));
    _reload();
  }

  Future<void> _noteActions(Note note, List<Notebook> notebooks) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in [
              ('pin', note.isPinned ? '取消置顶' : '置顶'),
              ('move', '移动到其他笔记本'),
              ('sources', '来源与引用'),
              ('delete', '移入回收站'),
            ])
              ListTile(
                title: Text(item.$2),
                onTap: () => Navigator.pop(sheetContext, item.$1),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null || note.id == null) return;
    try {
      switch (action) {
        case 'pin':
          await _db.setNotePinned(note.id!, !note.isPinned);
          break;
        case 'move':
          final updatedNotebooks = await _db.queryNotebooks();
          if (!mounted) return;
          final target = await showModalBottomSheet<Notebook>(
            context: context,
            useSafeArea: true,
            builder: (sheetContext) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final notebook in updatedNotebooks)
                    ListTile(
                      title: Text(notebook.name),
                      selected: notebook.id == note.notebookId,
                      onTap: () => Navigator.pop(sheetContext, notebook),
                    ),
                ],
              ),
            ),
          );
          if (target?.id != null) {
            await _db.moveNoteToNotebook(note.id!, target!.id!);
          }
          break;
        case 'sources':
          await _showSources(note, notebooks);
          break;
        case 'delete':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('移入回收站？'),
              content: const Text('笔记会保留 30 天。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('移入回收站'),
                ),
              ],
            ),
          );
          if (confirmed == true) await _db.softDelete(note.id!);
          break;
      }
    } catch (_) {
      if (mounted) AppToast.show(context, '操作失败，请重试');
    }
  }

  Future<void> _showSources(Note note, List<Notebook> notebooks) async {
    final notes = await _db.queryAllNotes();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.85,
        child: StatefulBuilder(
          builder: (context, refresh) => _NoteDetail(
            key: ValueKey(_reloadToken),
            note: note,
            database: _db,
            onOpenNote: () async {
              Navigator.pop(sheetContext);
              await _openEditor(
                ChatNoteCaptureSelection(
                  notebook: notebooks.firstWhere(
                    (item) => item.id == note.notebookId,
                    orElse: () => notebooks.first,
                  ),
                  keepBookAssociation: note.bookId != null,
                  existingNote: note,
                ),
              );
              _reload();
            },
            onAddRelation: () async {
              await _addRelation(note, notes);
              if (sheetContext.mounted) refresh(() => _reloadToken++);
            },
            onRemoveRelation: (target) async {
              try {
                await _db.removeNoteRelation(
                  noteId: note.id!,
                  relatedNoteId: target.id!,
                );
                if (sheetContext.mounted) refresh(() => _reloadToken++);
              } catch (_) {
                if (context.mounted) AppToast.show(context, '移除引用失败，请重试');
              }
            },
          ),
        ),
      ),
    );
  }

  Future<void> _addRelation(Note note, List<Note> notes) async {
    final candidates = notes.where((item) => item.id != note.id).toList();
    if (candidates.isEmpty) {
      AppToast.show(context, '暂无可引用的其他笔记');
      return;
    }
    final target = await showModalBottomSheet<Note>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        children: [
          for (final item in candidates)
            ListTile(
              title: Text(item.title.trim().isEmpty ? '未命名笔记' : item.title),
              onTap: () => Navigator.pop(sheetContext, item),
            ),
        ],
      ),
    );
    if (target?.id == null) return;
    try {
      await _db.addNoteRelation(noteId: note.id!, relatedNoteId: target!.id!);
    } catch (_) {
      if (mounted) AppToast.show(context, '添加引用失败，请重试');
    }
  }

  Widget _surface(ScrollController? scrollController) {
    return ClipRRect(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(widget.asPanel && !_expanded ? 28 : 0),
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF4F6F8), Colors.white],
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: FutureBuilder<List<Notebook>>(
            future: _notebooksFuture,
            builder: (context, snapshot) {
              if (snapshot.hasError || snapshot.data?.isEmpty == true) {
                return Center(
                  child: TextButton(
                    onPressed: () => setState(() {
                      _notebooksFuture = _loadNotebooks();
                    }),
                    child: const Text('笔记本加载失败，点此重试'),
                  ),
                );
              }
              if (!snapshot.hasData) return const _NotePagePlaceholder();
              final notebooks = snapshot.data!;
              final defaultNotebook = notebooks.firstWhere(
                (item) => item.isDefault,
                orElse: () => notebooks.first,
              );
              return AddChatNoteSheet(
                notebooks: notebooks,
                defaultNotebook: defaultNotebook,
                initialNotebookId: widget.initialNotebookId,
                bookId: widget.initialBookId,
                bookName: widget.initialBookName,
                captureMode: widget.chatSource != null,
                active: widget.active,
                expanded: !widget.asPanel || _expanded,
                scrollController: scrollController,
                reloadToken: _reloadToken,
                onToggleExpanded: widget.asPanel
                    ? () => _setExpanded(!_expanded)
                    : null,
                onClose:
                    widget.onClose ??
                    (widget.asPanel ? () => Navigator.maybePop(context) : null),
                onHeaderDragUpdate: widget.asPanel ? _dragHeader : null,
                onHeaderDragStart: widget.asPanel ? _beginHeaderDrag : null,
                onHeaderDragEnd: widget.asPanel ? _endHeaderDrag : null,
                onOpenTrash: _openTrash,
                onSelect: _openEditor,
                onNoteActions: (note) => _noteActions(note, notebooks),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!widget.asPanel) return _surface(null);
          final media = MediaQuery.of(context);
          _availableHeight = math.max(1.0, constraints.maxHeight);
          _compactSize = media.size.shortestSide >= 600 ? 0.60 : 0.88;
          return NotificationListener<DraggableScrollableNotification>(
            onNotification: (notification) {
              if (notification.depth != 0) return false;
              final expanded = notification.extent >= (_compactSize + 1) / 2;
              if (_expanded != expanded) {
                setState(() => _expanded = expanded);
              }
              return false;
            },
            child: Align(
              alignment: Alignment.bottomCenter,
              child: DraggableScrollableSheet(
                controller: _sheetController,
                initialChildSize: _compactSize,
                minChildSize: _compactSize,
                maxChildSize: 1,
                expand: false,
                snap: true,
                snapAnimationDuration: MediaQuery.disableAnimationsOf(context)
                    ? const Duration(milliseconds: 1)
                    : const Duration(milliseconds: 220),
                shouldCloseOnMinExtent: false,
                builder: (context, scrollController) =>
                    _surface(scrollController),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NoteDetail extends StatelessWidget {
  const _NoteDetail({
    super.key,
    required this.note,
    required this.database,
    required this.onOpenNote,
    required this.onAddRelation,
    required this.onRemoveRelation,
  });

  final Note note;
  final DatabaseService database;
  final VoidCallback onOpenNote;
  final VoidCallback onAddRelation;
  final ValueChanged<Note> onRemoveRelation;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                note.title.trim().isEmpty ? '未命名笔记' : note.title,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: onOpenNote,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('编辑'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          note.content.trim().isEmpty ? '暂无正文' : note.content.trim(),
          style: const TextStyle(
            fontSize: 16,
            height: 1.7,
            color: Color(0xFF333333),
          ),
        ),
        const SizedBox(height: 28),
        _DetailSection(
          title: '主要来源',
          child: Text(
            note.bookName.trim().isEmpty
                ? '无来源'
                : '${note.bookName}${note.bookPage.trim().isEmpty ? '' : ' · 第 ${note.bookPage} 页'}',
            style: const TextStyle(fontSize: 14),
          ),
        ),
        _DetailSection(
          title: '引用书籍',
          child: FutureBuilder<List<Map<String, Object?>>>(
            future: database.queryNoteBookReferences(note.id ?? -1),
            builder: (context, snapshot) {
              final rows = snapshot.data ?? const <Map<String, Object?>>[];
              if (rows.isEmpty) return const Text('暂无引用书籍');
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: rows
                    .map(
                      (row) => Chip(
                        label: Text(row['book_name'] as String? ?? '未知书籍'),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ),
        _DetailSection(
          title: '引用笔记',
          trailing: TextButton.icon(
            onPressed: onAddRelation,
            icon: const Icon(Icons.add, size: 17),
            label: const Text('添加'),
          ),
          child: FutureBuilder<List<Note>>(
            future: database.queryLinkedNotes(note.id ?? -1),
            builder: (context, snapshot) {
              final notes = snapshot.data ?? const <Note>[];
              if (notes.isEmpty) return const Text('暂无引用笔记');
              return Column(
                children: notes
                    .map(
                      (item) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          item.title.trim().isEmpty ? '未命名笔记' : item.title,
                        ),
                        subtitle: item.isDeleted == 1
                            ? const Text('笔记已删除')
                            : null,
                        trailing: IconButton(
                          tooltip: '移除引用',
                          onPressed: () => onRemoveRelation(item),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ),
        _DetailSection(
          title: '反向链接',
          child: FutureBuilder<List<Note>>(
            future: database.queryBacklinks(note.id ?? -1),
            builder: (context, snapshot) {
              final notes = snapshot.data ?? const <Note>[];
              if (notes.isEmpty) return const Text('暂无反向链接');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: notes
                    .map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          item.isDeleted == 1
                              ? '笔记已删除'
                              : (item.title.trim().isEmpty
                                    ? '未命名笔记'
                                    : item.title),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF777777),
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _NotePagePlaceholder extends StatelessWidget {
  const _NotePagePlaceholder();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
    children: List.generate(
      5,
      (index) => const Padding(
        padding: EdgeInsets.only(bottom: 14),
        child: SizedBox(
          height: 54,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Color(0xFFF2F2F2)),
          ),
        ),
      ),
    ),
  );
}

class NoteTrashPage extends StatefulWidget {
  const NoteTrashPage({super.key});

  @override
  State<NoteTrashPage> createState() => _NoteTrashPageState();
}

class _NoteTrashPageState extends State<NoteTrashPage> {
  final _db = DatabaseService();
  late Future<List<Note>> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = _db.queryDeletedNotes();
  }

  void _reload() {
    if (mounted) setState(() => _future = _db.queryDeletedNotes());
  }

  Future<void> _restore(Note note) async {
    if (note.id == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _db.restoreNotes([note.id!]);
      _reload();
    } catch (_) {
      if (mounted) AppToast.show(context, '恢复失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteForever(Note note) async {
    if (note.id == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('永久删除？'),
        content: const Text('删除后无法恢复，附件也可能被清理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _db.permanentlyDeleteNotes([note.id!]);
      _reload();
    } catch (_) {
      if (mounted) AppToast.show(context, '删除失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    appBar: AppBar(
      title: const Text('回收站'),
      backgroundColor: Colors.white,
      foregroundColor: const Color(0xFF111111),
      surfaceTintColor: Colors.white,
      elevation: 0,
    ),
    body: FutureBuilder<List<Note>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: _reload,
              child: const Text('回收站加载失败，点此重试'),
            ),
          );
        }
        if (!snapshot.hasData) return const _NotePagePlaceholder();
        final notes = snapshot.data!;
        if (notes.isEmpty) return const Center(child: Text('回收站为空'));
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: notes.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final note = notes[index];
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(note.title.trim().isEmpty ? '未命名笔记' : note.title),
              subtitle: Text(
                '${note.bookName.trim().isEmpty ? '无来源' : note.bookName} · 保留 30 天',
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _restore(note),
                    child: const Text('恢复'),
                  ),
                  IconButton(
                    tooltip: '永久删除',
                    onPressed: _busy ? null : () => _deleteForever(note),
                    icon: const Icon(Icons.delete_forever_outlined),
                  ),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}
