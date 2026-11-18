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
import 'note_management_page.dart';

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
  int _libraryRefreshVersion = 0;

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
      _closeBook();
      return;
    }
    setState(() => _destination = value);
  }

  void _closeBook() {
    setState(() {
      _destination = BookLearningDestination.books;
      _openBookId = null;
      _libraryRefreshVersion++;
    });
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
    final coverReady = await showBookMetadataForm(
      context: context,
      initial: book,
    );
    if (!mounted || coverReady == null) return;
    book = coverReady.book;
    if (book.title.trim().isEmpty || book.title == '待确认书籍') {
      final completed = await showBookMetadataForm(
        context: context,
        initial: book,
      );
      if (!mounted || completed == null) return;
      book = completed.book;
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
        if (mounted) {
          AppToast.show(context, '资料导入失败，已保留书籍资料：$error');
        }
      }
      return;
    }
  }

  void _showDuplicateImportToast() {
    AppToast.show(context, '这份资料已经在本书资料中，不会重复添加');
  }

  Future<PlatformFile?> _pickBookSource() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: supportedBookSourceFileExtensions,
    );
    if (!mounted || file == null) return null;
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
    final bytes = await file.readAsBytes();
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
        _closeBook();
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
            child: Stack(
              fit: StackFit.expand,
              children: [
                Offstage(
                  offstage: _openBookId != null,
                  child: Theme(
                    data: _bookLibraryTheme(context),
                    child: BookLearningSpacePage(
                      key: const PageStorageKey('book_learning_space'),
                      refreshVersion: _libraryRefreshVersion,
                      bookLibraryService: _library,
                      onCreateBook: _createBook,
                      onOpenBook: (bookId) => setState(() {
                        _destination = BookLearningDestination.books;
                        _openBookId = bookId;
                      }),
                    ),
                  ),
                ),
                if (_openBookId != null)
                  BookStudyPage(
                    key: ValueKey(
                      'book-study-$_openBookId-$_bookDetailVersion',
                    ),
                    bookId: _openBookId!,
                    bookLibraryService: _library,
                    onBack: _closeBook,
                  ),
              ],
            ),
          ),
          NoteManagementPage(
            key: const PageStorageKey('book_learning_notes'),
            active: _destination == BookLearningDestination.notes,
            onClose: () => _changeDestination(BookLearningDestination.books),
          ),
          DiscoverEmptyPage(
            onBackToBooks: () =>
                _changeDestination(BookLearningDestination.books),
          ),
          const _EmptyDestinationPage(),
        ],
      ),
      bottomNavigationBar: _openBookId == null
          ? BookLearningBottomBar(
              selected: _destination,
              onDestinationSelected: _changeDestination,
            )
          : null,
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

class _BookPageTransition extends StatefulWidget {
  const _BookPageTransition({
    required this.transitionKey,
    required this.forward,
    required this.child,
  });

  final Object transitionKey;
  final bool forward;
  final Widget child;

  @override
  State<_BookPageTransition> createState() => _BookPageTransitionState();
}

class _BookPageTransitionState extends State<_BookPageTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 190),
  )..forward();

  @override
  void didUpdateWidget(covariant _BookPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitionKey != widget.transitionKey) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final beginOffset = widget.forward ? 18.0 : -14.0;
    return ClipRect(
      child: AnimatedBuilder(
        animation: _controller,
        child: RepaintBoundary(child: widget.child),
        builder: (context, child) => Transform.translate(
          offset: reduceMotion
              ? Offset.zero
              : Offset(
                  beginOffset *
                      (1 - Curves.easeOutQuart.transform(_controller.value)),
                  0,
                ),
          child: child,
        ),
      ),
    );
  }
}

ThemeData _bookLibraryTheme(BuildContext context) {
  final base = Theme.of(context);
  final borderColor = const Color(0xFFD5D8DE);
  final outline = OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: borderColor),
  );
  return base.copyWith(
    colorScheme: base.colorScheme.copyWith(
      primary: BookFlowTheme.ink,
      onPrimary: Colors.white,
      secondary: BookFlowTheme.ink,
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: BookFlowTheme.ink,
      outline: borderColor,
      outlineVariant: borderColor,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: BookFlowTheme.ink,
        minimumSize: const Size(48, 48),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: BookFlowTheme.ink,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: BookFlowTheme.ink,
        minimumSize: const Size(48, 48),
        side: BorderSide(color: borderColor),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: BookFlowTheme.ink,
        minimumSize: const Size(48, 48),
      ),
    ),
    checkboxTheme: base.checkboxTheme.copyWith(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return BookFlowTheme.ink;
        return Colors.white;
      }),
      checkColor: WidgetStateProperty.all(Colors.white),
      side: BorderSide(color: borderColor),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: Colors.white,
      border: outline,
      enabledBorder: outline,
      focusedBorder: outline.copyWith(
        borderSide: const BorderSide(color: BookFlowTheme.ink, width: 1.3),
      ),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      color: Colors.white,
      surfaceTintColor: Colors.white,
    ),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
    ),
  );
}
