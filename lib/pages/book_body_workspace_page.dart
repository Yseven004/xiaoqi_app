import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../config/note_page_theme.dart';
import '../models/book_library_item.dart';
import '../models/book_source.dart';
import '../models/capture_source_link.dart';
import '../models/note.dart';
import '../models/ocr_layout.dart';
import '../models/pdf_catalog.dart';
import '../models/reader_pagination.dart';
import '../models/xiaoqi_document.dart';
import '../services/book_library_service.dart';
import '../services/page_image_asset_store.dart';
import '../services/note_generation_service.dart';
import '../services/pdf_catalog_service.dart';
import '../services/pdf_document_session_cache.dart';
import '../services/reader_pagination_preferences.dart';
import '../services/source_document_loader.dart';
import '../widgets/book_page_annotation_view.dart';
import '../widgets/book_page_document_view.dart';
import '../widgets/editor_toolbar_asset_button.dart';
import '../widgets/pdf_page_canvas.dart';
import '../widgets/reflow_document_pager.dart';
import '../widgets/xiaoqi_document_block_view.dart';
import '../widgets/app_toast.dart';
import 'book_page_edit_page.dart';
import 'book_page_reader_page.dart';
import 'book_source_edit_page.dart';

class BookBodyWorkspacePage extends StatefulWidget {
  const BookBodyWorkspacePage({
    super.key,
    required this.item,
    required this.bookLibraryService,
    required this.onCapturePages,
    required this.onCreateTextNote,
    this.imageRecognitionVersion,
    this.initialSourceId,
    this.initialChapterTitle,
  });

  final BookLibraryItem item;
  final BookLibraryService bookLibraryService;
  final Future<void> Function(
    BookLibraryItem item,
    BookImageImportAction action,
  )
  onCapturePages;
  final Future<void> Function(BookLibraryItem item) onCreateTextNote;
  final ValueNotifier<int>? imageRecognitionVersion;
  final int? initialSourceId;
  final String? initialChapterTitle;

  @override
  State<BookBodyWorkspacePage> createState() => _BookBodyWorkspacePageState();
}

