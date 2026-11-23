import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import 'book_search_query.dart';
import 'book_search_service.dart';

/// Extracts file links that a publisher associates with a specific book.
class BookSearchWebPage {
  static const _idPrefix = 'web-edition-';
  static const _standardHost = 'standardebooks.org';
  static final _sample = RegExp(
    r'\b(?:sample|preview|excerpt|chapter|supplement)\b|试读|試讀|样章|樣章|节选|節選',
    caseSensitive: false,
  );

  /// The publisher advertises this public catalog in its OpenSearch document.
  static Uri? standardCatalog(BookSearchQuery query) {
    if (!RegExp(
          r'^[A-Za-z][\p{Script=Latin}0-9\p{P} ]+$',
          unicode: true,
        ).hasMatch(query.title) ||
        (query.language.isNotEmpty && _language(query.language) != '英文') ||
        (query.format.isNotEmpty && query.format != 'epub')) {
      return null;
    }
    return Uri.https(_standardHost, '/ebooks', {
      'query': _withoutArticle(query.title),
      'per-page': '5',
      'page': '1',
    });
  }

  static Iterable<Uri> catalogPages(List<int> bytes, Uri catalog) {
    final links = html
        .parse(bytes)
        .querySelectorAll('a[href][property="schema:url"]');
    return {
      for (final link in links)
        if (_resolve(catalog, link.attributes['href']!) case final uri?
            when uri.host == _standardHost &&
                uri.pathSegments.length >= 3 &&
                uri.pathSegments.first == 'ebooks')
          uri,
    };
  }

  static String? fileFormat(Uri uri) {
    final path = uri.path.toLowerCase();
    if (path.endsWith('.pdf')) return 'pdf';
    if (path.endsWith('.epub') || isWrappedEpub(uri)) return 'epub';
    return null;
  }

  static bool isWrappedEpub(Uri uri) {
    final path = uri.path.toLowerCase();
    return path.endsWith('.epub.zip') || path.endsWith('.epub_.zip');
  }

  /// Follow publication links actually advertised by the file's own host.
  static Iterable<Uri> publicationPages(
    List<int> bytes,
    Uri home,
    BookSearchQuery query,
  ) sync* {
    final seen = {home};
    final bookNavigation = RegExp(
      r'^(?:(?:圖書|图书|電子書|电子书|書籍|书籍)(?:下載|下载|目錄|目录)|'
      r'books|e-?books|catalog(?:ue)?|publications|open access books)$',
      caseSensitive: false,
    );
    for (final link in html.parse(bytes).querySelectorAll('a[href]')) {
      final label = link.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (!_sameTitle(label, query.title) && !bookNavigation.hasMatch(label)) {
        continue;
      }
      final uri = _resolve(home, link.attributes['href']!);
      if (uri != null &&
          _sameOrigin(home, uri) &&
          fileFormat(uri) == null &&
          seen.add(uri)) {
        yield uri;
      }
    }
  }

  static Iterable<BookSearchCandidate> editions(
    List<int> bytes,
    Uri page,
    BookSearchQuery query,
  ) sync* {
    final document = html.parse(bytes);
    final books = [
      ...document
          .querySelectorAll('[typeof]')
          .where(
            (node) =>
                _has(node, 'typeof', 'Book') && _scope(node.parent) == null,
          ),
      ..._jsonLdBooks(document),
    ];
    for (final book in books) {
      if (_one(book, 'url') case final declared?
          when page.resolve(declared).removeFragment() != page) {
        continue;
      }
      final versions = [
        book,
        ..._fields(
          book,
          'workExample',
        ).where((node) => _has(node, 'typeof', 'Book')),
      ];
      for (final release in versions) {
        final title = _one(release, 'name') ?? _one(book, 'name');
        final authors = _contributors(release, 'author');
        final author = (authors.isEmpty
            ? _contributors(book, 'author')
            : authors);
        final translators = _contributors(release, 'translator');
        final publisher = _contributors(release, 'publisher').firstOrNull;
        final language = _language(
          _one(release, 'inLanguage') ?? _one(book, 'inLanguage'),
        );
        final edition = _one(release, 'bookEdition');
        final isbn = _one(release, 'isbn');
        final date = _one(release, 'datePublished');
        final license = _license(_one(release, 'license'));
        if (title == null ||
            !_sameTitle(title, query.title) ||
            author.isEmpty ||
            language == null ||
            license == null ||
            !_languageMatches(query.language, language) ||
            !_matches(query.author, author) ||
            !query.matchesTranslator(translators.join('、')) ||
            !_matches(query.edition, [
              if (edition != null) edition,
              ...translators,
            ]) ||
            !_matches(query.isbn, [if (isbn != null) isbn])) {
          continue;
        }
        yield* _files(release, page, query, license, (
          title: title,
          authors: author.join('、'),
          translator: translators.join('、'),
          publisher: publisher,
          language: language,
          edition: edition,
          isbn: isbn,
          date: date,
        ));
      }
    }
    yield* _licensedHtmlCatalog(document, page, query);
  }

