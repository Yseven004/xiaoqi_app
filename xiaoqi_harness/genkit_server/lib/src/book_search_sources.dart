import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'book_search_query.dart';
import 'book_search_service.dart';
import 'web_service.dart';
import 'wikisource_books.dart';

/// Searches trusted publishers, Chinese Wikisource and bibliographic catalogs.
class BookSearchSources {
  BookSearchSources({this.webService, HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory;

  final WebService Function(void Function() checkCancelled)? webService;
  final HttpClient Function()? _clientFactory;
  final _metadataCache = <String, (DateTime, List<BookSearchCandidate>)>{};
  DateTime? _lastMetadataRequest;

  static const _fileLimit = 256 * 1024 * 1024;
  static const _probeTimeout = Duration(seconds: 9);
  static final _versionPattern = RegExp(r'\b\d+\.\d+(?:\.\d+)?\b');
  static final _metadataAuthorPrefix = RegExp(
    r'^[（(【\[]\s*(?:[美英法德日俄中意澳加](?:国)?)\s*[）)】\]]\s*',
  );
  static final _authorSeparators = RegExp(r'[\s\p{P}]', unicode: true);
  static final _wordPattern = RegExp(r'[^a-z0-9\u3400-\u9fff]+');

  static const _helloRelease = '1.3.0';
  static const _proGitRelease = '2.1.80';

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
        matches = await _discover(criteria.title, cancellation);
      } on BookSearchException {
        _checkActive(cancellation);
      }
    }
    if (matches.isEmpty) {
      bool failed = false;
      final providers = [
        _metadata(criteria, cancellation),
        if (WikisourceBooks.supports(criteria))
          _wiki(criteria, cancellation).then((row) => [if (row != null) row]),
      ];
      final results = providers.map((provider) async {
        try {
          return await provider;
        } on Exception {
          failed = true;
          return <BookSearchCandidate>[];
        }
      });
      await for (final rows in Stream.fromFutures(results)) {
        _checkActive(cancellation);
        yield* Stream.fromIterable(rows);
      }
      if (failed) throw const BookSearchException(503, '有些来源暂不可用。');
      return;
    }
    final candidates = matches.expand((s) => s.select(criteria)).take(8);
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
    if (sourceFailed) {
      throw const BookSearchException(503, '有些来源暂不可用。');
    }
  }

  Future<BookSearchCandidate?> _wiki(
    BookSearchQuery query,
    BookSearchCancellation cancellation,
  ) async {
    final client = _client(cancellation)..autoUncompress = true;
    try {
      return await WikisourceBooks.find(client, query);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<BookSearchCandidate>> _metadata(
    BookSearchQuery query,
    BookSearchCancellation cancellation,
  ) async {
    final cacheKey = jsonEncode(query.toJson());
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
      Future<List<BookSearchCandidate>> operation,
    ) async {
      try {
        return await operation;
      } on Exception {
        _checkActive(cancellation);
        sourceFailed = true;
        return [];
      }
    }

    Future<List<BookSearchCandidate>> primary() async {
      final byIsbn = await attempt(_openLibrary(query, cancellation, isbn));
      if (byIsbn.isNotEmpty || isbn.isEmpty || query.isbn.isNotEmpty)
        return byIsbn;
      // The linked print ISBN is a hint, not a restriction on the search.
      return _openLibrary(query, cancellation, '');
    }

    var rows = <BookSearchCandidate>[];
    await for (final hits in Stream.fromFutures([
      attempt(primary()),
      if (nativeTitle) attempt(_archiveTitleEditions(query, cancellation)),
    ])) {
      if (hits.isNotEmpty) {
        rows = hits;
        break;
      }
    }
    if (rows.isEmpty && nativeTitle && webService != null) {
      rows = await attempt(_libraryIsbns(query, cancellation));
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
          } on BookSearchException {
            _checkActive(cancellation);
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
        } on Exception {
          _checkActive(cancellation); // The verified edition remains usable.
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
    if (docs is! List) throw const BookSearchException(503, '书目响应格式无效。');
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

  /// Library records can store Latin transliteration in title and the actual
  /// Chinese title in title-alt-script. Only the latter's exact main title
  /// identifies an edition here. These catalog hits never authorize a download.
  Future<List<BookSearchCandidate>> _archiveTitleEditions(
    BookSearchQuery query,
    BookSearchCancellation cancellation,
  ) async {
    final literal = query.title.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final uri = Uri.https('archive.org', '/advancedsearch.php', {
      'q':
          'mediatype:texts AND collection:internetarchivebooks AND title-alt-script:"$literal"',
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
      throw const BookSearchException(503, '原文题名目录响应格式无效。');
    }
    final rows = <BookSearchCandidate>[];
    final entries = (response['docs'] as List)
        .whereType<Map>()
        .take(5)
        .toList();
    final details = await _linkedEditions(entries, cancellation);
    for (final record in entries) {
      final id = _metadataText(record['identifier']);
      if (id == null ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$').hasMatch(id))
        continue;
      final title = _catalogStrings(
        record['title-alt-script'],
      ).where((name) => _sameCatalogTitle(name, query.title)).firstOrNull;
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
          isbn: isbns
              .where(
                (n) => RegExp(r'^(?:97[89]\d{10}|\d{9}[\dX])$').hasMatch(n),
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
    } on BookSearchException {
      _checkActive(cancel);
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
        if (response.statusCode != HttpStatus.ok) throw const FormatException();
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
    } on Exception {
      _checkActive(cancellation);
      throw const BookSearchException(503, '书目来源暂不可用。');
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

  Future<List<_BookSource>> _discover(
    String query,
    BookSearchCancellation cancellation,
  ) async {
    final service = webService!(() => _checkActive(cancellation));
    unawaited(cancellation.whenCancelled.then((_) => service.close()));
    try {
      final result = await service
          .search(
            String.fromCharCodes(query.runes.take(128)),
            purpose: '查询电子书的准确书名和作者官方发布页',
            limit: 5,
          )
          .timeout(_probeTimeout);
      final sources = result['sources'];
      if (sources is! List) return [];
      return _catalog
          .where(
            (book) => sources.whereType<Map>().any((source) {
              final uri = Uri.tryParse('${source['url'] ?? ''}');
              final title = _normalized('${source['title'] ?? ''}');
              return uri != null &&
                  book.isOfficialPage(uri) &&
                  book.recognizes(title) &&
                  book.matchesPartial(_normalized(query));
            }),
          )
          .toList();
    } on BookSearchException {
      rethrow;
    } on Exception {
      _checkActive(cancellation);
      throw const BookSearchException(503, '来源暂不可用。');
    } finally {
      service.close();
    }
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
    if (uri == null ||
        !_catalog.any(
          (source) => source.candidates.any(
            (edition) =>
                edition.id == candidate.id &&
                edition.format == candidate.format &&
                edition.downloadUri == uri,
          ),
        )) {
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
      ).timeout(_probeTimeout);
      return uri;
    } on Exception {
      _checkActive(cancellation);
      throw const BookSearchException(503, '该来源的文件暂时无法验证。');
    } finally {
      client.close(force: true);
    }
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
    BookSearchCancellation cancellation,
  ) async {
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
        throw const FormatException('书源文件不可用。');
      }
      final contentLength = response.contentLength;
      if (contentLength <= 128 || contentLength > _fileLimit) {
        throw const FormatException('书源文件大小无效。');
      }
      final prefix = BytesBuilder(copy: false);
      await for (final chunk in response) {
        _checkActive(cancellation);
        prefix.add(chunk.take(128 - prefix.length).toList());
        if (prefix.length >= 128) break;
      }
      if (!_matchesFormat(prefix.takeBytes(), format)) {
        throw const FormatException('书源文件格式不匹配。');
      }
      return;
    }
    throw const FormatException('书源跳转超出限制。');
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

  static bool _matchesFormat(Uint8List bytes, String format) {
    if (format == 'pdf') {
      return bytes.length >= 5 &&
          ascii.decode(bytes.sublist(0, 5), allowInvalid: true) == '%PDF-';
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
    required this.discoveryRepository,
    required this.revision,
    required this.candidates,
  });

  final List<String> aliases;
  final Set<String> discoveryHosts;
  final String discoveryRepository;
  final String revision;
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
    if (uri.host != 'github.com') return false;
    final repository = '/$discoveryRepository';
    return uri.path == repository || uri.path.startsWith('$repository/');
  }

  Iterable<BookSearchCandidate> select(BookSearchQuery query) {
    final lower = query.displayText.toLowerCase();
    final version = BookSearchSources._versionPattern
        .firstMatch(lower)
        ?.group(0);
    if (version != null &&
        version != revision &&
        !revision.startsWith('$version.')) {
      return const [];
    }
    if (RegExp(r'纸质版|紙質版|纸质书|紙質書').hasMatch(lower)) {
      return const [];
    }
    final edition = RegExp(
      r'第\s*([一二三四五六七八九\d]+)\s*版',
    ).firstMatch(lower)?.group(1);
    if (edition != null &&
        (edition != '二' && edition != '2' || !revision.startsWith('2.'))) {
      return const [];
    }
    final format = query.format.toLowerCase();
    final language = RegExp(r'繁[体體]|演算法|zh-hant').hasMatch(lower)
        ? '繁體中文'
        : query.language.isNotEmpty &&
              BookSearchSources._catalogLanguage(query.language) != '中文'
        ? BookSearchSources._catalogLanguage(query.language)
        : '简体中文';
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
    var editionQualifier = query.edition
        .toLowerCase()
        .replaceAll(BookSearchSources._versionPattern, '')
        .replaceAll(RegExp(r'第\s*[一二三四五六七八九\d]+\s*版'), '');
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
          (format.isEmpty || candidate.format == format) &&
          (variants.isEmpty ||
              variants.any(
                (variant) =>
                    candidate.title.toLowerCase().endsWith('· $variant 版'),
              )),
    );
  }
}