class _BookBodyWorkspacePageState extends State<BookBodyWorkspacePage> {
  List<Note> _notes = const [];
  List<BookImageRecognitionEntry> _imageEntries = const [];
  List<BookSourceRecord> _sources = const [];
  List<PdfCatalogEntry> _catalog = const [];
  Set<String> _expandedCatalogIds = const {};
  BookSourceRecord? _activeSource;
  PdfViewerController? _pdfController;
  Note? _selectedNote;
  Note? _previewNoteWhileOriginal;
  int _pdfPage = 1;
  int? _pdfPageCount;
  PdfReaderAnchor? _pdfAnchor;
  ReaderPaginationMode _readingMode = ReaderPaginationMode.horizontal;
  ReaderPaginationProgress? _reflowProgress;
  Offset? _pdfInteractionStart;
  int? _pdfInteractionStartPage;
  bool _pdfSnapScheduled = false;
  bool _pdfEditPreparing = false;
  bool _pdfEditorRouteActive = false;
  bool _drawerOpen = false;
  Timer? _imageRefreshTimer;
  bool _loading = true;
  bool _catalogLoading = false;
  int _catalogScanCompleted = 0;
  int _catalogScanTotal = 0;
  String? _error;
  XiaoqiDocument? _document;
  bool _pdfFirstPageReady = false;
  String? _selectedDocumentChapterId;
  FlowReaderAnchor? _pendingDocumentAnchor;
  Object? _documentError;
  Map<String, String> _documentEntryChapterIds = const {};
  Map<String, String> _documentEntryBlockIds = const {};
  late final PageImageAssetStore _imageStore = PageImageAssetStore();
  final _paginationPreferences = const ReaderPaginationPreferences();
  final _readingModeListenable = ValueNotifier(ReaderPaginationMode.horizontal);
  final _catalogVersionListenable = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    widget.imageRecognitionVersion?.addListener(
      _onImageRecognitionVersionChanged,
    );
    _load();
  }

  void _onImageRecognitionVersionChanged() {
    unawaited(_refreshImageEntries());
  }

  Future<void> _refreshImageEntries() async {
    try {
      final entries = await widget.bookLibraryService
          .listImageRecognitionForBook(widget.item.book.id!);
      if (!mounted) return;
      setState(() => _imageEntries = entries);
      _scheduleImageRefresh();
    } catch (_) {
      // Keep the last visible state; the next version event retries.
    }
  }

  @override
  void dispose() {
    _imageRefreshTimer?.cancel();
    widget.imageRecognitionVersion?.removeListener(
      _onImageRecognitionVersionChanged,
    );
    _readingModeListenable.dispose();
    _catalogVersionListenable.dispose();
    super.dispose();
  }

  void _scheduleImageRefresh() {
    final pending = _imageEntries.any(
      (entry) =>
          entry.note == null &&
          (entry.batchStatus == 'processing' || entry.batchStatus == 'paused'),
    );
    if (!pending) {
      _imageRefreshTimer?.cancel();
      _imageRefreshTimer = null;
      return;
    }
    if (_imageRefreshTimer != null) return;
    _imageRefreshTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refreshImageEntries()),
    );
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final values = await Future.wait<Object>([
        widget.bookLibraryService
            .getNotesForBook(widget.item.book.id!)
            .timeout(const Duration(seconds: 8)),
        widget.bookLibraryService
            .listImageRecognitionForBook(widget.item.book.id!)
            .timeout(const Duration(seconds: 8)),
        widget.bookLibraryService
            .listSourcesForBook(widget.item.book.id!)
            .timeout(const Duration(seconds: 8)),
      ]);
      final notes = values[0] as List<Note>;
      final imageEntries = values[1] as List<BookImageRecognitionEntry>;
      var sources = values[2] as List<BookSourceRecord>;
      if (!mounted) return;
      var source = _resolveInitialSource(sources);
      if (source != null && !source.isPrimary) {
        await widget.bookLibraryService.setPrimaryBookSource(
          sourceId: source.id,
          bookId: widget.item.book.id!,
        );
        sources = await widget.bookLibraryService.listSourcesForBook(
          widget.item.book.id!,
        );
        if (!mounted) return;
        source = _resolveInitialSource(sources);
      }
      final initialCatalog = source?.format == 'pdf'
          ? _decodeCatalog(source!.catalogJson)
          : const <PdfCatalogEntry>[];
      final staleProcessing =
          source != null &&
          source.catalogStatus == 'processing' &&
          _isCatalogJobStale(source);
      final readingMode = source == null
          ? ReaderPaginationMode.horizontal
          : await _paginationPreferences.load(
              bookId: widget.item.book.id!,
              format: source.format,
            );
      final savedAnchor = source == null
          ? null
          : await _paginationPreferences.loadAnchor(
              bookId: widget.item.book.id!,
              sourceId: source.id,
            );
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _imageEntries = imageEntries;
        _sources = sources;
        _activeSource = source;
        _selectedNote = null;
        _document = null;
        _selectedDocumentChapterId = savedAnchor is FlowReaderAnchor
            ? savedAnchor.chapterId
            : null;
        _pendingDocumentAnchor = savedAnchor is FlowReaderAnchor
            ? savedAnchor
            : null;
        _pdfPage = savedAnchor is PdfReaderAnchor ? savedAnchor.pageNumber : 1;
        _pdfPageCount = null;
        _pdfAnchor = savedAnchor is PdfReaderAnchor ? savedAnchor : null;
        _pdfController = null;
        _pdfFirstPageReady = false;
        _reflowProgress = null;
        _readingMode = readingMode;
        _readingModeListenable.value = readingMode;
        _documentError = null;
        _documentEntryChapterIds = const {};
        _documentEntryBlockIds = const {};
        _catalog = initialCatalog;
        _expandedCatalogIds = _defaultExpandedCatalog();
        _catalogLoading = _isStructuredSourceFormat(source?.format)
            ? true
            : source?.catalogStatus == 'processing' && !staleProcessing;
        _loading = false;
        _error = null;
      });
      _scheduleImageRefresh();
      if (source != null && _isStructuredSourceFormat(source.format)) {
        unawaited(_loadDocument(source));
      } else if (source != null &&
          source.catalogStatus != 'confirmed' &&
          (staleProcessing ||
              (source.catalogStatus != 'processing' &&
                  (source.catalogParserVersion <
                          PdfCatalogService.parserVersion ||
                      source.catalogStatus == 'not_started' ||
                      source.catalogStatus == 'failed')))) {
        unawaited(_parseCatalog(source));
      } else if (source?.catalogStatus == 'processing') {
        // Import starts parsing in the background. If the user enters this
        // page immediately, follow that same job instead of leaving a stale
        // empty drawer until the next navigation.
        unawaited(_waitForCatalog(source!));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is TimeoutException
            ? '正文资料加载超时，请重试'
            : '正文资料暂时无法加载：$error';
      });
    }
  }

  BookSourceRecord? _resolveInitialSource(List<BookSourceRecord> sources) {
    final preferredId = widget.initialSourceId;
    if (preferredId != null) {
      for (final source in sources) {
        if (source.id == preferredId) return source;
      }
    }
    for (final source in sources) {
      if (source.isPrimary) return source;
    }
    return sources.where((item) => item.format == 'pdf').firstOrNull ??
        sources
            .where((item) => _isStructuredSourceFormat(item.format))
            .firstOrNull;
  }

  Future<void> _loadDocument(BookSourceRecord source) async {
    if (mounted) {
      setState(() {
        _catalogLoading = true;
        _documentError = null;
      });
    }
    try {
      final revision = await widget.bookLibraryService.loadBookSourceRevision(
        source,
      );
      final loader = const SourceDocumentLoader();
      final document =
          revision ??
          await loader.parseFile(source.filePath, format: source.format);
      final entryChapterIds = <String, String>{};
      final entryBlockIds = <String, String>{};
      final entries = _documentCatalogEntries(
        document,
        source.format,
        entryChapterIds: entryChapterIds,
        entryBlockIds: entryBlockIds,
      );
      if (!mounted) return;
      if (_activeSource?.id != source.id) return;
      final savedAnchor = _pendingDocumentAnchor;
      final savedChapter =
          savedAnchor is FlowReaderAnchor &&
              document.chapters.any(
                (chapter) => chapter.id == savedAnchor.chapterId,
              )
          ? savedAnchor
          : null;
      setState(() {
        _document = document;
        _selectedDocumentChapterId =
            savedChapter?.chapterId ?? document.chapters.first.id;
        _pendingDocumentAnchor = savedChapter;
        _documentEntryChapterIds = entryChapterIds;
        _documentEntryBlockIds = entryBlockIds;
        _catalog = entries;
        _expandedCatalogIds = _defaultExpandedCatalog();
        _catalogLoading = false;
        _documentError = null;
      });
    } catch (error) {
      if (!mounted) return;
      if (_activeSource?.id != source.id) return;
      setState(() {
        _catalog = const [];
        _catalogLoading = false;
        _documentError = error;
      });
    }
  }

  List<PdfCatalogEntry> _documentCatalogEntries(
    XiaoqiDocument document,
    String format, {
    required Map<String, String> entryChapterIds,
    required Map<String, String> entryBlockIds,
  }) {
    final entries = <PdfCatalogEntry>[];
    for (final chapter in document.chapters) {
      entries.add(
        PdfCatalogEntry(
          id: chapter.id,
          title: chapter.title,
          level: 1,
          order: entries.length,
          nodeType: 'chapter',
          sourceKind: format,
          confidence: 1,
          status: 'confirmed',
        ),
      );
      entryChapterIds[chapter.id] = chapter.id;
      if (!const {'markdown', 'docx', 'html'}.contains(format)) continue;
      final headingStack = <({int level, String id})>[];
      for (final block in chapter.blocks.where(
        (block) => block.kind == 'heading' && block.text != chapter.title,
      )) {
        while (headingStack.isNotEmpty &&
            headingStack.last.level >= block.level) {
          headingStack.removeLast();
        }
        final parentId = headingStack.isEmpty
            ? chapter.id
            : headingStack.last.id;
        final entryId = '${chapter.id}:${block.id}';
        entries.add(
          PdfCatalogEntry(
            id: entryId,
            title: block.text,
            level: block.level.clamp(2, 6).toInt(),
            parentId: parentId,
            order: entries.length,
            nodeType: 'section',
            sourceKind: format,
            confidence: 1,
            status: 'confirmed',
          ),
        );
        entryChapterIds[entryId] = chapter.id;
        entryBlockIds[entryId] = block.id;
        headingStack.add((level: block.level, id: entryId));
      }
    }
    return List.unmodifiable(entries);
  }

  Future<void> _switchSource(BookSourceRecord source) async {
    if (!File(source.filePath).existsSync()) {
      _showMessage('找不到这份资料文件，请重新导入');
      return;
    }
    if (_activeSource?.id == source.id) {
      _closeDrawer();
      return;
    }
    try {
      await widget.bookLibraryService.setPrimaryBookSource(
        sourceId: source.id,
        bookId: widget.item.book.id!,
      );
    } catch (error) {
      if (mounted) _showMessage('切换正文失败：$error');
      return;
    }
    final refreshedSources = await widget.bookLibraryService.listSourcesForBook(
      widget.item.book.id!,
    );
    if (!mounted) return;
    final selected = refreshedSources.firstWhere(
      (item) => item.id == source.id,
      orElse: () => source,
    );
    final initialCatalog = selected.format == 'pdf'
        ? _decodeCatalog(selected.catalogJson)
        : const <PdfCatalogEntry>[];
    final staleProcessing =
        selected.format == 'pdf' &&
        selected.catalogStatus == 'processing' &&
        _isCatalogJobStale(selected);
    final readingMode = await _paginationPreferences.load(
      bookId: widget.item.book.id!,
      format: selected.format,
    );
    final savedAnchor = await _paginationPreferences.loadAnchor(
      bookId: widget.item.book.id!,
      sourceId: selected.id,
    );
    if (!mounted) return;
    setState(() {
      _sources = refreshedSources;
      _activeSource = selected;
      _selectedNote = null;
      _document = null;
      _selectedDocumentChapterId = savedAnchor is FlowReaderAnchor
          ? savedAnchor.chapterId
          : null;
      _pendingDocumentAnchor = savedAnchor is FlowReaderAnchor
          ? savedAnchor
          : null;
      _readingMode = readingMode;
      _readingModeListenable.value = readingMode;
      _documentError = null;
      _documentEntryChapterIds = const {};
      _documentEntryBlockIds = const {};
      _catalog = initialCatalog;
      _expandedCatalogIds = _defaultExpandedCatalog();
      _catalogLoading = _isStructuredSourceFormat(selected.format)
          ? true
          : selected.catalogStatus == 'processing' && !staleProcessing;
      _catalogScanCompleted = 0;
      _catalogScanTotal = 0;
      _pdfPage = savedAnchor is PdfReaderAnchor ? savedAnchor.pageNumber : 1;
      _pdfPageCount = null;
      _pdfAnchor = savedAnchor is PdfReaderAnchor ? savedAnchor : null;
      _pdfController = null;
      _pdfFirstPageReady = false;
      _reflowProgress = null;
      _drawerOpen = false;
    });
    if (_isStructuredSourceFormat(selected.format)) {
      unawaited(_loadDocument(selected));
      return;
    }
    if (selected.catalogStatus != 'confirmed' &&
        (staleProcessing ||
            (selected.catalogStatus != 'processing' &&
                (selected.catalogParserVersion <
                        PdfCatalogService.parserVersion ||
                    selected.catalogStatus == 'not_started' ||
                    selected.catalogStatus == 'failed')))) {
      unawaited(_parseCatalog(selected));
    } else if (selected.catalogStatus == 'processing') {
      unawaited(_waitForCatalog(selected));
    }
  }

  Future<void> _selectImageEntry(BookImageRecognitionEntry entry) async {
    final note = entry.note;
    if (note == null) {
      _showMessage(
        entry.status == 'failed' ? '这张图片识别失败，请重新添加图片' : '这张图片正在识别，完成后可预览正文',
      );
      return;
    }
    final link = entry.link;
    if (link != null && _activeSource?.id != link.targetSourceId) {
      final source = _sources
          .where((item) => item.id == link.targetSourceId)
          .firstOrNull;
      if (source != null) await _switchSource(source);
    }
    if (!mounted) return;
    _closeDrawer();
    setState(() => _selectedNote = note);
  }

  Note? _replacementNoteForPdfPage(int pageNumber) {
    final sourceId = _activeSource?.id;
    if (sourceId != null) {
      for (final entry in _imageEntries) {
        final link = entry.link;
        final note = entry.note;
        if (link == null || note == null || link.targetSourceId != sourceId) {
          continue;
        }
        if (link.mode != 'replace' || link.anchorKind != 'pdf_page') continue;
        final anchor = link.toAnchor();
        if (anchor is PdfReaderAnchor && anchor.pageNumber == pageNumber) {
          return note;
        }
      }
    }
    return _pdfTextLayerNoteForPage(pageNumber);
  }

  Note? _pdfTextLayerNoteForPage(int pageNumber) {
    final sourcePath = _activeSource?.filePath;
    if (sourcePath == null || sourcePath.isEmpty) return null;
    for (final note in _notes) {
      if (_isPdfTextLayerNoteFor(note, sourcePath, pageNumber)) return note;
    }
    return null;
  }

  Future<void> _replaceSelectedImageOnCurrentPdfPage() async {
    final note = _selectedNote;
    final source = _activeSource;
    final capturePageId = note?.capturePageId;
    if (note == null || source == null || source.format != 'pdf') return;
    if (capturePageId == null) {
      _showMessage('这张图片还没有可关联的识别记录');
      return;
    }
    try {
      await widget.bookLibraryService.saveCapturePlacements(
        bookId: widget.item.book.id!,
        sourceId: source.id,
        placements: {
          capturePageId: CapturePagePlacement(
            kind: CapturePlacementKind.replacePdfPage,
            anchor: PdfReaderAnchor(
              sourceId: source.id.toString(),
              pageNumber: _pdfPage,
            ),
          ),
        },
      );
      final refreshed = await widget.bookLibraryService
          .listImageRecognitionForBook(widget.item.book.id!);
      if (!mounted) return;
      setState(() {
        _imageEntries = refreshed;
        _selectedNote = null;
      });
      _showMessage('已替换当前页，电子原页仍可查看');
    } catch (error) {
      if (mounted) _showMessage('替换当前页失败：$error');
    }
  }

  void _handleWorkspaceBack() {
    if (_selectedNote != null || _previewNoteWhileOriginal != null) {
      setState(() {
        _selectedNote = null;
        _previewNoteWhileOriginal = null;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  void _showOriginalWhilePressed() {
    if (_selectedNote == null) return;
    setState(() => _previewNoteWhileOriginal = _selectedNote);
  }

  void _restorePreviewAfterOriginal() {
    if (_previewNoteWhileOriginal == null) return;
    setState(() => _previewNoteWhileOriginal = null);
  }

  Future<void> _showSourcePicker() async {
    if (_sources.length < 2) return;
    final selected = await showModalBottomSheet<BookSourceRecord>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SourcePickerSheet(
        sources: _sources,
        activeSourceId: _activeSource?.id,
      ),
    );
    if (selected != null && mounted) await _switchSource(selected);
  }

  Set<String> _defaultExpandedCatalog() => const {};

  void _toggleCatalogNode(String id) {
    void toggle() {
      if (_expandedCatalogIds.contains(id)) {
        _expandedCatalogIds = {..._expandedCatalogIds}..remove(id);
      } else {
        _expandedCatalogIds = {..._expandedCatalogIds, id};
      }
    }

    if (_pdfEditorRouteActive) {
      toggle();
      _catalogVersionListenable.value++;
      return;
    }
    setState(toggle);
  }

  bool _isCatalogJobStale(BookSourceRecord source) {
    final started = DateTime.tryParse(source.catalogUpdatedAt);
    return started == null ||
        DateTime.now().difference(started) > const Duration(minutes: 5);
  }

  Future<void> _parseCatalog(BookSourceRecord source) async {
    if (_catalogLoading || _activeSource?.id != source.id) return;
    setState(() {
      _catalogLoading = true;
      _catalogScanCompleted = 0;
      _catalogScanTotal = 0;
    });
    try {
      final quick = await widget.bookLibraryService.parsePdfCatalogForSource(
        source,
      );
      if (quick.sourceKind == 'no_text_layer' ||
          quick.sourceKind == 'text_no_toc') {
        final pageCount = quick.pageCount;
        final pageLimit = pageCount.clamp(1, 24).toInt();
        await widget.bookLibraryService.parsePdfCatalogForSource(
          source,
          scannedPageNumbers: [
            for (var page = 1; page <= pageLimit; page++) page,
          ],
          onProgress: (completed, total) {
            if (!mounted) return;
            if (_activeSource?.id != source.id) return;
            setState(() {
              _catalogScanCompleted = completed;
              _catalogScanTotal = total;
            });
          },
        );
      }
      final sources = await widget.bookLibraryService.listSourcesForBook(
        widget.item.book.id!,
      );
      if (_activeSource?.id != source.id) return;
      final updated = sources.firstWhere(
        (item) => item.id == source.id,
        orElse: () => source,
      );
      if (!mounted) return;
      if (_activeSource?.id != source.id) return;
      setState(() {
        _sources = sources;
        _activeSource = updated;
        _catalog = _decodeCatalog(updated.catalogJson);
        _expandedCatalogIds = _defaultExpandedCatalog();
        _catalogLoading = false;
        _catalogScanCompleted = 0;
        _catalogScanTotal = 0;
      });
      unawaited(_watchCatalogRefinement(updated));
    } catch (error) {
      if (!mounted) return;
      if (_activeSource?.id != source.id) return;
      setState(() {
        _catalogLoading = false;
        _catalogScanCompleted = 0;
        _catalogScanTotal = 0;
      });
      _showMessage('目录解析失败：$error');
    }
  }

  Future<void> _waitForCatalog(BookSourceRecord source) async {
    for (var attempt = 0; attempt < 120; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final sources = await widget.bookLibraryService.listSourcesForBook(
        widget.item.book.id!,
      );
      BookSourceRecord? updated;
      for (final candidate in sources) {
        if (candidate.id == source.id) {
          updated = candidate;
          break;
        }
      }
      final resolved = updated;
      if (resolved == null || resolved.catalogStatus == 'processing') {
        continue;
      }
      if (!mounted) return;
      if (_activeSource?.id != source.id) return;
      setState(() {
        _sources = sources;
        _activeSource = resolved;
        _catalog = _decodeCatalog(resolved.catalogJson);
        _expandedCatalogIds = _defaultExpandedCatalog();
        _catalogLoading = false;
      });
      unawaited(_watchCatalogRefinement(resolved));
      return;
    }
  }

  Future<void> _watchCatalogRefinement(BookSourceRecord source) async {
    final baseline = source.catalogUpdatedAt;
    if (baseline.isEmpty || source.catalogStatus == 'confirmed') return;
    for (var attempt = 0; attempt < 60; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final sources = await widget.bookLibraryService.listSourcesForBook(
        widget.item.book.id!,
      );
      BookSourceRecord? updated;
      for (final candidate in sources) {
        if (candidate.id == source.id) {
          updated = candidate;
          break;
        }
      }
      final resolved = updated;
      if (resolved == null) return;
      if (resolved.catalogUpdatedAt == baseline ||
          resolved.catalogStatus == 'processing') {
        continue;
      }
      if (!mounted) return;
      if (_activeSource?.id != source.id) return;
      setState(() {
        _sources = sources;
        _activeSource = resolved;
        _catalog = _decodeCatalog(resolved.catalogJson);
        _expandedCatalogIds = _defaultExpandedCatalog();
      });
      return;
    }
  }

  List<PdfCatalogEntry> _decodeCatalog(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! List) return const [];
      return value
          .whereType<Map>()
          .map((item) => PdfCatalogEntry.fromJson(item.cast<String, dynamic>()))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  PdfCatalogEntry? _currentPdfCatalogEntry([int? page]) {
    final currentPage = page ?? _pdfPage;
    PdfCatalogEntry? match;
    for (final entry in _catalog) {
      final start = entry.pdfPage;
      if (start == null || start > currentPage) continue;
      final end = entry.pdfEndPage ?? _derivedCatalogEndPage(entry);
      if (currentPage > end) continue;
      if (match == null ||
          entry.level > match.level ||
          (entry.level == match.level && start > (match.pdfPage ?? 0))) {
        match = entry;
      }
    }
    return match;
  }

  int _derivedCatalogEndPage(PdfCatalogEntry entry) {
    final index = _catalog.indexWhere((item) => item.id == entry.id);
    if (index < 0) return _pdfPageCount ?? entry.pdfPage ?? 1;
    for (var nextIndex = index + 1; nextIndex < _catalog.length; nextIndex++) {
      final next = _catalog[nextIndex];
      if (next.pdfPage != null && next.level <= entry.level) {
        return (next.pdfPage! - 1).clamp(entry.pdfPage ?? 1, 1 << 30).toInt();
      }
    }
    return _pdfPageCount ?? (1 << 30);
  }

  PdfCatalogEntry? _currentDocumentCatalogEntry() {
    final chapterId = _selectedDocumentChapterId;
    if (chapterId == null || chapterId.isEmpty) return null;
    final anchor = _pendingDocumentAnchor;
    if (anchor is FlowReaderAnchor && anchor.blockId != null) {
      final chapter = _document?.chapters
          .where((item) => item.id == chapterId)
          .firstOrNull;
      final blocks = chapter?.blocks ?? const <XiaoqiDocumentBlock>[];
      var blockIndex = blocks.indexWhere((block) => block.id == anchor.blockId);
      if (blockIndex < 0) blockIndex = blocks.length;
      for (var index = blockIndex; index >= 0; index--) {
        if (index >= blocks.length) continue;
        final block = blocks[index];
        if (block.kind != 'heading' || block.text == chapter?.title) continue;
        final headingId = '$chapterId:${block.id}';
        for (final entry in _catalog) {
          if (entry.id == headingId) return entry;
        }
      }
      for (final entry in _catalog) {
        if (_documentEntryChapterIds[entry.id] == chapterId &&
            _documentEntryBlockIds[entry.id] == anchor.blockId) {
          return entry;
        }
      }
    }
    for (final entry in _catalog) {
      if ((_documentEntryChapterIds[entry.id] ?? entry.id) == chapterId) {
        return entry;
      }
    }
    return null;
  }

  PdfCatalogEntry? _currentCatalogEntry() => _activeSource?.format == 'pdf'
      ? _currentPdfCatalogEntry()
      : _currentDocumentCatalogEntry();

  List<PdfCatalogEntry> _catalogPath(PdfCatalogEntry? entry) {
    if (entry == null) return const [];
    final byId = {for (final item in _catalog) item.id: item};
    final result = <PdfCatalogEntry>[];
    final visited = <String>{};
    PdfCatalogEntry? current = entry;
    while (current != null && visited.add(current.id)) {
      result.add(current);
      current = current.parentId == null ? null : byId[current.parentId];
    }
    return result.reversed.toList(growable: false);
  }

  Set<String> _expandedWithCurrentPath() {
    final ids = {..._expandedCatalogIds};
    for (final entry in _catalogPath(_currentCatalogEntry())) {
      ids.add(entry.id);
    }
    return ids;
  }

  String _currentLocationTitle() {
    final path = _catalogPath(_currentCatalogEntry());
    if (path.isEmpty) return '章节待定位';
    return path.map((entry) => entry.title).join(' · ');
  }

  String _currentLocationSubtitle() {
    final source = _activeSource;
    if (source?.format == 'pdf') {
      final total = _pdfPageCount;
      return total == null || total <= 0
          ? '原书第 $_pdfPage 页'
          : '原书第 $_pdfPage / $total 页';
    }
    final progress = _reflowProgress;
    if (progress == null) return '当前章节正在定位';
    final original = progress.originalPageLabel == null
        ? '原书页码待定位'
        : '原书第 ${progress.originalPageLabel} 页';
    return '阅读第 ${progress.currentScreenPage} / ${progress.screenPageCount} 页 · $original';
  }

  Widget _buildReadingLocation() {
    final title = _currentLocationTitle();
    final subtitle = _currentLocationSubtitle();
    final entry = _currentCatalogEntry();
    final uncertain =
        entry == null ||
        entry.status == 'estimated' ||
        entry.status == 'needs_review';
    final label = '当前阅读位置：$title，$subtitle。点击打开目录';
    return Positioned(
      top: 66,
      left: 16,
      right: 16,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Semantics(
            button: true,
            label: label,
            child: Material(
              color: NotePageTheme.card.withOpacity(.96),
              elevation: 4,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                key: const Key('body_workspace_reading_location'),
                borderRadius: BorderRadius.circular(16),
                onTap: _toggleDrawer,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
                  child: Row(
                    children: [
                      Icon(
                        uncertain
                            ? Icons.location_searching_rounded
                            : Icons.my_location_rounded,
                        size: 18,
                        color: uncertain
                            ? NotePageTheme.gold
                            : NotePageTheme.green,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: NotePageTheme.ink,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: NotePageTheme.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.expand_more_rounded,
                        size: 20,
                        color: NotePageTheme.inkSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _selectCatalogEntry(PdfCatalogEntry entry) async {
    final source = _activeSource;
    if (source == null) return;
    if (source.format != 'pdf') {
      final chapterId =
          _documentEntryChapterIds[entry.id] ?? entry.parentId ?? entry.id;
      final blockId = _documentEntryBlockIds[entry.id];
      _closeDrawer();
      setState(() {
        _selectedNote = null;
        _selectedDocumentChapterId = chapterId;
        _pendingDocumentAnchor = FlowReaderAnchor(
          sourceId: source.id.toString(),
          chapterId: chapterId,
          blockId: blockId,
        );
        unawaited(
          _paginationPreferences.saveAnchor(
            bookId: widget.item.book.id!,
            anchor: _pendingDocumentAnchor!,
          ),
        );
      });
      return;
    }
    if (entry.pdfPage == null) {
      _showMessage('该章节暂时没有可跳转的页码');
      return;
    }
    _closeDrawer();
    setState(() {
      _selectedNote = null;
      _activeSource = source;
      _pdfPage = entry.pdfPage!;
      _expandedCatalogIds = {
        ..._expandedCatalogIds,
        ..._catalogPath(entry).map((item) => item.id),
      };
      _pdfAnchor = PdfReaderAnchor(
        sourceId: source.id.toString(),
        pageNumber: entry.pdfPage!,
      );
      unawaited(
        _paginationPreferences.saveAnchor(
          bookId: widget.item.book.id!,
          anchor: _pdfAnchor!,
        ),
      );
      _pdfController ??= PdfViewerController();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _pdfController;
      if (mounted && controller?.isReady == true) {
        unawaited(_goToPdfPage(entry.pdfPage!));
      }
    });
  }

  void _toggleDrawer() {
    setState(() {
      _drawerOpen = !_drawerOpen;
      if (_drawerOpen) _expandedCatalogIds = _expandedWithCurrentPath();
    });
  }

  void _closeDrawer() {
    if (_drawerOpen) setState(() => _drawerOpen = false);
  }

  Widget _buildEditorCatalogDrawer(
    VoidCallback onClose,
    ValueChanged<int> onSelectPage,
    VoidCallback onFinishEditor,
  ) {
    void selectNote(Note? note) {
      if (note == null) {
        AppToast.show(context, '这项内容还没有可编辑的书页');
        return;
      }
      final index = _notes.indexWhere(
        (item) =>
            (note.id != null && item.id == note.id) ||
            (note.capturePageId != null &&
                item.capturePageId == note.capturePageId),
      );
      if (index < 0) {
        AppToast.show(context, '这项内容不在当前编辑页中');
        return;
      }
      onClose();
      onSelectPage(index);
    }

    final source = _activeSource;
    return _ChapterDrawer(
      bookTitle: widget.item.book.title,
      sourceId: source?.id,
      sourceName: source?.displayName,
      sourceFormat: source?.format ?? '',
      sources: _sources,
      entries: _catalog,
      currentEntryId: _currentCatalogEntry()?.id,
      currentLocationTitle: _currentLocationTitle(),
      currentLocationSubtitle: _currentLocationSubtitle(),
      imageEntries: _imageEntries,
      readingMode: _readingMode,
      expandedIds: _expandedCatalogIds,
      loading: _catalogLoading,
      loadingSubtitle: _catalogScanTotal > 0
          ? '正在整理章节目录（$_catalogScanCompleted/$_catalogScanTotal），可稍后返回。'
          : _isStructuredSourceFormat(source?.format)
          ? '正在整理文档结构，完成后章节会出现在这里。'
          : '先继续查看原书页，目录完成后会出现在这里。',
      onSelect: (entry) {
        if (source?.format == 'pdf' && _pdfEditorRouteActive) {
          final page = entry.pdfPage;
          if (page == null) {
            AppToast.show(context, '该目录项没有对应的 PDF 书页');
            return;
          }
          onClose();
          onSelectPage(page);
          return;
        }
        if (_isStructuredSourceFormat(source?.format)) {
          final chapterId =
              _documentEntryChapterIds[entry.id] ?? entry.parentId ?? entry.id;
          final chapterIndex = _document?.chapters.indexWhere(
            (chapter) => chapter.id == chapterId,
          );
          if (chapterIndex != null && chapterIndex >= 0) {
            onClose();
            onSelectPage(chapterIndex);
            return;
          }
        }
        final page = entry.pdfPage;
        selectNote(page == null ? null : _replacementNoteForPdfPage(page));
      },
      onToggle: _toggleCatalogNode,
      onCapture: () {
        onClose();
        unawaited(_capturePages());
      },
      onDeleteImage: (entry) => unawaited(_deleteImageRecognition(entry)),
      onToggleImage: (entry) => unawaited(_toggleImageRecognition(entry)),
      needsConfirmation:
          source?.format == 'pdf' &&
          !_isStructuredSourceFormat(source?.format) &&
          source?.catalogStatus != 'confirmed',
      onConfirm: source?.format == 'pdf'
          ? () => unawaited(_confirmCatalog())
          : null,
      onRetry: source == null
          ? null
          : _isStructuredSourceFormat(source.format)
          ? () => unawaited(_loadDocument(source))
          : () => unawaited(_parseCatalog(source)),
      onSelectSource: () {
        onClose();
        unawaited(_showSourcePicker());
      },
      onSelectImage: (entry) => selectNote(entry.note),
      onReadingModeChanged: (mode) => unawaited(_setReadingMode(mode)),
      onClose: onClose,
    );
  }

  Future<void> _openEditor() async {
    final source = _activeSource;
    if (source?.format == 'pdf') {
      await _openPdfEditor(source!);
      return;
    }
    if (source != null && _isStructuredSourceFormat(source.format)) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => BookSourceEditPage(
            source: source,
            bookLibraryService: widget.bookLibraryService,
            catalogDrawerBuilder: _buildEditorCatalogDrawer,
          ),
        ),
      );
      if (mounted) await _load();
      return;
    }
    final note = _selectedNote;
    if (note == null) return;
    final editorNote = note;
    final editorNotes =
        _notes.any(
          (item) =>
              (editorNote.id != null && item.id == editorNote.id) ||
              (editorNote.capturePageId != null &&
                  item.capturePageId == editorNote.capturePageId),
        )
        ? _notes
        : [editorNote];
    final editorIndex = editorNotes.indexWhere(
      (item) =>
          (editorNote.id != null && item.id == editorNote.id) ||
          (editorNote.capturePageId != null &&
              item.capturePageId == editorNote.capturePageId),
    );
    await Navigator.of(context).push<List<Note>>(
      MaterialPageRoute(
        builder: (_) => BookPageEditPage(
          initialNote: editorNote,
          initialNotes: editorNotes,
          initialIndex: editorIndex < 0 ? 0 : editorIndex,
          isDraft: false,
          bookId: widget.item.book.id,
          bookName: widget.item.book.title,
          catalogDrawerBuilder: _buildEditorCatalogDrawer,
          onOriginalPage: (_) async {
            if (!mounted) return;
            _showMessage('原始 PDF 文件保持不变，当前编辑的是识别文字层');
          },
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openPdfEditor(BookSourceRecord source) async {
    if (_pdfEditPreparing) return;
    setState(() => _pdfEditPreparing = true);
    _pdfEditorRouteActive = true;
    _showMessage('正在准备当前 PDF 页的可编辑文字');
    try {
      final documentRef = _pdfDocumentRefFor(source);
      final note =
          _pdfTextLayerNoteForPage(_pdfPage) ??
          await _createPdfTextLayerNote(
            source,
            _pdfPage,
            documentRef: documentRef,
          );
      if (!mounted) return;
      if (note == null) {
        _showMessage('当前 PDF 页没有可编辑的文字层，请先完成文字识别');
        return;
      }
      await Navigator.of(context).push<List<Note>>(
        MaterialPageRoute(
          builder: (_) => BookPageEditPage(
            initialNote: note,
            initialNotes: [note],
            initialIndex: 0,
            isDraft: false,
            bookId: widget.item.book.id,
            bookName: widget.item.book.title,
            pdfDocumentRef: documentRef,
            pdfPageNumber: _pdfPage,
            pdfPageLoader: (page) async {
              final existing = _replacementNoteForPdfPage(page);
              return existing ??
                  await _createPdfTextLayerNote(
                    source,
                    page,
                    documentRef: documentRef,
                  );
            },
            pdfPaginationModeListenable: _readingModeListenable,
            catalogDrawerVersionListenable: _catalogVersionListenable,
            catalogDrawerBuilder: _buildEditorCatalogDrawer,
            onPdfPageChanged: (page) {
              if (!mounted || page == _pdfPage) return;
              void update() {
                _pdfPage = page;
                _pdfPageCount = _pdfController?.isReady == true
                    ? _pdfController!.pageCount
                    : _pdfPageCount;
                _pdfAnchor = PdfReaderAnchor(
                  sourceId: source.id.toString(),
                  pageNumber: page,
                );
                _expandedCatalogIds = _expandedWithCurrentPath();
                unawaited(
                  _paginationPreferences.saveAnchor(
                    bookId: widget.item.book.id!,
                    anchor: _pdfAnchor!,
                  ),
                );
              }

              if (_pdfEditorRouteActive) {
                update();
                _catalogVersionListenable.value++;
              } else {
                setState(update);
              }
            },
            onOriginalPage: (_) async {
              if (!mounted) return;
              _showMessage('原始 PDF 文件保持不变，当前编辑的是识别文字层');
            },
          ),
        ),
      );
      if (mounted) await _load();
    } finally {
      _pdfEditorRouteActive = false;
      if (mounted) setState(() => _pdfEditPreparing = false);
    }
  }

  Future<Note?> _createPdfTextLayerNote(
    BookSourceRecord source,
    int pageNumber, {
    PdfDocumentRef? documentRef,
  }) async {
    // 同一页只能有一条文字层笔记：内存里的列表可能还没加载完，先兜底查库，
    // 否则每次进入编辑页都会给同一页插入一条新笔记（设备上第 17 页曾积累 4 条）。
    final existing = await _existingPdfTextLayerNote(source, pageNumber);
    if (existing != null) return existing;
    if (documentRef != null) {
      return documentRef.resolveListenable().useDocument<Note?>(
        (document) =>
            _createPdfTextLayerNoteForDocument(source, pageNumber, document),
      );
    }
    try {
      await pdfrxFlutterInitialize();
      final document = await PdfDocument.openFile(source.filePath);
      try {
        return await _createPdfTextLayerNoteForDocument(
          source,
          pageNumber,
          document,
        );
      } finally {
        await document.dispose();
      }
    } on Object catch (_) {
      return null;
    }
  }

  Future<Note?> _existingPdfTextLayerNote(
    BookSourceRecord source,
    int pageNumber,
  ) async {
    final cached = _pdfTextLayerNoteForPage(pageNumber);
    if (cached != null && cached.pdfPath == source.filePath) return cached;
    try {
      return await widget.bookLibraryService.findPdfTextLayerNote(
        pdfPath: source.filePath,
        pageNumber: pageNumber,
      );
    } on Object catch (_) {
      // 查库失败时按“没有已有笔记”处理，保持原来的创建流程。
      return null;
    }
  }

  bool _isPdfTextLayerNoteFor(Note note, String pdfPath, int pageNumber) =>
      note.pdfPath == pdfPath &&
      note.bookPage.trim() == pageNumber.toString() &&
      (note.sourceType == 'pdf_text_layer' ||
          note.sourceType == 'pdf_ocr_layer');

  Future<Note?> _createPdfTextLayerNoteForDocument(
    BookSourceRecord source,
    int pageNumber,
    PdfDocument document,
  ) async {
    if (pageNumber < 1 || pageNumber > document.pages.length) return null;
    final text = await document.pages[pageNumber - 1].loadStructuredText();
    final content = text.fullText.trim();
    if (content.isEmpty) {
      final imagePath = await const PdfCatalogService().renderPageForEditing(
        source.filePath,
        pageNumber,
      );
      final recognized = await NoteGenerationService.generateAnnotationNote(
        imagePath,
        dbInserter: (_) async => -1,
        dbUpdater: (_) async => 0,
      );
      return recognized.copyWith(
        clearId: true,
        sourceType: 'pdf_ocr_layer',
        pdfPath: source.filePath,
        bookName: widget.item.book.title,
        bookPage: pageNumber.toString(),
        bookId: widget.item.book.id,
      );
    }

    final page = document.pages[pageNumber - 1];
    double unit(double value) => value.clamp(0.0, 1.0).toDouble();
    final layoutBlocks = <OcrBlock>[
      // Keep the figure sentinel so the editor persists coordinate blocks
      // instead of flattening them into the legacy body field. The PDF viewer
      // remains the visual source; no duplicate full-page raster is generated.
      OcrBlock(
        id: 0,
        text: '',
        type: 'figure',
        x: .04,
        y: .04,
        width: .92,
        height: .92,
        figureKind: 'pdf_original_page',
        figureAspectRatio: page.width / page.height,
      ),
    ];
    for (var index = 0; index < text.fragments.length; index++) {
      final fragment = text.fragments[index];
      if (fragment.text.trim().isEmpty) continue;
      final bounds = fragment.bounds.toRect(page: page);
      final charHeights = fragment.charRects
          .map((rect) => rect.height)
          .where((height) => height > 0)
          .toList();
      charHeights.sort();
      final charHeightRatio = charHeights.isEmpty || bounds.height <= 0
          ? null
          : charHeights[charHeights.length ~/ 2] / bounds.height;
      layoutBlocks.add(
        OcrBlock(
          id: index + 1,
          text: fragment.text.trim(),
          type: 'paragraph',
          x: unit(bounds.left / page.width),
          y: unit(bounds.top / page.height),
          width: unit(bounds.width / page.width),
          height: unit(bounds.height / page.height),
          attributes: charHeightRatio == null
              ? const {}
              : {'pdf_char_height_ratio': charHeightRatio.toString()},
        ),
      );
    }
    final now = DateTime.now().toIso8601String();
    final pageDocument = BookPageDocument(
      schemaVersion: 2,
      blocks: layoutBlocks,
      pageNumber: pageNumber.toString(),
      compatibilityMarkdown: content,
    );
    return Note(
      type: 'text',
      title: 'PDF 第 $pageNumber 页',
      content: content,
      sourceType: 'pdf_text_layer',
      pdfPath: source.filePath,
      bookName: widget.item.book.title,
      bookPage: pageNumber.toString(),
      bookId: widget.item.book.id,
      annotationsJson: jsonEncode(pageDocument.toJson()),
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> _capturePages() async {
    _closeDrawer();
    final action = await showModalBottomSheet<BookImageImportAction>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ImageImportChoiceSheet(),
    );
    if (!mounted || action == null) return;
    await widget.onCapturePages(widget.item, action);
    if (mounted) await _refreshImageEntries();
  }

  Future<void> _deleteImageRecognition(BookImageRecognitionEntry entry) async {
    await widget.bookLibraryService.deleteImageRecognitionPage(
      entry.capturePageId,
    );
    if (!mounted) return;
    setState(() {
      _imageEntries = _imageEntries
          .where((item) => item.capturePageId != entry.capturePageId)
          .toList(growable: false);
      if (_selectedNote?.capturePageId == entry.capturePageId) {
        _selectedNote = null;
      }
    });
    _showMessage('已删除图片识别文本');
  }

  Future<void> _toggleImageRecognition(BookImageRecognitionEntry entry) async {
    final paused = await widget.bookLibraryService.toggleCaptureBatchPause(
      entry.batchId,
    );
    if (!mounted || paused == null) return;
    setState(() {
      _imageEntries = _imageEntries
          .map(
            (item) => item.batchId == entry.batchId
                ? item.copyWith(batchStatus: paused ? 'paused' : 'processing')
                : item,
          )
          .toList(growable: false);
    });
    _showMessage(paused ? '已暂停本批图片识别' : '已继续本批图片识别');
  }

  Future<void> _confirmCatalog() async {
    final source = _activeSource;
    if (source == null || source.format != 'pdf' || _catalog.isEmpty) return;
    if (_catalog.any((entry) => entry.pdfPage == null)) {
      _showMessage('还有目录页码待确认，确认前请先完成映射');
      return;
    }
    await widget.bookLibraryService.confirmPdfCatalog(
      sourceId: source.id,
      entries: _catalog,
    );
    if (!mounted) return;
    final sources = await widget.bookLibraryService.listSourcesForBook(
      widget.item.book.id!,
    );
    final updated = sources.firstWhere((item) => item.id == source.id);
    setState(() {
      _sources = sources;
      _activeSource = updated;
    });
    _showMessage('目录已确认，可用于正文还原和批注定位');
  }

  Future<void> _openQuickNote() => widget.onCreateTextNote(widget.item);

  void _showMessage(String message) {
    AppToast.show(context, message);
  }

  Future<void> _setReadingMode(ReaderPaginationMode mode) async {
    final source = _activeSource;
    if (source == null || mode == _readingMode) return;
    if (_pdfEditorRouteActive) {
      _readingMode = mode;
    } else {
      setState(() => _readingMode = mode);
    }
    _readingModeListenable.value = mode;
    _catalogVersionListenable.value++;
    if (source.format == 'pdf') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_goToPdfPage(_pdfPage));
      });
    }
    await _paginationPreferences.save(
      bookId: widget.item.book.id!,
      format: source.format,
      mode: mode,
    );
  }

  void _onPdfInteractionStart(ScaleStartDetails details) {
    if (_readingMode != ReaderPaginationMode.horizontal) return;
    final controller = _pdfController;
    if (controller == null || !controller.isReady) return;
    _pdfInteractionStart = controller.centerPosition;
    _pdfInteractionStartPage = controller.pageNumber ?? _pdfPage;
  }

  void _onPdfInteractionEnd(ScaleEndDetails details) {
    if (_readingMode != ReaderPaginationMode.horizontal) return;
    if (_pdfSnapScheduled) return;
    _pdfSnapScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _pdfSnapScheduled = false;
      await _snapPdfPage(details);
    });
  }

  Future<void> _snapPdfPage(ScaleEndDetails details) async {
    final controller = _pdfController;
    final start = _pdfInteractionStart;
    final startPage = _pdfInteractionStartPage;
    if (controller == null ||
        !controller.isReady ||
        start == null ||
        startPage == null ||
        controller.currentZoom >
            _pdfPageWidthZoom(controller, startPage) * 1.05) {
      return;
    }

    final end = controller.centerPosition;
    final delta = end.dx - start.dx;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final threshold = math.max(48.0, controller.viewSize.width * .16);
    var target = startPage;
    if (velocity.abs() >= 650 || delta.abs() >= threshold) {
      final forward = velocity < -650 || delta > 0;
      target = startPage + (forward ? 1 : -1);
    }
    target = target.clamp(1, controller.layout.pageLayouts.length).toInt();
    if (target == controller.pageNumber && delta.abs() < 1) return;
    await _goToPdfPage(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
    );
  }

  double _pdfPageWidthZoom(PdfViewerController controller, int pageNumber) {
    final layouts = controller.layout.pageLayouts;
    final index = pageNumber.clamp(1, layouts.length).toInt() - 1;
    final width = layouts[index].width;
    return width <= 0
        ? controller.currentZoom
        : controller.viewSize.width / width;
  }

  Future<void> _goToPdfPage(
    int pageNumber, {
    Duration duration = const Duration(milliseconds: 220),
  }) async {
    final controller = _pdfController;
    if (controller == null || !controller.isReady) return;
    final safePage = pageNumber
        .clamp(1, controller.layout.pageLayouts.length)
        .toInt();
    final pageRect = controller.layout.pageLayouts[safePage - 1];
    final zoom = _readingMode == ReaderPaginationMode.horizontal
        ? _pdfPageWidthZoom(controller, safePage)
        : controller.alternativeFitScale ?? controller.currentZoom;
    final matrix = controller.calcMatrixFor(
      pageRect.center,
      zoom: zoom,
      viewSize: controller.viewSize,
    );
    await controller.goTo(
      matrix,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : duration,
    );
  }

  bool? _onPdfKey(
    PdfViewerKeyHandlerParams params,
    LogicalKeyboardKey key,
    bool isRealKeyPress,
  ) {
    if (!isRealKeyPress) return null;
    if (_readingMode != ReaderPaginationMode.horizontal) return null;
    final controller = _pdfController;
    if (controller == null ||
        !controller.isReady ||
        controller.currentZoom >
            _pdfPageWidthZoom(controller, _pdfPage) * 1.05) {
      return null;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_goToPdfPage(_pdfPage - 1));
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_goToPdfPage(_pdfPage + 1));
      return true;
    }
    return null;
  }

  void _updatePdfPageCount() {
    final controller = _pdfController;
    if (!mounted || controller == null || !controller.isReady) return;
    final count = controller.layout.pageLayouts.length;
    if (count <= 0 || count == _pdfPageCount) return;
    setState(() => _pdfPageCount = count);
  }

  Widget _buildPageIndicator() {
    final source = _activeSource;
    if (source == null) return const SizedBox.shrink();
    if (source.format == 'pdf') {
      final total = _pdfPageCount;
      if (total == null || total <= 0) return const SizedBox.shrink();
      return Positioned(
        left: 0,
        right: 0,
        bottom: 24,
        child: IgnorePointer(
          child: Center(
            child: _ReaderPageProgressPill(label: '第 $_pdfPage / $total 页'),
          ),
        ),
      );
    }
    if (_readingMode != ReaderPaginationMode.horizontal) {
      return const SizedBox.shrink();
    }
    final progress = _reflowProgress;
    if (progress == null) return const SizedBox.shrink();
    final label = progress.hasOriginalPagination
        ? progress.originalPageLabel == null
              ? '阅读第 ${progress.currentScreenPage} / ${progress.screenPageCount} 页 · 原书页码待定位'
              : '原书第 ${progress.originalPageLabel} / ${progress.originalPageCount} 页'
        : '阅读第 ${progress.currentScreenPage} / ${progress.screenPageCount} 页 · 原书未提供固定页码';
    return Positioned(
      left: 0,
      right: 0,
      bottom: 24,
      child: IgnorePointer(
        child: Center(child: _ReaderPageProgressPill(label: label)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: NotePageTheme.card,
        body: const Center(
          child: Text(
            '正在打开正文',
            style: TextStyle(color: NotePageTheme.muted, fontSize: 15),
          ),
        ),
      );
    }
    if (_error != null) {
      return Scaffold(
        backgroundColor: NotePageTheme.card,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                TextButton(onPressed: _load, child: const Text('重试打开正文')),
              ],
            ),
          ),
        ),
      );
    }
    return PopScope(
      canPop: _selectedNote == null && _previewNoteWhileOriginal == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleWorkspaceBack();
      },
      child: Scaffold(
        backgroundColor: NotePageTheme.card,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              _buildBody(),
              _buildReadingLocation(),
              _buildPageIndicator(),
              _buildToolbar(),
              if (_drawerOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeDrawer,
                    child: const ColoredBox(color: Color(0x66000000)),
                  ),
                ),
                _ChapterDrawer(
                  bookTitle: widget.item.book.title,
                  sourceId: _activeSource?.id,
                  sourceName: _activeSource?.displayName,
                  sourceFormat: _activeSource?.format ?? '',
                  sources: _sources,
                  entries: _catalog,
                  currentEntryId: _currentCatalogEntry()?.id,
                  currentLocationTitle: _currentLocationTitle(),
                  currentLocationSubtitle: _currentLocationSubtitle(),
                  imageEntries: _imageEntries,
                  readingMode: _readingMode,
                  expandedIds: _expandedCatalogIds,
                  loading: _catalogLoading,
                  loadingSubtitle: _catalogScanTotal > 0
                      ? '正在整理章节目录（$_catalogScanCompleted/$_catalogScanTotal），可稍后返回。'
                      : _isStructuredSourceFormat(_activeSource?.format)
                      ? '正在整理文档结构，完成后章节会出现在这里。'
                      : '先继续查看原书页，目录完成后会出现在这里。',
                  onSelect: _selectCatalogEntry,
                  onToggle: _toggleCatalogNode,
                  onCapture: _capturePages,
                  onDeleteImage: _deleteImageRecognition,
                  onToggleImage: _toggleImageRecognition,
                  needsConfirmation:
                      !_isStructuredSourceFormat(_activeSource?.format) &&
                      _activeSource?.catalogStatus != 'confirmed',
                  onConfirm:
                      _isStructuredSourceFormat(_activeSource?.format) ||
                          _catalog.isEmpty
                      ? null
                      : _confirmCatalog,
                  onRetry: _activeSource == null
                      ? null
                      : _isStructuredSourceFormat(_activeSource?.format)
                      ? () => _loadDocument(_activeSource!)
                      : () => _parseCatalog(_activeSource!),
                  onSelectSource: _showSourcePicker,
                  onSelectImage: _selectImageEntry,
                  onReadingModeChanged: (mode) =>
                      unawaited(_setReadingMode(mode)),
                  onClose: _closeDrawer,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final preview = _selectedNote;
    final original = _buildOriginalBody();
    // PDF stays in the fixed-page reader. Selected notes are a separate
    // preview state for captured/reflowable material only.
    final showingPreview =
        _activeSource?.format != 'pdf' &&
        preview != null &&
        _previewNoteWhileOriginal == null;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(ignoring: showingPreview, child: original),
        ),
        if (showingPreview)
          Positioned.fill(
            child: _StructuredPageSurface(
              note: preview,
              imageStore: _imageStore,
            ),
          ),
      ],
    );
  }

  Widget _buildOriginalBody() {
    final source = _activeSource;
    if (source != null && _isStructuredSourceFormat(source.format)) {
      return _buildDocumentBody();
    }
    if (source == null || !File(source.filePath).existsSync()) {
      return _OriginalEmptyState(
        title: _notes.isEmpty ? '还没有已还原的书页' : '当前书页尚未还原',
        subtitle: '可以先从左上角选择章节和书页，或拍摄书页后提取正文。',
        onCapture: _capturePages,
      );
    }
    _pdfController ??= PdfViewerController();
    final documentRef = _pdfDocumentRefFor(source);
    final documentListenable = documentRef.resolveListenable();
    final documentAlreadyLoaded = documentListenable.document != null;
    final horizontal = _readingMode == ReaderPaginationMode.horizontal;
    return Padding(
      padding: const EdgeInsets.only(top: 124, bottom: 18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          PdfPageCanvas(
            documentRef: documentRef,
            controller: _pdfController!,
            document: const BookPageDocument(blocks: []),
            initialPageNumber: _pdfAnchor?.pageNumber ?? _pdfPage,
            horizontal: horizontal,
            layoutPages: horizontal ? horizontalPdfPageLayout : null,
            pageOverlaysBuilder: _buildPdfPageOverlays,
            calculateInitialZoom: horizontal
                ? (document, controller, fitZoom, coverZoom) {
                    if (!controller.isReady) return fitZoom;
                    return _pdfPageWidthZoom(
                      controller,
                      controller.pageNumber ?? _pdfPage,
                    );
                  }
                : null,
            onInteractionStart: horizontal ? _onPdfInteractionStart : null,
            onInteractionEnd: horizontal ? _onPdfInteractionEnd : null,
            onKey: horizontal ? _onPdfKey : null,
            onViewSizeChanged: horizontal
                ? (viewSize, oldViewSize, controller) {
                    if (oldViewSize == null || !controller.isReady) return;
                    _updatePdfPageCount();
                    Future<void>.delayed(Duration.zero, () {
                      if (!mounted || !controller.isReady) return;
                      _updatePdfPageCount();
                      unawaited(
                        _goToPdfPage(_pdfPage, duration: Duration.zero),
                      );
                    });
                  }
                : null,
            onPageChanged: (page) {
              if (page != null && mounted) {
                setState(() {
                  _pdfPage = page;
                  if (_pdfController?.isReady == true) {
                    _pdfPageCount = _pdfController!.layout.pageLayouts.length;
                  }
                  _pdfAnchor = PdfReaderAnchor(
                    sourceId: source.id.toString(),
                    pageNumber: page,
                  );
                  _expandedCatalogIds = _expandedWithCurrentPath();
                  unawaited(
                    _paginationPreferences.saveAnchor(
                      bookId: widget.item.book.id!,
                      anchor: _pdfAnchor!,
                    ),
                  );
                });
              }
            },
            onDocumentLoadFinished: (_, succeeded) {
              if (!mounted || _activeSource?.id != source.id) return;
              setState(() => _pdfFirstPageReady = succeeded);
            },
            onViewerReady: (_, _) {
              if (!documentAlreadyLoaded || !mounted) return;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || _activeSource?.id != source.id) return;
                setState(() => _pdfFirstPageReady = true);
              });
            },
            loadingBannerBuilder: (_, _, _) =>
                const Center(child: Text('原书页正在打开')),
            errorBannerBuilder: (_, error, _, _) =>
                Center(child: Text('原书页打开失败：$error')),
          ),
          if (!_pdfFirstPageReady && documentListenable.error == null)
            const Positioned.fill(child: _PdfFirstPagePlaceholder()),
        ],
      ),
    );
  }

  PdfDocumentRef _pdfDocumentRefFor(BookSourceRecord source) =>
      PdfDocumentSessionCache.obtain(source);

  List<Widget> _buildPdfPageOverlays(
    BuildContext _,
    Rect pageRect,
    PdfPage page,
  ) {
    final note = _replacementNoteForPdfPage(page.pageNumber);
    if (note == null || _previewNoteWhileOriginal != null) {
      return const <Widget>[];
    }
    final pageDocument = documentForBookNote(note);
    final originalById = <int, OcrBlock>{
      for (final block in pageDocument.blocks) block.id: block,
    };
    final edited = pageDocument.editedBlocks;
    if (edited == null) return const <Widget>[];
    final changed = edited
        .where((block) {
          final original = originalById[block.id];
          return original != null &&
              block.text != original.text &&
              block.type != 'figure' &&
              block.type != 'table' &&
              block.width > 0 &&
              block.height > 0;
        })
        .toList(growable: false);
    if (changed.isEmpty) return const <Widget>[];
    return [
      IgnorePointer(
        child: SizedBox(
          width: pageRect.width,
          height: pageRect.height,
          child: Stack(
            children: [
              for (final block in changed)
                Positioned(
                  left: block.x * pageRect.width,
                  top: block.y * pageRect.height,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: block.width * pageRect.width,
                      minHeight: block.height * pageRect.height,
                    ),
                    child: ColoredBox(
                      color: Colors.white,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          block.text,
                          maxLines: null,
                          overflow: TextOverflow.clip,
                          style: pdfPageTextStyle(
                            block,
                            block.height * pageRect.height,
                            color: NotePageTheme.bookText,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _buildDocumentBody() {
    if (_catalogLoading) {
      return Center(
        child: Text(
          _activeSource?.format == 'txt' ? '正在整理 TXT 内容' : '正在整理文档内容',
        ),
      );
    }
    final document = _document;
    final error = _documentError;
    if (error != null || document == null || document.chapters.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            error == null ? '资料暂时没有可读取的内容' : '资料打开失败：$error',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 124, bottom: 18),
      child: ReflowDocumentPager(
        key: ValueKey('reflow_document_pager_${_activeSource?.id}'),
        document: document,
        sourceId: _activeSource?.id.toString() ?? '',
        initialChapterId: _selectedDocumentChapterId,
        mode: _readingMode,
        initialAnchor: _pendingDocumentAnchor,
        onChapterChanged: (chapterId) {
          if (_selectedDocumentChapterId == chapterId) return;
          if (mounted) {
            setState(() {
              _selectedDocumentChapterId = chapterId;
              _expandedCatalogIds = _expandedWithCurrentPath();
            });
          } else {
            _selectedDocumentChapterId = chapterId;
          }
        },
        onAnchorChanged: (anchor) {
          if (mounted) {
            setState(() {
              _pendingDocumentAnchor = anchor;
              _expandedCatalogIds = _expandedWithCurrentPath();
            });
          } else {
            _pendingDocumentAnchor = anchor;
          }
          unawaited(
            _paginationPreferences.saveAnchor(
              bookId: widget.item.book.id!,
              anchor: anchor,
            ),
          );
        },
        onProgressChanged: (progress) {
          if (!mounted) return;
          setState(() => _reflowProgress = progress);
        },
        blockBuilder: (context, slice, onSelectionChanged) {
          final asset = slice.block.assetId.isEmpty
              ? null
              : document.assets
                    .where((item) => item.id == slice.block.assetId)
                    .firstOrNull;
          return XiaoqiDocumentBlockView(
            block: slice.block,
            asset: asset,
            textOverride: slice.text,
            tableRowsOverride: slice.tableRows,
            continuation: slice.continuation,
            onSelectionChanged: onSelectionChanged,
          );
        },
      ),
    );
  }

  Widget _buildToolbar() => Stack(
    children: [
      Positioned(
        top: 12,
        left: 16,
        child: _ReaderActionCapsule(
          children: [
            _ReaderIconButton(
              key: const Key('body_workspace_back_button'),
              icon: Icons.arrow_back,
              tooltip: '返回书籍详情',
              onPressed: _handleWorkspaceBack,
            ),
            EditorToolbarAssetButton(
              key: const Key('body_workspace_catalog_button'),
              tooltip: '查看目录与识别文本',
              onPressed: _toggleDrawer,
              assetPath: EditorToolbarAssets.bookPageA,
              color: NotePageTheme.ink,
              iconSize: 32,
              buttonExtent: 52,
            ),
          ],
        ),
      ),
      Positioned(
        top: 12,
        right: 16,
        child: Row(
          children: [
            if (_selectedNote != null &&
                _previewNoteWhileOriginal == null &&
                _activeSource?.format == 'pdf')
              _ReaderTextButton(
                label: '替换当前页',
                icon: Icons.swap_horiz_rounded,
                onPressed: _replaceSelectedImageOnCurrentPdfPage,
              ),
            if (_selectedNote != null &&
                _previewNoteWhileOriginal == null &&
                _activeSource?.format == 'pdf')
              const SizedBox(width: 8),
            if (_selectedNote != null || _previewNoteWhileOriginal != null)
              _ReaderLongPressButton(
                label: '原书',
                icon: _activeSource?.format == 'pdf'
                    ? Icons.picture_as_pdf_outlined
                    : Icons.menu_book_outlined,
                onLongPressStart: _showOriginalWhilePressed,
                onLongPressEnd: _restorePreviewAfterOriginal,
                onLongPressCancel: _restorePreviewAfterOriginal,
              ),
            if (_selectedNote != null || _previewNoteWhileOriginal != null)
              const SizedBox(width: 8),
            _ReaderTextButton(
              label: '随记',
              icon: Icons.edit_note_outlined,
              onPressed: _openQuickNote,
            ),
            const SizedBox(width: 8),
            _ReaderIconButton(
              key: const Key('body_workspace_edit_button'),
              icon: Icons.edit_outlined,
              tooltip: _isStructuredSourceFormat(_activeSource?.format)
                  ? '编辑资料'
                  : '编辑书页',
              onPressed:
                  !_pdfEditPreparing &&
                      (_selectedNote != null ||
                          _isStructuredSourceFormat(_activeSource?.format) ||
                          _activeSource?.format == 'pdf')
                  ? _openEditor
                  : null,
            ),
          ],
        ),
      ),
    ],
  );
}

class _DocumentBlockView extends StatelessWidget {
  const _DocumentBlockView({
    required this.block,
    this.asset,
    this.textOverride,
    this.tableRowsOverride,
    this.continuation = false,
    this.onSelectionChanged,
  });

  final XiaoqiDocumentBlock block;
  final XiaoqiDocumentAsset? asset;
  final String? textOverride;
  final List<List<String>>? tableRowsOverride;
  final bool continuation;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final text = textOverride ?? block.text;
    switch (block.kind) {
      case 'heading':
        return Padding(
          padding: EdgeInsets.only(
            top: continuation
                ? 0
                : block.level <= 1
                ? 8
                : 14,
            bottom: 6,
          ),
          child: Text(
            text,
            style: TextStyle(
              color: NotePageTheme.ink,
              fontSize: block.level <= 1 ? 21 : 18,
              height: 1.35,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      case 'list_item':
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SelectableText(
            continuation ? text : '• $text',
            style: const TextStyle(
              color: NotePageTheme.bookText,
              fontSize: 17,
              height: 1.6,
            ),
            onSelectionChanged: (selection, _) =>
                onSelectionChanged?.call(!selection.isCollapsed),
          ),
        );
      case 'quote':
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: NotePageTheme.gold, width: 3),
            ),
            color: NotePageTheme.soft,
          ),
          child: SelectableText(
            text,
            style: const TextStyle(
              color: NotePageTheme.bookText,
              fontSize: 16,
              height: 1.6,
            ),
            onSelectionChanged: (selection, _) =>
                onSelectionChanged?.call(!selection.isCollapsed),
          ),
        );
      case 'code':
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F1F2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SelectableText(
            text,
            style: const TextStyle(
              color: NotePageTheme.ink,
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.5,
            ),
            onSelectionChanged: (selection, _) =>
                onSelectionChanged?.call(!selection.isCollapsed),
          ),
        );
      case 'divider':
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(color: NotePageTheme.lineStrong),
        );
      case 'table':
        return _DocumentTableBlock(
          block: block,
          textOverride: textOverride,
          rowsOverride: tableRowsOverride,
          onSelectionChanged: onSelectionChanged,
        );
      case 'image':
        return _DocumentImageBlock(
          block: block,
          asset: asset,
          textOverride: textOverride,
        );
      default:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SelectableText(
            text,
            style: const TextStyle(
              color: NotePageTheme.bookText,
              fontSize: 17,
              height: 1.7,
            ),
            onSelectionChanged: (selection, _) =>
                onSelectionChanged?.call(!selection.isCollapsed),
          ),
        );
    }
  }
}

