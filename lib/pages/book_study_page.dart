import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../config/book_flow_theme.dart';
import '../models/book_category.dart';
import '../models/book_library_item.dart';
import '../models/book_recognition.dart';
import '../models/book_source.dart';
import '../models/note.dart';
import '../services/book_library_service.dart';
import '../utils/book_cover_palette.dart';
import '../widgets/book_cover.dart';
import '../widgets/book_spine_shading.dart';
import '../widgets/app_toast.dart';
import '../widgets/book_cover_picker_sheet.dart';
import '../widgets/book_metadata_form_sheet.dart';
import '../widgets/book_paper_background.dart';
import 'ai_note_detail_page.dart';
import 'book_page_reader_page.dart';
import 'book_sources_page.dart';
import 'note_editor_page.dart';
import 'photo_note_detail_page.dart';

class BookStudyPage extends StatefulWidget {
  const BookStudyPage({
    super.key,
    required this.bookId,
    required this.onBack,
    this.bookLibraryService,
  });

  final int bookId;
  final VoidCallback onBack;
  final BookLibraryService? bookLibraryService;

  @override
  State<BookStudyPage> createState() => _BookStudyPageState();
}

class _BookStudyPageState extends State<BookStudyPage> {
  late final BookLibraryService _library;
  BookLibraryItem? _item;
  List<Note> _notes = const [];
  List<BookSourceRecord> _sources = const [];
  List<BookCategory> _categories = const [];
  bool _loading = true;
  bool _showAllNotes = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _library = widget.bookLibraryService ?? BookLibraryService();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final item = await _library.getBookLibraryItem(widget.bookId);
      if (item == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '这本书已经不存在';
          });
        }
        return;
      }
      final notes = await _library.getNotesForBook(widget.bookId);
      final sources = await _library.listSourcesForBook(widget.bookId);
      final categories = await _library.listCategories();
      unawaited(_library.recordStudyActivity(widget.bookId));
      if (!mounted) return;
      setState(() {
        _item = item;
        _notes = notes;
        _sources = sources;
        _categories = categories;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '本书资料暂时无法加载：$error';
      });
    }
  }

  Future<void> _openBookSources() async {
    final item = _item;
    if (item == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BookSourcesPage(
          bookId: widget.bookId,
          bookTitle: item.book.title,
          bookLibraryService: _library,
        ),
      ),
    );
    if (mounted) await _load();
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
      page = NoteEditorPage(
        notebookId: note.notebookId ?? 1,
        existingNote: note,
        bookId: widget.bookId,
        bookName: _item?.book.title ?? note.bookName,
      );
    }
    await Navigator.of(
      context,
    ).push<Object?>(MaterialPageRoute(builder: (_) => page));
    if (mounted) await _load();
  }

  Future<void> _editMetadata() async {
    final item = _item;
    if (item == null) return;
    final updated = await showModalBottomSheet<BookRecord>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Material(
        color: BookFlowTheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BookMetadataFormSheet(initial: item.book),
      ),
    );
    if (updated == null || !mounted) return;
    try {
      await _library.updateBookMetadata(updated);
      await _load();
    } catch (error) {
      if (mounted) {
        AppToast.show(context, '书籍资料保存失败：$error');
      }
    }
  }

  Future<void> _editCover() async {
    final item = _item;
    if (item == null) return;
    final selected = await showBookCoverPicker(context, initial: item.book);
    if (!mounted || selected == null) return;
    try {
      await _library.updateBookMetadata(selected);
      await _load();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '封面保存失败，请重试：$error');
    }
  }

  Future<void> _editCategories() async {
    final item = _item;
    if (item == null) return;
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
                    style: BookFlowTheme.primaryButtonStyle(),
                    onPressed: () => Navigator.pop(
                      sheetContext,
                      selected.toList(growable: false),
                    ),
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
    await _library.setBookCategories(widget.bookId, result);
    await _load();
  }

  Future<void> _deleteBook() async {
    final item = _item;
    if (item == null || item.book.id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这本书？'),
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
      await _library.deleteBooks([item.book.id!]);
      if (!mounted) return;
      widget.onBack();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '删除书籍失败：$error');
    }
  }

  Future<void> _unlinkNote(Note note) async {
    final noteId = note.id;
    if (noteId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从本书移除笔记？'),
        content: const Text('笔记和原图会保留，只是不再归入这本书。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _library.unlinkNotesFromBook([noteId]);
    await _load();
  }

  Future<void> _toggleNotePinned(Note note) async {
    final noteId = note.id;
    if (noteId == null) return;
    try {
      await _library.setNotePinned(noteId, !note.isPinned);
      await _load();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(
        context,
        note.isPinned ? '取消置顶失败：$error' : '置顶失败：$error',
      );
    }
  }

  Future<void> _shareBook() async {
    final item = _item;
    if (item == null) return;
    final lines = <String>[
      '《${item.book.title}》',
      if (item.book.authorLabel.isNotEmpty) item.book.authorLabel,
      if (item.book.publisher.isNotEmpty) item.book.publisher,
      '${item.noteCount} 篇学习笔记',
    ];
    await SharePlus.instance.share(
      ShareParams(text: lines.join('\n'), subject: item.book.title),
    );
  }

  Future<void> _showAssociationInfo() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          decoration: BoxDecoration(
            color: BookFlowTheme.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: BookFlowTheme.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x330C1712),
                blurRadius: 28,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.link_rounded,
                color: BookFlowTheme.detailPrimary,
              ),
              const SizedBox(height: 14),
              const Text('微信读书关联', style: BookFlowTheme.heading),
              const SizedBox(height: 8),
              const Text(
                '这是可选的后续服务。它未来可在你主动授权后补充目录和跳转链接，'
                '不会影响当前书籍识别、保存或阅读。\n\n'
                '目前正在等待适合移动端的正式授权方式开放。',
                style: TextStyle(fontSize: 14, height: 1.55),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('知道了'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showBookDescription() async {
    final description = _item?.book.description.trim() ?? '';
    if (description.isEmpty || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final maxHeight = MediaQuery.sizeOf(dialogContext).height * .72;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Container(
              padding: const EdgeInsets.fromLTRB(22, 18, 18, 16),
              decoration: BoxDecoration(
                color: BookFlowTheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: BookFlowTheme.line),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x330C1712),
                    blurRadius: 28,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('本书简介', style: BookFlowTheme.heading),
                      ),
                      IconButton(
                        tooltip: '关闭简介',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Scrollbar(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(right: 8, bottom: 4),
                        child: SelectableText(
                          description,
                          style: const TextStyle(fontSize: 15, height: 1.7),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showNoteActions(Note note) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(
                note.isPinned
                    ? PhosphorIconsRegular.pushPinSlash
                    : PhosphorIconsRegular.pushPin,
              ),
              title: Text(note.isPinned ? '取消置顶' : '置顶笔记'),
              onTap: () {
                Navigator.pop(sheetContext);
                _toggleNotePinned(note);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_off_rounded),
              title: const Text('从本书移除'),
              subtitle: const Text('不会删除笔记或原图'),
              onTap: () {
                Navigator.pop(sheetContext);
                _unlinkNote(note);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showBookActions() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑书籍资料'),
              onTap: () {
                Navigator.pop(sheetContext);
                _editMetadata();
              },
            ),
            ListTile(
              leading: const Icon(Icons.category_outlined),
              title: const Text('调整分类'),
              onTap: () {
                Navigator.pop(sheetContext);
                _editCategories();
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
                _deleteBook();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ColoredBox(
        color: BookFlowTheme.detailCanvas,
        child: SizedBox.shrink(),
      );
    }
    if (_error != null || _item == null) {
      return ColoredBox(
        color: BookFlowTheme.detailCanvas,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 44),
                const SizedBox(height: 12),
                Text(_error ?? '书籍不存在', style: BookFlowTheme.body),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: widget.onBack,
                  child: const Text('返回阅读空间'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final item = _item!;
    final visibleNotes = _showAllNotes ? _notes : _notes.take(3);
    return BookPaperBackground(
      showBotanicalShadow: true,
      warmEditorial: true,
      child: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: BookFlowTheme.detailPrimary,
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
            children: [
              Row(
                children: [
                  Transform.translate(
                    offset: const Offset(-16, 0),
                    child: _RoundIconButton(
                      tooltip: '返回阅读空间',
                      onTap: widget.onBack,
                      icon: PhosphorIconsRegular.caretLeft,
                      size: 44,
                      iconSize: 23,
                    ),
                  ),
                  const Spacer(),
                  Transform.translate(
                    offset: const Offset(4, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RoundIconButton(
                          tooltip: '分享书籍',
                          onTap: _shareBook,
                          icon: PhosphorIconsRegular.export,
                          size: 44,
                          iconSize: 22,
                          radius: 13,
                          backgroundColor: const Color(0x12FFFFFF),
                        ),
                        const SizedBox(width: 2),
                        _RoundIconButton(
                          tooltip: '更多书籍操作',
                          onTap: _showBookActions,
                          icon: PhosphorIconsBold.dotsThree,
                          size: 44,
                          iconSize: 24,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final coverWidth = (constraints.maxWidth * .405).clamp(
                    122.0,
                    148.0,
                  );
                  final coverHeight = coverWidth * 1.43;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        button: true,
                        label: '更换《${item.book.title}》封面',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: _editCover,
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: _BookHeroCover(
                              book: item.book,
                              width: coverWidth,
                              height: coverHeight,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 22),
                      Expanded(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: coverHeight),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                item.book.title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    const TextStyle(
                                      color: BookFlowTheme.ink,
                                      fontSize: 25,
                                      height: 1.24,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -.2,
                                    ).copyWith(
                                      fontSize: _detailTitleSize(
                                        item.book.title,
                                      ),
                                    ),
                              ),
                              if (item.book.authorLabel.isNotEmpty) ...[
                                const SizedBox(height: 7),
                                Text(
                                  item.book.authorLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: BookFlowTheme.inkSecondary,
                                    fontSize: 14.5,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                              if (_publicationLabel(item).isNotEmpty) ...[
                                const SizedBox(height: 14),
                                Text(
                                  _publicationLabel(item),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: BookFlowTheme.inkSecondary,
                                    fontSize: 13.5,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              _BookStats(
                                item: item,
                                sourceCount: _sources.length,
                                onOpenSources: _openBookSources,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              if (item.book.description.isNotEmpty ||
                  item.book.tableOfContents.isNotEmpty) ...[
                const SizedBox(height: 18),
                _BookMetadataSummary(
                  book: item.book,
                  onShowDescription: _showBookDescription,
                ),
              ],
              const SizedBox(height: 14),
              _OptionalAssociationCard(onTap: _showAssociationInfo),
              const SizedBox(height: 26),
              Row(
                children: [
                  const Expanded(
                    child: Text('最近笔记', style: BookFlowTheme.heading),
                  ),
                  if (_notes.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() => _showAllNotes = true),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '查看全部',
                            style: TextStyle(
                              color: BookFlowTheme.inkSecondary,
                              fontSize: 14,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: BookFlowTheme.inkSecondary,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (_notes.isEmpty)
                const _EmptyNotes()
              else
                for (final note in visibleNotes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _BookNoteCard(
                      note: note,
                      onTap: () => _openNote(note),
                      onLongPress: () => _unlinkNote(note),
                      onTogglePinned: () => _toggleNotePinned(note),
                      onMore: () => _showNoteActions(note),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  String _publicationLabel(BookLibraryItem item) => [
    item.book.publishedDate,
    item.book.publisher,
    item.book.edition,
  ].where((value) => value.trim().isNotEmpty).join(' · ');

  double _detailTitleSize(String title) {
    final length = title.runes.length;
    if (length > 18) return 19;
    if (length > 12) return 21;
    return 25;
  }
}

class _BookMetadataSummary extends StatelessWidget {
  const _BookMetadataSummary({
    required this.book,
    required this.onShowDescription,
  });

  final BookRecord book;
  final VoidCallback onShowDescription;

  @override
  Widget build(BuildContext context) {
    final hasDescription = book.description.trim().isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: hasDescription ? onShowDescription : null,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xDFFAF6EE),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFDDDBC7)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasDescription) ...[
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '本书简介',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const Icon(
                      Icons.open_in_new_rounded,
                      size: 15,
                      color: BookFlowTheme.inkSecondary,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      '查看全文',
                      style: TextStyle(
                        color: BookFlowTheme.inkSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                ConstrainedBox(
                  // 保持原来约 4 行简介的卡片高度，长简介仍可在此区域内滚动。
                  constraints: const BoxConstraints(maxHeight: 84),
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        book.description,
                        style: const TextStyle(fontSize: 13, height: 1.55),
                      ),
                    ),
                  ),
                ),
              ],
              if (book.tableOfContents.isNotEmpty) ...[
                if (hasDescription) const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(
                      Icons.format_list_bulleted_rounded,
                      size: 18,
                      color: BookFlowTheme.detailPrimary,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      '已保存 ${book.tableOfContents.length} 项目录',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionalAssociationCard extends StatelessWidget {
  const _OptionalAssociationCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '微信读书关联，可选，暂未开放正式授权',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F0E7),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BookFlowTheme.line),
        ),
        child: const Row(
          children: [
            Icon(Icons.link_rounded, color: BookFlowTheme.inkSecondary),
            SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '微信读书关联（可选）',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 3),
                  Text('正式授权准备中，不影响本书识别和使用', style: BookFlowTheme.caption),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: BookFlowTheme.inkSecondary,
            ),
          ],
        ),
      ),
    ),
  );
}

class _BookHeroCover extends StatefulWidget {
  const _BookHeroCover({
    required this.book,
    required this.width,
    required this.height,
  });

  final BookRecord book;
  final double width;
  final double height;

  @override
  State<_BookHeroCover> createState() => _BookHeroCoverState();
}

class _BookHeroCoverState extends State<_BookHeroCover> {
  BookCoverPalette _palette = BookCoverPalette.fallback;

  @override
  void initState() {
    super.initState();
    _loadPalette();
  }

  Future<void> _loadPalette() async {
    final palette = await BookCoverPalette.fromBook(widget.book);
    if (mounted) setState(() => _palette = palette);
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = widget.height;
    // The cover artwork wraps the whole book; this shading layer only adds
    // physical light and shadow, tinted by the cover's own palette.
    final spineWidth = (width * .075).clamp(8.0, 11.0);

    return SizedBox(
      width: width + 4,
      height: height + 6,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -18,
            top: 7,
            width: width + 34,
            height: height + 38,
            child: IgnorePointer(
              child: CustomPaint(
                painter: _DirectionalBookShadowPainter(palette: _palette),
              ),
            ),
          ),
          Positioned(
            left: 1,
            top: 0,
            width: width,
            height: height,
            child: BookCover(
              book: widget.book,
              borderRadius: 8,
              topLeftRadius: 8,
              bottomLeftRadius: 8,
              topRightRadius: 5,
              bottomRightRadius: 5,
              builtInSpineShading: false,
            ),
          ),
          Positioned(
            left: 1,
            top: 0,
            width: spineWidth + 2,
            height: height,
            child: IgnorePointer(
              child: CustomPaint(
                painter: BookSpineShadingPainter(
                  palette: _palette,
                  foldX: spineWidth,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the cast shadow with physical light from the top-right: the
/// shadow projects to the bottom-left in a wide, slanted sweep, tinted by
/// the cover's own palette.
class _DirectionalBookShadowPainter extends CustomPainter {
  const _DirectionalBookShadowPainter({required this.palette});

  final BookCoverPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    // The cover occupies (19, 2) inside this larger paint area.
    final bookLeft = 19.0;
    final bookTop = 2.0;
    final bookWidth = size.width - 34;
    final bookHeight = size.height - 38;
    final shadowBase = palette.shadow;

    // 1) Ambient: a strongly slanted projection toward the bottom-left.
    // Light arrives from the upper-right, so the left edge of the shadow
    // sweeps far left-down while the right edge stays close to the book.
    final ambientBounds = Rect.fromLTRB(
      bookLeft - 70,
      bookTop + 4,
      bookLeft + bookWidth + 12,
      bookTop + bookHeight + 36,
    );
    final ambientPath = Path()
      ..moveTo(bookLeft + bookWidth + 10, bookTop + 8)
      ..lineTo(bookLeft - 22, bookTop + 22)
      ..lineTo(bookLeft - 66, bookTop + bookHeight + 32)
      ..lineTo(bookLeft + bookWidth - 6, bookTop + bookHeight + 22)
      ..close();
    canvas.drawPath(
      ambientPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            shadowBase.withValues(alpha: .34),
            shadowBase.withValues(alpha: .10),
          ],
        ).createShader(ambientBounds)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );

    // 2) Core: tighter version of the same slanted projection.
    final coreBounds = Rect.fromLTRB(
      bookLeft - 34,
      bookTop + 6,
      bookLeft + bookWidth + 6,
      bookTop + bookHeight + 22,
    );
    final corePath = Path()
      ..moveTo(bookLeft + bookWidth + 4, bookTop + 10)
      ..lineTo(bookLeft - 10, bookTop + 16)
      ..lineTo(bookLeft - 30, bookTop + bookHeight + 18)
      ..lineTo(bookLeft + bookWidth - 2, bookTop + bookHeight + 12)
      ..close();
    canvas.drawPath(
      corePath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            shadowBase.withValues(alpha: .46),
            shadowBase.withValues(alpha: .20),
          ],
        ).createShader(coreBounds)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    // 3) Contact: hugs the left and bottom edges only.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          bookLeft - 8,
          bookTop + 2,
          bookWidth + 12,
          bookHeight + 8,
        ),
        const Radius.circular(9),
      ),
      Paint()
        ..color = shadowBase.withValues(alpha: .45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // 4) Bottom contact: a soft blurred band under the book. No hard line,
    // so the bottom edge blends naturally into the desk.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          bookLeft - 4,
          bookTop + bookHeight + .5,
          bookWidth + 8,
          5,
        ),
        const Radius.circular(3),
      ),
      Paint()
        ..color = shadowBase.withValues(alpha: .18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
  }

  @override
  bool shouldRepaint(covariant _DirectionalBookShadowPainter oldDelegate) =>
      oldDelegate.palette != palette;
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.tooltip,
    required this.onTap,
    required this.icon,
    this.size = 48,
    this.iconSize = 22,
    this.radius,
    this.backgroundColor,
  });

  final String tooltip;
  final VoidCallback onTap;
  final IconData icon;
  final double size;
  final double iconSize;
  final double? radius;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: backgroundColor ?? Colors.transparent,
      shape: radius == null
          ? const CircleBorder()
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius!),
            ),
      child: InkWell(
        onTap: onTap,
        customBorder: radius == null
            ? const CircleBorder()
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius!),
              ),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: BookFlowTheme.ink, size: iconSize),
        ),
      ),
    ),
  );
}

class _BookStats extends StatelessWidget {
  const _BookStats({
    required this.item,
    required this.sourceCount,
    required this.onOpenSources,
  });

  final BookLibraryItem item;
  final int sourceCount;
  final VoidCallback onOpenSources;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Stat(
          icon: Icons.note_alt_outlined,
          value: '${item.noteCount}',
          label: '篇笔记',
        ),
        const SizedBox(
          width: 28,
          child: VerticalDivider(
            width: 1,
            thickness: 1,
            color: BookFlowTheme.detailLineStrong,
          ),
        ),
        _Stat(
          icon: Icons.file_copy_outlined,
          value: '${item.recognizedPageCount}',
          label: '页已整理',
        ),
        const SizedBox(
          width: 28,
          child: VerticalDivider(
            width: 1,
            thickness: 1,
            color: BookFlowTheme.detailLineStrong,
          ),
        ),
        _Stat(
          icon: Icons.description_outlined,
          value: '$sourceCount',
          label: '本书资料',
          onTap: onOpenSources,
          color: BookFlowTheme.detailPrimary,
        ),
      ],
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.value,
    required this.label,
    this.onTap,
    this.color = BookFlowTheme.inkSecondary,
  });

  final IconData icon;
  final String value;
  final String label;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              value,
              style: TextStyle(
                color: onTap == null ? BookFlowTheme.ink : color,
                fontSize: 15,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: TextStyle(color: color, fontSize: 12.5, height: 1.4),
        ),
      ],
    );
    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: '查看本书资料，共$value份',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: content,
        ),
      ),
    );
  }
}

