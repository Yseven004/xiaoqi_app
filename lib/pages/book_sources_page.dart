import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:pdfrx/pdfrx.dart';

import '../config/book_flow_theme.dart';
import '../models/book_source.dart';
import '../models/xiaoqi_document.dart';
import '../services/book_library_service.dart';
import '../services/epub_document_service.dart';
import '../services/source_document_loader.dart';
import '../widgets/app_toast.dart';
import '../widgets/book_editor_dialog.dart';
import '../widgets/book_source_import.dart';

enum _SourceAction { setPrimary, move, share, remove, deleteFile }

class BookSourcesPage extends StatefulWidget {
  const BookSourcesPage({
    super.key,
    required this.bookId,
    required this.bookLibraryService,
  });

  final int bookId;
  final BookLibraryService bookLibraryService;

  @override
  State<BookSourcesPage> createState() => _BookSourcesPageState();
}

class _BookSourcesPageState extends State<BookSourcesPage> {
  List<BookSourceRecord> _sources = const [];
  bool _loading = true;
  bool _importing = false;
  bool _choosingSource = false;
  int? _editingSourceId;
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

  Future<void> _importBookSource(BuildContext anchorContext) async {
    if (_choosingSource) return;
    _choosingSource = true;
    try {
      final outcome = await showExistingBookSourceImport(
        context,
        bookId: widget.bookId,
        library: widget.bookLibraryService,
        anchorContext: anchorContext,
        onImporting: () => setState(() => _importing = true),
      );
      if (!mounted || outcome == null) return;
      await _loadSources();
      if (outcome.reusedExisting && mounted) {
        _showDuplicateNotice();
      }
    } finally {
      _choosingSource = false;
      if (mounted && _importing) setState(() => _importing = false);
    }
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
      case _SourceAction.setPrimary:
        await _setPrimarySource(source);
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

  Future<void> _renameSource(
    BookSourceRecord source,
    String displayName,
  ) async {
    await widget.bookLibraryService.renameBookSource(
      bookId: widget.bookId,
      sourceId: source.id,
      displayName: displayName,
    );
    if (mounted) await _loadSources();
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
          fileDeleted ? '资料文件已删除，已有笔记保留' : '资料记录已移除；原文件未删除（仍被笔记引用或文件已不存在）',
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
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BookFlowTheme.canvas,
    body: SafeArea(
      child: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildContent()),
        ],
      ),
    ),
  );

  Widget _buildHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 6, 24, 8),
    child: Row(
      children: [
        IconButton(
          tooltip: '返回书籍详情',
          icon: RotatedBox(
            quarterTurns: 2,
            child: bookEditorIcon('caret-right', size: 20),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '本书资料',
            style: BookFlowTheme.heading.copyWith(fontSize: 26),
          ),
        ),
        if (_sources.isNotEmpty)
          _ImportSourceButton(
            importing: _importing,
            onImport: _importBookSource,
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
      return _EmptySources(importing: _importing, onImport: _importBookSource);
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      itemCount: _sources.length,
      findChildIndexCallback: (key) {
        final index = _sources.indexWhere(
          (source) => ValueKey(source.id) == key,
        );
        return index < 0 ? null : index;
      },
      itemBuilder: (context, index) {
        final source = _sources[index];
        return _SourceRow(
          key: ValueKey(source.id),
          source: source,
          editing: _editingSourceId == source.id,
          onTap: () => _openSource(source),
          onEdit: () => setState(() => _editingSourceId = source.id),
          onRename: (name) => _renameSource(source, name),
          onFinishEditing: () {
            if (_editingSourceId == source.id) {
              setState(() => _editingSourceId = null);
            }
          },
          onAction: (action) => _handleSourceAction(source, action),
        );
      },
    );
  }
}

class _SourceRow extends StatefulWidget {
  const _SourceRow({
    super.key,
    required this.source,
    required this.editing,
    required this.onTap,
    required this.onEdit,
    required this.onRename,
    required this.onFinishEditing,
    required this.onAction,
  });

  final BookSourceRecord source;
  final bool editing;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final Future<void> Function(String) onRename;
  final VoidCallback onFinishEditing;
  final ValueChanged<_SourceAction> onAction;

  @override
  State<_SourceRow> createState() => _SourceRowState();
}