class _DocumentTableBlock extends StatelessWidget {
  const _DocumentTableBlock({
    required this.block,
    this.textOverride,
    this.rowsOverride,
    this.onSelectionChanged,
  });

  final XiaoqiDocumentBlock block;
  final String? textOverride;
  final List<List<String>>? rowsOverride;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final rawRows = rowsOverride ?? _decodeDocumentTableRows(block);
    if (rawRows == null) return _fallbackTable(textOverride ?? block.text);
    try {
      final rows = rawRows;
      if (rows.isEmpty) return _fallbackTable(textOverride ?? block.text);
      final columnCount = rows.fold<int>(
        0,
        (max, row) => row.length > max ? row.length : max,
      );
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          border: Border.all(color: NotePageTheme.lineStrong),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Table(
          border: TableBorder.symmetric(
            inside: BorderSide(color: NotePageTheme.lineStrong),
          ),
          children: [
            for (final row in rows)
              TableRow(
                children: [
                  for (var index = 0; index < columnCount; index++)
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: SelectableText(
                        index < row.length ? row[index] : '',
                        style: const TextStyle(
                          color: NotePageTheme.bookText,
                          fontSize: 15,
                          height: 1.45,
                        ),
                        onSelectionChanged: (selection, _) =>
                            onSelectionChanged?.call(!selection.isCollapsed),
                      ),
                    ),
                ],
              ),
          ],
        ),
      );
    } catch (_) {
      return _fallbackTable(textOverride ?? block.text);
    }
  }

  Widget _fallbackTable(String text) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: NotePageTheme.soft,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: NotePageTheme.lineStrong),
    ),
    child: SelectableText(
      text,
      style: const TextStyle(
        color: NotePageTheme.bookText,
        fontSize: 16,
        height: 1.55,
      ),
      onSelectionChanged: (selection, _) =>
          onSelectionChanged?.call(!selection.isCollapsed),
    ),
  );
}