class _BookNoteCard extends StatelessWidget {
  const _BookNoteCard({
    required this.note,
    required this.onTap,
    required this.onLongPress,
    required this.onTogglePinned,
    required this.onMore,
  });

  final Note note;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onTogglePinned;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: BookFlowTheme.detailSurfaceElevated,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BookFlowTheme.detailLine),
      boxShadow: BookFlowTheme.detailCardShadow,
    ),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
          child: Stack(
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 84,
                      constraints: const BoxConstraints(minHeight: 92),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFF5EFE5), Color(0xFFEEE6D9)],
                        ),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0x66FFFFFF)),
                      ),
                      alignment: Alignment.topLeft,
                      child: Text(
                        note.bookPage.isEmpty ? '未标页码' : '第 ${note.bookPage} 页',
                        maxLines: 2,
                        style: const TextStyle(
                          color: BookFlowTheme.ink,
                          fontSize: 13.5,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 40),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              note.content.isEmpty
                                  ? (note.title.isEmpty
                                        ? '点击继续编辑笔记'
                                        : note.title)
                                  : note.content,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: BookFlowTheme.ink,
                                fontSize: 14.5,
                                height: 1.58,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _dateLabel(note.updatedAt),
                              style: BookFlowTheme.caption,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: -8,
                right: -6,
                child: IconButton(
                  tooltip: note.isPinned ? '取消置顶' : '置顶笔记',
                  onPressed: onTogglePinned,
                  icon: Icon(
                    note.isPinned
                        ? PhosphorIconsFill.pushPin
                        : PhosphorIconsRegular.pushPin,
                  ),
                  color: BookFlowTheme.detailPrimary,
                  iconSize: 18,
                  constraints: const BoxConstraints.tightFor(
                    width: 44,
                    height: 44,
                  ),
                ),
              ),
              Positioned(
                right: -6,
                bottom: -8,
                child: IconButton(
                  tooltip: '笔记操作',
                  onPressed: onMore,
                  icon: Icon(PhosphorIconsBold.dotsThree),
                  color: BookFlowTheme.inkSecondary,
                  iconSize: 21,
                  constraints: const BoxConstraints.tightFor(
                    width: 44,
                    height: 44,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  String _dateLabel(String timestamp) {
    final value = DateTime.tryParse(timestamp);
    if (value == null) return '最近更新';
    final now = DateTime.now();
    final difference = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(value.year, value.month, value.day)).inDays;
    if (difference == 0) return '今天';
    if (difference == 1) return '昨天';
    return '${value.month}月${value.day}日';
  }
}

class _EmptyNotes extends StatelessWidget {
  const _EmptyNotes();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: BookFlowTheme.detailSurfaceElevated,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BookFlowTheme.detailLine),
      boxShadow: BookFlowTheme.detailCardShadow,
    ),
    child: const Column(
      children: [
        Icon(
          Icons.auto_stories_outlined,
          color: BookFlowTheme.primary,
          size: 30,
        ),
        SizedBox(height: 8),
        Text(
          '还没有笔记',
          style: TextStyle(
            color: BookFlowTheme.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 4),
        Text('关联到这本书的笔记会显示在这里。', style: BookFlowTheme.caption),
      ],
    ),
  );
}
