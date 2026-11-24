part of 'reflow_document_pager.dart';

/// A single replaceable horizontal layout for this source and current text
/// settings. The file references immutable source blocks and holds no assets.
Future<_PaginationPublish?> _loadReaderLayout(
  File file,
  String key,
  XiaoqiDocument document,
  _PageYieldGate gate, {
  required bool epub,
}) async {
  try {
    const maxLayoutBytes = 16 * 1024 * 1024;
    if (await file.length() > maxLayoutBytes || gate.cancelled) return null;
    final data = await _readLayoutRows(file.path);
    if (data['layout'] != key || gate.cancelled) return null;
    final chapters = {
      for (final chapter in document.chapters) chapter.id: chapter,
    };
    final pdfChapter = epub ? null : document.chapters.single;
    final blocksByChapter = <String, Map<String, XiaoqiDocumentBlock>>{};
    final tableRows = <XiaoqiDocumentBlock, List<List<String>>?>{};
    final pages = <ReaderPageSlice>[];
    final chapterFirstPages = <String, int>{};
    for (final row in data['pages'] as List) {
      if (pages.isNotEmpty && pages.length % 128 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (gate.cancelled) return null;
      }
      final chapter = pdfChapter ?? chapters[row[3]]!;
      final blocks = blocksByChapter.putIfAbsent(chapter.id, () {
        if (chapter.blocks.isEmpty) {
          final block = _plainChapterBlock(chapter);
          return {block.id: block};
        }
        return {for (final block in chapter.blocks) block.id: block};
      });
      final parts = <ReaderBlockSlice>[];
      for (final fragment in row[2] as List) {
        final block = blocks[fragment[0]]!;
        final start = fragment[1] as int;
        final end = fragment[2] as int?;
        final rows = epub && fragment.length > 3 && fragment[3] == true
            ? tableRows
                  .putIfAbsent(block, () => _decodeTableRows(block))!
                  .sublist(start, end!)
            : null;
        parts.add(
          ReaderBlockSlice(
            chapterId: chapter.id,
            block: block,
            text: rows != null || end == null
                ? block.text
                : block.text.substring(start, end),
            startOffset: start,
            endOffset: end,
            tableRows: rows,
            continuation: start > 0,
          ),
        );
      }
      chapterFirstPages.putIfAbsent(chapter.id, () => pages.length);
      pages.add(
        ReaderPageSlice(
          chapterId: chapter.id,
          chapterTitle: epub ? row[5] as String : chapter.title,
          showChapterTitle: epub && row[4] as bool,
          originalPageLabel: row[0] as String?,
          mayOverflow: row[1] as bool,
          blocks: parts,
        ),
      );
    }
    if (pages.isEmpty || chapterFirstPages.length != chapters.length) {
      return null;
    }
    return _PaginationPublish(
      pages: pages,
      chapterFirstPages: chapterFirstPages,
      complete: true,
    );
  } on Object {
    // A changed or damaged cache can always be regenerated from the source.
    return null;
  }
}

// Keep the isolate closure apart from the document and the widget's epoch
// predicate. Neither the parsed book's assets nor widget state cross isolates.
Future<Map> _readLayoutRows(String path) =>
    Isolate.run(() async => jsonDecode(await File(path).readAsString()) as Map);

Future<void> _saveReaderLayout(
  File file,
  String key,
  List<ReaderPageSlice> pages, {
  required bool epub,
}) async {
  final staging = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    final encoded = await Isolate.run(
      () => jsonEncode({
        'layout': key,
        'pages': [
          for (final page in pages)
            [
              page.originalPageLabel,
              page.mayOverflow,
              [
                for (final slice in page.blocks)
                  [
                    slice.block.id,
                    slice.startOffset,
                    slice.endOffset,
                    if (epub && slice.tableRows != null) true,
                  ],
              ],
              if (epub) ...[
                page.chapterId,
                page.showChapterTitle,
                page.chapterTitle,
              ],
            ],
        ],
      }),
    );
    await file.parent.create(recursive: true);
    await staging.writeAsString(encoded);
    await staging.rename(file.path);
  } on Object {
    // The active layout is already complete; recompute on a later cold open.
  } finally {
    try {
      if (await staging.exists()) await staging.delete();
    } on FileSystemException {
      // A later cache cleanup can remove unused staging files.
    }
  }
}