  /// Match a book and its explicitly labelled file inside the same bounded
  /// catalog card. Page-wide licensing is accepted only if the publisher
  /// explicitly applies it to all books. Ordinary unrelated links stay leads.
  static Iterable<BookSearchCandidate> _licensedHtmlCatalog(
    Document document,
    Uri page,
    BookSearchQuery query,
  ) sync* {
    final allBooks = RegExp(
      r'all books (?:on this platform|on this site|in this catalog)|本(?:平台|站|網站)(?:的)?所有[圖图]書',
      caseSensitive: false,
    );
    final license = document
        .querySelectorAll('a[href]')
        .map((link) {
          if (!allBooks.hasMatch(link.parent?.text ?? '')) return null;
          return _license(link.attributes['href']);
        })
        .nonNulls
        .toSet();
    if (license.length != 1 || query.title.isEmpty) return;
    final language = _language(document.documentElement?.attributes['lang']);
    if (language == null || !_languageMatches(query.language, language)) return;

    final used = <Uri>{};
    for (final link in document.querySelectorAll('a[href]')) {
      final format = switch (link.text.trim().toLowerCase().replaceAll(
        RegExp(r'\s'),
        '',
      )) {
        '下載pdf' || '下载pdf' || 'downloadpdf' => 'pdf',
        '下載epub' || '下载epub' || 'downloadepub' => 'epub',
        _ => '',
      };
      if (format.isEmpty || (query.format.isNotEmpty && query.format != format))
        continue;
      final file = _resolve(page, link.attributes['href']!);
      if (file == null ||
          !_sameOrigin(page, file) ||
          fileFormat(file) != format ||
          _sample.hasMatch(file.path) ||
          used.contains(file))
        continue;

      // Walk only local containers with a single file of this format. This
      // prevents borrowing a nearby book's title, contributor or download.
      for (
        var card = link.parent, depth = 0;
        card != null && depth < 8;
        card = card.parent, depth++
      ) {
        final files = card.querySelectorAll('a[href]').where((a) {
          final uri = _resolve(page, a.attributes['href']!);
          return uri != null && fileFormat(uri) == format;
        });
        if (files.length != 1 || card.text.length > 1200) break;
        final heading = card
            .querySelectorAll(
              'h1,h2,h3,h4,p,[data-widget_type="text-editor.default"]',
            )
            .map((node) => node.text.trim())
            .where((title) => _sameTitle(title, query.title))
            .firstOrNull;
        if (heading == null) continue;
        final attribution = RegExp(
          r'([^\n・·]{1,80}?)\s+(?:編著|编著|著|編|编)(?:\s*[・·]\s*([^\n]{1,60}?)\s+[譯译])?\s*([^\n]{1,100}?出版社)\s+(\d{4})',
        ).firstMatch(card.text.trim().replaceFirst(heading, ''));
        if (attribution == null || query.isbn.isNotEmpty) break;
        final author = attribution[1]!.trim();
        final translator = attribution[2]?.trim();
        final publisher = attribution[3]!.trim();
        final year = attribution[4]!;
        if (!_matches(query.author, author.split('、')) ||
            !query.matchesTranslator(translator) ||
            (query.edition.isNotEmpty && query.edition != year))
          break;
        final (name, licenseUrl) = license.single;
        used.add(file);
        yield BookSearchCandidate(
          id: _id(page, file, format),
          title: heading,
          author: author,
          translator: translator,
          language: language,
          edition: '电子版 · $year',
          publisher: publisher,
          publicationYear: year,
          format: format,
          sourceName: page.host,
          sourceUri: page,
          license: name,
          licenseUri: licenseUrl,
          downloadUri: file,
        );
        break;
      }
    }
  }

