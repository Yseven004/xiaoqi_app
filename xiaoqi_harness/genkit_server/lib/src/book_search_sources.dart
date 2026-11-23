import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show ZLibDecoder;
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import 'book_search_query.dart';
import 'book_search_service.dart';
import 'book_search_web_page.dart';
import 'gutenberg_books.dart';
import 'thoth_books.dart';
import 'web_service.dart';
import 'wikisource_books.dart';

/// Retain the HTTP status for diagnostics without retaining URLs or bodies.
class _UpstreamHttpFailure implements Exception {
  const _UpstreamHttpFailure(this.status);

  final int status;
}

class _FileReadFailure extends FormatException {
  const _FileReadFailure(this.reason, super.message);

  final String reason;
}

class _CatalogFailure extends BookSearchException {
  const _CatalogFailure(this.cause, [String message = '书目来源暂不可用。'])
    : super(503, message);

  final Object cause;
}

/// Searches trusted publishers, Chinese Wikisource and bibliographic catalogs.
class BookSearchSources {
  BookSearchSources({
    this.webService,
    HttpClient Function()? clientFactory,
    void Function(Map<String, Object>)? onDiagnostic,
  }) : _clientFactory = clientFactory,
       _onDiagnostic = onDiagnostic;

  final WebService Function(void Function() checkCancelled)? webService;
  final HttpClient Function()? _clientFactory;
  final void Function(Map<String, Object>)? _onDiagnostic;
  final _metadataCache = <String, (DateTime, List<BookSearchCandidate>)>{};
  final _publisherCache = <String, (DateTime, List<BookSearchCandidate>)>{};
  DateTime? _lastMetadataRequest;

  static const _fileLimit = 256 * 1024 * 1024;
  static const _probeTimeout = Duration(seconds: 9);
  static final _versionPattern = RegExp(r'\b\d+\.\d+(?:\.\d+)?\b');
  static final _releaseQualifier = RegExp(
    r'\b[vV]?\d+\.\d+(?:\.\d+)?\b|第\s*[一二三四五六七八九十\d]+\s*版(?:次)?|\b\d+(?:st|nd|rd|th)\s+edition\b',
    caseSensitive: false,
  );
  static final _metadataAuthorPrefix = RegExp(
    r'^[（(【\[]\s*(?:[美英法德日俄中意澳加](?:国)?)\s*[）)】\]]\s*',
  );
  static final _authorSeparators = RegExp(r'[\s\p{P}]', unicode: true);
  static final _wordPattern = RegExp(r'[^a-z0-9\u3400-\u9fff]+');

  static const _helloRelease = '1.3.0';
  static const _proGitRelease = '2.1.80';

  void _report(
    BookSearchCancellation cancellation,
    String source,
    String stage,
    String outcome, {
    String? reason,
    Object? error,
  }) {
    if (cancellation.isCancelled) return;
    final (failure, status) = _failure(error);
    final outcomeReason =
        reason ??
        switch (status) {
          401 || 403 => 'access_denied',
          429 => 'rate_limited',
          _ => failure,
        };
    final diagnostic = <String, Object>{
      'component': 'book_search_source',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'attempt': identityHashCode(cancellation),
      'source': source,
      'stage': stage,
      'outcome': outcome,
      if (outcomeReason != null) 'reason': outcomeReason,
      if (status != null) 'upstream_status': status,
    };
    cancellation.report({
      'source': source,
      'stage': stage,
      'outcome': outcome,
      if (outcomeReason != null) 'reason': outcomeReason,
      if (status != null) 'upstream_status': status,
    });
    try {
      if (_onDiagnostic case final log?) {
        log(diagnostic);
      } else {
        stderr.writeln(jsonEncode(diagnostic));
      }
    } on Object {
      // Diagnostics must not affect the search result.
    }
  }

  static (String?, int?) _failure(Object? error) => switch (error) {
    null => (null, null),
    _CatalogFailure(:final cause) => _failure(cause),
    _UpstreamHttpFailure(:final status) => ('upstream_http_status', status),
    GutenbergHttpFailure(:final status) => ('upstream_http_status', status),
    ThothHttpFailure(:final statusCode) => ('upstream_http_status', statusCode),
    _FileReadFailure(:final reason) => (reason, null),
    WikisourceHttpFailure(:final upstreamStatus) => (
      'upstream_http_status',
      upstreamStatus,
    ),
    WikisourceContentFailure(:final reason) => (reason, null),
    TimeoutException() => ('timeout', null),
    TlsException() => ('tls_failure', null),
    SocketException() || HttpException() => ('connection_failure', null),
    FormatException() => ('invalid_response', null),
    FileSystemException() => ('local_file_failure', null),
    BookSearchException(statusCode: 409 || 422) => ('content_rejected', null),
    _ => ('unclassified_failure', null),
  };

  static String _fileSource(BookSearchCandidate candidate) =>
      BookSearchWebPage.isDiscovered(candidate)
      ? 'web_book_page'
      : switch (candidate.sourceName) {
          '作者官方仓库' => 'hello_algo',
          'D2L 作者官网' => 'd2l',
          'Git 官网 / Pro Git 官方仓库' => 'pro_git',
          'Eloquent JavaScript 作者官网' => 'eloquent_javascript',
          'Green Tea Press' => 'green_tea_press',
          ThothBooks.sourceName => 'open_book_publishers',
          ThothBooks.archiveSourceName => 'open_book_publishers_archive',
          GutenbergBooks.sourceName => 'gutenberg',
          '中文维基文库' => 'wikisource_zh',
          _ => 'official_release',
        };

  static final _catalog = <_BookSource>[
    _BookSource(
      aliases: const [
        'hello算法',
        'hello演算法',
        'helloalgo',
        '靳宇栋',
        '靳宇棟',
        'krahets',
      ],
      discoveryHosts: const {'www.hello-algo.com', 'hello-algo.com'},
      discoveryRepository: 'krahets/hello-algo',
      revision: _helloRelease,
      candidates: [
        for (final (languageCode, language, title) in const [
          ('zh', '简体中文', 'Hello 算法'),
          ('zh-hant', '繁體中文', 'Hello 演算法'),
          ('en', '英文', 'Hello Algorithms'),
        ])
          for (final (code, variant) in const [
            ('python', 'Python'),
            ('java', 'Java'),
            ('cpp', 'C++'),
            ('csharp', 'C#'),
            ('dart', 'Dart'),
            ('javascript', 'JavaScript'),
            ('typescript', 'TypeScript'),
            ('go', 'Go'),
            ('kotlin', 'Kotlin'),
            ('ruby', 'Ruby'),
            ('rust', 'Rust'),
            ('swift', 'Swift'),
            ('c', 'C'),
          ])
            for (final format in const ['pdf', 'epub'])
              BookSearchCandidate(
                id: 'hello-$_helloRelease-$languageCode-$code-$format',
                title: '$title · $variant 版',
                author: '靳宇栋（krahets）',
                language: language,
                edition: _helloRelease,
                format: format,
                sourceName: '作者官方仓库',
                sourceUri: Uri.https(
                  'github.com',
                  '/krahets/hello-algo/releases/tag/$_helloRelease',
                ),
                downloadUri: Uri.https(
                  'github.com',
                  '/krahets/hello-algo/releases/download/$_helloRelease/'
                      'hello-algo_${_helloRelease}_${languageCode}_$code.$format',
                ),
                license: 'CC BY-NC-SA 4.0',
                licenseUri: Uri.https(
                  'creativecommons.org',
                  '/licenses/by-nc-sa/4.0/',
                ),
                publicationYear: '2026',
              ),
      ],
    ),
    _BookSource(
      aliases: const ['动手学深度学习', '動手學深度學習', 'diveintodeeplearning', 'd2l'],
      discoveryHosts: const {'zh.d2l.ai', 'zh-v2.d2l.ai'},
      discoveryRepository: 'd2l-ai/d2l-zh',
      revision: '2.0.0',
      candidates: [
        for (final (variant, path) in const [
          ('PyTorch', '/d2l-zh-pytorch.pdf'),
          ('MXNet', '/d2l-zh.pdf'),
        ])
          BookSearchCandidate(
            id: 'd2l-2.0.0-${variant.toLowerCase()}-pdf',
            title: '动手学深度学习 · $variant 版',
            author: 'Aston Zhang、Zachary C. Lipton、Mu Li、Alexander J. Smola',
            language: '简体中文',
            edition: '中文第 2 版 · 2.0.0',
            format: 'pdf',
            sourceName: 'D2L 作者官网',
            sourceUri: Uri.https('zh-v2.d2l.ai', '/'),
            downloadUri: Uri.https('zh-v2.d2l.ai', path),
            license: 'Apache-2.0（中文源项目）',
            licenseUri: Uri.https(
              'github.com',
              '/d2l-ai/d2l-zh/blob/master/LICENSE',
            ),
            publicationYear: '2023',
          ),
      ],
    ),
    _BookSource(
      aliases: const ['progit', 'scottchacon', 'benstraub'],
      discoveryHosts: const {'git-scm.com'},
      discoveryRepository: 'progit/progit2-zh',
      revision: _proGitRelease,
      candidates: [
        for (final format in const ['pdf', 'epub'])
          BookSearchCandidate(
            id: 'pro-git-zh-$_proGitRelease-$format',
            title: 'Pro Git',
            author: 'Scott Chacon、Ben Straub',
            language: '简体中文',
            edition: '简体中文第 2 版 · $_proGitRelease',
            format: format,
            sourceName: 'Git 官网 / Pro Git 官方仓库',
            sourceUri: Uri.https(
              'github.com',
              '/progit/progit2-zh/releases/tag/$_proGitRelease',
            ),
            downloadUri: Uri.https(
              'github.com',
              '/progit/progit2-zh/releases/download/$_proGitRelease/progit.$format',
            ),
            license: 'CC BY-NC-SA 3.0',
            licenseUri: Uri.https(
              'creativecommons.org',
              '/licenses/by-nc-sa/3.0/',
            ),
            publicationYear: '2026',
          ),
      ],
    ),
    _BookSource(
      aliases: const ['eloquentjavascript', 'marijnhaverbeke'],
      discoveryHosts: const {'eloquentjavascript.net'},
      candidates: [
        for (final format in const ['pdf', 'epub'])
          BookSearchCandidate(
            id: 'eloquent-javascript-4-en-$format',
            title: 'Eloquent JavaScript',
            author: 'Marijn Haverbeke',
            language: '英文',
            edition: '4th edition',
            format: format,
            sourceName: 'Eloquent JavaScript 作者官网',
            sourceUri: Uri.https('eloquentjavascript.net', '/'),
            downloadUri: Uri.https(
              'eloquentjavascript.net',
              '/Eloquent_JavaScript.$format',
            ),
            license: 'CC BY-NC 3.0',
            licenseUri: Uri.https(
              'creativecommons.org',
              '/licenses/by-nc/3.0/',
            ),
            publicationYear: '2024',
          ),
      ],
    ),
    _BookSource(
      aliases: const ['thinkpython', 'allenbdowney', 'allendowney'],
      discoveryHosts: const {'greenteapress.com'},
      candidates: [
        BookSearchCandidate(
          id: 'think-python-2-en-pdf',
          title: 'Think Python',
          author: 'Allen B. Downey',
          language: '英文',
          edition: '2nd edition',
          format: 'pdf',
          sourceName: 'Green Tea Press',
          sourceUri: Uri.https('greenteapress.com', '/wp/think-python-2e/'),
          downloadUri: Uri.https(
            'greenteapress.com',
            '/thinkpython2/thinkpython2.pdf',
          ),
          license: 'CC BY-NC 3.0',
          licenseUri: Uri.https('creativecommons.org', '/licenses/by-nc/3.0/'),
        ),
      ],
    ),
  ];