List<List<String>>? _decodeDocumentTableRows(XiaoqiDocumentBlock block) {
  final rawRows = block.attributes['rows'];
  if (rawRows == null) return null;
  try {
    final decoded = jsonDecode(rawRows);
    if (decoded is! List) return null;
    final rows = decoded
        .whereType<List>()
        .map(
          (row) => row.map((cell) => cell.toString()).toList(growable: false),
        )
        .where((row) => row.isNotEmpty)
        .toList(growable: false);
    return rows.isEmpty ? null : rows;
  } catch (_) {
    return null;
  }
}

class _DocumentImageBlock extends StatelessWidget {
  const _DocumentImageBlock({
    required this.block,
    required this.asset,
    this.textOverride,
  });

  final XiaoqiDocumentBlock block;
  final XiaoqiDocumentAsset? asset;
  final String? textOverride;

  @override
  Widget build(BuildContext context) {
    final currentAsset = asset;
    if (currentAsset == null || currentAsset.bytes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          (textOverride ?? block.text).isEmpty
              ? '文档图片暂时无法显示'
              : (textOverride ?? block.text),
          style: const TextStyle(color: NotePageTheme.inkSecondary),
        ),
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: NotePageTheme.soft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: Image.memory(
              Uint8List.fromList(currentAsset.bytes),
              fit: BoxFit.contain,
              width: double.infinity,
              errorBuilder: (_, _, _) => const Text('文档图片暂时无法显示'),
            ),
          ),
          if (currentAsset.altText.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              currentAsset.altText,
              style: const TextStyle(
                color: NotePageTheme.inkSecondary,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SourcePickerSheet extends StatelessWidget {
  const _SourcePickerSheet({
    required this.sources,
    required this.activeSourceId,
  });

  final List<BookSourceRecord> sources;
  final int? activeSourceId;

  @override
  Widget build(BuildContext context) => Material(
    color: NotePageTheme.card,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
    clipBehavior: Clip.antiAlias,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: NotePageTheme.lineStrong,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '选择正文资料',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              '切换只改变当前查看来源，不会删除文件或笔记。',
              style: TextStyle(color: NotePageTheme.inkSecondary),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: sources.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final source = sources[index];
                  final selected = source.id == activeSourceId;
                  return Material(
                    color: selected
                        ? NotePageTheme.greenSoft
                        : NotePageTheme.soft,
                    borderRadius: BorderRadius.circular(14),
                    child: ListTile(
                      onTap: () => Navigator.of(context).pop(source),
                      minVerticalPadding: 10,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                      ),
                      leading: Container(
                        width: 46,
                        height: 46,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _sourceFormatColor(source.format),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          _sourceFormatLabel(source.format),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      title: Text(
                        source.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '${_sourceFormatBytes(source.fileSize)} · ${_sourceStatusLabel(source.status)}',
                      ),
                      trailing: selected
                          ? const Icon(
                              Icons.check_circle_rounded,
                              color: NotePageTheme.green,
                            )
                          : const Icon(
                              Icons.radio_button_unchecked_rounded,
                              color: NotePageTheme.inkSecondary,
                            ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ImageImportChoiceSheet extends StatelessWidget {
  const _ImageImportChoiceSheet();

  @override
  Widget build(BuildContext context) => Material(
    color: NotePageTheme.card,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: NotePageTheme.lineStrong,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '添加图片识别文本',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              '图片会先保存到图片区，识别完成后再决定是否替换正文。',
              style: TextStyle(color: NotePageTheme.inkSecondary),
            ),
            const SizedBox(height: 12),
            ListTile(
              minVerticalPadding: 10,
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍摄照片'),
              subtitle: const Text('打开相机，完成后返回正文工作台'),
              onTap: () =>
                  Navigator.of(context).pop(BookImageImportAction.capture),
            ),
            ListTile(
              minVerticalPadding: 10,
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('上传图片'),
              subtitle: const Text('从相册选择一张或多张图片'),
              onTap: () =>
                  Navigator.of(context).pop(BookImageImportAction.upload),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DrawerSectionHeader extends StatelessWidget {
  const _DrawerSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
    child: Text(
      title,
      style: const TextStyle(
        color: NotePageTheme.ink,
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _RecognitionPreview extends StatefulWidget {
  const _RecognitionPreview({required this.entry});

  final BookImageRecognitionEntry entry;

  @override
  State<_RecognitionPreview> createState() => _RecognitionPreviewState();
}

class _RecognitionPreviewState extends State<_RecognitionPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  bool get _animating =>
      widget.entry.note == null &&
      widget.entry.batchStatus == 'processing' &&
      widget.entry.status != 'failed' &&
      widget.entry.status != 'cancelled';

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (_animating) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _RecognitionPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_animating && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!_animating && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.entry.note;
    if (note != null) {
      final text = note.content.trim().replaceAll(RegExp(r'\s+'), ' ');
      return Container(
        width: 48,
        height: 48,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: NotePageTheme.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text.isEmpty ? '已识别' : text,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: NotePageTheme.inkSecondary,
            fontSize: 8,
            height: 1.2,
          ),
        ),
      );
    }
    final paused = widget.entry.batchStatus == 'paused';
    final stopped =
        widget.entry.status == 'failed' || widget.entry.status == 'cancelled';
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final cover = _animating ? 1 - _controller.value : 1.0;
        return Container(
          width: 48,
          height: 48,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: NotePageTheme.greenSoft,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: Icon(
                  stopped
                      ? Icons.error_outline_rounded
                      : paused
                      ? Icons.pause_rounded
                      : widget.entry.inputKind == CaptureInputKind.gallery
                      ? Icons.photo_library_outlined
                      : Icons.add_a_photo_outlined,
                  color: NotePageTheme.green,
                  size: 21,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: cover,
                  heightFactor: 1,
                  child: ColoredBox(color: const Color(0x665A7168)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ImageRecognitionTile extends StatelessWidget {
  const _ImageRecognitionTile({
    required this.entry,
    required this.onTap,
    this.onDelete,
  });

  final BookImageRecognitionEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final note = entry.note;
    final link = entry.link;
    final anchor = link?.toAnchor();
    final target = note == null
        ? entry.status == 'failed'
              ? '识别失败，可重新添加图片'
              : entry.status == 'cancelled'
              ? '已取消识别，可重新添加图片'
              : entry.status == 'captured'
              ? '等待识别'
              : '正在识别，完成后可预览正文'
        : link == null
        ? '未关联电子材料'
        : anchor is PdfReaderAnchor
        ? '已替换 ${entry.targetSourceName} · PDF 第 ${anchor.pageNumber} 页'
        : anchor is FlowReaderAnchor
        ? '已关联 ${entry.targetSourceName} · 章节 ${anchor.chapterId}'
        : '关联位置待核对';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      minVerticalPadding: 8,
      leading: _RecognitionPreview(entry: entry),
      title: Text(
        entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        '${entry.inputKind.displayLabel} · ${note?.bookPage.trim().isEmpty == false ? '书内第 ${note!.bookPage} 页 · ' : ''}$target',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: NotePageTheme.muted),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onDelete != null)
            IconButton(
              tooltip: '删除图片识别文本',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          const Icon(
            Icons.chevron_right_rounded,
            color: NotePageTheme.inkSecondary,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _ChapterDrawer extends StatelessWidget {
  const _ChapterDrawer({
    required this.bookTitle,
    required this.sourceId,
    required this.sourceName,
    required this.sourceFormat,
    required this.sources,
    required this.entries,
    required this.currentEntryId,
    required this.currentLocationTitle,
    required this.currentLocationSubtitle,
    required this.imageEntries,
    required this.readingMode,
    required this.expandedIds,
    required this.loading,
    required this.loadingSubtitle,
    required this.onSelect,
    required this.onToggle,
    required this.onCapture,
    required this.onDeleteImage,
    required this.onToggleImage,
    required this.needsConfirmation,
    required this.onConfirm,
    required this.onRetry,
    required this.onSelectSource,
    required this.onSelectImage,
    required this.onReadingModeChanged,
    required this.onClose,
  });

  final String bookTitle;
  final int? sourceId;
  final String? sourceName;
  final String sourceFormat;
  final List<BookSourceRecord> sources;
  final List<PdfCatalogEntry> entries;
  final String? currentEntryId;
  final String currentLocationTitle;
  final String currentLocationSubtitle;
  final List<BookImageRecognitionEntry> imageEntries;
  final ReaderPaginationMode readingMode;
  final Set<String> expandedIds;
  final bool loading;
  final String loadingSubtitle;
  final ValueChanged<PdfCatalogEntry> onSelect;
  final ValueChanged<String> onToggle;
  final VoidCallback onCapture;
  final ValueChanged<BookImageRecognitionEntry> onDeleteImage;
  final ValueChanged<BookImageRecognitionEntry> onToggleImage;
  final bool needsConfirmation;
  final VoidCallback? onConfirm;
  final VoidCallback? onRetry;
  final VoidCallback onSelectSource;
  final ValueChanged<BookImageRecognitionEntry> onSelectImage;
  final ValueChanged<ReaderPaginationMode> onReadingModeChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final visibleEntries = _visibleEntries();
    final parentIds = entries
        .map((entry) => entry.parentId)
        .whereType<String>()
        .toSet();
    final width = (MediaQuery.sizeOf(context).width * .78)
        .clamp(280.0, 360.0)
        .toDouble();
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: width,
      child: Material(
        color: NotePageTheme.card,
        elevation: 18,
        child: SafeArea(
          right: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '目录与识别文本',
                        style: TextStyle(
                          color: NotePageTheme.ink,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭目录与识别文本',
                      onPressed: onClose,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                Text(
                  '《$bookTitle》${sourceName == null ? '' : ' · $sourceName'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NotePageTheme.muted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                  decoration: BoxDecoration(
                    color: NotePageTheme.soft,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: NotePageTheme.lineStrong),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        currentEntryId == null
                            ? Icons.location_searching_rounded
                            : Icons.my_location_rounded,
                        size: 18,
                        color: currentEntryId == null
                            ? NotePageTheme.gold
                            : NotePageTheme.green,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '当前阅读位置',
                              style: TextStyle(
                                color: NotePageTheme.muted,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              currentLocationTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: NotePageTheme.ink,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              currentLocationSubtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: NotePageTheme.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (sources.length > 1) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: onSelectSource,
                      icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                      label: const Text('切换当前资料'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  '翻页方式',
                  style: TextStyle(
                    color: NotePageTheme.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  sourceFormat.isEmpty
                      ? '仅影响当前正文资料'
                      : '仅影响当前 ${sourceFormat.toUpperCase()} 资料',
                  style: const TextStyle(
                    color: NotePageTheme.muted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _ReadingModeOption(
                        mode: ReaderPaginationMode.horizontal,
                        selected:
                            readingMode == ReaderPaginationMode.horizontal,
                        onTap: () => onReadingModeChanged(
                          ReaderPaginationMode.horizontal,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ReadingModeOption(
                        mode: ReaderPaginationMode.vertical,
                        selected: readingMode == ReaderPaginationMode.vertical,
                        onTap: () =>
                            onReadingModeChanged(ReaderPaginationMode.vertical),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: loading
                      ? _DrawerMessage(
                          title: '目录正在准备',
                          subtitle: loadingSubtitle,
                        )
                      : ListView.separated(
                          itemCount:
                              1 +
                              (visibleEntries.isEmpty
                                  ? 1
                                  : visibleEntries.length) +
                              1 +
                              (imageEntries.isEmpty ? 1 : imageEntries.length),
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final catalogCount = visibleEntries.isEmpty
                                ? 1
                                : visibleEntries.length;
                            final imageHeaderIndex = 1 + catalogCount;
                            if (index == 0) {
                              return const _DrawerSectionHeader(
                                title: '电子材料目录',
                              );
                            }
                            if (index < imageHeaderIndex) {
                              if (visibleEntries.isEmpty) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  child: Text(
                                    '还没有可用目录，仍可直接查看电子材料。',
                                    style: TextStyle(
                                      color: NotePageTheme.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                );
                              }
                              final entry = visibleEntries[index - 1];
                              final isCurrent = entry.id == currentEntryId;
                              final hasChildren = parentIds.contains(entry.id);
                              final indent = ((entry.level - 1) * 14.0)
                                  .clamp(0.0, width - 92.0)
                                  .toDouble();
                              final ready =
                                  sourceId != null &&
                                  imageEntries.any((item) {
                                    final link = item.link;
                                    final anchor = link?.toAnchor();
                                    return item.note != null &&
                                        link?.targetSourceId == sourceId &&
                                        link?.mode == 'replace' &&
                                        anchor is PdfReaderAnchor &&
                                        anchor.pageNumber == entry.pdfPage;
                                  });
                              final sourceHint = entry.sourcePdfPage == null
                                  ? ''
                                  : ' · 来源目录第 ${entry.sourcePdfPage} 页';
                              final pageDescription =
                                  sourceFormat != 'pdf' &&
                                      sourceFormat.isNotEmpty
                                  ? '${sourceFormat.toUpperCase()} 章节 · 点击查看'
                                  : entry.pdfPage == null
                                  ? '页码待确认$sourceHint'
                                  : entry.status == 'estimated'
                                  ? 'PDF 第 ${entry.pdfPage} 页 · 估算页码$sourceHint'
                                  : entry.status == 'needs_review'
                                  ? 'PDF 第 ${entry.pdfPage} 页 · 页码待核对$sourceHint'
                                  : 'PDF 第 ${entry.pdfPage} 页 · ${ready ? '已还原' : '查看原书页'}$sourceHint';
                              return Padding(
                                padding: EdgeInsets.only(left: indent),
                                child: Semantics(
                                  selected: isCurrent,
                                  label: isCurrent
                                      ? '${entry.title}，当前位置'
                                      : entry.title,
                                  child: ListTile(
                                    selected: isCurrent,
                                    selectedTileColor: NotePageTheme.green
                                        .withOpacity(.10),
                                    dense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    leading: SizedBox(
                                      width: 62,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 40,
                                            height: 40,
                                            child: hasChildren
                                                ? IconButton(
                                                    padding: EdgeInsets.zero,
                                                    constraints:
                                                        const BoxConstraints(
                                                          minWidth: 40,
                                                          minHeight: 40,
                                                        ),
                                                    tooltip:
                                                        expandedIds.contains(
                                                          entry.id,
                                                        )
                                                        ? '折叠 ${entry.title}'
                                                        : '展开 ${entry.title}',
                                                    onPressed: () =>
                                                        onToggle(entry.id),
                                                    icon: Icon(
                                                      expandedIds.contains(
                                                            entry.id,
                                                          )
                                                          ? Icons
                                                                .expand_more_rounded
                                                          : Icons
                                                                .chevron_right_rounded,
                                                      color: NotePageTheme
                                                          .inkSecondary,
                                                      size: 18,
                                                    ),
                                                  )
                                                : null,
                                          ),
                                          Icon(
                                            entry.level == 1
                                                ? Icons.menu_book_outlined
                                                : Icons.description_outlined,
                                            color: NotePageTheme.green,
                                            size: 20,
                                          ),
                                        ],
                                      ),
                                    ),
                                    title: Text(
                                      entry.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: isCurrent
                                            ? NotePageTheme.green
                                            : NotePageTheme.ink,
                                        fontSize: entry.level == 1 ? 15 : 14,
                                        fontWeight: entry.level == 1
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                                    subtitle: Text(
                                      pageDescription,
                                      style: const TextStyle(
                                        color: NotePageTheme.muted,
                                        fontSize: 11,
                                      ),
                                    ),
                                    trailing: Icon(
                                      isCurrent
                                          ? Icons.my_location_rounded
                                          : Icons.chevron_right_rounded,
                                      color: isCurrent
                                          ? NotePageTheme.green
                                          : NotePageTheme.inkSecondary,
                                    ),
                                    onTap: () => onSelect(entry),
                                  ),
                                ),
                              );
                            }
                            if (index == imageHeaderIndex) {
                              return const _DrawerSectionHeader(
                                title: '图片识别文本',
                              );
                            }
                            if (imageEntries.isEmpty) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Text(
                                  '还没有图片识别文本，点击下方“拍摄或选择图片”开始。',
                                  style: TextStyle(
                                    color: NotePageTheme.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              );
                            }
                            final imageEntry =
                                imageEntries[index - imageHeaderIndex - 1];
                            return _ImageRecognitionTile(
                              entry: imageEntry,
                              onTap:
                                  imageEntry.note == null &&
                                      (imageEntry.batchStatus == 'processing' ||
                                          imageEntry.batchStatus == 'paused')
                                  ? () => onToggleImage(imageEntry)
                                  : () => onSelectImage(imageEntry),
                              onDelete: () => onDeleteImage(imageEntry),
                            );
                          },
                        ),
                ),
                if (needsConfirmation && onConfirm != null) ...[
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: onConfirm,
                    style: FilledButton.styleFrom(
                      backgroundColor: NotePageTheme.green,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('确认目录'),
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: onCapture,
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: const Text('拍摄或选择图片'),
                  style: FilledButton.styleFrom(
                    backgroundColor: NotePageTheme.card,
                    foregroundColor: NotePageTheme.green,
                    side: const BorderSide(color: NotePageTheme.green),
                    minimumSize: const Size.fromHeight(48),
                    elevation: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<PdfCatalogEntry> _visibleEntries() {
    final byId = {for (final entry in entries) entry.id: entry};
    final children = <String?, List<PdfCatalogEntry>>{};
    for (final entry in entries) {
      final parent = entry.parentId != null && byId.containsKey(entry.parentId)
          ? entry.parentId
          : null;
      children.putIfAbsent(parent, () => []).add(entry);
    }
    for (final group in children.values) {
      group.sort((a, b) => a.order.compareTo(b.order));
    }
    final visible = <PdfCatalogEntry>[];
    final visited = <String>{};
    void visit(PdfCatalogEntry entry) {
      if (!visited.add(entry.id)) return;
      visible.add(entry);
      if (!expandedIds.contains(entry.id)) return;
      for (final child in children[entry.id] ?? const <PdfCatalogEntry>[]) {
        visit(child);
      }
    }

    for (final root in children[null] ?? const <PdfCatalogEntry>[]) {
      visit(root);
    }
    return visible;
  }
}

class _ReadingModeOption extends StatelessWidget {
  const _ReadingModeOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ReaderPaginationMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: mode.label,
      child: Material(
        color: selected ? NotePageTheme.greenSoft : NotePageTheme.soft,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  mode == ReaderPaginationMode.horizontal
                      ? Icons.swap_horiz_rounded
                      : Icons.swap_vert_rounded,
                  size: 19,
                  color: selected
                      ? NotePageTheme.green
                      : NotePageTheme.inkSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  mode.label,
                  style: TextStyle(
                    color: selected
                        ? NotePageTheme.green
                        : NotePageTheme.inkSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerMessage extends StatelessWidget {
  const _DrawerMessage({
    required this.title,
    required this.subtitle,
    this.action,
  });

  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.account_tree_outlined,
          size: 34,
          color: NotePageTheme.muted,
        ),
        const SizedBox(height: 10),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(color: NotePageTheme.muted, fontSize: 12),
        ),
        ?action,
      ],
    ),
  );
}

class _StructuredPageSurface extends StatelessWidget {
  const _StructuredPageSurface({required this.note, required this.imageStore});

  final Note note;
  final PageImageAssetStore imageStore;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.only(top: 78, bottom: 18),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
        child: Stack(
          children: [
            BookPageDocumentView(document: documentForBookNote(note)),
            Positioned.fill(
              child: IgnorePointer(
                child: BookPageAnnotationView(
                  document: annotationsForBookNote(note),
                  imageStore: imageStore,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PdfFirstPagePlaceholder extends StatelessWidget {
  const _PdfFirstPagePlaceholder();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: NotePageTheme.canvas,
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: NotePageTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: NotePageTheme.line),
          boxShadow: NotePageTheme.cardShadow,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.picture_as_pdf_outlined,
                size: 30,
                color: NotePageTheme.green,
              ),
              const SizedBox(height: 10),
              const Text(
                '正在准备原书页',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              const Text(
                '正文位置已恢复，页面很快就会显示',
                style: TextStyle(color: NotePageTheme.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _OriginalEmptyState extends StatelessWidget {
  const _OriginalEmptyState({
    required this.title,
    required this.subtitle,
    required this.onCapture,
  });

  final String title;
  final String subtitle;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 120, 24, 24),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.menu_book_outlined,
            size: 44,
            color: NotePageTheme.muted,
          ),
          const SizedBox(height: 14),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: NotePageTheme.muted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onCapture,
            icon: const Icon(Icons.add_a_photo_outlined),
            label: const Text('拍摄书页'),
          ),
        ],
      ),
    ),
  );
}

class _ReaderActionCapsule extends StatelessWidget {
  const _ReaderActionCapsule({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: NotePageTheme.card,
    elevation: 8,
    borderRadius: BorderRadius.circular(18),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );
}

class _ReaderIconButton extends StatelessWidget {
  const _ReaderIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    icon: Icon(icon),
    color: NotePageTheme.ink,
    constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
    splashRadius: 24,
  );
}

class _ReaderTextButton extends StatelessWidget {
  const _ReaderTextButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: NotePageTheme.card,
    elevation: 8,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 19, color: NotePageTheme.ink),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: NotePageTheme.ink,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ReaderLongPressButton extends StatelessWidget {
  const _ReaderLongPressButton({
    required this.label,
    required this.icon,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.onLongPressCancel,
  });

  final String label;
  final IconData icon;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;
  final VoidCallback onLongPressCancel;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '长按$label查看，松手返回识别文本',
    child: Material(
      color: NotePageTheme.card,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: onLongPressStart,
        onLongPressEnd: (_) => onLongPressEnd(),
        onLongPressCancel: onLongPressCancel,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19, color: NotePageTheme.ink),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  color: NotePageTheme.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _sourceStatusLabel(String status) {
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

class _ReaderPageProgressPill extends StatelessWidget {
  const _ReaderPageProgressPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 360),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: NotePageTheme.card.withValues(alpha: .94),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: NotePageTheme.lineStrong),
      boxShadow: const [
        BoxShadow(
          color: Color(0x22000000),
          blurRadius: 10,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: NotePageTheme.inkSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

String _sourceFormatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

bool _isStructuredSourceFormat(String? format) =>
    SourceDocumentLoader.isStructuredFormat(format);

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