  /// Map explicit Book and MediaObject fields into the same evidence model as
  /// RDFa. In particular, licenses on chapters or an unrelated WebPage never
  /// qualify a book. No remote JSON-LD contexts are fetched.
  static Iterable<Element> _jsonLdBooks(Document document) sync* {
    Iterable<Map> nodes(Object? value, int depth) sync* {
      if (depth > 6) return;
      if (value is List) {
        for (final item in value) {
          yield* nodes(item, depth + 1);
        }
      } else if (value is Map) {
        yield value;
        yield* nodes(value['@graph'], depth + 1);
      }
    }

    for (final script
        in document
            .querySelectorAll('script[type="application/ld+json"]')
            .take(24)) {
      Object? data;
      try {
        data = jsonDecode(script.text);
      } on FormatException {
        continue;
      }
      for (final node in nodes(data, 0).take(100)) {
        if (_jsonType(node, 'Book')) yield _jsonLdRelease(node);
      }
    }
  }

  static bool _jsonType(Map row, String type) {
    final raw = row['@type'];
    return (raw is List ? raw : [raw]).any(
      (value) =>
          value == type ||
          value == 'schema:$type' ||
          value == 'https://schema.org/$type' ||
          value == 'http://schema.org/$type',
    );
  }

  static Element _jsonLdRelease(Map row, {bool version = false}) {
    final book = Element.tag('section')..attributes['typeof'] = 'schema:Book';
    if (version) book.attributes['property'] = 'schema:workExample';
    void field(Element parent, String term, Object? raw) {
      final value = raw is Map ? raw['@id'] ?? raw['url'] ?? raw['name'] : raw;
      if (value is! String || value.trim().isEmpty) return;
      parent.append(
        Element.tag('meta')
          ..attributes['property'] = 'schema:$term'
          ..attributes['content'] = value.trim(),
      );
    }

    List values(String term) =>
        row[term] is List ? row[term] as List : [row[term]];
    for (final term in [
      'name',
      'url',
      'inLanguage',
      'bookEdition',
      'isbn',
      'datePublished',
      'license',
    ]) {
      field(book, term, row[term]);
    }
    for (final term in ['author', 'translator', 'publisher']) {
      for (final value in values(term).take(20)) {
        field(book, term, value is Map ? value['name'] : value);
      }
    }
    for (final media in values('encoding').whereType<Map>().take(10)) {
      if (!_jsonType(media, 'MediaObject')) continue;
      final element = Element.tag('div')
        ..attributes['typeof'] = 'schema:MediaObject'
        ..attributes['property'] = 'schema:encoding';
      for (final term in [
        'contentUrl',
        'encodingFormat',
        'description',
        'license',
      ]) {
        field(element, term, media[term]);
      }
      book.append(element);
    }
    if (!version) {
      for (final release in values('workExample').whereType<Map>().take(10)) {
        if (_jsonType(release, 'Book'))
          book.append(_jsonLdRelease(release, version: true));
      }
    }
    return book;
  }

  static Iterable<BookSearchCandidate> _files(
    Element release,
    Uri page,
    BookSearchQuery query,
    (String, Uri) license,
    ({
      String title,
      String authors,
      String translator,
      String? publisher,
      String language,
      String? edition,
      String? isbn,
      String? date,
    })
    book,
  ) sync* {
    final formats = <String>{};
    for (final media in _fields(release, 'encoding')) {
      if (!_has(media, 'typeof', 'MediaObject')) continue;
      final link = _one(media, 'contentUrl');
      if (link == null) continue;
      final uri = _resolve(page, link);
      final format = switch (_one(media, 'encodingFormat')?.toLowerCase()) {
        'application/epub+zip' => 'epub',
        'application/pdf' => 'pdf',
        _ => '',
      };
      final mediaLicense = _one(media, 'license');
      if (uri == null ||
          !_sameOrigin(page, uri) ||
          format.isEmpty ||
          (query.format.isNotEmpty && query.format != format) ||
          _sample.hasMatch('${uri.path} ${_one(media, 'description') ?? ''}') ||
          (mediaLicense != null && _license(mediaLicense)?.$2 != license.$2) ||
          !formats.add(format)) {
        continue;
      }
      final year = RegExp(r'^\d{4}\b').stringMatch(book.date ?? '');
      final sourceName = book.publisher ?? page.host;
      final territorial = release.querySelector('.us-pd-warning') != null;
      yield BookSearchCandidate(
        id: _id(page, uri, format),
        title: book.title,
        author: book.authors,
        translator: book.translator.isEmpty ? null : book.translator,
        edition: book.edition ?? '电子版${year == null ? '' : ' · $year'}',
        language: book.language,
        format: format,
        sourceName: sourceName,
        sourceUri: page,
        downloadUri: uri,
        publisher: book.publisher,
        publicationYear: year,
        isbn: book.isbn?.replaceAll('-', ''),
        license: territorial ? '${license.$1} · 原作美国公版' : license.$1,
        licenseUri: license.$2,
      );
    }
  }

