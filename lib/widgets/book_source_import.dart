import 'dart:async';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../models/book_source.dart';
import '../services/book_library_service.dart';
import '../services/pdf_catalog_service.dart';
import 'app_toast.dart';
import 'book_pdf_import_sheet.dart';
import 'online_book_search_dialog.dart';

/// Imports one source into a known book and returns its durable record.
Future<BookSourceImportResult?> showExistingBookSourceImport(
  BuildContext context, {
  required int bookId,
  required BookLibraryService library,
  String bookTitle = '',
  VoidCallback? onImporting,
  BuildContext? anchorContext,
}) async {
  final action = await showBookAddSourceSheet(
    context,
    anchorContext: anchorContext,
    forExistingBook: true,
  );
  if (!context.mounted || action == null) return null;
  if (action == BookAddAction.findOnline) {
    final title = bookTitle.trim().isNotEmpty
        ? bookTitle
        : (await library.getBook(bookId))?.title ?? '';
    if (!context.mounted) return null;
    return showOnlineBookSearch(
      context,
      library: library,
      bookId: bookId,
      title: title,
      onImporting: onImporting,
    );
  }
  Directory? staging;
  var started = false;
  void startImport() {
    if (started || !context.mounted) return;
    started = true;
    onImporting?.call();
  }

  try {
    final file = await switch (action) {
      BookAddAction.importPdf => _pickBookSource(),
      BookAddAction.importFromWechat => pickWechatBookSource(context),
      BookAddAction.findOnline ||
      BookAddAction.scan => Future<PlatformFile?>.value(),
    };
    if (!context.mounted || file == null) return null;
    final format = _bookFileFormat(file.name);
    if (format == null) {
      AppToast.show(context, '请选择 PDF 或 EPUB 文件');
      return null;
    }
    startImport();
    var path = file.xFile.path;
    if (path.isEmpty || !await File(path).exists()) {
      final directory = await (await getTemporaryDirectory()).createTemp(
        'book-source-',
      );
      staging = directory;
      path = p.join(directory.path, 'upload.$format');
      await file.xFile.saveTo(path);
    }
    if (!context.mounted) return null;
    final result = await library.importBookSourceForBook(
      bookId: bookId,
      sourcePath: path,
      displayName: file.name,
      format: format,
    );
    final source = result.source;
    if (format == 'pdf' &&
        source.catalogStatus != 'processing' &&
        source.catalogStatus != 'confirmed' &&
        (source.catalogParserVersion < PdfCatalogService.parserVersion ||
            source.catalogStatus == 'not_started' ||
            source.catalogStatus == 'failed')) {
      unawaited(library.parsePdfCatalogForSource(source));
    }
    return result;
  } catch (error) {
    if (context.mounted) AppToast.show(context, '资料导入失败：$error');
    return null;
  } finally {
    try {
      await staging?.delete(recursive: true);
    } on FileSystemException {
      // Only a private temporary copy is left; the imported record is valid.
    }
  }
}

Future<PlatformFile?> _pickBookSource() => FilePicker.pickFile(
  type: FileType.custom,
  allowedExtensions: supportedBookSourceFileExtensions,
);

String? _bookFileFormat(String name) {
  final extension = p.extension(name).toLowerCase();
  if (extension == '.pdf') return 'pdf';
  if (extension == '.epub') return 'epub';
  return null;
}

bool Function(PlatformFile)? _pendingWechatSource;

/// Gives one compatible file to the currently visible book import guide.
/// Unconsumed shares keep following the ordinary attachment handler.
List<SharedMediaFile> routeExistingBookSharedMedia(
  List<SharedMediaFile> shared,
) {
  final receive = _pendingWechatSource;
  if (receive == null) return shared;
  for (final (index, media) in shared.indexed) {
    if (media.type != SharedMediaType.file) continue;
    final String path;
    try {
      final uri = Uri.tryParse(media.path);
      path = uri?.scheme == 'file' ? uri!.toFilePath() : media.path;
    } on UnsupportedError {
      continue;
    }
    final basename = p.basename(path);
    final format =
        _bookFileFormat(basename) ??
        switch (media.mimeType) {
          'application/pdf' => 'pdf',
          'application/epub+zip' => 'epub',
          _ => null,
        };
    if (format == null) continue;
    final file = File(path);
    try {
      if (!file.existsSync()) continue;
    } on FileSystemException {
      continue;
    }
    final name = _bookFileFormat(basename) != null
        ? basename
        : '$basename.$format';
    if (receive(_SharedBookFile(path, name))) {
      return [...shared.take(index), ...shared.skip(index + 1)];
    }
  }
  return shared;
}

Future<PlatformFile?> pickWechatBookSource(BuildContext context) async {
  final acceptSystemShare =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  PlatformFile? sharedFile;
  bool Function(PlatformFile)? handler;
  final bool? picked;
  try {
    picked = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        if (acceptSystemShare) {
          handler ??= (file) {
            if (!dialogContext.mounted ||
                ModalRoute.of(dialogContext)?.isCurrent != true ||
                sharedFile != null) {
              return false;
            }
            sharedFile = file;
            Navigator.pop(dialogContext, true);
            return true;
          };
          _pendingWechatSource = handler;
        }
        return AlertDialog(
          title: const Text('微信导入'),
          content: Text(
            acceptSystemShare
                ? '保持此窗口开启。在微信打开一份 PDF 或 EPUB，选择「其他应用打开」或系统分享，再选择小七。也可以选择已保存的微信文件。'
                : '先将微信里的 PDF 或 EPUB 保存到设备，再选择该文件。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('选择已保存文件'),
            ),
          ],
        );
      },
    );
  } finally {
    if (identical(_pendingWechatSource, handler)) _pendingWechatSource = null;
  }
  if (!context.mounted || picked != true) return null;
  return sharedFile ?? await _pickBookSource();
}

final class _SharedBookFile extends PlatformFile {
  _SharedBookFile(String path, this.name)
    : uri = Uri.file(path),
      xFile = XFile(path, name: name);

  @override
  final String name;

  @override
  final Uri uri;

  @override
  final XFile xFile;

  @override
  int? lengthSync() {
    try {
      return File.fromUri(uri).lengthSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<int?> length() async => lengthSync();

  @override
  Future<Uint8List> readAsBytes() => xFile.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() => xFile.openRead();
}
