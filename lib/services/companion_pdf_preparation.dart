part of 'companion_pdf_reflow.dart';

/// The reader retains text and source regions. Figure pixels stay in the
/// per-source disk cache and are decoded only for visible Flutter images.
class PreparedCompanionPdf {
  PreparedCompanionPdf(this.pages, this.document, this.layoutCache);
  final File layoutCache;
  final Map<int, CompanionReflowPage> pages;
  final XiaoqiDocument document;
}

Future<PreparedCompanionPdf> _assembleBook(
  Map<int, CompanionReflowPage> pages,
  File cache,
) => Isolate.run(() => _preparedBook(pages, cache));

PreparedCompanionPdf _preparedBook(
  Map<int, CompanionReflowPage> pages,
  File cache,
) => PreparedCompanionPdf(
  pages,
  CompanionReflowPage.readingWindow(pages.values, pages.length),
  cache,
);

Future<bool> _hasCompleteManifest(File marker, int pages) async {
  try {
    final data = jsonDecode(await marker.readAsString());
    return data is Map && data['pages'] == pages;
  } on Exception {
    return false;
  }
}

final _preparingBooks = <String, Future<PreparedCompanionPdf>>{};
Future<void>? _extractionTail;
const _pdfMetadataSlice = Duration(milliseconds: 50);
final _preparationClock = Stopwatch()..start();
int _preparationResumeAt = 0;

void _deferPdfPreparation() {
  _preparationResumeAt =
      _preparationClock.elapsedMicroseconds +
      const Duration(milliseconds: 240).inMicroseconds;
}

Future<void> _waitForPdfReadingIdle() async {
  while (true) {
    final delay = _preparationResumeAt - _preparationClock.elapsedMicroseconds;
    if (delay <= 0) return;
    await Future<void>.delayed(Duration(microseconds: delay));
  }
}

Future<PreparedCompanionPdf?> _restorePreparedBook(
  String directory,
  int pageCount,
) => Isolate.run(() async {
  if (!await _hasCompleteManifest(
    File('$directory/complete.json'),
    pageCount,
  )) {
    return null;
  }
  try {
    final pages = <int, CompanionReflowPage>{};
    for (var number = 1; number <= pageCount; number++) {
      final file = File('$directory/$number.json');
      final page = await CompanionPdfReflow._decodePageCache(
        await file.readAsString(),
        file.path,
        number,
      );
      if (!page.canRead) return null;
      pages[number] = page;
    }
    return _preparedBook(pages, File('$directory/layout.json'));
  } on Object {
    // The original file can repair any missing or invalid cached page.
    return null;
  }
}, debugName: 'restore prepared PDF ebook');

Future<PreparedCompanionPdf> _prepareCompanionBook(
  CompanionPdfReflow reflow, {
  required int? loadedPageCount,
  required bool? allowsCopying,
}) {
  if (allowsCopying == false) {
    return Future.error(const FormatException('这份 PDF 限制复制内容'));
  }
  final key = reflow._cacheKey;
  final current = _preparingBooks[key];
  if (current != null) return current;
  final result =
      _restoreOrExtractBook(
        reflow,
        allowsCopying == true ? loadedPageCount : null,
      ).whenComplete(() {
        _preparingBooks.remove(key);
      });
  _preparingBooks[key] = result;
  return result;
}

Future<PreparedCompanionPdf> _restoreOrExtractBook(
  CompanionPdfReflow reflow,
  int? loadedPageCount,
) async {
  final checkedCache = loadedPageCount != null && loadedPageCount > 0;
  if (checkedCache) {
    // The reader already opened the original and checked its copy permission.
    // A complete cache only needs disk I/O, so it can bypass native extraction.
    final directory = await reflow._directory;
    final cached = await _restorePreparedBook(directory.path, loadedPageCount);
    if (cached != null) return cached;
  }
  final result = (_extractionTail ?? Future<void>.value()).then(
    (_) => _extractBook(reflow, tryRestoreCompleteCache: !checkedCache),
  );
  final tail = result.then<void>((_) {}, onError: (Object _) {});
  _extractionTail = tail;
  unawaited(
    tail.then((_) {
      if (identical(_extractionTail, tail)) _extractionTail = null;
    }),
  );
  return result;
}

Future<PreparedCompanionPdf> _extractBook(
  CompanionPdfReflow reflow, {
  required bool tryRestoreCompleteCache,
}) async {
  await pdfrxFlutterInitialize();
  await _waitForPdfReadingIdle();
  final pdf = await PdfDocument.openFile(
    reflow._source.filePath,
    useProgressiveLoading: true,
  );
  try {
    if (pdf.permissions?.allowsCopying == false) {
      throw const FormatException('这份 PDF 限制复制内容');
    }
    final directory = await reflow._directory;
    final pageCount = pdf.pages.length;
    if (pageCount == 0) throw const FormatException('这份 PDF 没有可读页面');
    final pages = <int, CompanionReflowPage>{};
    final marker = File('${directory.path}/complete.json');
    final published = await _hasCompleteManifest(marker, pageCount);
    if (published && tryRestoreCompleteCache) {
      final cached = await _restorePreparedBook(directory.path, pageCount);
      if (cached != null) return cached;
    }
    await _waitForPdfReadingIdle();
    await pdf.loadPagesProgressively<void>(
      loadUnitDuration: _pdfMetadataSlice,
      onPageLoadProgress: (_, _, _) async {
        await _waitForPdfReadingIdle();
        return true;
      },
    );
    for (var number = 1; number <= pageCount; number++) {
      try {
        final page = await reflow._readPage(
          pdf,
          number,
          _ReflowJob('book-$number', prefetch: false, preparingBook: true),
        );
        if (page == null || !page.canRead) {
          throw const FormatException('缺少可读内容');
        }
        pages[number] = page;
      } on FileSystemException {
        throw FormatException('第 $number 页无法写入，请检查可用存储空间后重试');
      } on FormatException catch (error) {
        throw FormatException('第 $number 页${error.message}，请重试');
      } on Exception {
        throw FormatException('第 $number 页未能完整解析，请重试');
      }
    }
    if (!published) {
      final staging = File('${marker.path}.tmp');
      await staging.writeAsString(jsonEncode({'pages': pages.length}));
      await staging.rename(marker.path);
    }
    return await _assembleBook(pages, File('${directory.path}/layout.json'));
  } finally {
    await pdf.dispose();
  }
}