  Stream<BookSearchCandidate> search(
    String query,
    BookSearchCancellation cancellation,
  ) => searchByCriteria(BookSearchQuery.fromText(query), cancellation);

  Stream<BookSearchCandidate> searchByCriteria(
    BookSearchQuery criteria,
    BookSearchCancellation cancellation,
  ) async* {
    _checkActive(cancellation);
    final title = _normalized(criteria.title);
    final author = _normalized(
      criteria.author.replaceFirst(_metadataAuthorPrefix, ''),
    );
    Future<List<Map>>? webResults;
    Future<List<Map>> webLookup() =>
        webResults ??= _searchWebBooks(criteria, cancellation);
    var matches = _catalog
        .where(
          (s) =>
              criteria.isbn.isEmpty &&
              (title.isNotEmpty || author.isNotEmpty) &&
              (title.isEmpty || s.recognizes(title)) &&
              (author.isEmpty ||
                  s.recognizes(author) ||
                  s.candidates.any(
                    (book) => _normalized(book.author).contains(author),
                  )),
        )
        .toList();
    if (matches.isEmpty &&
        criteria.isbn.isEmpty &&
        author.isEmpty &&
        webService != null &&
        _catalog.any((s) => s.matchesPartial(title))) {
      try {
        final sources = await webLookup();
        matches = _catalog
            .where(
              (book) =>
                  book.matchesPartial(title) &&
                  sources.any((source) {
                    final uri = Uri.tryParse('${source['url'] ?? ''}');
                    return uri != null &&
                        book.isOfficialPage(uri) &&
                        book.recognizes(
                          _normalized('${source['title'] ?? ''}'),
                        );
                  }),
            )
            .toList();
        _report(
          cancellation,
          'web_discovery',
          'lookup',
          matches.isEmpty ? 'no_match' : 'release_match',
        );
      } on BookSearchException catch (error) {
        _checkActive(cancellation);
        _report(
          cancellation,
          'web_discovery',
          'lookup',
          'failed',
          error: error,
        );
      }
    }
    if (matches.isEmpty) {
      _report(cancellation, 'official_catalog', 'lookup', 'no_match');
    }
    final candidates = matches
        .expand((source) {
          final editions = source.select(criteria).toList();
          if (editions.isEmpty) {
            _report(
              cancellation,
              _fileSource(source.candidates.first),
              'lookup',
              'no_match',
              reason: 'no_matching_edition',
            );
          }
          return editions;
        })
        .take(8)
        .toList();
    bool sourceFailed = false;
    final probes = candidates.map((candidate) async {
      try {
        await verify(candidate, cancellation);
        return candidate;
      } on BookSearchException {
        sourceFailed = true;
        return null;
      }
    });
    await for (final candidate in Stream.fromFutures(probes)) {
      _checkActive(cancellation);
      if (candidate != null) yield candidate;
    }

    // Each eligible provider can offer a matching entry. The service stops the
    // remaining lookups when it accepts a result or the user cancels.
    _checkActive(cancellation);
    final supportsWiki = WikisourceBooks.supports(criteria);
    if (!supportsWiki) {
      _report(
        cancellation,
        'wikisource_zh',
        'lookup',
        'skipped',
        reason: 'unsupported_query',
      );
    }
    final gutenbergIds = GutenbergBooks.matchingIds(criteria);
    final providers = [
      _metadata(criteria, cancellation),
      if (supportsWiki)
        _wiki(criteria, cancellation).then((book) => [if (book != null) book]),
      if (gutenbergIds.isNotEmpty)
        _gutenbergBooks(criteria, cancellation, gutenbergIds),
      if (BookSearchWebPage.standardCatalog(criteria) case final catalog?)
        _standardEditions(catalog, criteria, cancellation),
      if (title.length >= 2) _publisherBooks(criteria, cancellation),
    ];
    final results = providers.map((provider) async {
      try {
        return await provider;
      } on Exception {
        sourceFailed = true;
        return <BookSearchCandidate>[];
      }
    });
    await for (final rows in Stream.fromFutures(results)) {
      _checkActive(cancellation);
      yield* Stream.fromIterable(rows);
    }
    final alternative = _alternateEdition(criteria, matches, candidates);
    if (alternative != null) {
      try {
        await verify(alternative, cancellation);
        _checkActive(cancellation);
        yield alternative;
      } on BookSearchException {
        _checkActive(cancellation);
        sourceFailed = true;
      }
    }
    if (webService != null && title.length >= 2 && criteria.isbn.isEmpty) {
      try {
        final leads = _webSourceLeads(criteria, await webLookup());
        final lookups = leads.map(
          (lead) => _webEditions(lead.sourceUri, criteria, cancellation),
        );
        await for (final editions in Stream.fromFutures(lookups)) {
          _checkActive(cancellation);
          yield* Stream.fromIterable(editions);
        }
        _checkActive(cancellation);
        _report(
          cancellation,
          'web_discovery',
          'lookup',
          leads.isEmpty ? 'no_match' : 'lead_match',
        );
        yield* Stream.fromIterable(
          leads
              .where(
                (lead) => BookSearchWebPage.fileFormat(lead.sourceUri) == null,
              )
              .take(2),
        );
      } on BookSearchException catch (error) {
        _checkActive(cancellation);
        _report(
          cancellation,
          'web_discovery',
          'lookup',
          'failed',
          error: error,
        );
      }
    }
    if (sourceFailed) {
      throw const BookSearchException(503, '有些来源暂不可用。');
    }
  }

  Stream<BookSearchCandidate> inspect(
    Uri uri,
    BookSearchQuery criteria,
    BookSearchCancellation cancellation,
  ) async* {
    if (!BookSearchWebPage.isPublicPage(uri)) {
      _report(
        cancellation,
        'web_book_page',
        'lookup',
        'rejected',
        reason: 'unsupported_source_url',
      );
      return;
    }
    if (GutenbergBooks.epubId(uri) case final id?) {
      try {
        yield* Stream.fromIterable(
          await _gutenbergBooks(criteria, cancellation, [id]),
        );
      } on Exception {
        // The source adapter already recorded the lookup or probe failure.
        _checkActive(cancellation);
      }
      return;
    }
    yield* Stream.fromIterable(await _webEditions(uri, criteria, cancellation));
  }

  Future<List<BookSearchCandidate>> _webEditions(
    Uri uri,
    BookSearchQuery query,
    BookSearchCancellation cancellation,
  ) async {
    final response = await _readBookSource(uri, cancellation);
    if (response == null) return const [];
    final directFormat = response.format;
    if (directFormat != null &&
        query.format.isNotEmpty &&
        directFormat != query.format) {
      _report(
        cancellation,
        uri.host,
        'match',
        'rejected',
        reason: 'file_format_mismatch',
      );
      return const [];
    }
    final candidates = directFormat == null
        ? BookSearchWebPage.editions(
            response.html!,
            uri,
            query,
          ).take(2).toList()
        : await _linkedFileEditions(uri, directFormat, query, cancellation);
    if (candidates.isEmpty) {
      _report(
        cancellation,
        uri.host,
        'extract',
        'rejected',
        reason: directFormat == null
            ? 'no_matching_book_file_evidence'
            : 'direct_file_needs_publication_page',
      );
      return const [];
    }
    final verified = <BookSearchCandidate>[];
    for (final candidate in candidates) {
      try {
        await verify(candidate, cancellation);
        verified.add(candidate);
      } on BookSearchException {
        if (cancellation.isCancelled) break;
      }
    }
    _report(
      cancellation,
      uri.host,
      'probe',
      verified.isEmpty ? 'no_match' : 'release_match',
    );
    return verified;
  }

