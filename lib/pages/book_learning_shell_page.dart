import 'dart:async';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/api_config.dart';
import '../config/book_flow_theme.dart';
import '../models/book_source.dart';
import '../plugins/book_metadata/book_metadata_plugin.dart';
import '../models/book_recognition.dart';
import '../services/book_library_service.dart';
import '../services/book_recognition_repository.dart';
import '../services/pdf_catalog_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/book_learning_bottom_bar.dart';
import '../widgets/book_metadata_form_sheet.dart';
import '../widgets/book_pdf_import_sheet.dart';
import 'book_isbn_scanner_page.dart';
import 'book_learning_space_page.dart';
import 'book_study_page.dart';
import 'discover_empty_page.dart';

class BookLearningShellPage extends StatefulWidget {
  const BookLearningShellPage({
    super.key,
    this.bookLibraryService,
    this.recognitionRepository,
    this.initialBookId,
  });

  final BookLibraryService? bookLibraryService;
  final BookRecognitionRepository? recognitionRepository;
  final int? initialBookId;

  @override
  State<BookLearningShellPage> createState() => _BookLearningShellPageState();
}

class _BookLearningShellPageState extends State<BookLearningShellPage> {
  late final BookLibraryService _library;
  late final BookRecognitionRepository _recognition;
  late final BookMetadataPlugin _metadataPlugin;

  BookLearningDestination _destination = BookLearningDestination.books;
  int? _openBookId;
  int _bookDetailVersion = 0;

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

  bool get _canPop =>
      _destination == BookLearningDestination.books && _openBookId == null;

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
                  ),
          ),
          const _EmptyDestinationPage(),
          DiscoverEmptyPage(
            onBackToBooks: () =>
                _changeDestination(BookLearningDestination.books),
          ),
          const _EmptyDestinationPage(),
        ],
      ),
      bottomNavigationBar: BookLearningBottomBar(
        selected: _destination,
        onDestinationSelected: (destination) => _changeDestination(destination),
      ),
    ),
  );
}

class _EmptyDestinationPage extends StatelessWidget {
  const _EmptyDestinationPage();

  @override
  Widget build(BuildContext _) => const SafeArea(
    child: Center(child: Text('暂无内容', style: BookFlowTheme.caption)),
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
