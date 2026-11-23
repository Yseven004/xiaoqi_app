import 'dart:convert';
import 'dart:io';

import 'book_search_query.dart';
import 'book_search_service.dart';

class ThothHttpFailure implements Exception {
  const ThothHttpFailure(this.statusCode);

  final int statusCode;
}

/// Resolves whole Open Book Publishers editions from its Thoth metadata.
class ThothBooks {
  static const sourceName = 'Open Book Publishers';
  static const archiveSourceName = 'Open Book Publishers · Zenodo';
  static const _publisherId = '85fd969a-a16c-480b-b641-cb9adf979c3b';
  static const _catalogHost = 'api.thoth.pub';
  static const _publisherHost = 'www.openbookpublishers.com';
  static const _fileHost = 'books.openbookpublishers.com';
  static const _archiveHost = 'zenodo.org';
  static const _responseLimit = 256 * 1024;

  static final _editionPath = RegExp(r'^/books/10\.11647/obp\.(\d{4,8})$');
  static final _archivePath = RegExp(r'^/records/([1-9]\d{0,15})$');
  static const _uuidPattern =
      '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  static final _workIdPattern = RegExp('^$_uuidPattern\$');
  static final _archiveId = RegExp(
    '^thoth-obp-\\d{4,8}-($_uuidPattern)-zenodo-([1-9]\\d{0,15})-pdf\$',
  );
  static final _isbnPattern = RegExp(r'^(?:97[89]\d{10}|\d{9}[\dX])$');

  // The live API uses filter, even where newer SDKs expose it as search.
  static const _query = r'''
query($title: String!, $publishers: [Uuid!]!) {
  books(workStatus: ACTIVE, limit: 4, publishers: $publishers, filter: $title) {
    workId title fullTitle workStatus workType edition publicationDate
    landingPage license
    imprint { publisher { publisherName publisherId } }
    contributions { fullName contributionType }
    languages { languageCode }
    publications {
      publicationType isbn
      locations { canonical fullTextUrl landingPage }
    }
  }
}
''';

