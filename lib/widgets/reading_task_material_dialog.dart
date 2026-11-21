import 'dart:io';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';
import '../models/book_library_item.dart';
import '../models/book_source.dart';
import '../services/book_library_service.dart';
import 'book_cover.dart';
import 'book_editor_dialog.dart';
import 'book_import_progress.dart';
import 'book_source_import.dart';

Future<void> showReadingTaskMaterialsDialog(
  BuildContext context, {
  required BookLibraryItem book,
  required BookLibraryService library,
  required int bookId,
  required int? sourceId,
  required Future<void> Function(int) onSelect,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x40000000),
  builder: (_) => _ReadingTaskMaterialsDialog(
    book: book,
    library: library,
    bookId: bookId,
    sourceId: sourceId,
    onSelect: onSelect,
  ),
);

class _ReadingTaskMaterialsDialog extends StatefulWidget {
  const _ReadingTaskMaterialsDialog({
    required this.book,
    required this.library,
    required this.bookId,
    required this.sourceId,
    required this.onSelect,
  });

  final BookLibraryItem book;
  final BookLibraryService library;
  final int bookId;
  final int? sourceId;
  final Future<void> Function(int) onSelect;

  @override
  State<_ReadingTaskMaterialsDialog> createState() =>
      _ReadingTaskMaterialsDialogState();
}

class _ReadingTaskMaterialsDialogState
    extends State<_ReadingTaskMaterialsDialog> {
  late Future<List<BookSourceRecord>> _sources;
  int? _selectedSourceId;
  bool _busy = false;
  bool _importing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedSourceId = widget.sourceId;
    _sources = _loadSources();
  }

  Future<List<BookSourceRecord>> _loadSources() =>
      widget.library.listSourcesForBook(widget.bookId);

  bool _canSelect(BookSourceRecord source) =>
      supportedBookSourceFormats.contains(source.format) &&
      source.status == 'ready';

  void _close() {
    if (ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
  }

  Future<void> _commit(BookSourceRecord source) async {
    if (!_isCurrent) return;
    final sources = await _loadSources();
    final current = sources.where((item) => item.id == source.id).firstOrNull;
    if (current == null ||
        !_canSelect(current) ||
        !await File(current.filePath).exists()) {
      throw const FormatException('这份资料暂不可用，请重新导入');
    }
    if (!_isCurrent) return;
    await widget.onSelect(current.id);
    if (!_isCurrent) return;
    setState(() {
      _selectedSourceId = current.id;
      _sources = SynchronousFuture(sources);
    });
  }

  bool get _isCurrent => mounted && ModalRoute.of(context)?.isCurrent == true;

  Future<void> _run(Future<BookSourceRecord?> Function() selectSource) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final source = await selectSource();
      if (mounted && source != null) await _commit(source);
    } catch (error) {
      if (mounted) {
        setState(() {
          _sources = _loadSources();
          _error = error is FormatException ? error.message : '关联资料失败，请重试';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _importing = false;
        });
      }
    }
  }

  Future<void> _import() => _run(() async {
    final imported = await showExistingBookSourceImport(
      context,
      bookId: widget.bookId,
      library: widget.library,
      bookTitle: widget.book.book.title,
      onImporting: () {
        if (mounted) setState(() => _importing = true);
      },
    );
    return imported?.source;
  });

  Widget _buildSources(AsyncSnapshot<List<BookSourceRecord>> snapshot) {
    if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
      return const SizedBox(height: 56);
    }
    if (snapshot.hasError) {
      return TextButton(
        onPressed: () => setState(() {
          _sources = _loadSources();
        }),
        child: const Text('读取资料失败，点击重试'),
      );
    }
    final sources = snapshot.data ?? const <BookSourceRecord>[];
    if (sources.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('还没有导入资料', style: BookFlowTheme.body),
      );
    }
    final usable = sources.where(_canSelect).toList(growable: false);
    final selectedId = _selectedSourceId ?? usable.singleOrNull?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_selectedSourceId == null && usable.length > 1)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text('当前使用本书的全部可用资料', style: BookFlowTheme.body),
          ),
        if (_selectedSourceId != null &&
            !sources.any((source) => source.id == _selectedSourceId))
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('已关联的资料已移除', style: BookFlowTheme.body),
          ),
        for (final source in sources)
          _sourceRow(
            source,
            selected: source.id == selectedId,
            selectable: !_busy && source.id != selectedId && _canSelect(source),
          ),
      ],
    );
  }

  Widget _sourceRow(
    BookSourceRecord source, {
    required bool selected,
    required bool selectable,
  }) => Semantics(
    selected: selected,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        minTileHeight: 56,
        minLeadingWidth: 26,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        tileColor: selected ? const Color(0xFFF2F2F2) : Colors.transparent,
        leading: bookEditorIcon('file', size: 22),
        title: Text(
          source.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: BookFlowTheme.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          _canSelect(source)
              ? source.format.toUpperCase()
              : '${source.format.toUpperCase()} · 暂不可用',
          style: BookFlowTheme.body,
        ),
        trailing: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected || selectable
              ? BookFlowTheme.ink
              : BookFlowTheme.muted,
          size: 22,
        ),
        onTap: selectable ? () => _run(() async => source) : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: BookFlowTheme.surface,
    surfaceTintColor: Colors.transparent,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('关联资料', style: BookFlowTheme.heading),
                ),
                IconButton(
                  tooltip: '关闭关联资料',
                  onPressed: _busy ? null : _close,
                  icon: bookEditorIcon('close', size: 18),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    height: 50,
                    child: BookCover(
                      book: widget.book.book,
                      borderRadius: 4,
                      builtInSpineShading: false,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.book.book.title,
                      style: const TextStyle(
                        color: BookFlowTheme.ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFFDDE0E4)),
            FutureBuilder(
              future: _sources,
              builder: (_, snapshot) {
                return _buildSources(snapshot);
              },
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  error,
                  style: const TextStyle(color: BookFlowTheme.danger),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _import,
              style: FilledButton.styleFrom(
                backgroundColor: BookFlowTheme.ink,
                foregroundColor: Colors.white,
                // Source selection also locks the button. Only importing changes its colors.
                disabledBackgroundColor: _importing
                    ? const Color(0xFFE5E5E5)
                    : BookFlowTheme.ink,
                disabledForegroundColor: _importing
                    ? BookFlowTheme.inkSecondary
                    : Colors.white,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: _importing
                  ? const BookImportProgress()
                  : const Icon(Icons.add, size: 18),
              label: Text(_importing ? bookImportInProgressLabel : '导入资料'),
            ),
          ],
        ),
      ),
    ),
  );
}
