import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/api_config.dart';
import '../config/book_flow_theme.dart';
import '../models/book_library_item.dart';
import '../models/book_recognition.dart';
import '../models/book_source.dart';
import '../plugins/book_metadata/book_metadata_plugin.dart';
import '../services/book_library_service.dart';
import '../services/book_recognition_repository.dart';
import '../services/pdf_catalog_service.dart';
import '../pages/book_isbn_scanner_page.dart';
import 'book_metadata_form_sheet.dart';
import 'book_pdf_import_sheet.dart';
import 'app_toast.dart';

Future<BookLibraryItem?> createBookForReadingTask(
  BuildContext context, {
  required BookLibraryService library,
}) async {
  final action = await showBookAddSourceSheet(context);
  if (!context.mounted || action == null) return null;

  final bookId = switch (action) {
    BookAddAction.scan => await _scanAndSaveBook(context, library),
    BookAddAction.importPdf => await _importBook(context, library),
  };
  if (!context.mounted || bookId == null) return null;
  return library.getBookLibraryItem(bookId);
}

Future<int?> _scanAndSaveBook(
  BuildContext context,
  BookLibraryService library,
) async {
  final recognition = ApiConfig.useCloudBookRecognition
      ? CloudBookRecognitionRepository()
      : MockBookRecognitionRepository();
  final candidate = await Navigator.of(context).push<BookCandidate>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => BookIsbnScannerPage(
        repository: recognition,
        bookLibraryService: library,
        metadataPlugin: resolveBookMetadataPlugin(),
      ),
    ),
  );
  if (!context.mounted || candidate == null) return null;

  final firstConfirmation = await showModalBottomSheet<BookRecord>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x990C1712),
    builder: (_) => Material(
      color: BookFlowTheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: BookMetadataFormSheet(initial: candidate.book),
    ),
  );
  if (!context.mounted || firstConfirmation == null) return null;
  var confirmedBook = firstConfirmation;
  if (confirmedBook.title.trim().isEmpty || confirmedBook.title == '待确认书籍') {
    final completed = await showModalBottomSheet<BookRecord>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Material(
        color: BookFlowTheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BookMetadataFormSheet(initial: confirmedBook),
      ),
    );
    if (!context.mounted || completed == null) return null;
    confirmedBook = completed;
  }
  return library.saveBook(confirmedBook);
}

Future<int?> _importBook(
  BuildContext context,
  BookLibraryService library,
) async {
  PlatformFile? file = await _pickBookSource(context);
  while (context.mounted && file != null) {
    final books = await library.listBooks();
    if (!context.mounted) return null;
    final selection = await showBookPdfImportSheet(
      context: context,
      file: file,
      books: books,
    );
    if (!context.mounted || selection == null) return null;
    if (selection.shouldReselect) {
      file = await _pickBookSource(context);
      continue;
    }

    final sourcePath = await _ensurePickedFilePath(file);
    var bookId = selection.bookId;
    if (bookId == null && selection.newBook != null) {
      bookId = await library.saveBook(selection.newBook!);
    }
    if (bookId == null) return null;

    final outcome = await library.importBookSourceForBook(
      bookId: bookId,
      sourcePath: sourcePath,
      displayName: file.name,
      format: inferBookSourceFormat(file.name),
    );
    if (outcome.source.format == 'pdf' &&
        outcome.source.catalogStatus != 'processing' &&
        outcome.source.catalogStatus != 'confirmed' &&
        (outcome.source.catalogParserVersion <
                PdfCatalogService.parserVersion ||
            outcome.source.catalogStatus == 'not_started' ||
            outcome.source.catalogStatus == 'failed')) {
      unawaited(library.parsePdfCatalogForSource(outcome.source));
    }
    if (outcome.reusedExisting && context.mounted) {
      AppToast.show(context, '这份资料已经在本书资料中，不会重复添加');
    }
    return bookId;
  }
  return null;
}

Future<PlatformFile?> _pickBookSource(BuildContext context) async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: supportedBookSourceFileExtensions,
    withData: true,
  );
  if (!context.mounted || result == null || result.files.isEmpty) return null;
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
