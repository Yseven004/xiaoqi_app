import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'book_search_service.dart';
import 'web_service.dart';

/// Search and file verification for publisher-approved editions. Generic web
/// results are discovery hints. File links always come from this catalog.
class BookSearchSources {
  BookSearchSources({this.webService, HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory;

  final WebService Function(void Function() checkCancelled)? webService;
  final HttpClient Function()? _clientFactory;
  final _metadataCache = <Uri, (DateTime, List<BookSearchCandidate>)>{};
  DateTime? _lastMetadataRequest;

  static const _fileLimit = 256 * 1024 * 1024;
  static const _probeTimeout = Duration(seconds: 9);
  static final _versionPattern = RegExp(r'\b\d+\.\d+(?:\.\d+)?\b');
  static final _isbnPattern = RegExp(
    r'(?:^|\D)((?:97[89][\s-]*)?\d(?:[\s-]*\d){8}[\s-]*[\dXx])(?:$|\D)',
  );
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
  ) async* {
    _checkActive(cancellation);
    final isbn = _isbnPattern
        .firstMatch(query)
        ?.group(1)
        ?.replaceAll(RegExp(r'[\s-]'), '');
    if (isbn != null) {
      // These publisher files have no ebook ISBN. Never borrow a print ISBN.
      yield* Stream.fromIterable(
        await _metadata(query, cancellation, isbn: isbn),
      );
      return;
    }

    final term = _normalized(query);
    var matches = _catalog.where((source) => source.recognizes(term)).toList();
    if (matches.isEmpty && term.length >= 2 && webService != null) {
      try {
        matches = await _discover(query, cancellation);
      } on BookSearchException {
        _checkActive(cancellation);
        // The library catalog can still return exact edition information.
      }
    }
    _checkActive(cancellation);
    if (matches.isEmpty && term.isNotEmpty) {
      yield* Stream.fromIterable(await _metadata(query, cancellation));
      return;
    }

    final candidates = matches.expand((source) => source.select(query)).take(8);
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

  Future<List<BookSearchCandidate>> _metadata(
    String query,
    BookSearchCancellation cancellation, {
    String? isbn,
  }) async {
    final title = query.trim().replaceAll(RegExp(r'^[《〈「『]|[》〉」』]$'), '');
    final uri = Uri.https('openlibrary.org', '/search.json', {
      if (isbn != null) 'q': 'isbn:$isbn' else 'title': title,
      'limit': '5',
      'lang': 'zh',
      'fields':
          'key,title,author_name,editions,editions.key,editions.title,'
          'editions.language,editions.publisher,editions.publish_date,editions.isbn',
    });
    final cached = _metadataCache[uri];
    final now = DateTime.now();
    if (cached != null &&
        now.difference(cached.$1) < const Duration(minutes: 15)) {
      return cached.$2;
    }
    final last = _lastMetadataRequest;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      throw const BookSearchException(503, '书目来源繁忙，请稍后再试。');
    }
    _lastMetadataRequest = now;

    final client = _client(cancellation);
    try {
      final docs = await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw const FormatException('书目目录不可用。');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          _checkActive(cancellation);
          if (bytes.length + chunk.length > 256 * 1024) {
            throw const FormatException('书目超出长度限制。');
          }
          bytes.add(chunk);
        }
        final data = jsonDecode(utf8.decode(bytes.takeBytes()));
        return data is Map ? data['docs'] : null;
      })().timeout(_probeTimeout);
      _checkActive(cancellation);
      if (docs is! List) {
        throw const FormatException('书目格式无效。');
      }
      final rows = <BookSearchCandidate>[];
      for (final work in docs.take(5).whereType<Map>()) {
        final authorNames = work['author_name'];
        final editionsBlock = work['editions'];
        if (authorNames is! List ||
            authorNames.length != 1 ||
            editionsBlock is! Map ||
            editionsBlock['docs'] is! List) {
          // Work-level contributors can contain translators from other editions.
          continue;
        }
        final author = _metadataText(authorNames.single);
        for (final edition
            in (editionsBlock['docs'] as List).take(2).whereType<Map>()) {
          final key = _metadataText(edition['key']);
          final editionTitle = _metadataText(edition['title']);
          final date = _firstMetadataText(edition['publish_date']);
          final editionIsbns = edition['isbn'];
          final publisher = _firstMetadataText(edition['publisher']);
          if (key == null ||
              !RegExp(r'^/books/OL[0-9]+M$').hasMatch(key) ||
              editionTitle == null ||
              author == null ||
              (isbn == null
                  ? _normalized(editionTitle) != _normalized(title)
                  : editionIsbns is! List || !editionIsbns.contains(isbn))) {
            continue;
          }
          rows.add(
            BookSearchCandidate(
              id: key.substring('/books/'.length),
              title: editionTitle,
              author: author,
              language: switch (_firstMetadataText(edition['language'])) {
                'chi' || 'zho' || 'zh' => '中文',
                'eng' || 'en' => '英文',
                _ => '',
              },
              edition: [
                if (publisher != null) publisher,
                if (date != null) date,
              ].join(' · '),
              format: '',
              sourceName: 'Open Library 书目',
              sourceUri: Uri.https(uri.host, key),
              availability: '仅书目 · 暂无可验证整本',
              publicationYear: RegExp(
                r'\b\d{4}\b',
              ).firstMatch(date ?? '')?.group(0),
              isbn: isbn ?? _firstMetadataText(editionIsbns),
            ),
          );
        }
      }
      if (_metadataCache.length >= 64) {
        _metadataCache.remove(_metadataCache.keys.first);
      }
      _metadataCache[uri] = (now, rows);
      return rows;
    } on Exception {
      _checkActive(cancellation);
      throw const BookSearchException(503, '书目来源暂不可用。');
    } finally {
      client.close(force: true);
    }
  }

  static String? _metadataText(Object? value) =>
      value is String && value.trim().isNotEmpty && value.length <= 180
      ? value.trim()
      : null;

  static String? _firstMetadataText(Object? value) =>
      value is List && value.isNotEmpty ? _metadataText(value.first) : null;

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

  Iterable<BookSearchCandidate> select(String query) {
    final lower = query.toLowerCase();
    final version = BookSearchSources._versionPattern
        .firstMatch(query)
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
    final format = lower.contains('epub') && !lower.contains('pdf')
        ? 'epub'
        : lower.contains('pdf') && !lower.contains('epub')
        ? 'pdf'
        : null;
    final language = RegExp(r'繁[体體]|演算法|zh-hant').hasMatch(lower)
        ? '繁體中文'
        : RegExp(r'英[文语語]|english').hasMatch(lower)
        ? '英文'
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
    if (variants.isEmpty && discoveryRepository == 'krahets/hello-algo') {
      variants.addAll(['python', 'java']);
    }
    return candidates.where(
      (candidate) =>
          candidate.language == language &&
          (format == null || candidate.format == format) &&
          (variants.isEmpty ||
              variants.any(
                (variant) =>
                    candidate.title.toLowerCase().endsWith('· $variant 版'),
              )),
    );
  }
}
