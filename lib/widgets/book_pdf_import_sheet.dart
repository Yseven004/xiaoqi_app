import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';
import '../models/book_library_item.dart';
import '../models/book_recognition.dart';
import '../models/book_source.dart';
import 'book_cover.dart';
import 'book_metadata_form_sheet.dart';

enum BookAddAction { scan, importPdf }

Future<BookAddAction?> showBookAddSourceSheet(BuildContext context) {
  return showModalBottomSheet<BookAddAction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x990C1712),
    builder: (_) => const _BookAddSourceSheet(),
  );
}

Future<BookPdfImportSelection?> showBookPdfImportSheet({
  required BuildContext context,
  required PlatformFile file,
  required List<BookLibraryItem> books,
}) {
  return showModalBottomSheet<BookPdfImportSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x990C1712),
    builder: (_) => _BookPdfImportSheet(file: file, books: books),
  );
}

class BookPdfImportSelection {
  const BookPdfImportSelection.existing(this.bookId)
    : newBook = null,
      shouldReselect = false;

  const BookPdfImportSelection.newBook(this.newBook)
    : bookId = null,
      shouldReselect = false;

  const BookPdfImportSelection.reselect()
    : bookId = null,
      newBook = null,
      shouldReselect = true;

  final int? bookId;
  final BookRecord? newBook;
  final bool shouldReselect;
}

class _BookAddSourceSheet extends StatelessWidget {
  const _BookAddSourceSheet();

  @override
  Widget build(BuildContext context) => Material(
    color: BookFlowTheme.surface,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
    clipBehavior: Clip.antiAlias,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: BookFlowTheme.lineStrong,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text('添加到阅读空间', style: BookFlowTheme.heading),
            const SizedBox(height: 6),
            const Text('选择你手边已有的资料，或先确认一本书。', style: BookFlowTheme.caption),
            const SizedBox(height: 18),
            _SourceActionCard(
              icon: Icons.menu_book_rounded,
              title: '导入资料',
              subtitle: '支持 PDF、EPUB',
              primary: true,
              onTap: () => Navigator.of(context).pop(BookAddAction.importPdf),
            ),
            const SizedBox(height: 10),
            _SourceActionCard(
              icon: Icons.qr_code_scanner_rounded,
              title: '扫描 / 输入 ISBN',
              subtitle: '从实体书条码确认书籍资料',
              onTap: () => Navigator.of(context).pop(BookAddAction.scan),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SourceActionCard extends StatelessWidget {
  const _SourceActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Material(
    color: primary ? BookFlowTheme.primarySoft : BookFlowTheme.surface,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: primary
                    ? BookFlowTheme.ochreSoft
                    : BookFlowTheme.surfaceSoft,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(icon, color: BookFlowTheme.ink, size: 24),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: _bookCardTitle),
                  const SizedBox(height: 3),
                  Text(subtitle, style: BookFlowTheme.caption),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: BookFlowTheme.inkSecondary,
              size: 24,
            ),
          ],
        ),
      ),
    ),
  );
}

class _BookPdfImportSheet extends StatefulWidget {
  const _BookPdfImportSheet({required this.file, required this.books});

  final PlatformFile file;
  final List<BookLibraryItem> books;

  @override
  State<_BookPdfImportSheet> createState() => _BookPdfImportSheetState();
}

class _BookPdfImportSheetState extends State<_BookPdfImportSheet> {
  int? _selectedBookId;

  @override
  void initState() {
    super.initState();
    _selectedBookId = widget.books.isEmpty ? null : widget.books.first.book.id;
  }