  Future<List<BookSearchCandidate>> _linkedFileEditions(
    Uri file,
    String format,
    BookSearchQuery query,
    BookSearchCancellation cancellation,
  ) async {
    final home = Uri.https(file.host, '/');
    if (home == file) return const [];
    final bytes = (await _readBookSource(home, cancellation))?.html;
    if (bytes == null) return const [];

    List<BookSearchCandidate> matching(List<int> html, Uri page) =>
        BookSearchWebPage.editions(html, page, query)
            .where((book) => book.downloadUri == file && book.format == format)
            .take(2)
            .toList();

    final onHome = matching(bytes, home);
    if (onHome.isNotEmpty) return onHome;
    for (final page in BookSearchWebPage.publicationPages(
      bytes,
      home,
      query,
    ).take(2)) {
      _checkActive(cancellation);
      final html = (await _readBookSource(page, cancellation))?.html;
      if (html == null) continue;
      final candidates = matching(html, page);
      if (candidates.isNotEmpty) return candidates;
    }
    return const [];
  }

  Future<List<BookSearchCandidate>> _standardEditions(
    Uri catalog,
    BookSearchQuery query,
    BookSearchCancellation cancellation,
  ) async {
    final bytes = (await _readBookSource(catalog, cancellation))?.html;
    if (bytes == null) return const [];
    final pages = BookSearchWebPage.catalogPages(bytes, catalog).take(3);
    final verdicts = await Future.wait(
      pages.map((page) => _webEditions(page, query, cancellation)),
    );
    return verdicts.expand((editions) => editions).toList();
  }

