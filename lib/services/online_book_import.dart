import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/book_recognition.dart';
import '../models/book_source.dart';
import '../utils/isbn.dart';
import 'book_library_service.dart';
import 'book_download_storage.dart';
import 'epub_document_service.dart';

/// The book is safely in the library; publishing the user-visible copy failed.
class OnlineBookDownloadSaveException implements Exception {
  const OnlineBookDownloadSaveException(this.result, this.message);

  final BookSourceImportResult result;
  final String message;

  @override
  String toString() => message;
}

/// Downloads a resolved candidate and commits the selected edition to the library.
Future<BookSourceImportResult> importOnlineBook(
  Map<String, dynamic> candidate, {
  int? bookId,
  BookLibraryService? library,
  BookDownloadSaver saveDownload = saveVerifiedBookToDownloads,
}) async {
  String field(String key) => candidate[key]?.toString().trim() ?? '';

  final format = field('format').toLowerCase();
  final title = field('title');
  final candidateId = field('id');
  final sourcePage = Uri.tryParse(field('sourceUrl'));
  final stagedFilePath = field('stagedFilePath');
  final expectedSha256 = field('fileSha256');
  final expectedLength = candidate['fileLength'];
  if (candidate['importable'] != true ||
      candidate['verified'] != true ||
      title.isEmpty ||
      candidateId.isEmpty ||
      !supportedBookSourceFormats.contains(format) ||
      !_isHttps(sourcePage) ||
      stagedFilePath.isEmpty ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256) ||
      expectedLength is! int ||
      expectedLength <= 128 ||
      expectedLength > 256 * 1024 * 1024) {
    throw const FormatException('这个版本没有经过核验的整本文件');
  }

  final edition = field('edition');
  // File variants of one edition have the same catalogue ID before the format suffix.
  final fileSuffix = '-$format';
  final editionId = candidateId.endsWith(fileSuffix)
      ? candidateId.substring(0, candidateId.length - fileSuffix.length)
      : candidateId;
  final sourceName = field('sourceName');
  final author = field('author');
  final publisher = field('publisher');
  final year = field('publicationYear');
  final isbn13 = Isbn.normalize(field('isbn')) ?? '';
  final targetLibrary = library ?? BookLibraryService();
  final directory = await (await getTemporaryDirectory()).createTemp(
    'online-book-',
  );
  try {
    final filePath = p.join(directory.path, 'book.$format');
    final stagedFile = File(stagedFilePath);
    if (!await stagedFile.exists() ||
        await stagedFile.length() != expectedLength ||
        (await sha256.bind(stagedFile.openRead()).first).toString() !=
            expectedSha256) {
      throw const FormatException('已核验文件传输不完整或校验值不一致');
    }
    await stagedFile.copy(filePath);
    final embeddedCoverPath = await _validateBookAndStageCover(
      filePath,
      format,
    );
    final result = await targetLibrary.importVerifiedOnlineBook(
      book: BookRecord(
        title: title,
        authors: author
            .split('、')
            .where((name) => name.trim().isNotEmpty)
            .toList(),
        publisher: publisher,
        edition: edition,
        publishedDate: year,
        isbn13: isbn13,
        source: 'online_book_search',
        sourceId: editionId,
        metadataSources: [
          BookMetadataSource(
            provider: sourceName,
            sourceId: candidateId,
            sourceUrls: [sourcePage!.toString()],
            fields: [
              'title',
              if (author.isNotEmpty) 'authors',
              if (edition.isNotEmpty) 'edition',
              if (publisher.isNotEmpty) 'publisher',
              if (year.isNotEmpty) 'published_date',
              if (isbn13.isNotEmpty) 'isbn_13',
            ],
            fetchedAt: field('verifiedAt'),
            exactIsbnMatch: isbn13.isNotEmpty,
          ),
        ],
      ),
      bookId: bookId,
      sourcePath: filePath,
      displayName: edition.isEmpty
          ? '$title.$format'
          : '$title · $edition.$format',
      format: format,
      sourcePage: sourcePage,
      embeddedCoverPath: embeddedCoverPath,
    );
    if (format == 'pdf' && !result.reusedExisting) {
      unawaited(
        targetLibrary
            .parsePdfCatalogForSource(result.source)
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    try {
      await saveDownload(
        file: File(result.source.filePath),
        displayName: edition.isEmpty
            ? '$title.$format'
            : '$title · $edition.$format',
        format: format,
        sha256: expectedSha256,
      );
    } on Object catch (error) {
      final detail = switch (error) {
        PlatformException(
          code: 'downloads_not_supported',
          message: final String message,
        ) =>
          message,
        UnsupportedError(:final message) => message,
        _ => '保存到系统下载目录失败，请重试',
      };
      throw OnlineBookDownloadSaveException(result, '已导入书库，但$detail');
    }
    return result;
  } finally {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // A staging cleanup failure does not invalidate the committed book.
    }
  }
}

bool _isHttps(Uri? uri) =>
    uri != null &&
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    uri.host.isNotEmpty;

Future<String?> _validateBookAndStageCover(
  String filePath,
  String format, {
  String? compiledTitle,
  String? compiledAuthor,
}) async {
  if (format == 'epub') {
    final cover = await Isolate.run(() async {
      final document = await const EpubDocumentService()
          .parseFile(filePath, includeCover: true)
          .onError((Object _, StackTrace _) {
            throw const FormatException('下载文件不是可打开的 EPUB');
          });
      if (compiledTitle != null &&
          (document.title != compiledTitle ||
              (compiledAuthor?.isNotEmpty == true &&
                  document.author != compiledAuthor) ||
              document.chapters.isEmpty)) {
        throw const FormatException('电子书的书名、署名或正文与选中版本不符');
      }
      final asset = document.assets.singleOrNull;
      if (asset == null) return null;
      return _validateEpubCover(asset.bytes, asset.mimeType);
    });
    if (cover == null) return null;
    try {
      final path = p.join(p.dirname(filePath), 'cover.${cover.extension}');
      await File(path).writeAsBytes(cover.bytes);
      return path;
    } catch (_) {
      // An optional image must not block an otherwise valid import.
      return null;
    }
  }
  final file = await File(filePath).open();
  try {
    if (String.fromCharCodes(await file.read(5)) != '%PDF-') {
      throw const FormatException('下载文件不是 PDF');
    }
  } finally {
    await file.close();
  }
  return null;
}

({Uint8List bytes, String extension})? _validateEpubCover(
  List<int> asset,
  String mimeType,
) {
  final bytes = asset is Uint8List ? asset : Uint8List.fromList(asset);
  final (decoder, extension) = switch (mimeType) {
    'image/jpeg' => (image.JpegDecoder(), 'jpg'),
    'image/png' => (image.PngDecoder(), 'png'),
    'image/webp' => (image.WebPDecoder(), 'webp'),
    _ => (null, ''),
  };
  try {
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > 16 * 1024 * 1024) {
      return null;
    }
    return (bytes: bytes, extension: extension);
  } catch (_) {
    // An invalid raster does not make the main EPUB unreadable.
    return null;
  }
}