  static bool isDiscovered(BookSearchCandidate candidate) =>
      candidate.id.startsWith(_idPrefix);

  static bool matchesPublication(
    BookSearchCandidate candidate,
    XmlDocument xml,
  ) {
    final metadata = xml.findAllElements('metadata').firstOrNull;
    if (metadata == null) return false;
    Iterable<String> values(String name) => metadata.childElements
        .where((element) => element.name.local == name)
        .map((element) => element.innerText);
    final translators = _epubTranslators(metadata);
    return values('title').any((title) => _sameTitle(title, candidate.title)) &&
        candidate.author
            .split('、')
            .every((name) => _matches(name, values('creator'))) &&
        (candidate.translator
                ?.split('、')
                .every((name) => _matches(name, translators)) ??
            true) &&
        _matchesEpubLanguage(candidate.language, values('language'));
  }

  static bool _matchesEpubLanguage(String declared, Iterable<String> values) {
    final languages = values.map(_language).nonNulls.toSet();
    if (languages.any((value) => _languageMatches(declared, value)))
      return true;
    // An EPUB may record only the base language. Its matching publication
    // supplies the script unless the file declares a conflicting variant.
    return languages.length == 1 &&
        languages.contains('中文') &&
        (declared == '繁體中文' || declared == '简体中文');
  }

  static Iterable<String> _epubTranslators(XmlElement metadata) {
    final ids = metadata.childElements
        .where(
          (element) =>
              element.name.local == 'meta' &&
              element.getAttribute('property') == 'role' &&
              element.innerText.trim() == 'trl',
        )
        .map((element) => element.getAttribute('refines'))
        .toSet();
    return metadata.childElements
        .where(
          (element) =>
              const {'creator', 'contributor'}.contains(element.name.local) &&
              (ids.contains('#${element.getAttribute('id')}') ||
                  element.attributes.any(
                    (attribute) =>
                        attribute.name.local == 'role' &&
                        attribute.value == 'trl',
                  )),
        )
        .map((element) => element.innerText);
  }

