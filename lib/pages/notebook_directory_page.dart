import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/notebook_theme.dart';
import '../models/note.dart';
import '../models/note_editor_result.dart';
import '../models/notebook.dart';
import '../services/database_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/notebook_cover.dart';
import '../widgets/prototype_pressable.dart';
import 'ai_note_detail_page.dart';
import 'book_page_reader_page.dart';
import 'note_editor_page.dart';
import 'photo_note_detail_page.dart';

class NotebookDirectoryPage extends StatefulWidget {
  const NotebookDirectoryPage({super.key, required this.notebookId});

  final int notebookId;

  @override
  State<NotebookDirectoryPage> createState() => _NotebookDirectoryPageState();
}

class _NotebookDirectoryPageState extends State<NotebookDirectoryPage> {
  final _db = DatabaseService();
  final _searchController = TextEditingController();
  Notebook? _notebook;
  List<Note> _notes = const [];
  Timer? _searchTimer;
  String _query = '';
  String _displayMode = 'cover';
  bool _loading = true;

  static const _displayPreferenceKey = 'notebook_directory_display';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _restorePreference();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _restorePreference() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _displayMode = preferences.getString(_displayPreferenceKey) ?? 'cover';
    });
    await _load();
  }

  void _onSearchChanged() {
    setState(() {});
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  Future<void> _setDisplayMode(String mode) async {
    setState(() => _displayMode = mode);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_displayPreferenceKey, mode);
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object?>([
        _db.getNotebookById(widget.notebookId),
        _db.queryNotesByNotebook(widget.notebookId),
      ]);
      if (!mounted) return;
      setState(() {
        _notebook = values[0] as Notebook?;
        _notes = values[1] as List<Note>;
        _loading = false;
      });
      if (_notebook == null && mounted) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      debugPrint('[NotebookDirectory] 加载失败: $error');
      if (!mounted) return;
      setState(() => _loading = false);
      AppToast.show(context, '笔记目录加载失败，请重试');
    }
  }

  List<Note> get _filtered {
    final query = _query;
    if (query.isEmpty) return _notes;
    return _notes
        .where(
          (note) =>
              note.title.toLowerCase().contains(query) ||
              note.content.toLowerCase().contains(query) ||
              note.bookName.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  Future<void> _createNote() async {
    final result = await Navigator.of(context).push<NoteEditorResult>(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(notebookId: widget.notebookId),
      ),
    );
    await _handleEditorResult(result);
    await _load();
  }

  Future<void> _openNote(Note note) async {
    Widget page;
    if (note.type == 'photo') {
      page = PhotoNoteDetailPage(note: note);
    } else if (note.type == 'annotated_note') {
      page = BookPageReaderPage(initialNote: note);
    } else if (note.type == 'ai_generated' && note.contentDelta.isEmpty) {
      page = AiNoteDetailPage(note: note);
    } else {
      page = NoteEditorPage(notebookId: widget.notebookId, existingNote: note);
    }
    final result = await Navigator.of(
      context,
    ).push<Object?>(MaterialPageRoute(builder: (_) => page));
    if (result is NoteEditorResult) await _handleEditorResult(result);
    await _load();
  }

  Future<void> _handleEditorResult(NoteEditorResult? result) async {
    if (result?.outcome != NoteEditorOutcome.deleted ||
        result?.previousNote == null ||
        !mounted) {
      return;
    }
    final deletedNote = result!.previousNote!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: const Text('笔记已删除'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              await _db.update(
                deletedNote.copyWith(
                  isDeleted: 0,
                  updatedAt: DateTime.now().toIso8601String(),
                ),
              );
              await _load();
            },
          ),
        ),
      );
  }

  Future<void> _renameNote(Note note) async {
    final controller = TextEditingController(text: note.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名笔记'),
        content: TextField(
          key: const Key('rename_note_field'),
          controller: controller,
          autofocus: false,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: '笔记标题',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(dialogContext, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title == note.title) return;
    try {
      await _db.update(
        note.copyWith(
          title: title,
          updatedAt: DateTime.now().toIso8601String(),
        ),
      );
      await _load();
    } catch (error) {
      if (mounted) AppToast.show(context, '重命名失败，请重试');
    }
  }

  Future<void> _moveNote(Note note) async {
    final notebooks = await _db.queryNotebooks();
    if (!mounted) return;
    final candidates = notebooks
        .where((item) => item.id != widget.notebookId)
        .toList(growable: false);
    if (candidates.isEmpty) {
      AppToast.show(context, '还没有其他笔记本可移动');
      return;
    }
    final target = await showModalBottomSheet<Notebook>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '移动到其他笔记本',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 20),
              children: candidates
                  .map(
                    (item) => ListTile(
                      minTileHeight: 56,
                      leading: Container(
                        width: 36,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: NotebookTheme.coverGradient(
                            item.coverIndex,
                          ),
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                      title: Text(item.name),
                      subtitle: Text(
                        '${item.category} · ${item.noteCount} 条笔记',
                      ),
                      onTap: () => Navigator.pop(sheetContext, item),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
    if (target == null) return;
    try {
      await _db.moveNoteToNotebook(note.id!, target.id!);
      await _load();
      if (mounted) AppToast.show(context, '已移动到「${target.name}」');
    } catch (error) {
      if (mounted) AppToast.show(context, '移动失败，请重试');
    }
  }

  Future<void> _deleteNote(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这篇笔记？'),
        content: const Text('删除后可在下方提示中立即撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: NotebookTheme.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _db.softDelete(note.id!);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            content: const Text('笔记已删除'),
            action: SnackBarAction(
              label: '撤销',
              onPressed: () async {
                await _db.update(
                  note.copyWith(isDeleted: 0, updatedAt: note.updatedAt),
                );
                await _load();
              },
            ),
          ),
        );
    } catch (error) {
      if (mounted) AppToast.show(context, '删除失败，请重试');
    }
  }

  void _showNoteMenu(Note note) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              minTileHeight: 52,
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(sheetContext);
                _renameNote(note);
              },
            ),
            ListTile(
              minTileHeight: 52,
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动到其他笔记本'),
              onTap: () {
                Navigator.pop(sheetContext);
                _moveNote(note);
              },
            ),
            ListTile(
              minTileHeight: 52,
              leading: const Icon(
                Icons.delete_outline,
                color: NotebookTheme.danger,
              ),
              title: const Text(
                '删除笔记',
                style: TextStyle(color: NotebookTheme.danger),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _deleteNote(note);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notebook = _notebook;
    return Scaffold(
      backgroundColor: NotebookTheme.lightBackground,
      appBar: AppBar(
        backgroundColor: NotebookTheme.lightBackground,
        surfaceTintColor: Colors.transparent,
        title: Text(
          notebook?.name ?? '笔记目录',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create_note_button'),
        onPressed: notebook == null ? null : _createNote,
        backgroundColor: NotebookTheme.accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('新建笔记'),
      ),
      body: _loading
          ? const SizedBox.shrink()
          : notebook == null
          ? const SizedBox.shrink()
          : SafeArea(
              top: false,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: _NotebookHeader(notebook: notebook),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                      child: SearchBar(
                        controller: _searchController,
                        hintText: '搜索当前笔记本',
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
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'cover',
                            icon: Icon(Icons.auto_stories_outlined),
                            label: Text('封面'),
                          ),
                          ButtonSegment(
                            value: 'compact',
                            icon: Icon(Icons.view_list_outlined),
                            label: Text('紧凑'),
                          ),
                          ButtonSegment(
                            value: 'paper',
                            icon: Icon(Icons.article_outlined),
                            label: Text('纸张'),
                          ),
                        ],
                        selected: {_displayMode},
                        showSelectedIcon: false,
                        onSelectionChanged: (values) =>
                            _setDisplayMode(values.first),
                      ),
                    ),
                  ),
                  if (_filtered.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _DirectoryEmpty(
                        searching: _searchController.text.trim().isNotEmpty,
                        onCreate: _createNote,
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        0,
                        16,
                        MediaQuery.paddingOf(context).bottom + 100,
                      ),
                      sliver: SliverList.separated(
                        itemCount: _filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, index) {
                          final note = _filtered[index];
                          return _NoteDirectoryCard(
                            note: note,
                            displayMode: _displayMode,
                            onTap: () => _openNote(note),
                            onMore: () => _showNoteMenu(note),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _NotebookHeader extends StatelessWidget {
  const _NotebookHeader({required this.notebook});

  final Notebook notebook;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 74,
            height: 98,
            child: NotebookCover(
              notebook: notebook,
              borderRadius: BorderRadius.circular(13),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x24000000),
                  blurRadius: 14,
                  offset: Offset(0, 7),
                ),
              ],
              child: const Center(
                child: Icon(Icons.menu_book_outlined, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notebook.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NotebookTheme.lightInk,
                    fontSize: 24,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  notebook.category,
                  style: const TextStyle(
                    color: NotebookTheme.lightMuted,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${notebook.noteCount} 条笔记 · 按更新时间倒序',
                  style: const TextStyle(
                    color: NotebookTheme.lightMuted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteDirectoryCard extends StatelessWidget {
  const _NoteDirectoryCard({
    required this.note,
    required this.displayMode,
    required this.onTap,
    required this.onMore,
  });

  final Note note;
  final String displayMode;
  final VoidCallback onTap;
  final VoidCallback onMore;

  static ({IconData icon, String label}) source(Note note) {
    if (note.sourceType == 'photo_analysis' ||
        note.type == 'photo' ||
        note.type == 'annotated_note') {
      return (
        icon: PhosphorIcons.camera(PhosphorIconsStyle.regular),
        label: '拍照分析',
      );
    }
    if (note.sourceType == 'ai_generated' || note.type == 'ai_generated') {
      return (
        icon: PhosphorIcons.sparkle(PhosphorIconsStyle.regular),
        label: 'AI生成',
      );
    }
    if (note.sourceType == 'voice') {
      return (
        icon: PhosphorIcons.microphone(PhosphorIconsStyle.regular),
        label: '语音笔记',
      );
    }
    return (
      icon: PhosphorIcons.notePencil(PhosphorIconsStyle.regular),
      label: '文字笔记',
    );
  }

  static String time(String value) {
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return value;
    final now = DateTime.now();
    if (parsed.year == now.year &&
        parsed.month == now.month &&
        parsed.day == now.day) {
      return '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
    }
    return '${parsed.month}/${parsed.day}';
  }

  @override
  Widget build(BuildContext context) {
    final origin = source(note);
    final summary = note.content.trim().replaceAll(RegExp(r'\s+'), ' ');
    return Semantics(
      button: true,
      label: '${note.title.isEmpty ? '未命名笔记' : note.title}，${origin.label}',
      child: Material(
        color: displayMode == 'paper'
            ? const Color(0xFFFFFCF3)
            : NotebookTheme.lightSurface,
        borderRadius: BorderRadius.circular(displayMode == 'compact' ? 10 : 16),
        child: PrototypePressable(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          onLongPress: onMore,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              displayMode == 'compact' ? 12 : 16,
              displayMode == 'compact' ? 9 : 14,
              6,
              displayMode == 'compact' ? 9 : 14,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            origin.icon,
                            size: 16,
                            color: NotebookTheme.accent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            origin.label,
                            style: const TextStyle(
                              color: NotebookTheme.lightMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            time(note.updatedAt),
                            style: const TextStyle(
                              color: NotebookTheme.lightMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      Text(
                        note.title.trim().isEmpty ? '未命名笔记' : note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: NotebookTheme.lightInk,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (summary.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: NotebookTheme.lightMuted,
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '管理笔记',
                  onPressed: onMore,
                  icon: const Icon(Icons.more_vert),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectoryEmpty extends StatelessWidget {
  const _DirectoryEmpty({required this.searching, required this.onCreate});

  final bool searching;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              searching ? Icons.search_off : Icons.note_add_outlined,
              color: NotebookTheme.lightMuted,
              size: 44,
            ),
            const SizedBox(height: 14),
            Text(
              searching ? '没有找到相关笔记' : '记录第一篇笔记',
              style: const TextStyle(
                color: NotebookTheme.lightInk,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              searching ? '换个关键词试试' : '写下想法、摘录，或从照片中分析内容',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: NotebookTheme.lightMuted,
                fontSize: 14,
              ),
            ),
            if (!searching) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('empty_create_note_button'),
                onPressed: onCreate,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('记录第一篇笔记'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(48, 48),
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
