import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../config/book_flow_theme.dart';
import '../models/book_library_item.dart';
import '../models/book_recognition.dart';
import '../models/book_source.dart';
import '../services/book_library_service.dart';
import '../widgets/book_cover.dart';
import '../widgets/app_toast.dart';
import '../widgets/book_cover_picker_sheet.dart';
import '../widgets/book_metadata_editor.dart';
import '../widgets/book_metadata_form_sheet.dart';
import 'book_sources_page.dart';
import 'note_management_page.dart';
import '../models/notebook.dart';
import '../services/database_service.dart';
import '../widgets/notebook_cover.dart';
import '../widgets/notebook_editor_overlay.dart';

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

enum _BookAction { edit, association, delete }

class _BookStudyPageState extends State<BookStudyPage> {
  late final BookLibraryService _library;
  BookLibraryItem? _item;
  List<Notebook> _notebooks = const [];
  List<BookSourceRecord> _sources = const [];
  bool _loading = true;
  bool _openingNotebookEditor = false;
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
      final notebooks = await DatabaseService().queryNotebooks(
        bookId: widget.bookId,
      );
      final sources = await _library.listSourcesForBook(widget.bookId);
      unawaited(_library.recordStudyActivity(widget.bookId));
      if (!mounted) return;
      setState(() {
        _item = item;
        _notebooks = notebooks;
        _sources = sources;
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
    if (_item == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BookSourcesPage(
          bookId: widget.bookId,
          bookLibraryService: _library,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openNotebook([Notebook? notebook]) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.white,
          body: NoteManagementPage(
            initialBookId: widget.bookId,
            initialBookName: _item?.book.title ?? '',
            initialNotebookId: notebook?.id,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openNotebookEditor([Notebook? notebook]) async {
    final book = _item?.book;
    if (book == null || _openingNotebookEditor) return;
    _openingNotebookEditor = true;
    try {
      final edited = await showNotebookEditor(
        context: context,
        bookId: widget.bookId,
        bookName: book.title,
        requireBookAssociation: true,
        notebook: notebook,
      );
      if (mounted && edited != null) await _load();
    } finally {
      _openingNotebookEditor = false;
    }
  }

  Future<void> _editMetadata() async {
    final item = _item;
    if (item == null) return;
    var categories = await _library.listCategories();
    if (!mounted) return;
    var draft = BookMetadataFormResult(
      book: item.book,
      categoryIds: item.categories
          .map((category) => category.id!)
          .toList(growable: false),
    );
    while (true) {
      if (!mounted) return;
      final updated = await showBookMetadataEditor(
        context: context,
        initial: draft.book,
        categories: categories,
        initialCategoryIds: draft.categoryIds,
        onCreateCategory: (name) async {
          final created = await _library.saveCustomCategory(name);
          if (!categories.any((category) => category.id == created.id)) {
            categories = [...categories, created];
          }
          return created;
        },
        saveError: draft.saveError,
      );
      if (!mounted || updated == null) return;
      try {
        await _library.updateBookMetadataAndCategories(
          updated.book,
          updated.categoryIds,
        );
        await _load();
        return;
      } catch (error) {
        if (!mounted) return;
        draft = BookMetadataFormResult(
          book: updated.book,
          categoryIds: updated.categoryIds,
          saveError: error.toString(),
        );
      }
    }
  }

  Future<void> _editCover() async {
    final item = _item;
    if (item == null) return;
    final selected = await showBookCoverPicker(context, initial: item.book);
    if (selected == null) return;
    if (!mounted) {
      if (selected.coverPath != item.book.coverPath) {
        await _library.discardUnreferencedBookCover(selected.coverPath);
      }
      return;
    }
    try {
      await _library.updateBookMetadata(selected);
      await _load();
    } catch (error) {
      if (selected.coverPath != item.book.coverPath) {
        await _library.discardUnreferencedBookCover(selected.coverPath);
      }
      if (!mounted) return;
      AppToast.show(context, '封面保存失败，请重试：$error');
    }
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
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFD5D8DE)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.link_rounded, color: BookFlowTheme.ink),
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
    await showBookDescriptionDialog(
      context: context,
      description: description,
      onSave: (description) async {
        await _library.updateBookDescription(widget.bookId, description);
        if (mounted) await _load();
      },
    );
  }

  void _handleBookAction(_BookAction action) {
    switch (action) {
      case _BookAction.edit:
        unawaited(_editMetadata());
        break;
      case _BookAction.association:
        unawaited(_showAssociationInfo());
        break;
      case _BookAction.delete:
        unawaited(_deleteBook());
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ColoredBox(color: Colors.white, child: SizedBox.shrink());
    }
    if (_error != null || _item == null) {
      return ColoredBox(
        color: Colors.white,
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
    final publication = _buildPublication(item);
    return ColoredBox(
      color: Colors.white,
      child: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: BookFlowTheme.ink,
          onRefresh: _load,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  6,
                  20,
                  _notebooks.isEmpty ? 0 : 32,
                ),
                sliver: SliverList.list(
                  children: [
                    Row(
                      children: [
                        Transform.translate(
                          offset: const Offset(-16, 0),
                          child: _RoundIconButton(
                            tooltip: '返回阅读空间',
                            onTap: widget.onBack,
                            icon: PhosphorIconsRegular.caretLeft,
                            size: 48,
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
                                size: 48,
                                iconSize: 22,
                                radius: 13,
                                backgroundColor: const Color(0x12FFFFFF),
                              ),
                              const SizedBox(width: 2),
                              PopupMenuButton<_BookAction>(
                                tooltip: '更多书籍操作',
                                onSelected: _handleBookAction,
                                offset: const Offset(0, 44),
                                color: Colors.white,
                                constraints: const BoxConstraints(
                                  minWidth: 196,
                                ),
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: _BookAction.edit,
                                    height: 48,
                                    child: Text('编辑书籍资料'),
                                  ),
                                  const PopupMenuItem(
                                    value: _BookAction.association,
                                    height: 48,
                                    child: Text('微信读书关联（准备中）'),
                                  ),
                                  const PopupMenuItem(
                                    value: _BookAction.delete,
                                    height: 48,
                                    child: Text(
                                      '删除该书籍',
                                      style: TextStyle(
                                        color: Color(0xFFB94A45),
                                      ),
                                    ),
                                  ),
                                ],
                                child: const SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Icon(
                                    PhosphorIconsBold.dotsThree,
                                    color: BookFlowTheme.ink,
                                    size: 24,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final coverWidth = constraints.maxWidth >= 600
                            ? (constraints.maxWidth * .255).clamp(180.0, 220.0)
                            : (constraints.maxWidth * .405).clamp(122.0, 148.0);
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
                                constraints: BoxConstraints(
                                  minHeight: coverHeight,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
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
                                    if (publication != null) ...[
                                      const SizedBox(height: 14),
                                      publication,
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
                    const SizedBox(height: 26),
                    Row(
                      children: [
                        const Expanded(
                          child: Text('笔记', style: BookFlowTheme.heading),
                        ),
                        if (_notebooks.isNotEmpty)
                          TextButton(
                            onPressed: () => _openNotebook(),
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
                    if (_notebooks.isNotEmpty)
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final width = (constraints.maxWidth * .18).clamp(
                            88.0,
                            108.0,
                          );
                          final captionHeight =
                              MediaQuery.textScalerOf(context).scale(14) * 2.5;
                          return SizedBox(
                            height: width * 1.5 + 10 + captionHeight,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _notebooks.length + 1,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 20),
                              itemBuilder: (context, index) {
                                if (index == _notebooks.length) {
                                  return _BookNotebookTile(
                                    width: width,
                                    caption: '新建笔记本',
                                    semanticsLabel: '新建笔记本',
                                    cover: const _NewNotebookCover(),
                                    onTap: _openNotebookEditor,
                                  );
                                }
                                final notebook = _notebooks[index];
                                final caption = '${notebook.noteCount} 篇笔记';
                                return _BookNotebookTile(
                                  width: width,
                                  caption: caption,
                                  semanticsLabel: '${notebook.name}，$caption',
                                  cover: NotebookCover(notebook: notebook),
                                  onTap: () => _openNotebook(notebook),
                                  onLongPress:
                                      notebook.id == null || notebook.isDefault
                                      ? null
                                      : () => _openNotebookEditor(notebook),
                                );
                              },
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
              if (_notebooks.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                    child: Center(
                      child: _EmptyBookNotebooks(onCreate: _openNotebookEditor),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _buildPublication(BookLibraryItem item) {
    final label = [
      item.book.publishedDate,
      item.book.publisher,
      item.book.edition,
    ].where((value) => value.trim().isNotEmpty).join(' · ');
    final categories = item.categories;
    if (label.isEmpty && categories.isEmpty) return null;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: EdgeInsetsDirectional.only(
              end: categories.isEmpty ? 0 : 8,
            ),
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: BookFlowTheme.inkSecondary,
                fontSize: 13.5,
                height: 1.5,
              ),
            ),
          ),
        for (final category in categories)
          DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFCCCCCC)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                category.name,
                style: const TextStyle(
                  color: BookFlowTheme.ink,
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
            ),
          ),
      ],
    );
  }

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
    return Column(
      children: [
        const Divider(height: 1, color: BookFlowTheme.line),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: hasDescription ? onShowDescription : null,
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
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
                          color: BookFlowTheme.ink,
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
        ),
        const Divider(height: 1, color: BookFlowTheme.line),
      ],
    );
  }
}

class _BookHeroCover extends StatelessWidget {
  const _BookHeroCover({
    required this.book,
    required this.width,
    required this.height,
  });

  final BookRecord book;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: BookCover(book: book, borderRadius: 8),
  );
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

class _BookNotesIcon extends StatelessWidget {
  const _BookNotesIcon({required this.size, this.color = BookFlowTheme.ink});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/images/home_reply_note.svg',
    width: size,
    height: size,
    excludeFromSemantics: true,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
  );
}

class _EmptyBookNotebooks extends StatelessWidget {
  const _EmptyBookNotebooks({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 288),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const _BookNotesIcon(size: 76, color: Color(0xFF898989)),
              const SizedBox(width: 16),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '还没有关联笔记本',
                      style: BookFlowTheme.heading.copyWith(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '为这本书整理阅读笔记',
                      style: BookFlowTheme.body.copyWith(
                        fontSize: 16,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: 276,
            child: FilledButton.icon(
              onPressed: onCreate,
              icon: _notebookPlus(18, Colors.white),
              label: const Text('新建笔记本', textAlign: TextAlign.center),
              style: FilledButton.styleFrom(
                backgroundColor: BookFlowTheme.ink,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 54),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                textStyle: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _NewNotebookCover extends StatelessWidget {
  const _NewNotebookCover();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xFFF3F3F3),
      border: Border.all(color: const Color(0xFFD5D8DE)),
      borderRadius: NotebookCover.radius,
    ),
    child: Stack(
      fit: StackFit.expand,
      children: [
        const Positioned(
          left: 8,
          top: 1,
          bottom: 1,
          width: 1,
          child: ColoredBox(color: Color(0xFFD5D8DE)),
        ),
        Center(child: _notebookPlus(28, BookFlowTheme.inkSecondary)),
      ],
    ),
  );
}

Widget _notebookPlus(double size, Color color) => SvgPicture.asset(
  'assets/icons/extension_market/detail/plus.svg',
  width: size,
  height: size,
  excludeFromSemantics: true,
  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
);

class _BookNotebookTile extends StatelessWidget {
  const _BookNotebookTile({
    required this.width,
    required this.caption,
    required this.semanticsLabel,
    required this.cover,
    required this.onTap,
    this.onLongPress,
  });

  final double width;
  final String caption;
  final String semanticsLabel;
  final Widget cover;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semanticsLabel,
    hint: onLongPress != null ? '长按编辑笔记本' : null,
    child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: width, height: width * 1.5, child: cover),
              const SizedBox(height: 8),
              Text(
                caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: BookFlowTheme.inkSecondary,
                  fontSize: 14,
                  height: 1.25,
                ),
              ),
            ],
          ),
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stats = [
        _Stat(
          icon: const _BookNotesIcon(size: 18),
          value: '${item.noteCount}',
          label: '篇笔记',
        ),
        _Stat(
          icon: const Icon(
            Icons.file_copy_outlined,
            size: 16,
            color: BookFlowTheme.inkSecondary,
          ),
          value: '${item.recognizedPageCount}',
          label: '页已整理',
        ),
        _Stat(
          icon: const Icon(
            Icons.description_outlined,
            size: 16,
            color: BookFlowTheme.ink,
          ),
          value: '$sourceCount',
          label: '本书资料',
          onTap: onOpenSources,
          color: BookFlowTheme.ink,
        ),
      ];
      final labelSize = MediaQuery.textScalerOf(context).scale(12.5);
      if (constraints.maxWidth < labelSize * 11 + 64) {
        return Wrap(spacing: 12, runSpacing: 8, children: stats);
      }
      final spread = constraints.maxWidth >= 440;
      return IntrinsicHeight(
        child: Row(
          mainAxisSize: spread ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, stat) in stats.indexed) ...[
              if (index != 0)
                const SizedBox(
                  width: 28,
                  child: VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: BookFlowTheme.lineStrong,
                  ),
                ),
              if (spread) Expanded(child: stat) else stat,
            ],
          ],
        ),
      );
    },
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

  final Widget icon;
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
            icon,
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                value,
                style: TextStyle(
                  color: onTap == null ? BookFlowTheme.ink : color,
                  fontSize: 15,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                ),
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
