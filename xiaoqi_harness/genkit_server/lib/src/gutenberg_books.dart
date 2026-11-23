import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'book_search_query.dart';
import 'book_search_service.dart';
import 'gutenberg_chinese_titles.dart';

class GutenbergHttpFailure implements Exception {
  const GutenbergHttpFailure(this.status);

  final int status;
}

/// Discovers Chinese EPUBs using a local title index and live official RDF.
class GutenbergBooks {
  static const sourceName = 'Project Gutenberg';
  static const _website = 'www.gutenberg.org';
  static const _mirror = 'gutenberg.pglaf.org';
  static const _terms = 'http://purl.org/dc/terms/';
  static const _dc = 'http://purl.org/dc/elements/1.1/';
  static const _pg = 'http://www.gutenberg.org/2009/pgterms/';
  static const _rdf = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';
  static const _rights = 'Public domain in the USA.';
  static const _maxMetadataBytes = 128 * 1024;
  static final _keyPattern = RegExp(r'[^a-z0-9\u3400-\u9fff]');
  static final _cjk = RegExp(r'^[\u3400-\u9fff]{2,20}$');
  static final _year = RegExp(r'^\d{4}(?=-\d{2}-\d{2}$)');
  static final _authorDates = RegExp(r', (?:active|approximately|\d).*$');

  static String _key(String value) =>
      value.toLowerCase().replaceAll(_keyPattern, '');

  static Uri _source(int id) => Uri.https(_website, '/ebooks/$id');
  static Uri _file(int id) =>
      Uri.https(_mirror, '/cache/epub/$id/pg$id-images-3.epub');

  static int? epubId(Uri uri) {
    if (uri.hasQuery || (uri.host != _website && uri.host != _mirror)) {
      return null;
    }
    final file = RegExp(
      r'^/cache/epub/([1-9]\d{0,6})/pg\1-images-3\.epub$',
    ).firstMatch(uri.path);
    final link = uri.host == _website
        ? RegExp(
            r'^/ebooks/([1-9]\d{0,6})\.epub3\.images$',
          ).firstMatch(uri.path)
        : null;
    return int.tryParse((file ?? link)?.group(1) ?? '');
  }

  static List<int> matchingIds(BookSearchQuery query) {
    if (!query.acceptsFile(
      title: query.title,
      edition: '古登堡电子版',
      format: 'epub',
      language: '中文',
      checkEdition: false,
    )) {
      return const [];
    }
    return gutenbergChineseTitles[_key(query.title)] ?? const [];
  }

  static Future<BookSearchCandidate?> lookup(
    HttpClient client,
    BookSearchQuery query,
    int id,
  ) async {
    final request = await client.getUrl(
      Uri.https(_mirror, '/cache/epub/$id/pg$id.rdf'),
    );
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/rdf+xml');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.listen((_) {}).cancel();
      throw GutenbergHttpFailure(response.statusCode);
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > _maxMetadataBytes) {
        throw const FormatException('古登堡书目超过大小限制。');
      }
      bytes.addAll(chunk);
    }
    final entry = XmlDocument.parse(
      utf8.decode(bytes),
    ).rootElement.getElement('ebook', namespaceUri: _pg);
    if (entry == null ||
        entry.getAttribute('about', namespaceUri: _rdf) != 'ebooks/$id') {
      throw const FormatException('古登堡书目编号不匹配。');
    }
    String term(String name) =>
        entry.getElement(name, namespaceUri: _terms)?.innerText.trim() ?? '';
    final title = term('title');
    final language = term('language');
    final year = _year.stringMatch(term('issued'));
    final files = entry.findAllElements('file', namespaceUri: _pg);
    if (term('rights') != _rights ||
        term('type') != 'Text' ||
        language != 'zh' ||
        year == null ||
        !(gutenbergChineseTitles[_key(title)] ?? const []).contains(id) ||
        (query.title.isNotEmpty && !matchingIds(query).contains(id)) ||
        !files.any(
          (file) =>
              file.getAttribute('about', namespaceUri: _rdf) ==
              '${_source(id)}.epub3.images',
        )) {
      return null;
    }
    final edition = '古登堡电子版 · $year';
    if (!query.acceptsFile(
      title: title,
      edition: edition,
      format: 'epub',
      language: '中文',
    )) {
      return null;
    }
    final authors = <String>[];
    final names = <String>{};
    for (final creator in entry.findElements('creator', namespaceUri: _terms)) {
      final agent = creator.getElement('agent', namespaceUri: _pg);
      if (agent == null) continue;
      final name = agent
          .getElement('name', namespaceUri: _pg)
          ?.innerText
          .trim();
      if (name == null || name.isEmpty) continue;
      final aliases = agent
          .findElements('alias', namespaceUri: _pg)
          .map((alias) => alias.innerText.trim())
          .toList();
      final pageNames = agent
          .findElements('webpage', namespaceUri: _pg)
          .map(
            (page) => Uri.tryParse(
              page.getAttribute('resource', namespaceUri: _rdf) ?? '',
            ),
          )
          .whereType<Uri>()
          .where(
            (uri) =>
                uri.host == 'zh.wikipedia.org' &&
                uri.pathSegments.firstOrNull == 'wiki',
          )
          .map((uri) => uri.pathSegments.last)
          .where(_cjk.hasMatch);
      final displayName =
          pageNames.firstOrNull ??
          aliases.where(_cjk.hasMatch).firstOrNull ??
          name.replaceFirst(_authorDates, '');
      authors.add(displayName);
      names.addAll([
        name,
        name.replaceFirst(_authorDates, ''),
        ...aliases,
        ...pageNames,
      ]);
    }
    if (authors.isEmpty ||
        (query.author.isNotEmpty &&
            !names.map(_key).contains(_key(query.author)))) {
      return null;
    }
    return BookSearchCandidate(
      id: 'gutenberg-$id-epub',
      title: title,
      author: authors.join('、'),
      language: '中文',
      edition: edition,
      format: 'epub',
      sourceName: sourceName,
      sourceUri: _source(id),
      license: _rights,
      licenseUri: Uri.https(_website, '/policy/license.html'),
      downloadUri: _file(id),
      publisher: sourceName,
      publicationYear: year,
    );
  }

  static int? _id(BookSearchCandidate candidate) => int.tryParse(
    RegExp(
          r'^gutenberg-([1-9]\d{0,6})-epub$',
        ).firstMatch(candidate.id)?.group(1) ??
        '',
  );

  static bool permitsDownload(BookSearchCandidate candidate) {
    final id = _id(candidate);
    return id != null &&
        candidate.sourceName == sourceName &&
        candidate.sourceUri == _source(id) &&
        candidate.downloadUri == _file(id) &&
        candidate.format == 'epub' &&
        candidate.license == _rights &&
        (gutenbergChineseTitles[_key(candidate.title)] ?? const []).contains(
          id,
        );
  }

  static bool matchesPublication(
    BookSearchCandidate candidate,
    XmlDocument package,
  ) {
    final id = _id(candidate);
    return package
            .findAllElements('identifier', namespaceUri: _dc)
            .any(
              (field) =>
                  field.innerText.trim() == 'http://$_website/$id' ||
                  field.innerText.trim() == 'https://$_website/$id',
            ) &&
        package
            .findAllElements('title', namespaceUri: _dc)
            .any((field) => _key(field.innerText) == _key(candidate.title)) &&
        package
            .findAllElements('language', namespaceUri: _dc)
            .any((field) => field.innerText.trim() == 'zh');
  }
}
