import 'dart:async';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/api_config.dart';
import '../config/book_flow_theme.dart';
import '../models/captured_page.dart';
import '../models/capture_source_link.dart';
import '../models/book_library_item.dart';
import '../models/book_source.dart';
import '../models/note.dart';
import '../plugins/book_metadata/book_metadata_plugin.dart';
import '../models/book_recognition.dart';
import '../services/book_library_service.dart';
import '../services/book_recognition_repository.dart';
import '../services/camera_service.dart';
import '../services/database_service.dart';
import '../services/note_generation_service.dart';
import '../services/permission_service.dart';
import '../services/pdf_catalog_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/book_learning_bottom_bar.dart';
import '../widgets/book_metadata_form_sheet.dart';
import '../widgets/book_pdf_import_sheet.dart';
import 'book_isbn_scanner_page.dart';
import 'book_learning_space_page.dart';
import 'book_study_page.dart';
import 'discover_empty_page.dart';
import 'note_editor_page.dart';
import 'note_manager_page.dart';
import 'settings_page.dart';

class BookLearningShellPage extends StatefulWidget {
  const BookLearningShellPage({
    super.key,
    this.bookLibraryService,
    this.recognitionRepository,
    this.initialBookId,
    this.initialChapterTitle,
  });

  final BookLibraryService? bookLibraryService;
  final BookRecognitionRepository? recognitionRepository;
  final int? initialBookId;
  final String? initialChapterTitle;

  @override
  State<BookLearningShellPage> createState() => _BookLearningShellPageState();
}

class _BookLearningShellPageState extends State<BookLearningShellPage> {
  late final BookLibraryService _library;
  late final BookRecognitionRepository _recognition;
  late final BookMetadataPlugin _metadataPlugin;
  final CameraService _cameraService = CameraService();
  final PermissionService _permissionService = PermissionService();
  final ValueNotifier<int> _imageRecognitionVersion = ValueNotifier(0);

  BookLearningDestination _destination = BookLearningDestination.books;
  int? _openBookId;
  int _bookDetailVersion = 0;
  bool _openingCamera = false;

  @override
  void initState() {
    super.initState();
    _library = widget.bookLibraryService ?? BookLibraryService();
    _recognition =
        widget.recognitionRepository ??
        (ApiConfig.useCloudBookRecognition
            ? CloudBookRecognitionRepository()
            : MockBookRecognitionRepository());
    _metadataPlugin = resolveBookMetadataPlugin();
    _openBookId = widget.initialBookId;
    _cameraService.prefetchCameras();
  }