  static Uri? downloadRefresh(List<int> bytes, Uri current) {
    final document = html.parse(bytes);
    final tag = document.head?.querySelector('meta[http-equiv="refresh"]');
    final match = RegExp(
      r'^0\s*;\s*url\s*=\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(tag?.attributes['content'] ?? '');
    if (match == null) return null;
    final destination = Uri.tryParse(match[1]!);
    if (destination == null) return null;
    final next = current.resolveUri(destination);
    // Follow a published, immediate download continuation for the same file.
    return next.query == 'source=download' &&
            !current.hasQuery &&
            next.path == current.path &&
            _sameOrigin(current, next) &&
            next.userInfo.isEmpty &&
            !next.hasFragment
        ? next
        : null;
  }

  static bool hasReadableText(List<int> bytes) {
    final document = html.parse(bytes);
    for (final node in document.querySelectorAll('nav, script, style')) {
      node.remove();
    }
    return (document.body?.text ?? '').runes
            .where((rune) => rune > 32)
            .take(1500)
            .length ==
        1500;
  }

  static bool permitsDownload(BookSearchCandidate candidate) {
    final file = candidate.downloadUri;
    final page = candidate.sourceUri;
    return file != null &&
        _publicHttps(page) &&
        _publicHttps(file) &&
        _sameOrigin(page, file) &&
        (candidate.format == 'epub' || candidate.format == 'pdf') &&
        _license(candidate.licenseUri?.toString()) != null &&
        candidate.id == _id(page, file, candidate.format);
  }

  static String _id(Uri page, Uri file, String format) =>
      '$_idPrefix${sha256.convert(utf8.encode('$page\n$file\n$format'))}-$format';

  static bool _has(Element node, String attribute, String term) =>
      (node.attributes[attribute] ?? '')
          .split(RegExp(r'\s+'))
          .any(
            (value) =>
                value == 'schema:$term' ||
                value == 'https://schema.org/$term' ||
                value == 'http://schema.org/$term',
          );

  static Element? _scope(Element? node) {
    for (var ancestor = node; ancestor != null; ancestor = ancestor.parent) {
      if (ancestor.attributes.containsKey('typeof')) return ancestor;
    }
    return null;
  }

  static Iterable<Element> _fields(Element scope, String name) => scope
      .querySelectorAll('[property]')
      .where(
        (node) => _has(node, 'property', name) && _scope(node.parent) == scope,
      );

  static String? _value(Element node) {
    final raw =
        (node.attributes['content'] ?? node.attributes['href'] ?? node.text)
            .trim();
    return raw.isEmpty || raw.length > 850 ? null : raw;
  }

  static String? _one(Element scope, String name) {
    final values = _fields(scope, name).map(_value).nonNulls.toSet();
    return values.length == 1 ? values.single : null;
  }

  static List<String> _contributors(Element scope, String field) => [
    for (final node in _fields(scope, field))
      if ((node.attributes.containsKey('typeof')
              ? _one(node, 'name')
              : _value(node))
          case final name?)
        name,
  ];

  static String _key(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );

  static bool _matches(String requested, Iterable<String> values) =>
      requested.isEmpty ||
      values.any((value) => _key(value) == _key(requested));

  static bool _sameTitle(String title, String wanted) =>
      wanted.isNotEmpty &&
      _matches(_withoutArticle(wanted), [
        _withoutArticle(title),
        _withoutArticle(title.split(RegExp(r'[:：]')).first),
      ]);

  static String _withoutArticle(String title) =>
      title.replaceFirst(RegExp(r'^the\s+', caseSensitive: false), '');

  static String? _language(String? code) =>
      switch (code?.trim().toLowerCase()) {
        'zh-cn' || 'zh-hans' || '简体中文' => '简体中文',
        'zh-tw' || 'zh-hant' || 'zh-hk' || '繁體中文' || '繁体中文' => '繁體中文',
        'zh' || '中文' => '中文',
        'en' ||
        'en-gb' ||
        'en-us' ||
        'en-ca' ||
        'en-au' ||
        '英文' ||
        'english' => '英文',
        final value
            when value != null &&
                RegExp(r'^[a-z]{2,3}(-[a-z0-9]{2,8})*$').hasMatch(value) =>
          value,
        _ => null,
      };

  static bool _languageMatches(String wanted, String actual) =>
      wanted.isEmpty ||
      (_language(wanted) == '中文'
          ? actual.contains('中文')
          : _language(wanted) == actual);

  static (String, Uri)? _license(String? value) {
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null ||
        !_publicHttps(uri) ||
        uri.host != 'creativecommons.org') {
      return null;
    }
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    final cc = RegExp(
      r'^/licenses/(by|by-sa|by-nd|by-nc|by-nc-sa|by-nc-nd)/(3\.0|4\.0)/$',
    ).firstMatch(path);
    final name = cc != null
        ? 'CC ${cc[1]!.toUpperCase()} ${cc[2]}'
        : switch (path) {
            '/publicdomain/zero/1.0/' => 'CC0 1.0',
            '/publicdomain/mark/1.0/' => 'Public Domain Mark 1.0',
            _ => null,
          };
    return name == null ? null : (name, Uri.https(uri.host, path));
  }

  static Uri? _resolve(Uri page, String url) {
    final value = Uri.tryParse(url);
    final uri = value == null ? null : page.resolveUri(value).removeFragment();
    return uri != null && _publicHttps(uri) ? uri : null;
  }

  static bool isPublicPage(Uri uri) => _publicHttps(uri);

  static bool _publicHttps(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      uri.host.contains('.') &&
      !uri.hasFragment &&
      InternetAddress.tryParse(uri.host) == null;

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;
}
