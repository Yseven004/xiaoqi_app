import 'dart:async';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/book_source.dart';
import '../services/book_library_service.dart';
import '../services/epub_document_service.dart';
import '../services/pdf_catalog_service.dart';
import 'app_toast.dart';
import 'book_editor_dialog.dart';
import 'book_pdf_import_sheet.dart';

typedef _BookSourceFile = ({XFile file, String name});

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
      BookAddAction.importFromWechat => _pickWechatSource(context),
      BookAddAction.findOnline => _pickOnlineSource(
        context,
        bookTitle: bookTitle,
        library: library,
        bookId: bookId,
        download: (uri) async {
          startImport();
          final directory = await (await getTemporaryDirectory()).createTemp(
            'book-source-download-',
          );
          staging = directory;
          return _downloadBookSource(uri, directory);
        },
      ),
      BookAddAction.scan => Future<_BookSourceFile?>.value(),
    };
    if (!context.mounted || file == null) return null;
    final format = _bookFileFormat(file.name);
    if (format == null) {
      AppToast.show(context, '请选择 PDF 或 EPUB 文件');
      return null;
    }
    startImport();
    var path = file.file.path;
    if (path.isEmpty || !await File(path).exists()) {
      final directory = await (await getTemporaryDirectory()).createTemp(
        'book-source-',
      );
      staging = directory;
      path = p.join(directory.path, 'upload.$format');
      await file.file.saveTo(path);
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

Future<_BookSourceFile?> _pickBookSource() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: supportedBookSourceFileExtensions,
  );
  return file == null ? null : (file: file.xFile, name: file.name);
}

String? _bookFileFormat(String name) {
  final extension = p.extension(name).toLowerCase();
  if (extension == '.pdf') return 'pdf';
  if (extension == '.epub') return 'epub';
  return null;
}

bool Function(_BookSourceFile)? _pendingWechatSource;

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
    if (receive((name: name, file: XFile(path)))) {
      return [...shared.take(index), ...shared.skip(index + 1)];
    }
  }
  return shared;
}

Future<_BookSourceFile?> _pickWechatSource(BuildContext context) async {
  final acceptSystemShare =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  _BookSourceFile? sharedFile;
  bool Function(_BookSourceFile)? handler;
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

Future<_BookSourceFile?> _pickOnlineSource(
  BuildContext context, {
  required String bookTitle,
  required BookLibraryService library,
  required int bookId,
  required Future<_BookSourceFile> Function(Uri uri) download,
}) async {
  final search =
      (bookTitle.trim().isEmpty
              ? (await library.getBook(bookId))?.title ?? ''
              : bookTitle)
          .trim();
  if (!context.mounted) return null;
  final catalog = Uri.https(
    'www.gutenberg.org',
    search.isEmpty ? '/ebooks/index.html' : '/ebooks/search/',
    search.isEmpty ? null : {'query': search},
  );
  final selected = await showDialog<({Uri? link})>(
    context: context,
    builder: (_) => _OnlineBookSourceDialog(catalog: catalog),
  );
  if (!context.mounted || selected == null) return null;
  final link = selected.link;
  return link == null ? _pickBookSource() : download(link);
}

bool _isHttpsDownload(Uri? uri) =>
    uri != null &&
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

Future<_BookSourceFile> _downloadBookSource(
  Uri link,
  Directory directory,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  final deadline = Timer(
    const Duration(minutes: 2),
    () => client.close(force: true),
  );
  try {
    var uri = link;
    for (var hop = 0; hop <= 5; hop++) {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        final redirect = location == null ? null : uri.resolve(location);
        if (!_isHttpsDownload(redirect) || hop == 5) {
          throw const FormatException('下载地址的跳转无效');
        }
        await response.listen((_) {}).cancel();
        uri = redirect!;
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('下载失败（HTTP ${response.statusCode}）');
      }
      final pathName = uri.pathSegments.lastOrNull ?? '';
      final format = switch (response.headers.contentType?.mimeType) {
        'application/pdf' => 'pdf',
        'application/epub+zip' => 'epub',
        null ||
        'application/octet-stream' ||
        'application/zip' => _bookFileFormat(pathName),
        _ => null,
      };
      if (format == null) throw const FormatException('链接未返回 PDF 或 EPUB');
      final limit = format == 'pdf'
          ? PdfCatalogService.maxPdfBytes
          : EpubDocumentService.maxInputBytes;
      if (response.contentLength > limit) {
        throw const FormatException('下载资料超出允许的大小');
      }
      final target = File(p.join(directory.path, 'download.$format'));
      final writer = await target.open(mode: FileMode.write);
      var size = 0;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 20),
        )) {
          size += chunk.length;
          if (size > limit) {
            throw const FormatException('下载资料超出允许的大小');
          }
          await writer.writeFrom(chunk);
        }
      } finally {
        await writer.close();
      }
      return (
        file: XFile(target.path),
        name: _bookFileFormat(pathName) == format ? pathName : '下载资料.$format',
      );
    }
    throw const FormatException('下载地址跳转过多');
  } on TimeoutException {
    throw StateError('下载超时，请稍后重试');
  } finally {
    deadline.cancel();
    client.close(force: true);
  }
}

class _OnlineBookSourceDialog extends StatefulWidget {
  const _OnlineBookSourceDialog({required this.catalog});

  final Uri catalog;

  @override
  State<_OnlineBookSourceDialog> createState() =>
      _OnlineBookSourceDialogState();
}

class _OnlineBookSourceDialogState extends State<_OnlineBookSourceDialog>
    with WidgetsBindingObserver, BookEditorInputFocus<_OnlineBookSourceDialog> {
  final _link = TextEditingController();
  final _linkFocus = FocusNode();
  String? _error;
  bool _openingCatalog = false;

  @override
  Iterable<(FocusNode, TextEditingController)> get editorInputs => [
    (_linkFocus, _link),
  ];

  @override
  void dispose() {
    _linkFocus.dispose();
    _link.dispose();
    super.dispose();
  }

  void _submitLink() {
    final link = Uri.tryParse(_link.text.trim());
    if (!_isHttpsDownload(link)) {
      setState(() => _error = '请输入可下载的 HTTPS 文件链接');
      return;
    }
    Navigator.pop(context, (link: link));
  }

  Future<void> _openCatalog() async {
    if (_openingCatalog) return;
    setState(() => _openingCatalog = true);
    var launched = false;
    try {
      launched = await launchUrl(
        widget.catalog,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // The app may not have an external HTTPS handler.
    }
    if (!mounted) return;
    setState(() => _openingCatalog = false);
    if (!launched) AppToast.show(context, '无法打开开放书库，请稍后重试');
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('网上找书'),
    content: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('在 Project Gutenberg 查找可下载的电子书，或粘贴 PDF、EPUB 的下载链接。'),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: _openingCatalog ? null : _openCatalog,
              child: const Text('打开开放书库'),
            ),
          ),
          TextField(
            controller: _link,
            focusNode: _linkFocus,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            decoration: bookEditorInput(hint: 'HTTPS 下载链接', error: _error),
            onTapOutside: (_) => _linkFocus.unfocus(),
            onEditingComplete: () {},
            onSubmitted: (_) => _submitLink(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, (link: null)),
        child: const Text('选择已下载文件'),
      ),
      FilledButton(onPressed: _submitLink, child: const Text('导入链接')),
    ],
  );
}