  static Future<List<BookSearchCandidate>> search(
    HttpClient client,
    BookSearchQuery query,
  ) async {
    final title = query.title.trim();
    if (title.isEmpty || title.runes.length > 240) return const [];
    final request = await client.postUrl(Uri.https(_catalogHost, '/graphql'));
    request.followRedirects = false;
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(HttpHeaders.acceptEncodingHeader, 'identity')
      ..set(HttpHeaders.userAgentHeader, 'XiaoqiBookSearch/1.0');
    request.write(
      jsonEncode({
        'query': _query,
        'variables': {
          'title': title,
          'publishers': [_publisherId],
        },
      }),
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.listen((_) {}).cancel();
      throw ThothHttpFailure(response.statusCode);
    }
    if (response.contentLength > _responseLimit) {
      await response.listen((_) {}).cancel();
      throw const FormatException('Thoth 响应超过大小限制。');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > _responseLimit) {
        throw const FormatException('Thoth 响应超过大小限制。');
      }
      bytes.addAll(chunk);
    }
    final payload = jsonDecode(utf8.decode(bytes));
    final data = _field(payload, 'data');
    final books = _field(data, 'books');
    if (_field(payload, 'errors') != null || books is! List) {
      throw const FormatException('Thoth 书目响应结构无效。');
    }
    final candidates = <String, BookSearchCandidate>{};
    for (final book in books.take(4).whereType<Map>()) {
      for (final candidate in _editions(book, query)) {
        candidates.putIfAbsent(candidate.id, () => candidate);
      }
    }
    return candidates.values.toList(growable: false);
  }

  static Iterable<BookSearchCandidate> _editions(
    Map book,
    BookSearchQuery query,
  ) sync* {
    final publisher = _field(book['imprint'], 'publisher');
    if (book['workStatus'] != 'ACTIVE' ||
        !const {
          'MONOGRAPH',
          'EDITED_BOOK',
          'TEXTBOOK',
        }.contains(book['workType']) ||
        _field(publisher, 'publisherId') != _publisherId ||
        _field(publisher, 'publisherName') != sourceName) {
      return;
    }
    final title = _text(book['title']);
    final fullTitle = _text(book['fullTitle']);
    final requested = _compare(query.title);
    if (title.isEmpty ||
        requested.isEmpty ||
        (_compare(title) != requested && _compare(fullTitle) != requested)) {
      return;
    }
    final landingPage = _httpsUrl(book['landingPage'], _publisherHost);
    final editionKey = _editionKey(landingPage);
    final license = _license(book['license']);
    final editionNumber = book['edition'];
    final language = _language(book['languages']);
    if (landingPage == null ||
        editionKey == null ||
        license == null ||
        editionNumber is! int ||
        editionNumber <= 0 ||
        language == null) {
      return;
    }
    final authors = _contributors(book['contributions'], 'AUTHOR');
    final editors = _contributors(book['contributions'], 'EDITOR');
    final credits = authors.isNotEmpty ? authors : editors;
    if (credits.isEmpty ||
        (query.author.trim().isNotEmpty &&
            !credits.any((name) => _compare(name) == _compare(query.author)))) {
      return;
    }
    final author = '${credits.join('、')}${authors.isEmpty ? '（编）' : ''}';
    final edition = '第$editionNumber版';
    final displayTitle = fullTitle.isEmpty ? title : fullTitle;
    final issued = _text(book['publicationDate']);
    final year = RegExp(r'^\d{4}(?=-|$)').stringMatch(issued);
    final workId = _text(book['workId']);
    for (final publication in _rows(book['publications'])) {
      final format = _text(publication['publicationType']).toLowerCase();
      if (format != 'pdf' && format != 'epub') continue;
      final normalizedIsbn = _text(
        publication['isbn'],
      ).replaceAll(RegExp(r'[-\s]'), '').toUpperCase();
      final isbn = _isbnPattern.hasMatch(normalizedIsbn)
          ? normalizedIsbn
          : null;
      if (!query.acceptsFile(
        title: displayTitle,
        edition: edition,
        format: format,
        language: language,
        isbn: isbn,
      )) {
        continue;
      }
      BookSearchCandidate candidate({
        required String id,
        required String name,
        required Uri source,
        required Uri file,
      }) => BookSearchCandidate(
        id: id,
        title: displayTitle,
        author: author,
        language: language,
        edition: edition,
        format: format,
        sourceName: name,
        sourceUri: source,
        downloadUri: file,
        license: license.$1,
        licenseUri: license.$2,
        isbn: isbn,
        publisher: sourceName,
        publicationYear: year,
      );

      BookSearchCandidate? official;
      BookSearchCandidate? archive;
      for (final location in _rows(publication['locations'])) {
        final page = location['landingPage'];
        final file = location['fullTextUrl'];
        if (location['canonical'] == true &&
            _httpsUrl(page, _publisherHost) == landingPage &&
            _httpsUrl(file, _fileHost) ==
                _publicationFile(editionKey, format)) {
          official ??= candidate(
            id: 'thoth-obp-$editionKey-$format',
            name: sourceName,
            source: landingPage,
            file: _publicationFile(editionKey, format),
          );
        }
        if (format != 'pdf' || !_workIdPattern.hasMatch(workId)) continue;
        final archivePage = _httpsUrl(page, _archiveHost);
        final record = _archivePath
            .firstMatch(archivePage?.path ?? '')
            ?.group(1);
        if (archivePage != null &&
            record != null &&
            _httpsUrl(file, _archiveHost) == _archiveFile(record, workId)) {
          archive ??= candidate(
            id: 'thoth-obp-$editionKey-$workId-zenodo-$record-pdf',
            name: archiveSourceName,
            source: archivePage,
            file: _archiveFile(record, workId),
          );
        }
      }
      if (archive != null) yield archive;
      if (official != null) yield official;
    }
  }

  /// Restricts acquisition to addresses from the edition or its publication
  /// record's deposited PDF. Only the server-side search creates candidates.
  static bool permitsDownload(BookSearchCandidate candidate) {
    final license = _license(candidate.licenseUri?.toString());
    if (license == null ||
        license.$1 != candidate.license ||
        candidate.publisher != sourceName) {
      return false;
    }
    if (candidate.sourceName == sourceName) {
      final key = _editionKey(candidate.sourceUri);
      final format = candidate.format;
      return key != null &&
          (format == 'pdf' || format == 'epub') &&
          candidate.id == 'thoth-obp-$key-$format' &&
          candidate.downloadUri == _publicationFile(key, format);
    }
    if (candidate.sourceName != archiveSourceName ||
        candidate.format != 'pdf') {
      return false;
    }
    final match = _archiveId.firstMatch(candidate.id);
    if (match == null) return false;
    final workId = match.group(1)!;
    final record = match.group(2)!;
    return candidate.sourceUri == Uri.https(_archiveHost, '/records/$record') &&
        candidate.downloadUri == _archiveFile(record, workId);
  }

  static String? _editionKey(Uri? uri) {
    if (_httpsUrl(uri?.toString(), _publisherHost) == null) return null;
    return _editionPath.firstMatch(uri!.path)?.group(1);
  }

  static Uri _publicationFile(String key, String format) =>
      Uri.https(_fileHost, '/10.11647/obp.$key.$format');

  static Uri _archiveFile(String record, String workId) =>
      Uri.https(_archiveHost, '/records/$record/files/${workId}_book.pdf');

  static String _text(Object? value) => value is String ? value.trim() : '';

  static String _compare(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static Object? _field(Object? value, String key) =>
      value is Map ? value[key] : null;

  static Iterable<Map> _rows(Object? value) =>
      value is List ? value.whereType<Map>() : const [];

  static List<String> _contributors(Object? value, String type) => {
    for (final contributor in _rows(value))
      if (contributor['contributionType'] == type &&
          _text(contributor['fullName']).isNotEmpty)
        _text(contributor['fullName']),
  }.toList();

  static String? _language(Object? value) {
    final codes = {
      for (final row in _rows(value)) _text(row['languageCode']).toLowerCase(),
    };
    if (codes.length != 1) return null;
    return switch (codes.single) {
      'eng' => '英文',
      'chi' || 'zho' => '中文',
      final code when RegExp(r'^[a-z]{3}$').hasMatch(code) => code,
      _ => null,
    };
  }

  static Uri? _httpsUrl(Object? value, String host) {
    final uri = Uri.tryParse(_text(value));
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host == host &&
            !uri.hasPort &&
            uri.userInfo.isEmpty &&
            !uri.hasQuery &&
            !uri.hasFragment
        ? uri
        : null;
  }

  static (String, Uri)? _license(Object? value) {
    // Some older records publish the original HTTP Creative Commons URI.
    final uri = _httpsUrl(
      _text(value).replaceFirst(RegExp(r'^http:'), 'https:'),
      'creativecommons.org',
    );
    return switch (uri?.path.replaceFirst(RegExp(r'/$'), '')) {
      '/licenses/by/3.0' => (
        'CC BY 3.0',
        Uri.https('creativecommons.org', '/licenses/by/3.0/'),
      ),
      '/licenses/by/4.0' => (
        'CC BY 4.0',
        Uri.https('creativecommons.org', '/licenses/by/4.0/'),
      ),
      '/publicdomain/zero/1.0' => (
        'CC0 1.0',
        Uri.https('creativecommons.org', '/publicdomain/zero/1.0/'),
      ),
      _ => null,
    };
  }
}
