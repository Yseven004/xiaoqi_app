import 'package:flutter/material.dart';

import '../models/note.dart';
import '../models/note_editor_result.dart';
import '../models/notebook.dart';
import '../services/database_service.dart';
import 'note_editor_page.dart';

class NoteManagementPage extends StatefulWidget {
  const NoteManagementPage({
    super.key,
    this.initialBookId,
    this.initialBookName = '',
  });

  final int? initialBookId;
  final String initialBookName;

  @override
  State<NoteManagementPage> createState() => _NoteManagementPageState();
}

class _NoteManagementPageState extends State<NoteManagementPage> {
  final _db = DatabaseService();
  final _searchController = TextEditingController();
  Future<List<Note>>? _notesFuture;
  String _search = '';
  int? _selectedNoteId;

  @override
  void initState() {
    super.initState();
    _notesFuture = _loadNotes();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<Note>> _loadNotes() {
    return _db.queryAllNotes(search: _search, bookId: widget.initialBookId);
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _notesFuture = _loadNotes());
  }

  Future<void> _openNote(Note? note) async {
    final notebooks = await _db.queryNotebooks(status: 'active');
    if (!mounted) return;
    Notebook? notebook = notebooks.isEmpty ? null : notebooks.first;
    if (note?.notebookId != null) {
      notebook = notebooks.cast<Notebook?>().firstWhere(
        (item) => item?.id == note!.notebookId,
        orElse: () => notebook,
      );
    }
    if (notebook?.id == null) return;
    final result = await Navigator.of(context).push<NoteEditorResult>(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          notebookId: notebook!.id!,
          existingNote: note,
          bookId: note?.bookId ?? widget.initialBookId,
          bookName: note?.bookName ?? widget.initialBookName,
        ),
      ),
    );
    if (!mounted || result?.changed != true) return;
    _reload();
  }

  Future<void> _createNote() => _openNote(null);

  Future<void> _togglePinned(Note note) async {
    if (note.id == null) return;
    await _db.setNotePinned(note.id!, !note.isPinned);
    _reload();
  }

  Future<void> _delete(Note note) async {
    if (note.id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移入回收站？'),
        content: const Text('笔记会保留 30 天，之后才会被清理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移入回收站'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _db.softDelete(note.id!);
    if (mounted) _reload();
  }

  Future<void> _openTrash() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const NoteTrashPage()));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('笔记'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF111111),
        surfaceTintColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '回收站',
            onPressed: _openTrash,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          IconButton(
            tooltip: '新建笔记',
            onPressed: _createNote,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<Note>>(
          future: _notesFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const _NotePagePlaceholder();
            final notes = snapshot.data!;
            return LayoutBuilder(
              builder: (context, constraints) {
                final selected = _selectedNote(notes);
                final list = _buildNoteList(notes);
                final detail = selected == null
                    ? const _NoteEmptyDetail()
                    : _NoteDetail(
                        key: ValueKey(selected.id),
                        note: selected,
                        database: _db,
                        onOpenNote: () => _openNote(selected),
                        onAddRelation: () => _addRelation(selected, notes),
                        onRemoveRelation: (target) =>
                            _removeRelation(selected, target),
                      );
                if (constraints.maxWidth >= 840) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 320, child: list),
                      const VerticalDivider(width: 1),
                      Expanded(child: detail),
                    ],
                  );
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [list, const SizedBox(height: 16), detail],
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createNote,
        tooltip: '新建笔记',
        backgroundColor: const Color(0xFF111111),
        foregroundColor: Colors.white,
        child: const Icon(Icons.add_rounded),
      ),
    );
  }

  Note? _selectedNote(List<Note> notes) {
    if (notes.isEmpty) return null;
    for (final note in notes) {
      if (note.id == _selectedNoteId) return note;
    }
    return notes.first;
  }

  Widget _buildNoteList(List<Note> notes) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: TextField(
            controller: _searchController,
            onChanged: (value) {
              _search = value;
              _reload();
            },
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: '搜索标题或正文',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: () {
                        _searchController.clear();
                        _search = '';
                        _reload();
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
              filled: true,
              fillColor: const Color(0xFFF7F7F7),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (notes.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 32, 24, 32),
            child: Column(
              children: [
                Icon(
                  Icons.note_alt_outlined,
                  size: 36,
                  color: Color(0xFF888888),
                ),
                SizedBox(height: 10),
                Text('还没有笔记'),
                SizedBox(height: 4),
                Text('新建一篇笔记开始记录', style: TextStyle(color: Color(0xFF777777))),
              ],
            ),
          )
        else
          ...notes.map(_buildNoteRow),
      ],
    );
  }

  Widget _buildNoteRow(Note note) {
    final selected = note.id == _selectedNoteId;
    return Material(
      color: selected ? const Color(0xFFF1F1F1) : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selectedNoteId = note.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title.trim().isEmpty ? '未命名笔记' : note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _noteSubtitle(note),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF777777),
                      ),
                    ),
                  ],
                ),
              ),
              if (note.isPinned)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.push_pin_rounded, size: 16),
                ),
              PopupMenuButton<String>(
                tooltip: '笔记操作',
                onSelected: (value) {
                  if (value == 'pin') _togglePinned(note);
                  if (value == 'delete') _delete(note);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'pin',
                    child: Text(note.isPinned ? '取消置顶' : '置顶'),
                  ),
                  const PopupMenuItem(value: 'delete', child: Text('移入回收站')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _noteSubtitle(Note note) {
    final source = note.bookName.trim().isEmpty ? '无来源' : note.bookName;
    return '${_formatDate(note.updatedAt)} · $source';
  }

  Future<void> _addRelation(Note note, List<Note> notes) async {
    if (note.id == null) return;
    final candidates = notes.where((item) => item.id != note.id).toList();
    if (candidates.isEmpty) return;
    final target = await showModalBottomSheet<Note>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: candidates
              .map(
                (item) => ListTile(
                  title: Text(item.title.trim().isEmpty ? '未命名笔记' : item.title),
                  subtitle: Text(_noteSubtitle(item)),
                  onTap: () => Navigator.pop(sheetContext, item),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (!mounted || target?.id == null) return;
    await _db.addNoteRelation(noteId: note.id!, relatedNoteId: target!.id!);
    setState(() => _selectedNoteId = note.id);
  }

  Future<void> _removeRelation(Note note, Note target) async {
    if (note.id == null || target.id == null) return;
    await _db.removeNoteRelation(noteId: note.id!, relatedNoteId: target.id!);
    if (mounted) setState(() => _selectedNoteId = note.id);
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

class _NoteEmptyDetail extends StatelessWidget {
  const _NoteEmptyDetail();

  @override
  Widget build(BuildContext context) => const Center(
    child: Text('选择一篇笔记查看来源与引用', style: TextStyle(color: Color(0xFF777777))),
  );
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

  @override
  void initState() {
    super.initState();
    _future = _db.queryDeletedNotes();
  }

  void _reload() {
    if (mounted) setState(() => _future = _db.queryDeletedNotes());
  }

  Future<void> _restore(Note note) async {
    if (note.id == null) return;
    await _db.restoreNotes([note.id!]);
    _reload();
  }

  Future<void> _deleteForever(Note note) async {
    if (note.id == null) return;
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
    if (confirmed != true) return;
    await _db.permanentlyDeleteNotes([note.id!]);
    _reload();
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
                    onPressed: () => _restore(note),
                    child: const Text('恢复'),
                  ),
                  IconButton(
                    tooltip: '永久删除',
                    onPressed: () => _deleteForever(note),
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

String _formatDate(String value) {
  final date = DateTime.tryParse(value);
  if (date == null) return '刚刚';
  final now = DateTime.now();
  if (date.year == now.year && date.month == now.month && date.day == now.day) {
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
  return '${date.month}月${date.day}日';
}