class _SourceRowState extends State<_SourceRow>
    with
        AutomaticKeepAliveClientMixin<_SourceRow>,
        WidgetsBindingObserver,
        BookEditorInputFocus<_SourceRow> {
  late final _name = TextEditingController(text: widget.source.displayName);
  final _nameFocus = FocusNode();
  bool _saving = false;
  String? _nameError;

  @override
  bool get wantKeepAlive =>
      widget.editing || _saving || _name.text != widget.source.displayName;

  @override
  Iterable<(FocusNode, TextEditingController)> get editorInputs => [
    (_nameFocus, _name),
  ];

  @override
  void didUpdateWidget(covariant _SourceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.displayName != widget.source.displayName &&
        _name.text == oldWidget.source.displayName) {
      _name.text = widget.source.displayName;
    }
    if (widget.editing && !oldWidget.editing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.editing &&
            !_saving &&
            ModalRoute.of(context)?.isCurrent == true) {
          _nameFocus.requestFocus();
        }
      });
    } else if (oldWidget.editing && !widget.editing) {
      _nameError = null;
    }
    updateKeepAlive();
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  void onEditorKeyboardDismissed(
    FocusNode focus,
    TextEditingController controller,
  ) => _leaveEditing();

  void _leaveEditing() {
    if (_saving || !widget.editing) return;
    _nameFocus.unfocus();
    if (_name.text.trim().isEmpty) _name.text = widget.source.displayName;
    widget.onFinishEditing();
  }

  Future<void> _saveName() async {
    if (_saving) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = '请输入资料名称');
      return;
    }

    _nameFocus.unfocus();
    if (name == widget.source.displayName) {
      _name.text = name;
      widget.onFinishEditing();
      return;
    }

    setState(() {
      _saving = true;
      _nameError = null;
    });
    try {
      await widget.onRename(name);
      if (!mounted) return;
      _name.text = name;
      widget.onFinishEditing();
    } catch (_) {
      if (mounted) setState(() => _nameError = '保存失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        updateKeepAlive();
      }
    }
  }

  Widget _buildTitle(BookSourceRecord source) {
    if (widget.editing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: TextField(
          controller: _name,
          focusNode: _nameFocus,
          readOnly: _saving,
          textInputAction: TextInputAction.done,
          maxLines: 1,
          style: _sourceTitle,
          decoration: InputDecoration(
            hintText: '资料名称',
            errorText: _nameError,
            errorMaxLines: 2,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFFDDE0E4)),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: BookFlowTheme.ink),
            ),
          ),
          onTapOutside: (_) => _leaveEditing(),
          onEditingComplete: _name.clearComposing,
          onSubmitted: (_) => unawaited(_saveName()),
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
        ),
      );
    }
    return Row(
      children: [
        Flexible(
          child: Text(
            source.displayName,
            style: _sourceTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: '编辑资料名称',
          onPressed: widget.onEdit,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          icon: bookEditorIcon('pencil', size: 15),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final source = widget.source;
    final metadata = [
      _formatBytes(source.fileSize),
      ?_formatSourceDate(source.createdAt),
      if (source.isPrimary) '主资料',
      if (source.status != 'ready') _statusLabel(source.status),
    ];

    return Column(
      children: [
        InkWell(
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 76),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  _SourceListFormatBadge(format: source.format),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildTitle(source),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final (index, value) in metadata.indexed)
                              Text(
                                index == 0 ? value : '· $value',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: BookFlowTheme.body,
                              ),
                          ],
                        ),
                        if (source.originUri.trim().isNotEmpty)
                          Text(
                            source.originUri,
                            style: BookFlowTheme.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  PopupMenuButton<_SourceAction>(
                    tooltip: '资料操作',
                    onSelected: widget.onAction,
                    color: BookFlowTheme.surface,
                    surfaceTintColor: Colors.transparent,
                    icon: bookEditorIcon('dots', size: 22),
                    itemBuilder: (_) => [
                      if (!source.isPrimary)
                        const PopupMenuItem(
                          value: _SourceAction.setPrimary,
                          child: Text('设为主资料'),
                        ),
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
                  ),
                ],
              ),
            ),
          ),
        ),
        const Divider(height: 1, thickness: 1, color: Color(0xFFDDE0E4)),
      ],
    );
  }
}

class _SourceListFormatBadge extends StatelessWidget {
  const _SourceListFormatBadge({required this.format});

  final String format;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 48),
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xFFF4F4F4),
      border: Border.all(color: const Color(0xFFE1E1E1)),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      _sourceFormatLabel(format),
      style: BookFlowTheme.caption.copyWith(
        color: BookFlowTheme.ink,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _EmptySources extends StatelessWidget {
  const _EmptySources({required this.importing, required this.onImport});

  final bool importing;
  final ValueChanged<BuildContext> onImport;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        (constraints.maxHeight * .11).clamp(24.0, 120.0),
        24,
        32,
      ),
      child: Center(
        child: Column(
          children: [
            bookEditorIcon('file-text', size: 64),
            const SizedBox(height: 28),
            Text(
              '还没有导入资料',
              style: BookFlowTheme.heading.copyWith(fontSize: 24),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              '支持 PDF 和 EPUB',
              style: BookFlowTheme.body.copyWith(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            _ImportSourceButton(
              importing: importing,
              onImport: onImport,
              prominent: true,
            ),
          ],
        ),
      ),
    ),
  );
}

class _ImportSourceButton extends StatelessWidget {
  const _ImportSourceButton({
    required this.importing,
    required this.onImport,
    this.prominent = false,
  });

  final bool importing;
  final ValueChanged<BuildContext> onImport;
  final bool prominent;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: importing ? null : () => onImport(context),
    icon: SvgPicture.asset(
      'assets/icons/extension_market/detail/plus-light.svg',
      width: 18,
      height: 18,
      excludeFromSemantics: true,
      colorFilter: ColorFilter.mode(
        importing ? BookFlowTheme.inkSecondary : Colors.white,
        BlendMode.srcIn,
      ),
    ),
    label: Text(
      importing ? '导入中' : '导入资料',
      style: prominent ? const TextStyle(fontSize: 16) : null,
    ),
    style: bookEditorActionStyle(
      context,
      width: prominent ? 208 : 128,
      height: prominent ? 56 : 42,
    ),
  );
}

class _SourceFormatBadge extends StatelessWidget {
  const _SourceFormatBadge({required this.format});

  final String format;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 56,
    child: Stack(
      children: [
        bookEditorIcon('file', size: 56),
        Align(
          alignment: const Alignment(0, .42),
          child: SizedBox(
            width: 29,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _sourceFormatLabel(format),
                style: const TextStyle(
                  color: BookFlowTheme.ink,
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
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
          Text('这份 ${_sourceFormatLabel(format)} 资料暂时打不开', style: _sourceTitle),
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

String? _formatSourceDate(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return null;
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${date.year}-${twoDigits(date.month)}-${twoDigits(date.day)} '
      '${twoDigits(date.hour)}:${twoDigits(date.minute)}';
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
