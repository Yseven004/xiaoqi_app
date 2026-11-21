import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/book_recognition.dart';
import '../models/book_source.dart';
import '../utils/isbn.dart';
import 'book_library_service.dart';
import 'epub_document_service.dart';
import 'pdf_catalog_service.dart';

/// Downloads a resolved candidate and commits the selected edition to the library.
Future<BookSourceImportResult> importOnlineBook(
  Map<String, dynamic> candidate, {
  int? bookId,
  BookLibraryService? library,
}) async {
  String field(String key) => candidate[key]?.toString().trim() ?? '';

  final format = field('format').toLowerCase();
  final title = field('title');
  final candidateId = field('id');
  final sourcePage = Uri.tryParse(field('sourceUrl'));
  final download = Uri.tryParse(field('downloadUrl'));
  if (candidate['importable'] != true ||
      title.isEmpty ||
      candidateId.isEmpty ||
      !supportedBookSourceFormats.contains(format) ||
      !_isHttps(sourcePage) ||
      !_isAllowedDownload(download)) {
    throw const FormatException('这个版本没有经过核验的下载地址');
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
    await _downloadBook(download!, filePath, format);
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

const _githubReleases = {
  '/krahets/hello-algo/releases/download/': '561730219',
  '/progit/progit2-zh/releases/download/': '26017730',
};

bool _isAllowedDownload(Uri? uri) {
  if (!_isHttps(uri) || uri!.hasFragment || uri.hasQuery) return false;
  return switch (uri.host) {
    'github.com' => _githubReleases.keys.any(uri.path.startsWith),
    'zh-v2.d2l.ai' => const {
      '/d2l-zh.pdf',
      '/d2l-zh-pytorch.pdf',
    }.contains(uri.path),
    _ => false,
  };
}

bool _isAllowedRedirect(Uri? redirect, Uri original) {
  if (!_isHttps(redirect) || redirect!.hasFragment) return false;
  if (redirect.host == original.host) return redirect.path == original.path;
  if (original.host != 'github.com' ||
      redirect.host != 'release-assets.githubusercontent.com') {
    return false;
  }
  return _githubReleases.entries.any(
    (entry) =>
        original.path.startsWith(entry.key) &&
        redirect.path.startsWith(
          '/github-production-release-asset/${entry.value}/',
        ),
  );
}

Future<void> _downloadBook(Uri link, String filePath, String format) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = false
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (uri, _, _) async {
      final addresses = await InternetAddress.lookup(
        uri.host,
      ).timeout(const Duration(seconds: 5));
      final publicAddresses = addresses.where(_isPublicAddress).toList();
      if (publicAddresses.isEmpty ||
          publicAddresses.length != addresses.length) {
        throw const FormatException('下载地址解析到了内网或无效 IP');
      }
      // The resolved address retains the DNS host for certificate validation.
      final address = publicAddresses.firstWhere(
        (address) => address.type == InternetAddressType.IPv4,
        orElse: () => publicAddresses.first,
      );
      return SecureSocket.startConnect(address, uri.port);
    };
  final deadline = Timer(
    const Duration(minutes: 2),
    () => client.close(force: true),
  );
  final maxBytes = format == 'pdf'
      ? PdfCatalogService.maxPdfBytes
      : EpubDocumentService.maxInputBytes;
  final expectedMime = format == 'pdf'
      ? 'application/pdf'
      : 'application/epub+zip';
  try {
    var uri = link;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, expectedMime);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        final redirect = location == null ? null : uri.resolve(location);
        if (redirects == 5 || !_isAllowedRedirect(redirect, link)) {
          throw const FormatException('来源的下载跳转已失效');
        }
        await response.listen((_) {}).cancel();
        uri = redirect!;
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('下载失败（HTTP ${response.statusCode}）');
      }
      final type = response.headers.contentType?.mimeType;
      if (type != null &&
          type != expectedMime &&
          type != 'application/octet-stream' &&
          !(format == 'epub' && type == 'application/zip')) {
        throw FormatException('来源未返回当前版本的 ${format.toUpperCase()} 文件');
      }
      if (response.contentLength > maxBytes) {
        throw const FormatException('下载资料超出允许的大小');
      }
      final target = await File(filePath).open(mode: FileMode.write);
      var written = 0;
      try {
        await for (final bytes in response.timeout(
          const Duration(seconds: 20),
        )) {
          written += bytes.length;
          if (written > maxBytes) throw const FormatException('下载资料超出允许的大小');
          await target.writeFrom(bytes);
        }
      } finally {
        await target.close();
      }
      if (written == 0 ||
          (response.contentLength >= 0 && written != response.contentLength)) {
        throw const FormatException('没有收到完整的电子书文件');
      }
      return;
    }
    throw const FormatException('下载地址跳转过多');
  } on TimeoutException {
    throw StateError('下载超时，请稍后重试');
  } on SocketException {
    throw StateError('无法连接到书籍来源，请检查网络后重试');
  } on HandshakeException {
    throw StateError('无法验证书籍来源的 HTTPS 连接');
  } on HttpException {
    throw StateError('下载连接已中断，请稍后重试');
  } finally {
    deadline.cancel();
    client.close(force: true);
  }
}

bool _isPublicAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    final [a, b, c, _] = bytes;
    return a != 0 &&
        a != 10 &&
        a != 127 &&
        a < 224 &&
        !(a == 100 && b >= 64 && b <= 127) &&
        !(a == 169 && b == 254) &&
        !(a == 172 && b >= 16 && b <= 31) &&
        !(a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)))) &&
        !(a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) &&
        !(a == 203 && b == 0 && c == 113);
  }
  // Restrict IPv6 to global unicast and exclude transition/documentation blocks.
  return address.type == InternetAddressType.IPv6 &&
      (bytes.first & 0xe0) == 0x20 &&
      !(bytes[0] == 0x20 && bytes[1] == 0x02) &&
      !(bytes[0] == 0x20 &&
          bytes[1] == 0x01 &&
          bytes[2] == 0x0d &&
          bytes[3] == 0xb8);
}

Future<String?> _validateBookAndStageCover(
  String filePath,
  String format,
) async {
  if (format == 'epub') {
    final cover = await Isolate.run(() async {
      final document = await const EpubDocumentService()
          .parseFile(filePath, includeCover: true)
          .onError((Object _, StackTrace _) {
            throw const FormatException('下载文件不是可打开的 EPUB');
          });
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