  Future<({Uint8List? html, String? format})?> _readBookSource(
    Uri uri,
    BookSearchCancellation cancellation,
  ) async {
    final client = _client(cancellation);
    try {
      return await (() async {
        _checkActive(cancellation);
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.acceptHeader,
          'text/html, application/xhtml+xml, application/pdf, application/epub+zip, application/zip',
        );
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw _UpstreamHttpFailure(response.statusCode);
        }
        if (!_isHtml(response)) {
          final format = switch (response.headers.contentType?.mimeType) {
            'application/pdf' => 'pdf',
            'application/epub+zip' => 'epub',
            'application/zip' when BookSearchWebPage.isWrappedEpub(uri) =>
              'epub',
            null ||
            'application/octet-stream' => BookSearchWebPage.fileFormat(uri),
            _ => null,
          };
          // Determine the route from the headers and close this request.
          // The edition probe fetches only a prefix after publication match.
          if (format != null) return (html: null, format: format);
          _report(
            cancellation,
            uri.host,
            'fetch',
            'rejected',
            reason: 'not_html',
          );
          return null;
        }
        final body = BytesBuilder(copy: false);
        await for (final chunk in response) {
          _checkActive(cancellation);
          if (body.length + chunk.length > 768 * 1024) {
            throw const FormatException('书页超出大小限制。');
          }
          body.add(chunk);
        }
        return (html: body.takeBytes(), format: null);
      })().timeout(_probeTimeout);
    } on Exception catch (error) {
      _report(cancellation, uri.host, 'fetch', 'failed', error: error);
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<BookSearchCandidate>> _publisherBooks(
    BookSearchQuery criteria,
    BookSearchCancellation cancellation,
  ) async {
    _checkActive(cancellation);
    final key = jsonEncode(criteria.toJson()..remove('referenceIsbn'));
    final cached = _publisherCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 15)) {
      return cached.$2;
    }
    final client = _client(cancellation);
    try {
      final candidates = await ThothBooks.search(
        client,
        criteria,
      ).timeout(_probeTimeout);
      _checkActive(cancellation);
      if (_publisherCache.length >= 64) {
        _publisherCache.remove(_publisherCache.keys.first);
      }
      _publisherCache[key] = (DateTime.now(), candidates);
      _report(
        cancellation,
        'open_book_publishers',
        'lookup',
        candidates.isEmpty ? 'no_match' : 'release_match',
      );
      return candidates;
    } on Exception catch (error) {
      _checkActive(cancellation);
      _report(
        cancellation,
        'open_book_publishers',
        'lookup',
        'failed',
        error: error,
      );
      // This supplementary source must not change other sources' results.
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  static BookSearchCandidate? _alternateEdition(
    BookSearchQuery criteria,
    List<_BookSource> matches,
    List<BookSearchCandidate> exact,
  ) {
    if (matches.length != 1 ||
        criteria.title.isEmpty ||
        criteria.isbn.isNotEmpty ||
        !_releaseQualifier.hasMatch(criteria.edition)) {
      return null;
    }
    final preferredAuthor = _normalizedAuthor(criteria.author);
    // Relax only the edition number, retaining any requested code variant.
    final otherEdition = BookSearchQuery(
      title: criteria.title,
      author: criteria.author,
      language: criteria.language,
      format: criteria.format,
      edition: criteria.edition.replaceAll(_releaseQualifier, ' ').trim(),
    );
    final id = _normalized(criteria.title);
    final selected = matches.single.select(otherEdition).where((book) {
      final availableTitle = book.title.split(' · ').first;
      final sourceAuthors = book.author.split(RegExp(r'[、（()）]'));
      return (_normalized(book.title) == id ||
              _normalized(availableTitle) == id) &&
          (preferredAuthor.isEmpty ||
              _normalizedAuthor(book.author) == preferredAuthor ||
              sourceAuthors.map(_normalizedAuthor).contains(preferredAuthor)) &&
          book.downloadUri != null &&
          book.licenseUri != null &&
          !exact.any((candidate) => candidate.id == book.id) &&
          otherEdition.acceptsFile(
            title: book.title,
            edition: book.edition,
            format: book.format,
            language: book.language,
            isbn: book.isbn,
          ) &&
          !criteria.acceptsFile(
            title: book.title,
            edition: book.edition,
            format: book.format,
            language: book.language,
            isbn: book.isbn,
          );
    }).firstOrNull;
    if (selected == null) return null;
    return BookSearchCandidate(
      id: selected.id,
      title: selected.title,
      author: selected.author,
      language: selected.language,
      edition: selected.edition,
      format: selected.format,
      sourceName: selected.sourceName,
      sourceUri: selected.sourceUri,
      license: selected.license,
      licenseUri: selected.licenseUri,
      downloadUri: selected.downloadUri,
      inlineEpub: selected.inlineEpub,
      availability: selected.availability,
      isbn: selected.isbn,
      translator: selected.translator,
      publisher: selected.publisher,
      publicationYear: selected.publicationYear,
      alternateEdition: true,
    );
  }

  Future<BookSearchCandidate?> _wiki(
    BookSearchQuery query,
    BookSearchCancellation cancellation,
  ) async {
    final client = _client(cancellation)..autoUncompress = true;
    try {
      final book = await WikisourceBooks.find(
        client,
        query,
        onRejected: (reason) =>
            _report(cancellation, 'wikisource_zh', 'lookup', switch (reason) {
              'title_not_found' || 'author_mismatch' => 'no_match',
              'unsupported_query' => 'skipped',
              _ => 'rejected',
            }, reason: reason),
      );
      if (book != null) {
        _report(cancellation, 'wikisource_zh', 'lookup', 'release_match');
      }
      return book;
    } on Exception catch (error) {
      _report(cancellation, 'wikisource_zh', 'lookup', 'failed', error: error);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<BookSearchCandidate>> _gutenbergBooks(
    BookSearchQuery query,
    BookSearchCancellation cancellation,
    List<int> ids,
  ) async {
    _checkActive(cancellation);
    final client = _client(cancellation);
    try {
      final book = await _gutenberg(
        query,
        cancellation,
        client,
        ids,
      ).timeout(_probeTimeout);
      _checkActive(cancellation);
      _report(
        cancellation,
        'gutenberg',
        'lookup',
        book == null ? 'no_match' : 'release_match',
        reason: book == null ? 'no_matching_public_epub' : null,
      );
      return [if (book != null) book];
    } on Exception catch (error) {
      _report(cancellation, 'gutenberg', 'lookup', 'failed', error: error);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<BookSearchCandidate?> _gutenberg(
    BookSearchQuery query,
    BookSearchCancellation cancellation,
    HttpClient client,
    List<int> ids,
  ) async {
    for (final id in ids.take(3)) {
      _checkActive(cancellation);
      final book = await GutenbergBooks.lookup(client, query, id);
      if (book != null) {
        await _probe(client, book.downloadUri!, book.format, cancellation);
        return book;
      }
    }
    return null;
  }

  Future<List<BookSearchCandidate>> _metadata(
    BookSearchQuery query,
    BookSearchCancellation cancellation,
  ) async {
    // Catalog entries do not describe an available file. Changing the file
    // format on an Agent retry does not change this source request.
    final cacheKey = jsonEncode(query.toJson()..remove('format'));
    final cached = _metadataCache[cacheKey];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 15)) {
      return cached.$2;
    }
    final isbn = query.isbn.isNotEmpty ? query.isbn : query.referenceIsbn;
    final nativeTitle =
        query.isbn.isEmpty && RegExp(r'[\u3400-\u9fff]').hasMatch(query.title);
    var sourceFailed = false;
    Future<List<BookSearchCandidate>> attempt(
      String source,
      Future<List<BookSearchCandidate>> operation,
    ) async {
      try {
        final rows = await operation;
        _report(
          cancellation,
          source,
          'lookup',
          rows.isEmpty ? 'no_match' : 'catalog_match',
        );
        return rows;
      } on Exception catch (error) {
        _checkActive(cancellation);
        _report(cancellation, source, 'lookup', 'failed', error: error);
        sourceFailed = true;
        return [];
      }
    }

    Future<List<BookSearchCandidate>> primary() async {
      final byIsbn = await attempt(
        'open_library',
        _openLibrary(query, cancellation, isbn),
      );
      if (byIsbn.isNotEmpty || isbn.isEmpty || query.isbn.isNotEmpty)
        return byIsbn;
      // The linked print ISBN is a hint, not a restriction on the search.
      return attempt('open_library', _openLibrary(query, cancellation, ''));
    }

    var rows = <BookSearchCandidate>[];
    await for (final hits in Stream.fromFutures([
      primary(),
      if (nativeTitle)
        attempt('internet_archive', _archiveTitleEditions(query, cancellation)),
    ])) {
      if (hits.isNotEmpty) {
        rows = hits;
        break;
      }
    }
    if (query.isbn.isNotEmpty &&
        (rows.isEmpty ||
            (rows.any((row) => row.language == '中文') &&
                !rows.any((row) => _hasHanTitle(row.title))))) {
      final original = await attempt(
        'internet_archive',
        _archiveTitleEditions(query, cancellation, exactEditions: rows),
      );
      if (original.isNotEmpty) rows = original;
    }
    if (rows.isEmpty && nativeTitle && webService != null) {
      rows = await attempt(
        'library_catalog',
        _libraryIsbns(query, cancellation),
      );
    }
    if (rows.isEmpty && sourceFailed) {
      throw const BookSearchException(503, '书目来源暂不可用。');
    }
    if (!sourceFailed) {
      if (_metadataCache.length >= 64)
        _metadataCache.remove(_metadataCache.keys.first);
      _metadataCache[cacheKey] = (DateTime.now(), rows);
    }
    return rows;
  }

  /// OPAC records supply the original-script title and ISBN. Verify the ISBN
  /// against a second, edition-specific catalog before publishing any row.
  Future<List<BookSearchCandidate>> _libraryIsbns(
    BookSearchQuery query,
    BookSearchCancellation cancellation,
  ) async {
    final web = webService!(() => _checkActive(cancellation));
    unawaited(cancellation.whenCancelled.then((_) => web.close()));
    try {
      final sources = await web
          .searchLibraryRecords(query.title, acceptUri: _isLibraryRecordUri)
          .timeout(const Duration(seconds: 9));
      final leads = <String, Uri>{};
      for (final source in sources) {
        final uri = Uri.parse(source['url'] as String);
        final summary =
            '${source['summary'] ?? ''}\n${source['snippet'] ?? ''}';
        final titles = <String>[
          ...RegExp(
            r'(?:书目详细信息|题名责任者项|题名/责任者)\s*[:：]\s*(?:[|\-]\s*)?([^/\r\n|]+)',
          ).allMatches(summary).map((m) => m.group(1)!),
          '${source['title'] ?? ''}'.replaceFirst(RegExp(r'_图书馆$'), ''),
        ];
        if (!titles.any((t) => _sameCatalogTitle(t, query.title))) continue;
        final numbers = RegExp(r'(?<!\d)97[89](?:[ \-–－]?\d){10}(?!\d)')
            .allMatches(summary)
            .map((m) => m.group(0)!.replaceAll(RegExp('[^0-9]'), ''))
            .where((isbn) {
              var sum = 0;
              for (var i = 0; i < isbn.length; i++) {
                sum += (isbn.codeUnitAt(i) - 48) * (i.isEven ? 1 : 3);
              }
              return sum % 10 == 0;
            })
            .toSet();
        if (numbers.length == 1) leads.putIfAbsent(numbers.single, () => uri);
        if (leads.length == 3) break;
      }
      var failed = false;
      (String, BookSearchCandidate)? related;
      final verified = await Future.wait(
        leads.entries.map((lead) async {
          try {
            final records = await _openLibrary(
              query,
              cancellation,
              lead.key,
              onWork: (work, record) => related ??= (work, record),
            );
            return [
              for (final record in records)
                BookSearchCandidate(
                  id: record.id,
                  title: query.title,
                  author: record.author,
                  language: record.language,
                  edition: record.edition,
                  format: '',
                  publisher: record.publisher,
                  publicationYear: record.publicationYear,
                  isbn: record.isbn,
                  sourceName: '图书馆书目 · Open Library 核验',
                  sourceUri: lead.value,
                  availability: record.availability,
                ),
            ];
          } on BookSearchException catch (error) {
            _checkActive(cancellation);
            _report(
              cancellation,
              'open_library',
              'verify_catalog_entry',
              'failed',
              error: error,
            );
            failed = true;
            return <BookSearchCandidate>[];
          }
        }),
      );
      final books = {
        for (final row in verified.expand((records) => records)) row.id: row,
      };
      if (failed && books.isEmpty)
        throw const BookSearchException(503, '书目核验来源暂不可用。');
      final match = related;
      if (match != null) {
        try {
          final page = await _catalogJson(
            Uri.https('openlibrary.org', '${match.$1}/editions.json', {
              'limit': '8',
            }),
            cancellation,
          ).timeout(const Duration(seconds: 4));
          final editions = page['entries'];
          if (editions is List) {
            for (final edition in editions.whereType<Map>()) {
              final works = edition['works'];
              final languages = edition['languages'];
              final key = _metadataText(edition['key']);
              if (works is! List ||
                  !works.whereType<Map>().any((w) => w['key'] == match.$1) ||
                  languages is! List ||
                  !languages.whereType<Map>().any(
                    (l) =>
                        _catalogLanguage('${l['key']}'.split('/').last) ==
                        match.$2.language,
                  ) ||
                  key == null ||
                  !RegExp(r'^/books/OL\d+M$').hasMatch(key) ||
                  !_sameCatalogTitle('${edition['title']}', match.$2.title))
                continue;
              final isbn = _catalogStrings(edition['isbn_13']).firstOrNull;
              if (isbn == null || books.values.any((row) => row.isbn == isbn))
                continue;
              final date = _metadataText(edition['publish_date']);
              final publisher = _catalogStrings(
                edition['publishers'],
              ).firstOrNull;
              final version = [
                ..._catalogStrings(
                  edition['edition_name'],
                ).map(_displayEdition),
                ?publisher,
                ?date,
              ].join(' · ');
              if (!_matchesCatalogFilters(query, match.$2.language, version))
                continue;
              final id = key.split('/').last;
              books[id] = BookSearchCandidate(
                id: id,
                title: query.title,
                author: match.$2.author,
                language: match.$2.language,
                edition: version,
                format: '',
                isbn: isbn,
                publisher: publisher,
                publicationYear: date == null
                    ? null
                    : RegExp(r'\b\d{4}\b').firstMatch(date)?.group(0),
                sourceName: 'Open Library 书目',
                sourceUri: Uri.https('openlibrary.org', key),
                availability: match.$2.availability,
              );
            }
          }
        } on Exception catch (error) {
          _checkActive(cancellation); // The verified edition remains usable.
          _report(
            cancellation,
            'open_library',
            'enrich_catalog_entry',
            'failed',
            error: error,
          );
        }
      }
      return books.values.toList();
    } finally {
      web.close();
    }
  }

  static bool _isLibraryRecordUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      (uri.host.endsWith('.edu.cn') ||
          uri.host.endsWith('.gov.cn') ||
          uri.host == 'tscx.open.ha.cn') &&
      RegExp(r'/opac/(?:book/[^/]+|item\.php)$').hasMatch(uri.path);

  Future<List<BookSearchCandidate>> _openLibrary(
    BookSearchQuery query,
    BookSearchCancellation cancellation,
    String isbn, {
    void Function(String key, BookSearchCandidate edition)? onWork,
  }) async {
    final authorQuery = query.author.trim().replaceFirst(
      _metadataAuthorPrefix,
      '',
    );
    final uri = Uri.https('openlibrary.org', '/search.json', {
      if (isbn.isNotEmpty)
        'q': 'isbn:$isbn'
      else ...{
        if (query.title.isNotEmpty) 'title': query.title,
        if (authorQuery.isNotEmpty) 'author': authorQuery,
        if (query.topic.isNotEmpty) 'subject': query.topic,
      },
      'limit': '8',
      'lang': _catalogLanguage(query.language) == '英文' ? 'en' : 'zh',
      'fields':
          'key,title,author_name,editions,editions.key,editions.title,'
          'editions.language,editions.publisher,editions.publish_date,editions.isbn,editions.edition_name',
    });
    final docs = (await _catalogJson(uri, cancellation))['docs'];
    if (docs is! List) {
      throw const _CatalogFailure(FormatException(), '书目响应格式无效。');
    }
    final rows = <BookSearchCandidate>[];
    for (final work in docs.whereType<Map>().take(8)) {
      final editions = work['editions'];
      if (editions is! Map || editions['docs'] is! List) continue;
      final names = _catalogStrings(work['author_name']);
      final author = _matchMetadataAuthor(
        names,
        authorQuery.isEmpty ? null : authorQuery,
      );
      if (author == null && authorQuery.isNotEmpty) continue;
      for (final edition in (editions['docs'] as List).whereType<Map>().take(
        5,
      )) {
        final key = _metadataText(edition['key']);
        final title = _metadataText(edition['title']);
        if (key == null ||
            !RegExp(r'^/books/OL[0-9]+M$').hasMatch(key) ||
            title == null)
          continue;
        final isbns = _catalogStrings(edition['isbn']);
        if (isbn.isNotEmpty
            ? !isbns.contains(isbn)
            : query.title.isNotEmpty && !_sameCatalogTitle(title, query.title))
          continue;
        final language = _catalogLanguage(
          _catalogStrings(edition['language']).firstOrNull ?? '',
        );
        final publisher = _catalogStrings(edition['publisher']).firstOrNull;
        final date = _catalogStrings(edition['publish_date']).firstOrNull;
        final version = [
          ..._catalogStrings(edition['edition_name']).map(_displayEdition),
          ?publisher,
          ?date,
        ].join(' · ');
        if (!_matchesCatalogFilters(query, language, version)) continue;
        rows.add(
          BookSearchCandidate(
            id: key.substring('/books/'.length),
            title: title,
            author: author ?? '',
            language: language,
            edition: version,
            publisher: publisher,
            publicationYear: date == null
                ? null
                : RegExp(r'\b\d{4}\b').firstMatch(date)?.group(0),
            isbn: isbn.isNotEmpty ? isbn : isbns.firstOrNull,
            format: '',
            sourceName: 'Open Library 书目',
            sourceUri: Uri.https(uri.host, key),
            availability: '仅书目 · 暂无可验证整本',
          ),
        );
        final workKey = _metadataText(work['key']);
        if (workKey != null && RegExp(r'^/works/OL\d+W$').hasMatch(workKey)) {
          onWork?.call(workKey, rows.last);
        }
      }
    }
    return rows;
  }

  /// Use the catalog's own original-script title. Match exact ISBN when given
  /// and check the edition link against any record already found by ISBN.
  Future<List<BookSearchCandidate>> _archiveTitleEditions(
    BookSearchQuery query,
    BookSearchCancellation cancellation, {
    List<BookSearchCandidate> exactEditions = const [],
  }) async {
    final isbn = query.isbn;
    final titleQuery = query.title
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"');
    final filter = isbn.isEmpty
        ? 'title-alt-script:"$titleQuery"'
        : 'isbn:"$isbn"';
    final uri = Uri.https('archive.org', '/advancedsearch.php', {
      'q': 'mediatype:texts AND collection:internetarchivebooks AND $filter',
      'fl[]': [
        'identifier',
        'title-alt-script',
        'openlibrary_edition',
        'creator',
        'publisher',
        'publisher-alt-script',
        'isbn',
        'language',
        'year',
        'edition',
      ],
      'rows': '5',
      'output': 'json',
    });
    final response = (await _catalogJson(uri, cancellation))['response'];
    if (response is! Map || response['docs'] is! List) {
      throw const _CatalogFailure(FormatException(), '原文题名目录响应格式无效。');
    }
    final rows = <BookSearchCandidate>[];
    final knownEditions = {for (final row in exactEditions) row.id};
    final entries = (response['docs'] as List).whereType<Map>().take(5).where((
      entry,
    ) {
      if (isbn.isEmpty) return true;
      final values = _catalogStrings(entry['isbn']);
      final linkedIds = _catalogStrings(entry['openlibrary_edition']);
      return values.contains(isbn) &&
          (knownEditions.isEmpty || linkedIds.any(knownEditions.contains));
    }).toList();
    final details = await _linkedEditions(entries, cancellation);
    for (final record in entries) {
      final id = _metadataText(record['identifier']);
      if (id == null ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$').hasMatch(id))
        continue;
      final title = _catalogStrings(record['title-alt-script']).where((name) {
        if (isbn.isEmpty || _hasHanTitle(query.title)) {
          return _sameCatalogTitle(name, query.title);
        }
        return _hasHanTitle(name.split(RegExp(r'[:：=]')).first);
      }).firstOrNull;
      if (title == null) continue;
      final authors = _catalogStrings(record['creator']).map((name) {
        final parts = name.split(', ');
        return parts.length == 2 ? '${parts[1]} ${parts[0]}' : name;
      }).toList();
      if (query.author.isNotEmpty &&
          !authors.any(
            (author) =>
                _normalizedAuthor(author) == _normalizedAuthor(query.author),
          ))
        continue;
      final language = _catalogLanguage(
        _catalogStrings(record['language']).firstOrNull ?? '',
      );
      final publisher =
          _catalogStrings(record['publisher-alt-script']).firstOrNull ??
          _catalogStrings(record['publisher']).firstOrNull;
      final date = record['year']?.toString();
      final year = date != null && RegExp(r'^\d{4}$').hasMatch(date)
          ? date
          : null;
      final isbns = _catalogStrings(record['isbn']);
      final linkedId = _catalogStrings(
        record['openlibrary_edition'],
      ).firstOrNull;
      final linked = details['OLID:$linkedId'];
      final detail = linked is Map ? linked['details'] : null;
      final sameEdition =
          detail is Map &&
          detail['key'] == '/books/$linkedId' &&
          [
            ..._catalogStrings(detail['isbn_13']),
            ..._catalogStrings(detail['isbn_10']),
          ].any(isbns.contains);
      final version = [
        ...{
          ..._catalogStrings(record['edition']).map(_displayEdition),
          if (sameEdition)
            ..._catalogStrings(detail['edition_name']).map(_displayEdition),
        },
        ?publisher,
        ?year,
      ].join(' · ');
      if (!_matchesCatalogFilters(query, language, version)) continue;
      rows.add(
        BookSearchCandidate(
          id: 'ia-$id',
          title: title.split(RegExp(r'\s*[:：=]\s*')).first,
          author: authors.join('、'),
          language: language,
          edition: version,
          format: '',
          publisher: publisher,
          publicationYear: year,
          isbn: isbn.isNotEmpty
              ? isbn
              : isbns
                    .where(
                      (n) =>
                          RegExp(r'^(?:97[89]\d{10}|\d{9}[\dX])$').hasMatch(n),
                    )
                    .firstOrNull,
          sourceName: 'Internet Archive 馆藏书目',
          sourceUri: Uri.https(uri.host, '/details/$id'),
          availability: '仅书目 · 暂无可验证整本',
        ),
      );
    }
    return rows;
  }

  Future<Map> _linkedEditions(
    List<Map> entries,
    BookSearchCancellation cancel,
  ) async {
    final ids = {
      for (final row in entries)
        for (final id in _catalogStrings(row['openlibrary_edition']))
          if (RegExp(r'^OL[0-9]+M$').hasMatch(id)) 'OLID:$id',
    };
    if (ids.isEmpty) return const {};
    try {
      return await _catalogJson(
        Uri.https('openlibrary.org', '/api/books', {
          'bibkeys': ids.join(','),
          'jscmd': 'details',
          'format': 'json',
        }),
        cancel,
      );
    } on BookSearchException catch (error) {
      _checkActive(cancel);
      _report(
        cancel,
        'open_library',
        'enrich_catalog_entry',
        'failed',
        error: error,
      );
      // The source library can still identify a particular printing by ISBN and year.
      return const {};
    }
  }

  Future<void> _reserveOpenLibraryRequest(
    BookSearchCancellation cancellation,
  ) async {
    // Reserve a request slot before yielding so concurrent searches respect the
    // provider-wide anonymous limit. Pending lookups stop with their dialog.
    final now = DateTime.now();
    final next = _lastMetadataRequest?.add(const Duration(seconds: 1));
    if (next != null && now.isBefore(next)) {
      final delay = next.difference(now);
      if (delay > const Duration(seconds: 4)) {
        throw const BookSearchException(503, '书目来源繁忙，请稍后再试。');
      }
      _lastMetadataRequest = next;
      await Future.any([
        Future<void>.delayed(delay),
        cancellation.whenCancelled,
      ]);
      _checkActive(cancellation);
    } else {
      _lastMetadataRequest = now;
    }
  }

  Future<Map> _catalogJson(Uri uri, BookSearchCancellation cancellation) async {
    if (uri.host == 'openlibrary.org')
      await _reserveOpenLibraryRequest(cancellation);
    _checkActive(cancellation);
    final client = _client(cancellation)..autoUncompress = true;
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'XiaoqiBookSearch/1.0',
        );
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok)
          throw _UpstreamHttpFailure(response.statusCode);
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          _checkActive(cancellation);
          if (bytes.length + chunk.length > 256 * 1024)
            throw const FormatException();
          bytes.add(chunk);
        }
        final data = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (data is! Map) throw const FormatException();
        return data;
      })().timeout(_probeTimeout);
    } on Exception catch (error) {
      _checkActive(cancellation);
      throw _CatalogFailure(error);
    } finally {
      client.close(force: true);
    }
  }

  static String? _metadataText(Object? value) =>
      value is String && value.trim().isNotEmpty && value.length <= 300
      ? value.trim()
      : null;

  static List<String> _catalogStrings(Object? value) => [
    for (final item in value is List ? value : [value])
      if (_metadataText(item) case final text?) text,
  ];

  static bool _sameCatalogTitle(String a, String b) {
    final wanted = _normalized(b);
    if (wanted.isEmpty) return false;
    return _normalized(a) == wanted ||
        _normalized(a.split(RegExp(r'[:：=]')).first) == wanted;
  }

  static bool _hasHanTitle(String title) =>
      RegExp(r'[\u3400-\u9fff]').hasMatch(title);

  static String _catalogLanguage(String value) => switch (value.toLowerCase()) {
    'chi' ||
    'zho' ||
    'zh' ||
    'zh-cn' ||
    'zh-hans' ||
    'zh-hant' ||
    '中文' ||
    '简体中文' ||
    '繁体中文' ||
    '繁體中文' => '中文',
    'eng' || 'en' || 'english' || '英文' || '英语' => '英文',
    _ => value,
  };

  static String _displayEdition(String name) {
    final transliterated = RegExp(
      r'^di\s+(\d+)\s+ban[.]?$',
      caseSensitive: false,
    ).firstMatch(name);
    if (transliterated != null) return '第${transliterated.group(1)}版';
    return name.replaceAllMapped(
      RegExp(r'第\s*([一二三四五六七八九])\s*版'),
      (match) => '第${'一二三四五六七八九'.indexOf(match.group(1)!) + 1}版',
    );
  }

  static bool _matchesCatalogFilters(
    BookSearchQuery query,
    String language,
    String edition,
  ) =>
      (query.language.isEmpty ||
          _catalogLanguage(query.language) == language) &&
      (query.edition.isEmpty ||
          edition.toLowerCase().contains(
            _displayEdition(query.edition).toLowerCase(),
          ));

  static String _normalizedAuthor(String author) => author
      .replaceFirst(_metadataAuthorPrefix, '')
      .toLowerCase()
      .replaceAll(_authorSeparators, '');

  static String? _matchMetadataAuthor(List<String> names, String? requested) {
    // Work-level contributors may be translators for a different edition.
    final distinct = {for (final name in names) _normalizedAuthor(name): name};
    if (distinct.length != 1) return null;
    if (requested == null) return names.first;
    return distinct.containsKey(_normalizedAuthor(requested))
        ? names.first
        : null;
  }

  Future<List<Map>> _searchWebBooks(
    BookSearchQuery query,
    BookSearchCancellation cancellation,
  ) async {
    final service = webService!(() => _checkActive(cancellation));
    unawaited(cancellation.whenCancelled.then((_) => service.close()));
    try {
      final result = await service
          .search(
            String.fromCharCodes(
              [
                query.title,
                query.author,
                query.translator,
                query.edition,
                query.language,
                query.format,
              ].where((value) => value.isNotEmpty).join(' ').runes.take(128),
            ),
            purpose: '查询电子书的准确书名和作者官方发布页',
            limit: 8,
          )
          .timeout(_probeTimeout);
      final sources = result['sources'];
      return sources is List ? sources.whereType<Map>().toList() : const [];
    } on BookSearchException {
      rethrow;
    } on Exception catch (error) {
      _checkActive(cancellation);
      throw _CatalogFailure(error, '来源暂不可用。');
    } finally {
      service.close();
    }
  }

  static List<BookSearchCandidate> _webSourceLeads(
    BookSearchQuery query,
    List<Map> sources,
  ) {
    final title = _normalized(query.title);
    final leads = <Uri, BookSearchCandidate>{};
    for (final row in sources) {
      final headline = row['title'];
      final url = row['url'];
      if (headline is! String || url is! String) continue;
      final uri = Uri.tryParse(url)?.removeFragment();
      if (uri == null || !BookSearchWebPage.isPublicPage(uri)) continue;
      final format = BookSearchWebPage.fileFormat(uri);
      if (format != null && query.format.isNotEmpty && format != query.format) {
        continue;
      }
      if (format == null &&
          (uri.hasQuery ||
              RegExp(
                r'\.(?!html?$|aspx?$|php$)[a-z0-9]{2,6}$',
                caseSensitive: false,
              ).hasMatch(uri.path))) {
        continue;
      }
      // Search snippets help prioritize leads. Metadata and permission still
      // come from the linked publication record, never from the snippet.
      final summary = row['summary'];
      if (!_normalized(headline).contains(title) &&
          !(format != null &&
              summary is String &&
              _normalized(summary).contains(title))) {
        continue;
      }
      leads.putIfAbsent(
        uri,
        () => BookSearchCandidate(
          id: 'web-${sha256.convert(utf8.encode(uri.toString()))}',
          title: query.title,
          author: '',
          edition: '',
          language: '',
          format: '',
          sourceName: uri.host,
          sourceUri: uri,
          availability: '网页线索 · 来源和版本待核，暂无可导入文件',
        ),
      );
      if (leads.length == 4) break;
    }
    return leads.values.toList();
  }

  Future<Uint8List> buildEpub(
    BookSearchCandidate candidate,
    BookSearchCancellation cancellation,
  ) async {
    _checkActive(cancellation);
    final client = _client(cancellation)..autoUncompress = true;
    try {
      final bytes = await WikisourceBooks.build(client, candidate);
      _checkActive(cancellation);
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Future<Uri> verify(
    BookSearchCandidate candidate,
    BookSearchCancellation cancellation,
  ) async {
    final uri = candidate.downloadUri;
    if (uri == null || !_permitsDownload(candidate)) {
      throw const BookSearchException(409, '该版本暂无可导入文件。');
    }
    _checkActive(cancellation);
    final client = _client(cancellation);
    try {
      await _probe(
        client,
        uri,
        candidate.format,
        cancellation,
        readDownloadPage: BookSearchWebPage.isDiscovered(candidate),
        wrappedEpub: _isWrappedEpub(candidate, uri),
      ).timeout(_probeTimeout);
      return uri;
    } on Exception catch (error) {
      _checkActive(cancellation);
      _report(
        cancellation,
        _fileSource(candidate),
        'probe',
        'failed',
        error: error,
      );
      throw const BookSearchException(503, '该来源的文件暂时无法验证。');
    } finally {
      client.close(force: true);
    }
  }

  static bool _permitsDownload(BookSearchCandidate candidate) =>
      BookSearchWebPage.permitsDownload(candidate) ||
      ThothBooks.permitsDownload(candidate) ||
      GutenbergBooks.permitsDownload(candidate) ||
      _catalog.any(
        (source) => source.candidates.any(
          (edition) =>
              edition.id == candidate.id &&
              edition.format == candidate.format &&
              edition.downloadUri == candidate.downloadUri,
        ),
      );

  static bool _isWrappedEpub(BookSearchCandidate candidate, Uri uri) =>
      BookSearchWebPage.isDiscovered(candidate) &&
      candidate.format == 'epub' &&
      BookSearchWebPage.isWrappedEpub(uri);

  Future<File> acquire(
    BookSearchCandidate candidate,
    BookSearchCancellation cancellation,
  ) async {
    Directory? directory;
    var stage = 'prepare_file';
    try {
      directory = await Directory.systemTemp.createTemp(
        'xiaoqi-book-search-verified-',
      );
      final file = File('${directory.path}/book.${candidate.format}');
      if (candidate.inlineEpub) {
        stage = 'build_epub';
        if (!candidate.id.startsWith('wikisource-zh-') ||
            candidate.format != 'epub') {
          throw const BookSearchException(409, '该版本暂无可导入文件。');
        }
        final bytes = await buildEpub(candidate, cancellation);
        if (bytes.length > 4 * 1024 * 1024) {
          throw const BookSearchException(422, '整书超出在线排版的大小限制。');
        }
        await file.writeAsBytes(bytes, flush: true);
      } else {
        stage = 'download';
        final uri = candidate.downloadUri;
        if (uri == null || !_permitsDownload(candidate)) {
          throw const BookSearchException(409, '该版本暂无可导入文件。');
        }
        final wrapped = _isWrappedEpub(candidate, uri);
        final download = wrapped ? File('${file.path}.zip') : file;
        final client = _client(cancellation);
        try {
          await _downloadVerified(
            client,
            uri,
            candidate.format,
            download,
            cancellation,
            readDownloadPage: BookSearchWebPage.isDiscovered(candidate),
            wrappedEpub: wrapped,
          ).timeout(const Duration(seconds: 90));
        } finally {
          client.close(force: true);
        }
        if (wrapped) {
          stage = 'extract_epub';
          await _extractWrappedEpub(download, file, cancellation);
          await download.delete();
        }
      }
      stage = 'validate_file';
      await _validateCompleteFile(file, candidate, cancellation);
      _report(cancellation, _fileSource(candidate), stage, 'verified');
      return file;
    } on Object catch (error) {
      _report(
        cancellation,
        _fileSource(candidate),
        stage,
        'failed',
        error: error,
      );
      final temp = directory;
      if (temp != null) {
        await temp.delete(recursive: true).catchError((_) => temp);
      }
      rethrow;
    }
  }

  static bool _isHtml(HttpClientResponse response) =>
      switch (response.headers.contentType?.mimeType) {
        'text/html' || 'application/xhtml+xml' => true,
        _ => false,
      };

  static Future<Uri?> _downloadContinuation(
    HttpClientResponse response,
    Uri uri,
    BookSearchCancellation cancellation,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_probeTimeout)) {
      _checkActive(cancellation);
      if (bytes.length + chunk.length > 32 * 1024) return null;
      bytes.add(chunk);
    }
    return BookSearchWebPage.downloadRefresh(bytes.takeBytes(), uri);
  }

  HttpClient _client(BookSearchCancellation cancellation) {
    final client =
        _clientFactory?.call() ??
        (HttpClient()
          ..connectionTimeout = _probeTimeout
          ..autoUncompress = false
          ..connectionFactory = (uri, proxyHost, proxyPort) async {
            final addresses = await InternetAddress.lookup(
              uri.host,
            ).timeout(const Duration(seconds: 4));
            _checkActive(cancellation);
            if (addresses.isEmpty ||
                addresses.any(
                  (address) => !WebService.publicAddress(address),
                )) {
              throw const FormatException('书源地址必须解析到公网。');
            }
            // Disconnect in-flight probes immediately and use the validated DNS
            // address for the actual socket. The URI still supplies TLS identity.
            final address = addresses.firstWhere(
              (address) => address.type == InternetAddressType.IPv4,
              orElse: () => addresses.first,
            );
            final task = await Socket.startConnect(address, uri.port);
            Socket? connected;
            var cancelled = false;
            return ConnectionTask.fromSocket(
              task.socket.then((socket) async {
                connected = socket;
                final secure = await SecureSocket.secure(
                  socket,
                  host: uri.host,
                );
                if (cancelled || cancellation.isCancelled) {
                  secure.destroy();
                  throw const SocketException('书源连接已停止。');
                }
                return secure;
              }),
              () {
                cancelled = true;
                task.cancel();
                connected?.destroy();
              },
            );
          }
          ..findProxy = (_) => 'DIRECT');
    unawaited(
      cancellation.whenCancelled.then((_) => client.close(force: true)),
    );
    return client;
  }

  static Future<void> _probe(
    HttpClient client,
    Uri start,
    String format,
    BookSearchCancellation cancellation, {
    bool readDownloadPage = false,
    bool wrappedEpub = false,
  }) async {
    var uri = start;
    for (var hop = 0; hop < 3; hop++) {
      _checkActive(cancellation);
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        unawaited(response.listen((_) {}).cancel());
        if (location == null) throw const FormatException('书源跳转地址缺失。');
        final next = uri.resolve(location);
        if (!_releaseRedirect(start, next)) {
          throw const FormatException('书源跳转不在允许范围。');
        }
        uri = next;
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw _UpstreamHttpFailure(response.statusCode);
      }
      if (readDownloadPage && _isHtml(response)) {
        final next = await _downloadContinuation(response, uri, cancellation);
        if (next == null) throw const FormatException('下载入口没有返回书籍文件。');
        uri = next;
        continue;
      }
      final contentLength = response.contentLength;
      if (contentLength <= 128 || contentLength > _fileLimit) {
        throw const _FileReadFailure('invalid_file_length', '书源文件大小无效。');
      }
      final prefix = BytesBuilder(copy: false);
      await for (final chunk in response) {
        _checkActive(cancellation);
        prefix.add(chunk.take(128 - prefix.length).toList());
        if (prefix.length >= 128) break;
      }
      if (!_matchesFormat(
        prefix.takeBytes(),
        format,
        wrappedEpub: wrappedEpub,
      )) {
        throw const _FileReadFailure('file_format_mismatch', '书源文件格式不匹配。');
      }
      return;
    }
    throw const FormatException('书源跳转超出限制。');
  }

  static Future<void> _downloadVerified(
    HttpClient client,
    Uri start,
    String format,
    File target,
    BookSearchCancellation cancellation, {
    bool readDownloadPage = false,
    bool wrappedEpub = false,
  }) async {
    var uri = start;
    for (var hop = 0; hop < 3; hop++) {
      _checkActive(cancellation);
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen((_) {}).cancel();
        if (location == null) throw const FormatException('书源跳转地址缺失。');
        final next = uri.resolve(location);
        if (!_releaseRedirect(start, next)) {
          throw const FormatException('书源跳转不在允许范围。');
        }
        uri = next;
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw _UpstreamHttpFailure(response.statusCode);
      }
      if (readDownloadPage && _isHtml(response)) {
        final next = await _downloadContinuation(response, uri, cancellation);
        if (next == null) throw const FormatException('下载入口没有返回书籍文件。');
        uri = next;
        continue;
      }
      if (response.contentLength <= 128 ||
          response.contentLength > _fileLimit) {
        throw const _FileReadFailure('invalid_file_length', '书源未返回可核验的完整文件。');
      }
      final sink = target.openWrite();
      final prefix = BytesBuilder(copy: false);
      final tail = BytesBuilder(copy: false);
      var length = 0;
      try {
        await for (final chunk in response.timeout(_probeTimeout)) {
          _checkActive(cancellation);
          length += chunk.length;
          if (length > _fileLimit) {
            throw const _FileReadFailure('file_size_limit', '书源文件超过大小限制。');
          }
          if (prefix.length < 128) {
            prefix.add(chunk.take(128 - prefix.length).toList());
          }
          tail.add(chunk);
          if (tail.length > 4096) {
            final bytes = tail.takeBytes();
            tail.add(bytes.sublist(bytes.length - 2048));
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (length != response.contentLength) {
        throw const _FileReadFailure('incomplete_file', '下载文件长度校验失败。');
      }
      if (!_matchesFormat(
        prefix.takeBytes(),
        format,
        wrappedEpub: wrappedEpub,
      )) {
        throw const _FileReadFailure('file_format_mismatch', '下载文件格式校验失败。');
      }
      if (format == 'pdf' &&
          !ascii
              .decode(tail.takeBytes(), allowInvalid: true)
              .contains('%%EOF')) {
        throw const _FileReadFailure(
          'incomplete_file',
          'PDF 文件缺少结束标记，可能未下载完整。',
        );
      }
      return;
    }
    throw const FormatException('书源跳转超出限制。');
  }

  static Future<void> _extractWrappedEpub(
    File download,
    File target,
    BookSearchCancellation cancellation,
  ) async {
    _checkActive(cancellation);
    final input = InputFileStream(download.path);
    const invalid = _FileReadFailure(
      'invalid_wrapped_epub',
      '压缩包须包含一个完整的 EPUB 文件。',
    );
    try {
      // Read the directory without ZipDecoder eagerly decoding symlink entries.
      final directory = ZipDirectory()..read(input);
      final books = directory.fileHeaders.where((header) {
        final parts = header.filename.replaceAll('\\', '/').split('/');
        return !parts.contains('__MACOSX') &&
            !parts.last.startsWith('._') &&
            parts.last.toLowerCase().endsWith('.epub');
      }).toList();
      if (books.length != 1 ||
          directory.totalCentralDirectoryEntries !=
              directory.fileHeaders.length ||
          directory.numberOfThisDisk != 0 ||
          directory.diskWithTheStartOfTheCentralDirectory != 0) {
        throw invalid;
      }
      final header = books.single;
      final entry = header.file!;
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      if (header.filename != entry.filename ||
          (type != 0 && type != 0x8000) ||
          ((header.generalPurposeBitFlag | entry.flags) & 1) != 0 ||
          header.diskNumberStart != 0 ||
          header.uncompressedSize <= 128 ||
          header.uncompressedSize > _fileLimit ||
          header.compressedSize <= 0 ||
          header.compressedSize > _fileLimit ||
          (header.compressionMethod != ZipFile.zipCompressionStore &&
              header.compressionMethod != ZipFile.zipCompressionDeflate)) {
        throw invalid;
      }
      final raw = entry.getStream(decompress: false);
      if (raw.length != header.compressedSize) throw invalid;

      Stream<List<int>> chunks() async* {
        while (!raw.isEOS) {
          _checkActive(cancellation);
          yield raw.readBytes(min(raw.length, 64 * 1024)).toUint8List();
        }
      }

      final contents = header.compressionMethod == ZipFile.zipCompressionStore
          ? chunks()
          : io.ZLibDecoder(raw: true).bind(chunks());
      final output = await target.open(mode: FileMode.writeOnly);
      var length = 0;
      var crc = 0;
      try {
        await for (final chunk in contents) {
          _checkActive(cancellation);
          length += chunk.length;
          if (length > header.uncompressedSize) throw invalid;
          crc = getCrc32(chunk, crc);
          await output.writeFrom(chunk);
        }
      } finally {
        await output.close();
      }
      if (length != header.uncompressedSize || crc != header.crc32) {
        throw invalid;
      }
      final prefix = await target
          .openRead(0, 58)
          .expand((chunk) => chunk)
          .toList();
      if (!_matchesFormat(Uint8List.fromList(prefix), 'epub')) throw invalid;
    } on FormatException catch (error) {
      if (error is _FileReadFailure) rethrow;
      throw invalid;
    } finally {
      await input.close();
    }
  }

  static Future<void> _validateCompleteFile(
    File file,
    BookSearchCandidate candidate,
    BookSearchCancellation cancellation,
  ) async {
    _checkActive(cancellation);
    final format = candidate.format;
    final length = await file.length();
    if (length <= 128 || length > _fileLimit) {
      throw const FormatException('完整文件大小无效。');
    }
    if (format == 'pdf') {
      final prefix = await file
          .openRead(0, 8)
          .fold<BytesBuilder>(
            BytesBuilder(copy: false),
            (builder, chunk) => builder..add(chunk),
          );
      if (!_matchesFormat(prefix.takeBytes(), format)) {
        throw const FormatException('PDF 文件头校验失败。');
      }
      return;
    }
    if (format != 'epub') throw const FormatException('不支持的电子书格式。');
    final input = InputFileStream(file.path);
    Archive? archive;
    try {
      archive = ZipDecoder().decodeStream(input);
      final mimetype = archive.find('mimetype');
      if (mimetype?.size != 20 ||
          ascii.decode(mimetype!.content, allowInvalid: true) !=
              'application/epub+zip') {
        throw const _FileReadFailure('incomplete_file', 'EPUB 文件标记无效。');
      }
      final rootfile = _epubXml(
        archive,
        'META-INF/container.xml',
      ).findAllElements('rootfile').firstOrNull?.getAttribute('full-path');
      if (rootfile == null || rootfile.isEmpty) {
        throw const _FileReadFailure('incomplete_file', 'EPUB 缺少书籍目录。');
      }
      final package = _epubXml(archive, rootfile);
      final fromWebPage = BookSearchWebPage.isDiscovered(candidate);
      if (fromWebPage &&
          !BookSearchWebPage.matchesPublication(candidate, package)) {
        throw const _FileReadFailure(
          'edition_mismatch',
          'EPUB 书内题名、作者或语种与书页不匹配。',
        );
      }
      if (candidate.sourceName == GutenbergBooks.sourceName &&
          !GutenbergBooks.matchesPublication(candidate, package)) {
        throw const _FileReadFailure(
          'edition_mismatch',
          '古登堡 EPUB 的馆藏编号、书名或语言与书目不匹配。',
        );
      }
      final items = {
        for (final item in package.findAllElements('item'))
          item.getAttribute('id'): item.getAttribute('href'),
      };
      final chapters = package.findAllElements('itemref').toList();
      if (chapters.isEmpty) {
        throw const _FileReadFailure('incomplete_file', 'EPUB 缺少正文阅读顺序。');
      }
      final base = Uri(path: '/$rootfile');
      var hasBookText = false;
      for (final chapter in chapters) {
        _checkActive(cancellation);
        final href = Uri.tryParse(items[chapter.getAttribute('idref')] ?? '');
        if (href == null ||
            href.hasScheme ||
            href.hasAuthority ||
            href.hasAbsolutePath ||
            href.path.isEmpty) {
          throw const _FileReadFailure('incomplete_file', 'EPUB 正文章节缺失。');
        }
        final path = Uri.decodeComponent(
          base.resolveUri(href).path.substring(1),
        );
        final entry = archive.find(path);
        if (entry == null || entry.size <= 0) {
          throw const _FileReadFailure('incomplete_file', 'EPUB 正文章节缺失。');
        }
        if (fromWebPage &&
            !hasBookText &&
            entry.size <= 2 * 1024 * 1024 &&
            RegExp(r'\.(?:xhtml|html)$', caseSensitive: false).hasMatch(path)) {
          hasBookText = BookSearchWebPage.hasReadableText(entry.content);
        }
      }
      if (fromWebPage && !hasBookText) {
        throw const _FileReadFailure('incomplete_file', 'EPUB 缺少可核验的正文。');
      }
    } finally {
      try {
        await archive?.clear();
      } finally {
        await input.close();
      }
    }
  }

  static XmlDocument _epubXml(Archive archive, String path) {
    final entry = archive.find(path);
    if (entry == null || !entry.isFile || entry.size > 4 * 1024 * 1024) {
      throw const _FileReadFailure('incomplete_file', 'EPUB 目录结构不完整。');
    }
    return XmlDocument.parse(utf8.decode(entry.content));
  }

  static bool _releaseRedirect(Uri start, Uri next) {
    if (start.host != 'github.com' ||
        next.scheme != 'https' ||
        next.userInfo.isNotEmpty ||
        next.port != 443 ||
        next.host != 'release-assets.githubusercontent.com') {
      return false;
    }
    final id = start.path.startsWith('/krahets/hello-algo/')
        ? '561730219'
        : '26017730';
    return next.path.startsWith('/github-production-release-asset/$id/');
  }

  static bool _matchesFormat(
    Uint8List bytes,
    String format, {
    bool wrappedEpub = false,
  }) {
    if (format == 'pdf') {
      return bytes.length >= 5 &&
          ascii.decode(bytes.sublist(0, 5), allowInvalid: true) == '%PDF-';
    }
    if (wrappedEpub) {
      return bytes.length >= 4 &&
          ByteData.sublistView(bytes).getUint32(0, Endian.little) ==
              ZipFile.zipSignature;
    }
    if (format != 'epub' || bytes.length < 58) return false;
    final header = ByteData.sublistView(bytes);
    return header.getUint32(0, Endian.little) == 0x04034b50 &&
        header.getUint16(8, Endian.little) == 0 &&
        header.getUint16(26, Endian.little) == 8 &&
        header.getUint16(28, Endian.little) == 0 &&
        ascii.decode(bytes.sublist(30, 58), allowInvalid: true) ==
            'mimetypeapplication/epub+zip';
  }

  static String _normalized(String text) =>
      text.toLowerCase().replaceAll(_wordPattern, '');

  static void _checkActive(BookSearchCancellation cancellation) {
    if (cancellation.isCancelled) {
      throw const BookSearchException(409, '找书已停止。');
    }
  }
}

class _BookSource {
  const _BookSource({
    required this.aliases,
    required this.discoveryHosts,
    required this.candidates,
    this.discoveryRepository,
    this.revision,
  });

  final List<String> aliases;
  final Set<String> discoveryHosts;
  final String? discoveryRepository;
  final String? revision;
  final List<BookSearchCandidate> candidates;

  bool recognizes(String normalized) => aliases.any(normalized.contains);

  bool matchesPartial(String normalized) =>
      normalized.length >= 3 &&
      aliases.any((alias) => alias.contains(normalized));

  bool isOfficialPage(Uri uri) {
    if (uri.scheme != 'https' || uri.port != 443 || uri.userInfo.isNotEmpty) {
      return false;
    }
    if (discoveryHosts.contains(uri.host)) return true;
    final slug = discoveryRepository;
    if (uri.host != 'github.com' || slug == null) return false;
    final repository = '/$slug';
    return uri.path == repository || uri.path.startsWith('$repository/');
  }

  Iterable<BookSearchCandidate> select(BookSearchQuery query) {
    final lower = query.displayText.toLowerCase();
    final version = BookSearchSources._versionPattern
        .firstMatch(lower)
        ?.group(0);
    final publishedRevision = revision;
    if (version != null &&
        (publishedRevision == null ||
            (version != publishedRevision &&
                !publishedRevision.startsWith('$version.')))) {
      return const [];
    }
    if (RegExp(r'纸质版|紙質版|纸质书|紙質書').hasMatch(lower)) {
      return const [];
    }
    final edition = BookSearchSources._releaseQualifier
        .allMatches(lower)
        .map((match) => match.group(0)!)
        .firstWhere(
          (qualifier) => !BookSearchSources._versionPattern.hasMatch(qualifier),
          orElse: () => '',
        );
    final editionFilter = BookSearchQuery(edition: edition);
    final format = query.format.toLowerCase();
    final language = RegExp(r'繁[体體]|演算法|zh-hant').hasMatch(lower)
        ? '繁體中文'
        : query.language.isNotEmpty &&
              BookSearchSources._catalogLanguage(query.language) != '中文'
        ? BookSearchSources._catalogLanguage(query.language)
        : candidates.first.language;
    final explicitlyChinese =
        query.language.isNotEmpty &&
        BookSearchSources._catalogLanguage(query.language) == '中文';
    final variantSet = candidates
        .where((candidate) => candidate.title.contains(' · '))
        .map(
          (candidate) =>
              candidate.title.split(' · ').last.split(' ').first.toLowerCase(),
        )
        .toSet();
    final variants = variantSet.where((variant) {
      return RegExp(
        '(?<![a-z0-9])${RegExp.escape(variant)}(?![a-z0-9+#])',
      ).hasMatch(lower);
    }).toSet();
    // An unrecognized edition must not silently fall back to the default.
    var editionQualifier = query.edition.toLowerCase().replaceAll(
      BookSearchSources._releaseQualifier,
      '',
    );
    for (final variant in variants) {
      editionQualifier = editionQualifier.replaceAll(variant, '');
    }
    if (editionQualifier
        .replaceAll(RegExp(r'版本|示例|电子版|電子版|版|[\s·,，]+'), '')
        .isNotEmpty)
      return [];
    if (variants.isEmpty && discoveryRepository == 'krahets/hello-algo') {
      variants.addAll(['python', 'java']);
    }
    return candidates.where(
      (candidate) =>
          candidate.language == language &&
          (!explicitlyChinese ||
              BookSearchSources._catalogLanguage(candidate.language) == '中文') &&
          editionFilter.acceptsFile(
            title: candidate.title,
            edition: candidate.edition,
            format: candidate.format,
            language: candidate.language,
          ) &&
          (format.isEmpty || candidate.format == format) &&
          (variants.isEmpty ||
              variants.any(
                (variant) =>
                    candidate.title.toLowerCase().endsWith('· $variant 版'),
              )),
    );
  }
}