  Future<void> _createNewBook() async {
    final selected = await showModalBottomSheet<BookRecord>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Material(
        color: BookFlowTheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: BookMetadataFormSheet(
          initial: BookRecord(
            title: _suggestedTitle(widget.file.name),
            source: 'local_${inferBookSourceFormat(widget.file.name)}',
            isCustom: true,
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    Navigator.of(context).pop(BookPdfImportSelection.newBook(selected));
  }

  @override
  Widget build(BuildContext context) => Material(
    color: BookFlowTheme.surface,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
    clipBehavior: Clip.antiAlias,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: BookFlowTheme.lineStrong,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const Text('添加到阅读空间', style: BookFlowTheme.heading),
              const SizedBox(height: 16),
              _PdfFileCard(
                file: widget.file,
                onReselect: () => Navigator.of(
                  context,
                ).pop(const BookPdfImportSelection.reselect()),
              ),
              const SizedBox(height: 12),
              if (widget.books.isNotEmpty) ...[
                _ImportChoiceCard(
                  selected: _selectedBookId != null,
                  onTap: () {
                    if (_selectedBookId == null) return;
                    Navigator.of(
                      context,
                    ).pop(BookPdfImportSelection.existing(_selectedBookId!));
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const _ChoiceIcon(icon: Icons.menu_book_rounded),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text('关联已有书籍', style: _bookCardTitle),
                          ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: BookFlowTheme.warning,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              child: Text(
                                '推荐',
                                style: TextStyle(
                                  color: BookFlowTheme.ink,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.only(left: 52),
                        child: Text(
                          '把这份 ${_formatLabel(widget.file.name)} 加到已经创建的书中',
                          style: BookFlowTheme.caption,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ...widget.books.take(2).map(_BookChoiceRow.new),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              _ImportChoiceCard(
                onTap: _createNewBook,
                child: const Row(
                  children: [
                    _ChoiceIcon(icon: Icons.note_add_rounded),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('创建新书并关联', style: _bookCardTitle),
                          SizedBox(height: 4),
                          Text(
                            '没有对应书籍？用这份资料创建一本新书',
                            style: BookFlowTheme.caption,
                          ),
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
              const SizedBox(height: 14),
              const Row(
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    size: 20,
                    color: BookFlowTheme.inkSecondary,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '文件将保存在本机；解析失败不会删除原文件',
                      style: BookFlowTheme.caption,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ImportChoiceCard extends StatelessWidget {
  const _ImportChoiceCard({
    required this.child,
    this.onTap,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? BookFlowTheme.ochreSoft : BookFlowTheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(
        color: selected ? BookFlowTheme.warning : BookFlowTheme.line,
        width: selected ? 1.5 : 1,
      ),
    ),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );
}

class _PdfFileCard extends StatelessWidget {
  const _PdfFileCard({required this.file, required this.onReselect});

  final PlatformFile file;
  final VoidCallback onReselect;

  @override
  Widget build(BuildContext context) {
    final format = inferBookSourceFormat(file.name);
    final formatLabel = _formatLabel(file.name);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: BookFlowTheme.primarySoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: format == 'epub'
                    ? const Color(0xFF4E6DD8)
                    : const Color(0xFFE84444),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SizedBox(
                width: 48,
                height: 58,
                child: Center(
                  child: Text(
                    formatLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
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
                  Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _bookCardTitle,
                  ),
                  const SizedBox(height: 4),
                  Text(_formatBytes(file.size), style: BookFlowTheme.caption),
                ],
              ),
            ),
            TextButton(onPressed: onReselect, child: const Text('重新选择')),
          ],
        ),
      ),
    );
  }
}

String _formatLabel(String fileName) =>
    inferBookSourceFormat(fileName).toUpperCase();

class _ChoiceIcon extends StatelessWidget {
  const _ChoiceIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: BookFlowTheme.surfaceSoft,
      shape: BoxShape.circle,
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Icon(icon, color: BookFlowTheme.ink, size: 23),
    ),
  );
}

class _BookChoiceRow extends StatelessWidget {
  const _BookChoiceRow(this.item);

  final BookLibraryItem item;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: BookFlowTheme.surface,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        SizedBox(width: 44, height: 60, child: BookCover(book: item.book)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.book.title, style: _bookCardTitle),
              const SizedBox(height: 3),
              Text(
                item.book.metadataLabel.isEmpty
                    ? '资料 ${item.recognizedPageCount + item.noteCount} 条'
                    : item.book.metadataLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: BookFlowTheme.caption,
              ),
            ],
          ),
        ),
        const Icon(
          Icons.chevron_right_rounded,
          color: BookFlowTheme.inkSecondary,
        ),
      ],
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _suggestedTitle(String fileName) {
  final withoutExtension = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
  return withoutExtension.trim().isEmpty ? '待确认书籍' : withoutExtension.trim();
}

const _bookCardTitle = TextStyle(
  color: BookFlowTheme.ink,
  fontSize: 15,
  height: 1.3,
  fontWeight: FontWeight.w700,
);
