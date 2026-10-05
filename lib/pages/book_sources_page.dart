import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../config/book_flow_theme.dart';
import '../models/book_source.dart';
import '../models/xiaoqi_document.dart';
import '../services/book_library_service.dart';
import '../services/epub_document_service.dart';
import '../services/pdf_catalog_service.dart';
import '../services/source_document_loader.dart';
import '../widgets/app_toast.dart';
import '../widgets/book_paper_background.dart';

enum _SourceAction { move, share, remove, deleteFile }

class BookSourcesPage extends StatefulWidget {
  const BookSourcesPage({
    super.key,
    required this.bookId,
    required this.bookTitle,
    required this.bookLibraryService,
  });

  final int bookId;
  final String bookTitle;
  final BookLibraryService bookLibraryService;

  @override
  State<BookSourcesPage> createState() => _BookSourcesPageState();
}
class _BookSourcesPageState extends State<BookSourcesPage> {
  List<BookSourceRecord> _sources = const [];
  bool _loading = true;
  bool _importing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    try {
      var sources = await widget.bookLibraryService.listSourcesForBook(
        widget.bookId,
      );
      BookSourceRecord? fallback;
      for (final source in sources) {
        if (File(source.filePath).existsSync()) {
          fallback = source;
          break;
        }
      }
      if (fallback != null && !sources.any((source) => source.isPrimary)) {
        await widget.bookLibraryService.setPrimaryBookSource(
          sourceId: fallback.id,
          bookId: widget.bookId,
        );
        sources = await widget.bookLibraryService.listSourcesForBook(
          widget.bookId,
        );
      }
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '资料暂时无法加载：$error';
      });
    }
  }

  Future<void> _setPrimarySource(BookSourceRecord source) async {
    if (!await File(source.filePath).exists()) {
      _showMessage('找不到这份资料文件，请重新导入');
      return;
    }
    if (source.isPrimary) {
      _showMessage('这份资料已是主资料');
      return;
    }
    try {
      await widget.bookLibraryService.setPrimaryBookSource(
        sourceId: source.id,
        bookId: widget.bookId,
      );
      await _loadSources();
      if (mounted) _showMessage('已设为主资料：${source.displayName}');
    } catch (error) {
      if (mounted) _showMessage('切换主资料失败：$error');
    }
  }

  Future<void> _importBookSource() async {
    if (_importing) return;
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedBookSourceFileExtensions,
      withData: true,
    );
    if (!mounted || result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final format = inferBookSourceFormat(file.name);
    if (!supportedBookSourceFormats.contains(format)) {
      _showMessage('目前支持导入 PDF 或 EPUB 文件');
      return;
    }
    setState(() => _importing = true);
    try {
      final sourcePath = await _ensurePickedFilePath(file);
      final outcome = await widget.bookLibraryService.importBookSourceForBook(
        bookId: widget.bookId,
        sourcePath: sourcePath,
        displayName: file.name,
        format: format,
      );
      if (format == 'pdf' &&
          outcome.source.catalogStatus != 'processing' &&
          outcome.source.catalogStatus != 'confirmed' &&
          (outcome.source.catalogParserVersion <
                  PdfCatalogService.parserVersion ||
              outcome.source.catalogStatus == 'not_started' ||
              outcome.source.catalogStatus == 'failed')) {
        unawaited(
          widget.bookLibraryService.parsePdfCatalogForSource(outcome.source),
        );
      }
      await _loadSources();
      if (outcome.reusedExisting && mounted) {
        _showDuplicateNotice();
      }
    } catch (error) {
      if (mounted) _showMessage('资料导入失败：$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<String> _ensurePickedFilePath(PlatformFile file) async {
    final existingPath = file.path;
    if (existingPath != null &&
        existingPath.trim().isNotEmpty &&
        await File(existingPath).exists()) {
      return existingPath;
    }
    final bytes = file.bytes;
    if (bytes == null) throw StateError('无法读取选中的文件');
    final temporary = await getTemporaryDirectory();
    final fallback = File(p.join(temporary.path, file.name));
    await fallback.writeAsBytes(bytes, flush: true);
    return fallback.path;
  }

  Future<void> _openSource(BookSourceRecord source) async {
    final file = File(source.filePath);
    if (!await file.exists()) {
      if (mounted) _showMessage('找不到这份资料文件，请重新导入');
      return;
    }
    if (!mounted) return;
    final reader = source.format == 'epub'
        ? EpubSourceReaderPage(
            source: source,
            bookLibraryService: widget.bookLibraryService,
          )
        : SourceDocumentLoader.isStructuredFormat(source.format)
        ? TextSourceReaderPage(
            source: source,
            bookLibraryService: widget.bookLibraryService,
          )
        : _PdfSourceReaderPage(source: source);
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => reader));
  }

  Future<void> _handleSourceAction(
    BookSourceRecord source,
    _SourceAction action,
  ) async {
    switch (action) {
      case _SourceAction.move:
        await _moveOrShareSource(source, move: true);
      case _SourceAction.share:
        await _moveOrShareSource(source, move: false);
      case _SourceAction.remove:
        await _removeSource(source);
      case _SourceAction.deleteFile:
        await _deleteSourceFile(source);
    }
  }

  Future<void> _moveOrShareSource(
    BookSourceRecord source, {
    required bool move,
  }) async {
    final targetBookId = await _chooseTargetBook();
    if (!mounted || targetBookId == null) return;
    try {
      if (move) {
        await widget.bookLibraryService.moveBookSource(
          sourceId: source.id,
          currentBookId: widget.bookId,
          targetBookId: targetBookId,
        );
      } else {
        await widget.bookLibraryService.shareBookSource(
          sourceId: source.id,
          currentBookId: widget.bookId,
          targetBookId: targetBookId,
        );
      }
      await _loadSources();
      if (mounted) _showMessage(move ? '资料已移动' : '资料已共享到目标书籍');
    } catch (error) {
      if (mounted) _showMessage('资料操作失败：$error');
    }
  }

  Future<int?> _chooseTargetBook() async {
    final books = (await widget.bookLibraryService.listBooks())
        .where((item) => item.book.id != widget.bookId)
        .toList(growable: false);
    if (!mounted) return null;
    if (books.isEmpty) {
      _showMessage('暂时没有其他书籍可以选择');
      return null;
    }
    return showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Material(
        color: BookFlowTheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            children: [
              const Text('选择目标书籍', style: BookFlowTheme.heading),
              const SizedBox(height: 12),
              for (final item in books)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.book.title),
                  subtitle: Text(
                    item.book.metadataLabel.isEmpty
                        ? '暂无作者信息'
                        : item.book.metadataLabel,
                    style: BookFlowTheme.caption,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(sheetContext).pop(item.book.id),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _removeSource(BookSourceRecord source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从本书移除？'),
        content: const Text('只会解除这本书的资料关联，原文件仍会保留。'),
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
    if (!mounted || confirmed != true) return;
    try {
      await widget.bookLibraryService.removeBookSource(
        sourceId: source.id,
        bookId: widget.bookId,
      );
      await _loadSources();
      if (mounted) _showMessage('已从本书移除，文件仍保留');
    } catch (error) {
      if (mounted) _showMessage('移除资料失败：$error');
    }
  }

  Future<void> _deleteSourceFile(BookSourceRecord source) async {
    final linkedBooks = await widget.bookLibraryService.listBooksForSource(
      source,
    );
    if (!mounted) return;
    final names = linkedBooks.map((book) => '《${book.title}》').join('、');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('彻底删除这份资料？'),
        content: Text(
          '删除后，${source.displayName} 会从 $names 的资料列表中消失。\n\n'
          '已有笔记不会自动删除；如果仍有笔记引用原文件，为保护这些笔记，文件只会解除关联而不会物理删除。这个操作不能撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB34A42),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      final fileDeleted = await widget.bookLibraryService.deleteBookSourceFile(
        sourceId: source.id,
        bookId: widget.bookId,
      );
      await _loadSources();
      if (mounted) {
        _showMessage(
          fileDeleted
              ? '资料文件已删除，已有笔记保留'
              : '资料记录已移除；原文件未删除（仍被笔记引用或文件已不存在）',
        );
      }
    } catch (error) {
      if (mounted) _showMessage('删除资料失败：$error');
    }
  }

  void _showMessage(String message) {
    AppToast.show(context, message);
  }

  void _showDuplicateNotice() {
    AppToast.show(context, '这份资料已经在本书资料中，不会重复添加');
  }

  @override
  Widget build(BuildContext context) => BookPaperBackground(
    showBotanicalShadow: true,
    warmEditorial: true,
    child: SafeArea(
      bottom: false,
      child: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildContent()),
        ],
      ),
    ),
  );

  Widget _buildHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
    child: Row(
      children: [
        _SourcesIconButton(
          tooltip: '返回书籍详情',
          icon: Icons.chevron_left_rounded,
          onTap: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '本书资料',
            style: BookFlowTheme.heading.copyWith(fontSize: 20),
          ),
        ),
        TextButton.icon(
          onPressed: _importing ? null : _importBookSource,
          icon: _importing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_circle_outline_rounded, size: 20),
          label: const Text('导入资料'),
          style: TextButton.styleFrom(
            foregroundColor: BookFlowTheme.detailPrimary,
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );

  Widget _buildContent() {
    if (_loading) {
      return const SizedBox.shrink();
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 42),
              const SizedBox(height: 10),
              Text(
                _error!,
                style: BookFlowTheme.body,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _loadSources, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_sources.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
        children: [_EmptySources(onImport: _importBookSource)],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
      itemCount: _sources.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index == _sources.length) {
          return _SourcesFootnote(bookTitle: widget.bookTitle);
        }
        final source = _sources[index];
        return _SourceCard(
          source: source,
          onTap: () => _openSource(source),
          onSelectSource: () => _setPrimarySource(source),
          onAction: (action) => _handleSourceAction(source, action),
        );
      },
    );
  }
}
class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.source,
    required this.onTap,
    required this.onSelectSource,
    required this.onAction,
  });

  final BookSourceRecord source;
  final VoidCallback onTap;
  final VoidCallback onSelectSource;
  final ValueChanged<_SourceAction> onAction;

  @override
  Widget build(BuildContext context) => Material(
    color: BookFlowTheme.surface,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          children: [
            Row(
              children: [
                _SourceFormatBadge(format: source.format),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(source.displayName, style: _sourceTitle),
                      const SizedBox(height: 4),
                      Text(
                        source.isPrimary
                            ? '主资料 · ${_formatBytes(source.fileSize)} · ${_statusLabel(source.status)}'
                            : '${_formatBytes(source.fileSize)} · ${_statusLabel(source.status)}',
                        style: const TextStyle(
                          color: BookFlowTheme.detailPrimary,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                      if (source.originUri.trim().isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          source.originUri,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: BookFlowTheme.inkSecondary,
                            fontSize: 12,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<_SourceAction>(
                  tooltip: '资料操作',
                  onSelected: (action) {
                    onAction(action);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: _SourceAction.move,
                      child: Text('移动到其他书籍'),
                    ),
                    const PopupMenuItem(
                      value: _SourceAction.share,
                      child: Text('共享到其他书籍'),
                    ),
                    const PopupMenuItem(
                      value: _SourceAction.remove,
                      child: Text('从本书移除'),
                    ),
                    const PopupMenuItem(
                      value: _SourceAction.deleteFile,
                      child: Text('彻底删除文件'),
                    ),
                  ],
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    color: BookFlowTheme.inkSecondary,
                  ),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1, color: BookFlowTheme.line),
            ),
            Row(
              children: [
                const Icon(
                  Icons.menu_book_outlined,
                  color: BookFlowTheme.inkSecondary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    source.status == 'ready'
                        ? '最近阅读：尚未开始阅读'
                        : '资料状态：${_statusLabel(source.status)}',
                    style: BookFlowTheme.caption,
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: onSelectSource,
                      icon: Icon(
                        source.isPrimary
                            ? Icons.check_circle_rounded
                            : Icons.swap_horiz_rounded,
                        size: 18,
                        color: source.isPrimary
                            ? const Color(0xFF2F8F55)
                            : null,
                      ),
                      label: Text(source.isPrimary ? '主资料' : '设为主资料'),
                      style: TextButton.styleFrom(
                        foregroundColor: BookFlowTheme.inkSecondary,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 44),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _EmptySources extends StatelessWidget {
  const _EmptySources({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 34),
    decoration: BoxDecoration(
      color: BookFlowTheme.surface.withValues(alpha: .58),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: BookFlowTheme.detailLineStrong),
    ),
    child: Column(
      children: [
        const Icon(
          Icons.description_outlined,
          size: 34,
          color: BookFlowTheme.inkSecondary,
        ),
        const SizedBox(height: 10),
        const Text('还没有导入资料', style: _sourceTitle),
        const SizedBox(height: 5),
        const Text(
          '导入 PDF 或 EPUB 后，可以在这里查看资料。',
          style: BookFlowTheme.caption,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: onImport,
          icon: const Icon(Icons.add_rounded),
          label: const Text('导入资料'),
          style: BookFlowTheme.primaryButtonStyle(),
        ),
      ],
    ),
  );
}

class _SourcesFootnote extends StatelessWidget {
  const _SourcesFootnote({required this.bookTitle});

  final String bookTitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
    child: Text(
      '资料属于《$bookTitle》，同一份文件可以被多个学习空间引用。',
      style: BookFlowTheme.caption,
      textAlign: TextAlign.center,
    ),
  );
}

class _SourceFormatBadge extends StatelessWidget {
  const _SourceFormatBadge({required this.format});

  final String format;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _sourceFormatColor(format),
      borderRadius: BorderRadius.circular(9),
    ),
    child: SizedBox(
      width: 48,
      height: 58,
      child: Center(
        child: Text(
          _sourceFormatLabel(format),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    ),
  );
}

class _SourcesIconButton extends StatelessWidget {
  const _SourcesIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: tooltip,
    child: IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 28),
      color: BookFlowTheme.detailPrimary,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    ),
  );
}

class _PdfSourceReaderPage extends StatefulWidget {
  const _PdfSourceReaderPage({required this.source});

  final BookSourceRecord source;

  @override
  State<_PdfSourceReaderPage> createState() => _PdfSourceReaderPageState();
}

class _PdfSourceReaderPageState extends State<_PdfSourceReaderPage> {
  late final PdfViewerController _controller;
  int _page = 1;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller = PdfViewerController();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BookFlowTheme.detailCanvas,
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: [
                _SourcesIconButton(
                  tooltip: '返回本书资料',
                  icon: Icons.chevron_left_rounded,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.source.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BookFlowTheme.heading,
                  ),
                ),
                Text('第 $_page 页', style: BookFlowTheme.caption),
              ],
            ),
          ),
          Expanded(
            child: _error == null
                ? PdfViewer.file(
                    widget.source.filePath,
                    controller: _controller,
                    params: PdfViewerParams(
                      onPageChanged: (page) {
                        if (page != null && mounted) {
                          setState(() => _page = page);
                        }
                      },
                      loadingBannerBuilder: (_, _, _) =>
                          const _ReaderPlaceholder(text: '资料正在打开'),
                      errorBannerBuilder: (_, error, _, _) =>
                          _ReaderError(error: error),
                    ),
                  )
                : _ReaderError(error: _error!),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('回到书籍详情'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

}

class EpubSourceReaderPage extends StatefulWidget {
  const EpubSourceReaderPage({required this.source, this.bookLibraryService});

  final BookSourceRecord source;
  final BookLibraryService? bookLibraryService;

  @override
  State<EpubSourceReaderPage> createState() => _EpubSourceReaderPageState();
}

class _EpubSourceReaderPageState extends State<EpubSourceReaderPage> {
  late final Future<XiaoqiDocument> _documentFuture;

  @override
  void initState() {
    super.initState();
    _documentFuture = _loadDocument();
  }

  Future<XiaoqiDocument> _loadDocument() async {
    final revision = await widget.bookLibraryService?.loadBookSourceRevision(
      widget.source,
    );
    return revision ??
        await EpubDocumentService().parseFile(widget.source.filePath);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BookFlowTheme.detailCanvas,
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: [
                _SourcesIconButton(
                  tooltip: '返回本书资料',
                  icon: Icons.chevron_left_rounded,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.source.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BookFlowTheme.heading,
                  ),
                ),
                const _SourceFormatBadge(format: 'epub'),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<XiaoqiDocument>(
              future: _documentFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const _ReaderPlaceholder(text: '正在整理 EPUB 章节');
                }
                if (snapshot.hasError || snapshot.data == null) {
                  return _ReaderError(
                    error: snapshot.error ?? '未读取到 EPUB 内容',
                    format: 'epub',
                  );
                }
                return _EpubDocumentView(document: snapshot.data!);
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class _EpubDocumentView extends StatelessWidget {
  const _EpubDocumentView({required this.document});

  final XiaoqiDocument document;

  @override
  Widget build(BuildContext context) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
    itemCount: document.chapters.length + 1,
    separatorBuilder: (_, _) => const SizedBox(height: 12),
    itemBuilder: (context, index) {
      if (index == 0) {
        return _EpubDocumentHeader(document: document);
      }
      final chapter = document.chapters[index - 1];
      return Card(
        margin: EdgeInsets.zero,
        color: BookFlowTheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ExpansionTile(
          initiallyExpanded: index == 1,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          title: Text(chapter.title, style: _sourceTitle),
          subtitle: Text('第 ${index} 节', style: BookFlowTheme.caption),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                chapter.plainText,
                style: BookFlowTheme.body,
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _EpubDocumentHeader extends StatelessWidget {
  const _EpubDocumentHeader({required this.document});

  final XiaoqiDocument document;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
    decoration: BoxDecoration(
      color: BookFlowTheme.surface,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          document.title.isEmpty
              ? '${document.format == 'markdown' ? 'Markdown' : document.format.toUpperCase()} 资料'
              : document.title,
          style: BookFlowTheme.heading.copyWith(fontSize: 21),
        ),
        if (document.author.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(document.author, style: BookFlowTheme.caption),
        ],
        const SizedBox(height: 10),
        Text(
          '已读取 ${document.chapters.length} 个章节',
          style: BookFlowTheme.caption,
        ),
      ],
    ),
  );
}

class _ReaderPlaceholder extends StatelessWidget {
  const _ReaderPlaceholder({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: BookFlowTheme.detailCanvas,
    child: Center(child: Text(text, style: BookFlowTheme.caption)),
  );
}

class _ReaderError extends StatelessWidget {
  const _ReaderError({required this.error, this.format = 'pdf'});

  final Object error;
  final String format;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            format == 'epub'
                ? Icons.menu_book_outlined
                : format == 'pdf'
                ? Icons.picture_as_pdf_outlined
                : Icons.description_outlined,
            size: 42,
          ),
          const SizedBox(height: 12),
          Text(
            '这份 ${_sourceFormatLabel(format)} 资料暂时打不开',
            style: _sourceTitle,
          ),
          const SizedBox(height: 6),
          Text(
            '$error',
            style: BookFlowTheme.caption,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

const _sourceTitle = TextStyle(
  color: BookFlowTheme.ink,
  fontSize: 16,
  height: 1.3,
  fontWeight: FontWeight.w700,
);

String _statusLabel(String status) {
  switch (status) {
    case 'ready':
      return '可阅读';
    case 'processing':
      return '准备中';
    case 'failed':
      return '处理失败';
    case 'partial':
      return '部分可用';
    default:
      return '已导入';
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class TextSourceReaderPage extends StatefulWidget {
  const TextSourceReaderPage({required this.source, this.bookLibraryService});

  final BookSourceRecord source;
  final BookLibraryService? bookLibraryService;

  @override
  State<TextSourceReaderPage> createState() => _TextSourceReaderPageState();
}

class _TextSourceReaderPageState extends State<TextSourceReaderPage> {
  late final Future<XiaoqiDocument> _documentFuture;

  @override
  void initState() {
    super.initState();
    _documentFuture = _loadDocument();
  }

  Future<XiaoqiDocument> _loadDocument() async {
    final revision = await widget.bookLibraryService?.loadBookSourceRevision(
      widget.source,
    );
    final loader = const SourceDocumentLoader();
    return revision ??
        await loader.parseFile(
          widget.source.filePath,
          format: widget.source.format,
        );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BookFlowTheme.detailCanvas,
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: [
                _SourcesIconButton(
                  tooltip: '返回本书资料',
                  icon: Icons.chevron_left_rounded,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.source.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BookFlowTheme.heading,
                  ),
                ),
                _SourceFormatBadge(format: widget.source.format),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<XiaoqiDocument>(
              future: _documentFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const _ReaderPlaceholder(text: '正在整理文档内容');
                }
                if (snapshot.hasError || snapshot.data == null) {
                  return _ReaderError(
                    error: snapshot.error ?? '未读取到文档内容',
                    format: widget.source.format,
                  );
                }
                return _EpubDocumentView(document: snapshot.data!);
              },
            ),
          ),
        ],
      ),
    ),
  );
}

String _sourceFormatLabel(String format) =>
    format == 'markdown' ? 'MD' : format.toUpperCase();

Color _sourceFormatColor(String format) {
  switch (format) {
    case 'epub':
      return const Color(0xFF4E6DD8);
    case 'markdown':
      return const Color(0xFF6956B8);
    case 'txt':
      return const Color(0xFF5F6B73);
    case 'docx':
      return const Color(0xFF2B579A);
    case 'html':
      return const Color(0xFF2F8F76);
    default:
      return const Color(0xFFE84444);
  }
}