  Future<void> _changeDestination(BookLearningDestination value) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (value == BookLearningDestination.books) {
      if (_destination == value && _openBookId != null) {
        setState(() => _openBookId = null);
      } else {
        setState(() {
          _destination = value;
          _openBookId = null;
        });
      }
      return;
    }
    setState(() => _destination = value);
  }

  Future<void> _createBook() async {
    final action = await showBookAddSourceSheet(context);
    if (!mounted || action == null) return;
    if (action == BookAddAction.importPdf) {
      await _importBookSource();
      return;
    }
    await _scanBook();
  }

  Future<void> _scanBook() async {
    final candidate = await Navigator.of(context).push<BookCandidate>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => BookIsbnScannerPage(
          repository: _recognition,
          bookLibraryService: _library,
          metadataPlugin: _metadataPlugin,
        ),
      ),
    );
    if (!mounted || candidate == null) return;
    var book = candidate.book;
    // Give every new book access to the cover chooser, including recognised
    // ISBN results. The following legacy branch remains as a defensive path
    // for malformed candidates and will be skipped after this confirmation.
    final coverReady = await showModalBottomSheet<BookRecord>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x990C1712),
      builder: (_) => Material(
        color: BookFlowTheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: BookMetadataFormSheet(initial: book),
      ),
    );
    if (!mounted || coverReady == null) return;
    book = coverReady;
    if (book.title.trim().isEmpty || book.title == '待确认书籍') {
      final completed = await showModalBottomSheet<BookRecord>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => Material(
          color: BookFlowTheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BookMetadataFormSheet(initial: book),
        ),
      );
      if (!mounted || completed == null) return;
      book = completed;
    }
    try {
      final bookId = await _library.saveBook(book);
      if (!mounted) return;
      setState(() {
        _destination = BookLearningDestination.books;
        _openBookId = bookId;
        _bookDetailVersion++;
      });
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '书籍保存失败：$error');
    }
  }

  Future<void> _importBookSource() async {
    var file = await _pickBookSource();
    while (mounted && file != null) {
      final selectedFile = file;
      final books = await _library.listBooks();
      if (!mounted) return;
      final selection = await showBookPdfImportSheet(
        context: context,
        file: selectedFile,
        books: books,
      );
      if (!mounted || selection == null) return;
      if (selection.shouldReselect) {
        file = await _pickBookSource();
        continue;
      }

      try {
        final sourcePath = await _ensurePickedFilePath(selectedFile);
        var bookId = selection.bookId;
        if (bookId == null && selection.newBook != null) {
          bookId = await _library.saveBook(selection.newBook!);
        }
        if (bookId == null) return;
        final outcome = await _library.importBookSourceForBook(
          bookId: bookId,
          sourcePath: sourcePath,
          displayName: selectedFile.name,
          format: inferBookSourceFormat(selectedFile.name),
        );
        if (outcome.source.format == 'pdf' &&
            outcome.source.catalogStatus != 'processing' &&
            outcome.source.catalogStatus != 'confirmed' &&
            (outcome.source.catalogParserVersion <
                    PdfCatalogService.parserVersion ||
                outcome.source.catalogStatus == 'not_started' ||
                outcome.source.catalogStatus == 'failed')) {
          unawaited(_library.parsePdfCatalogForSource(outcome.source));
        }
        if (!mounted) return;
        if (outcome.reusedExisting) {
          _showDuplicateImportToast();
        }
        setState(() {
          _destination = BookLearningDestination.books;
          _openBookId = bookId;
          _bookDetailVersion++;
        });
      } catch (error) {
        if (mounted) AppToast.show(context, '资料导入失败：$error');
      }
      return;
    }
  }

  void _showDuplicateImportToast() {
    AppToast.show(context, '这份资料已经在本书资料中，不会重复添加');
  }

  Future<PlatformFile?> _pickBookSource() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedBookSourceFileExtensions,
      withData: true,
    );
    if (!mounted || result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final format = inferBookSourceFormat(file.name);
    if (!supportedBookSourceFormats.contains(format)) {
      AppToast.show(context, '目前支持导入 PDF 或 EPUB 文件');
      return null;
    }
    return file;
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

  Future<void> _captureBookPages(
    BookLibraryItem item,
    BookImageImportAction action,
  ) async {
    final bookId = item.book.id;
    if (bookId == null || _openingCamera) return;
    _openingCamera = true;
    try {
      final batch = action == BookImageImportAction.capture
          ? await _captureFromCamera()
          : await _captureFromGallery();
      if (batch == null || batch.pages.isEmpty || !mounted) return;
      final batchId = batch.pages
              .map((page) => page.captureBatchId)
              .whereType<String>()
              .where((value) => value.isNotEmpty)
              .firstOrNull ??
          'batch_${DateTime.now().microsecondsSinceEpoch}';
      final pages = [
        for (var index = 0; index < batch.pages.length; index++)
          _pageWithBatch(
            batch.pages[index],
            batchId,
            index,
            action == BookImageImportAction.capture
                ? CaptureInputKind.camera
                : CaptureInputKind.gallery,
          ),
      ];
      await _library.createDraftBatch(
        batchId,
        pages,
        selectedBookId: bookId,
      );
      if (!mounted) return;
      AppToast.show(context, '已添加 ${pages.length} 张图片，正在识别');
      unawaited(
        _processImageBatch(
          batchId: batchId,
          pages: pages,
          bookId: bookId,
          bookName: item.book.title,
        ),
      );
    } catch (error) {
      _cameraService.cancelPrepare();
      if (mounted) AppToast.show(context, '图片添加失败，请重试');
    } finally {
      _openingCamera = false;
    }
  }

  Future<CameraCaptureBatch?> _captureFromCamera() async {
    final permitted = await _permissionService.requestCameraPermission();
    if (!permitted) {
      if (mounted) _permissionService.showPermissionDeniedDialog(context, '相机');
      return null;
    }
    if (!mounted) return null;
    return _cameraService.takePhotoBatch(context);
  }

  Future<CameraCaptureBatch?> _captureFromGallery() async {
    final permitted = await _permissionService.requestGalleryPermission();
    if (!permitted) {
      if (mounted) _permissionService.showPermissionDeniedDialog(context, '相册');
      return null;
    }
    final files = await _cameraService.pickMultipleFromGallery(maxImages: 5);
    if (!mounted || files.isEmpty) return null;
    final batchId = 'batch_${DateTime.now().microsecondsSinceEpoch}';
    final capturedAt = DateTime.now().toIso8601String();
    return CameraCaptureBatch([
      for (var index = 0; index < files.length; index++)
        CapturedPage(
          path: files[index].path,
          inputKind: CaptureInputKind.gallery,
          capturedAt: capturedAt,
          captureBatchId: batchId,
          captureSequence: index,
        ),
    ]);
  }

  CapturedPage _pageWithBatch(
    CapturedPage page,
    String batchId,
    int index,
    CaptureInputKind inputKind,
  ) {
    return CapturedPage(
      path: page.path,
      inputKind: inputKind,
      isDoublePage: page.isDoublePage,
      pageGroupId: page.pageGroupId,
      pageGroupIndex: page.pageGroupIndex,
      sourcePhotoPath: page.sourcePhotoPath,
      capturedAt: page.capturedAt,
      captureBatchId: batchId,
      captureSequence: page.captureSequence ?? index,
    );
  }

  Future<void> _processImageBatch({
    required String batchId,
    required List<CapturedPage> pages,
    required int bookId,
    required String bookName,
  }) async {
    final processed = <int, Note>{};
    var failed = 0;
    var nextIndex = 0;
    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= pages.length) return;
        if (!await _waitForCaptureBatch(batchId)) return;
        final page = pages[index];
        try {
          final capturePageId = await _library.capturePageId(batchId, index);
          if (capturePageId == null ||
              await _library.isCapturePageRemoved(capturePageId)) {
            continue;
          }
          await _library.updateDraftPage(
            batchId: batchId,
            pageOrder: index,
            status: 'processing',
          );
          var note = await NoteGenerationService.prepareAnnotationNote(page);
          if (!await _waitForCaptureBatch(batchId)) return;
          if (await _library.isCapturePageRemoved(capturePageId)) continue;
          note = note.copyWith(
            bookId: bookId,
            bookName: bookName,
            capturePageId: capturePageId,
            captureBatchId: batchId,
            captureSequence: page.captureSequence ?? index,
            capturedAt: page.capturedAt,
          );
          await _library.updateDraftPage(
            batchId: batchId,
            pageOrder: index,
            status: 'processed',
            processedPath: note.photoPath,
            originalPath: note.originalPhotoPath,
            ocrJson: note.annotationsJson,
            editedText: note.content,
          );
          processed[index] = note;
        } catch (error) {
          if (await _library.isCaptureBatchCancelled(batchId)) return;
          failed++;
          await _library.updateDraftPage(
            batchId: batchId,
            pageOrder: index,
            status: 'failed',
            errorMessage: error.toString(),
          );
        }
      }
    }
    final workerCount = pages.length < 3 ? pages.length : 3;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
    if (await _library.isCaptureBatchCancelled(batchId)) {
      _imageRecognitionVersion.value++;
      return;
    }
    try {
      final notes = processed.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      if (notes.isNotEmpty) {
        await DatabaseService().insertNotesBatch(
          notes.map((entry) => entry.value).toList(growable: false),
        );
      }
      if (failed > 0 || notes.isEmpty) {
        await _library.completeCaptureBatchAfterSaving(
          batchId,
          preserveBookAssociation: true,
        );
      } else {
        await _library.completeCaptureBatch(
          batchId,
          preserveBookAssociation: true,
        );
      }
    } finally {
      _imageRecognitionVersion.value++;
    }
  }

  Future<bool> _waitForCaptureBatch(String batchId) async {
    while (true) {
      if (await _library.isCaptureBatchCancelled(batchId)) return false;
      if (!await _library.isCaptureBatchPaused(batchId)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _createTextNote(BookLibraryItem item) async {
    final bookId = item.book.id;
    if (bookId == null) return;
    final notebooks = await DatabaseService().queryNotebooks();
    final notebook = notebooks.where((item) => item.isActive).firstOrNull;
    if (!mounted) return;
    if (notebook?.id == null) {
      AppToast.show(context, '暂时找不到可用笔记本，请稍后重试');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          notebookId: notebook!.id!,
          bookId: bookId,
          bookName: item.book.title,
        ),
      ),
    );
    if (mounted) setState(() => _bookDetailVersion++);
  }

  bool get _canPop =>
      _destination == BookLearningDestination.books && _openBookId == null;

  @override
  void dispose() {
    _imageRecognitionVersion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _canPop,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      if (_openBookId != null) {
        setState(() => _openBookId = null);
      } else if (_destination != BookLearningDestination.books) {
        setState(() => _destination = BookLearningDestination.books);
      }
    },
    child: Scaffold(
      backgroundColor: BookFlowTheme.canvas,
      body: IndexedStack(
        index: _destination.index,
        children: [
          _BookPageTransition(
            transitionKey: _openBookId == null
                ? 'book-library'
                : 'book-detail-$_openBookId',
            forward: _openBookId != null,
            child: _openBookId == null
                ? BookLearningSpacePage(
                    key: const PageStorageKey('book_learning_space'),
                    bookLibraryService: _library,
                    onCreateBook: _createBook,
                    onOpenBook: (bookId) => setState(() {
                      _destination = BookLearningDestination.books;
                      _openBookId = bookId;
                    }),
                  )
                : BookStudyPage(
                    key: ValueKey(
                      'book-study-$_openBookId-$_bookDetailVersion',
                    ),
                    bookId: _openBookId!,
                    bookLibraryService: _library,
                    onBack: () => setState(() => _openBookId = null),
                    onCapturePages: _captureBookPages,
                    onCreateTextNote: _createTextNote,
                    imageRecognitionVersion: _imageRecognitionVersion,
                    initialChapterTitle: _openBookId == widget.initialBookId
                        ? widget.initialChapterTitle
                        : null,
                  ),
          ),
          const NoteManagerPage(),
          DiscoverEmptyPage(
            onBackToBooks: () =>
                _changeDestination(BookLearningDestination.books),
          ),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: BookLearningBottomBar(
        selected: _destination,
        onDestinationSelected: (destination) => _changeDestination(destination),
      ),
    ),
  );
}

class _BookPageTransition extends StatelessWidget {
  const _BookPageTransition({
    required this.transitionKey,
    required this.forward,
    required this.child,
  });

  final Object transitionKey;
  final bool forward;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) return child;

    final beginOffset = forward ? 18.0 : -14.0;
    return ClipRect(
      child: TweenAnimationBuilder<double>(
        key: ValueKey<Object>(transitionKey),
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 190),
        curve: Curves.easeOutQuart,
        child: RepaintBoundary(child: child),
        builder: (context, value, child) => Transform.translate(
          offset: Offset(beginOffset * (1 - value), 0),
          child: child,
        ),
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
