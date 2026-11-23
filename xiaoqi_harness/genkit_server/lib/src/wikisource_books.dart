import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import 'book_search_query.dart';
import 'book_search_service.dart';

/// An upstream status kept separate from the public book-search error.
class WikisourceHttpFailure extends BookSearchException {
  const WikisourceHttpFailure(this.upstreamStatus, {required this.retryable})
    : super(503, '维基文库暂不可用。');

  final int upstreamStatus;
  final bool retryable;
}

class WikisourceContentFailure extends BookSearchException {
  const WikisourceContentFailure(super.statusCode, super.message, this.reason);

  final String reason;
}

/// Imports public-domain collections from the published MediaWiki directory.
class WikisourceBooks {
  static const _host = 'zh.wikisource.org';
  static const _exportHost = 'ws-export.wmcloud.org';
  static const _exportEdition = '维基文库官方导出版';
  static const _compiledEdition = '小栖整理版（维基文库）';
  static const _ua =
      'XiaoqiBookSearch/1.0 (https://github.com/Yseven004; Chinese ebook import)';
  static final _pageProperty = RegExp(
    r'消歧|待刪|待删|未完成|未完結|節選|节选|摘錄|摘录|侵權|侵权|殘篇|残篇',
  );
  static final _link = RegExp(r'\[\[([^\]|\n]+)(?:\|([^\]\n]+))?\]\]');
  // The named dynasty templates are the site's explicit public-domain notices.
  // A dynasty mentioned in the title, category or notes is not such a notice.
  static final _publicDomainTemplate = RegExp(
    r'^\s*\{\{\s*(?:先秦|元朝|明朝|清朝)作品\s*\}\}\s*$',
    multiLine: true,
  );
  static final _publicDomainCategory = RegExp(
    r'^Category:PD(?:-|$)',
    caseSensitive: false,
  );
  static final _numberedChapter = RegExp(r'/第(\d+)回$');
  static String _withoutComments(String source) =>
      source.replaceAll(RegExp(r'<!--[\s\S]*?(?:-->|$)'), '');

  static bool _title(String value) =>
      value.trim().isNotEmpty &&
      value.length <= 180 &&
      !RegExp(r'[\x00-\x1f\x7f:/\\|#?<>{}\[\]]').hasMatch(value) &&
      value != '.' &&
      value != '..';
  static bool supports(BookSearchQuery query) =>
      _title(query.title) &&
      query.isbn.isEmpty &&
      query.edition.isEmpty &&
      (query.format.isEmpty || query.format == 'epub') &&
      (query.language.isEmpty ||
          const {
            'zh',
            '中文',
            '中文版',
            'chinese',
          }.contains(query.language.toLowerCase()));
  static Uri _source(String title) =>
      Uri.https(_host, '/wiki/${title.replaceAll(' ', '_')}');
  static bool owns(BookSearchCandidate book) =>
      book.inlineEpub &&
      book.downloadUri == null &&
      book.format == 'epub' &&
      _title(book.title) &&
      book.sourceUri == _source(book.title) &&
      RegExp(
        r'^wikisource-zh-(?:export-)?\d+-\d+-[a-f0-9]{24}$',
      ).hasMatch(book.id) &&
      (book.id.startsWith('wikisource-zh-export-')
          ? book.edition == _exportEdition
          : book.edition == _compiledEdition);

  static Future<Map> _api(
    HttpClient client,
    Map<String, String> parameters,
  ) async {
    final uri = Uri.https(_host, '/w/api.php', {
      'format': 'json',
      'formatversion': '2',
      ...parameters,
    });
    // GETs for specific revisions are idempotent. A flaky connection may be
    // retried once. Refusals, rate limits and server-directed waits are final.
    try {
      return await _read(client, uri);
    } on Exception catch (error) {
      if (error is! TimeoutException &&
          error is! SocketException &&
          error is! HttpException &&
          !(error is WikisourceHttpFailure && error.retryable)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      return _read(client, uri);
    }
  }

  static Future<Map> _read(HttpClient client, Uri uri) async {
    HttpClientRequest? request;
    var expired = false;
    return (() async {
      final req = await client.getUrl(uri);
      request = req;
      if (expired) {
        req.abort();
        throw TimeoutException('维基文库读取超时。');
      }
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      final response = await req.close();
      const limit = 4 * 1024 * 1024;
      if (response.statusCode != 200) {
        final status = response.statusCode;
        final retryAfter = response.headers.value(HttpHeaders.retryAfterHeader);
        await response.listen((_) {}).cancel();
        throw WikisourceHttpFailure(
          status,
          retryable:
              const {502, 503, 504}.contains(status) && retryAfter == null,
        );
      }
      if (response.contentLength > limit) {
        await response.listen((_) {}).cancel();
        throw const FormatException('维基文库响应过大。');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (expired) throw TimeoutException('维基文库读取超时。');
        if (bytes.length + chunk.length > limit)
          throw const FormatException('维基文库响应过大。');
        bytes.add(chunk);
      }
      final result = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (result is! Map || result['error'] != null)
        throw const FormatException('维基文库返回错误。');
      return result;
    })().timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        expired = true;
        request?.abort();
        throw TimeoutException('维基文库读取超时。');
      },
    );
  }

  static Future<Map> _pages(HttpClient client, Iterable<String> titles) async {
    final result = await _api(client, {
      'action': 'query',
      'titles': titles.join('|'),
      'redirects': '1',
      'converttitles': '1',
      'prop': 'revisions|categories|pageprops',
      'rvprop': 'ids|content',
      'rvslots': 'main',
      'cllimit': 'max',
    });
    if (result['query']?['pages'] is! List)
      throw const FormatException('维基文库缺少作品修订。');
    return result['query'] as Map;
  }

  static Iterable<String> _categories(Map page) =>
      (page['categories'] as List? ?? []).whereType<Map>().map(
        (item) => item['title'].toString(),
      );

  static bool _eligible(Map page) =>
      !(page['pageprops'] is Map &&
          (page['pageprops'] as Map).containsKey('disambiguation')) &&
      !_categories(page).any(
        (title) => title == 'Category:25%' || _pageProperty.hasMatch(title),
      );

  static bool _licensed(Map page, String source) =>
      _categories(page).any(_publicDomainCategory.hasMatch) ||
      _publicDomainTemplate.hasMatch(source);

  static bool _subpage(String title, String page) => page.startsWith('$title/');

  static Map? _revision(Map? page) =>
      (page?['revisions'] as List?)?.whereType<Map>().firstOrNull;

  static Future<BookSearchCandidate?> find(
    HttpClient client,
    BookSearchQuery criteria, {
    void Function(String reason)? onRejected,
  }) async => (await _work(client, criteria, onRejected: onRejected))?.book;

  static Future<_Work?> _work(
    HttpClient client,
    BookSearchQuery criteria, {
    void Function(String reason)? onRejected,
  }) async {
    _Work? reject(String reason) {
      onRejected?.call(reason);
      return null;
    }

    if (!supports(criteria)) return reject('unsupported_query');
    final result = await _pages(client, [
      criteria.title,
      if (_title(criteria.author)) 'Author:${criteria.author}',
    ]);
    final pages = (result['pages'] as List).whereType<Map>();
    final root = pages
        .where((p) => p['ns'] == 0 && p['missing'] != true)
        .firstOrNull;
    if (root == null) return reject('title_not_found');
    final rev = _revision(root);
    final raw = rev?['slots']?['main']?['content'];
    final title = root['title'];
    if (raw is! String ||
        title is! String ||
        !_title(title) ||
        root['pageid'] is! int ||
        rev?['revid'] is! int)
      return reject('missing_work_revision');
    final text = _withoutComments(raw);
    if (!_eligible(root)) return reject('work_not_eligible');
    if (!_licensed(root, text)) return reject('work_license_missing');
    final header = RegExp(
      r'\{\{\s*(?:(?:collection[ _]+)?header|標題|标题)\s*\|([\s\S]*?)\}\}',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    if (header == null) return reject('unsupported_work_header');
    String authorField(String names) =>
        RegExp(
          '\\|\\s*(?:$names)[ \\t]*=[ \\t]*'
          r'((?:\[\[[^\]\n]+\]\]|[^\n}|\[])+)',
          caseSensitive: false,
        ).firstMatch('|$header')?.group(1)?.trim() ??
        '';
    final plainAuthor = authorField('author|作者');
    final authorRaw = plainAuthor.isEmpty
        ? authorField('override_author')
        : plainAuthor;
    final author =
        html
            .parseFragment(
              authorRaw.replaceAllMapped(
                RegExp(
                  r'\[\[(?:Author:|作者:)?([^\]|]+)(?:\|([^\]]+))?\]\]',
                  caseSensitive: false,
                ),
                (m) => m[2] ?? m[1]!,
              ),
            )
            .text
            ?.trim() ??
        '';
    final authorNames = {
      author,
      for (final m in _link.allMatches(authorRaw))
        if (RegExp(r'^(?:author|作者):', caseSensitive: false).hasMatch(m[1]!))
          m[1]!.split(':').last.trim(),
    };
    if (criteria.author.isNotEmpty && criteria.author != author) {
      final canonical = pages
          .where((p) => p['ns'] == 102 && p['missing'] != true)
          .firstOrNull?['title'];
      if (!authorNames.contains(criteria.author)) {
        if (canonical is! String) return reject('author_mismatch');
        if (!authorNames.contains(canonical.split(':').last)) {
          // Both the requested name and a credited name must resolve to the
          // same Wikisource author page, for example a pen name and a real name.
          final creditedAuthorTitles = [
            for (final name in authorNames)
              if (_title(name)) 'Author:$name',
          ];
          if (creditedAuthorTitles.isEmpty) return reject('author_mismatch');
          final authorPages = await _pages(client, creditedAuthorTitles);
          if (!(authorPages['pages'] as List).whereType<Map>().any(
            (page) =>
                page['ns'] == 102 &&
                page['missing'] != true &&
                page['title'] == canonical,
          )) {
            return reject('author_mismatch');
          }
        }
      }
    }
    var dir = RegExp(
      r'''<div\b[^>]*class=["'][^"']*\bws-summary\b[^"']*["'][^>]*>([\s\S]*?)</div>''',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    if (dir == null) {
      final head = RegExp(
        r'^==+[ \t]*(?:目錄|目录|目次)[ \t]*==+[ \t]*$',
        multiLine: true,
      ).firstMatch(text);
      if (head != null)
        dir = text
            .substring(head.end)
            .split(RegExp(r'^==|\{\{[Pp][Dd]', multiLine: true))
            .first;
    }
    if (dir == null) {
      // Some directories publish a list or table of immediate subpages without
      // a directory heading. Use the ordered list entries, not arbitrary links
      // in the header, notes, related editions, or the navigation footer.
      final children =
          RegExp(
            r'^\s*[:*#]+[ \t]*(\[\[[^\]\n]+\]\])',
            multiLine: true,
          ).allMatches(text).map((match) => match[1]!).where((entry) {
            final target = _link.firstMatch(entry)?[1]?.split('#').first.trim();
            if (target == null) return false;
            final normalized = target.replaceAll('_', ' ');
            if (!normalized.startsWith('/') && !_subpage(title, normalized)) {
              return false;
            }
            return !RegExp(r'/(?:全覽|全览|全文|全本|全篇)$').hasMatch(normalized);
          }).toList();
      if (children.length >= 2) dir = children.join('\n');
    }
    final rootAliases = <String>{title, criteria.title};
    for (final key in ['normalized', 'converted', 'redirects']) {
      for (final pair in (result[key] as List? ?? []).whereType<Map>()) {
        if (pair['from'] is String &&
            pair['to'] is String &&
            pair['tofragment'] == null &&
            (rootAliases.contains(pair['from']) ||
                rootAliases.contains(pair['to']))) {
          rootAliases.add(pair['from'] as String);
          rootAliases.add(pair['to'] as String);
        }
      }
    }
    final links = <({String page, String anchor, String label})>[];
    // A standalone transcribed work can have a verified run of scanned pages
    // and no table of contents. Its own title identifies its only spine item.
    if (dir == null) {
      if (!RegExp(
            r'<pages\b[^>]+\bindex\s*=',
            caseSensitive: false,
          ).hasMatch(text) ||
          RegExp(r'目錄|目录|目次|消歧|節選|节选|摘錄|摘录').hasMatch(text))
        return reject('unsupported_directory_layout');
      links.add((page: title, anchor: '', label: title));
    }
    for (final l in _link.allMatches(dir ?? '')) {
      final parts = l[1]!.trim().split('#');
      if (parts.length > 2) return reject('invalid_directory_link');
      var page = parts.first.replaceAll('_', ' ').trim();
      final anchor = parts.length == 2 ? parts.last.trim() : '';
      if (RegExp(
        r'^:?(?:category|分類|分类|file|image|檔案|文件):',
        caseSensitive: false,
      ).hasMatch(page)) {
        continue;
      }
      if (page.startsWith('/')) page = '$title$page';
      if (page.isEmpty || rootAliases.contains(page)) page = title;
      if (!page.split('/').every(_title) ||
          (anchor.isNotEmpty && !_title(anchor)))
        return reject('invalid_directory_link');
      if (page == title && anchor.isEmpty)
        return reject('invalid_directory_link');
      links.add((
        page: page,
        anchor: anchor,
        label:
            l[2]?.trim() ?? (anchor.isNotEmpty ? anchor : page.split('/').last),
      ));
    }
    if (links.isEmpty) return reject('empty_directory');
    if (links.length > 250) return reject('directory_limit');
    var chapterNumber = 0;
    for (final link in links) {
      final match = _numberedChapter.firstMatch(link.page);
      if (match != null && int.parse(match[1]!) != ++chapterNumber) {
        return reject('incomplete_chapter_sequence');
      }
    }
    final external = links
        .map((l) => l.page)
        .where((p) => p != title)
        .toSet()
        .toList();
    final byName = <String, Map>{title: root};
    final aliases = <String, String>{};
    for (var i = 0; i < external.length; i += 30) {
      final batch = await _pages(client, external.skip(i).take(30));
      for (final key in ['normalized', 'converted', 'redirects']) {
        for (final pair in (batch[key] as List? ?? []).whereType<Map>()) {
          if (pair['from'] is String &&
              pair['to'] is String &&
              pair['tofragment'] == null) {
            aliases[pair['from']] = pair['to'];
          }
        }
      }
      for (final p in (batch['pages'] as List).whereType<Map>()) {
        if (p['ns'] == 0 && p['missing'] != true && p['title'] is String)
          byName[p['title']] = p;
      }
    }
    final chapters = <_Chapter>[];
    final chapterIdentities = <(int, String)>{};
    for (final link in links) {
      var key = link.page;
      for (var i = 0; i < 5 && aliases.containsKey(key); i++) {
        key = aliases[key]!;
      }
      final page = byName[key];
      final chapterRev = _revision(page);
      final original = chapterRev?['slots']?['main']?['content'];
      if (page == null || original is! String || chapterRev?['revid'] is! int)
        return reject('missing_chapter_revision');
      final chapterSource = _withoutComments(original);
      // The root's license covers its own chapters when the directory and the
      // canonical chapter are both within the same work. Separate works still
      // need an explicit notice of their own.
      final ownChapter = _subpage(title, link.page);
      if (ownChapter && !_subpage(title, key)) {
        return reject('chapter_redirected_to_another_work');
      }
      if (!_eligible(page) ||
          (key != title && !ownChapter && !_licensed(page, chapterSource))) {
        return reject('chapter_not_eligible');
      }
      // A linked directory, redlink, or chapter stub cannot stand in for a leaf.
      if (key != title &&
          RegExp(
            r'ws-summary|^\s*==+\s*(目錄|目录|目次)\s*==+',
            multiLine: true,
          ).hasMatch(chapterSource))
        return reject('nested_directory');
      if (link.anchor.isNotEmpty &&
          !RegExp(
            r'^=+[ \t]*' + RegExp.escape(link.anchor) + r'[ \t]*=+[ \t]*$',
            multiLine: true,
          ).hasMatch(chapterSource))
        return reject('missing_chapter_anchor');
      final chapterRevision = chapterRev!['revid'] as int;
      if (!chapterIdentities.add((chapterRevision, link.anchor))) {
        return reject('duplicate_chapter');
      }
      chapters.add(_Chapter(key, link.anchor, link.label, chapterRevision));
    }
    final revisionId = rev!['revid'] as int;
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              for (final c in chapters) [c.page, c.anchor, c.revision],
            ]),
          ),
        )
        .toString()
        .substring(0, 24);
    final year = RegExp(
      r'\|\s*(?:year|年|y|times)\s*=\s*([0-9]{4})(?:年|\s|$)',
    ).firstMatch('|$header')?.group(1);
    final republic = int.tryParse(
      RegExp(r'\|\s*民\s*=\s*([0-9]{1,3})\b').firstMatch('|$header')?.group(1) ??
          '',
    );
    final source = _source(title);
    // A cold 40-page work otherwise requires at least 40 serialized parse calls.
    // WS Export is a different edition: its HTML is not pinned to our revisions.
    final useOfficialExport =
        chapters.length >= 40 &&
        chapters.every((chapter) => chapter.anchor.isEmpty);
    return _Work(
      BookSearchCandidate(
        id: 'wikisource-zh-${useOfficialExport ? 'export-' : ''}${root['pageid']}-$revisionId-$fingerprint',
        title: title,
        author: author,
        language: '中文',
        edition: useOfficialExport ? _exportEdition : _compiledEdition,
        format: 'epub',
        sourceName: useOfficialExport ? '中文维基文库 · 官方导出' : '中文维基文库',
        sourceUri: source,
        inlineEpub: true,
        license: '公有领域作品 · 维基文库标注',
        licenseUri: source,
        publicationYear:
            year ?? (republic == null ? null : '${1911 + republic}'),
      ),
      chapters,
    );
  }

  static Future<Uint8List> build(
    HttpClient client,
    BookSearchCandidate book,
  ) async {
    if (!owns(book)) throw const BookSearchException(409, '该条目不支持在线排版。');
    final work = await _work(client, BookSearchQuery(title: book.title));
    if (work == null || work.book.id != book.id)
      throw const WikisourceContentFailure(
        409,
        '作品或章节修订已更新，请重新查找。',
        'work_revision_changed',
      );
    if (book.id.startsWith('wikisource-zh-export-')) {
      return _officialExport(client, work);
    }
    final documents = <String>[];
    var total = 0;
    String? previousChapterHtml;
    int? previousRevision;
    for (final c in work.chapters) {
      if (c.revision != previousRevision) {
        final result = await _api(client, {
          'action': 'parse',
          'oldid': '${c.revision}',
          'prop': 'text|revid',
          'disableeditsection': '1',
        });
        final parsed = result['parse'];
        if (parsed is! Map ||
            parsed['revid'] != c.revision ||
            parsed['title'] != c.page ||
            parsed['text'] is! String) {
          throw const WikisourceContentFailure(
            409,
            '目录与正文修订不一致。',
            'chapter_revision_mismatch',
          );
        }
        previousRevision = c.revision;
        previousChapterHtml = parsed['text'] as String;
      }
      final body = _chapterBody(previousChapterHtml!, c);
      if (body == null) {
        throw WikisourceContentFailure(
          422,
          '${c.label} 缺少可核实的正文。',
          'missing_chapter_text',
        );
      }
      total += utf8.encode(body).length;
      if (total > 16 * 1024 * 1024)
        throw const BookSearchException(422, '整书超出在线排版的大小限制。');
      final permanent = Uri.https(_host, '/w/index.php', {
        'oldid': '${c.revision}',
      }).replace(fragment: c.anchor.isEmpty ? null : c.anchor);
      documents.add(
        _xhtml(
          c.label,
          '<h1>${_esc(c.label)}</h1>$body<footer><p><a href="${_esc(permanent.toString())}">源文修订 · ${c.revision}</a></p></footer>',
        ),
      );
    }
    return _epub(work, documents);
  }

  static Future<Uint8List> _officialExport(
    HttpClient client,
    _Work work,
  ) async {
    HttpClientRequest? request;
    var expired = false;
    final bytes =
        await (() async {
          final req = await client.getUrl(
            Uri.https(_exportHost, '/', {
              'lang': 'zh',
              'page': work.book.title,
              'format': 'epub',
            }),
          );
          request = req;
          if (expired) {
            req.abort();
            throw TimeoutException('维基文库整本导出超时。');
          }
          req.followRedirects = false;
          req.headers.set(HttpHeaders.userAgentHeader, _ua);
          req.headers.set(HttpHeaders.acceptHeader, 'application/epub+zip');
          final response = await req.close();
          if (response.statusCode != 200) {
            await response.listen((_) {}).cancel();
            throw WikisourceHttpFailure(response.statusCode, retryable: false);
          }
          const limit = 4 * 1024 * 1024;
          if (response.contentLength > limit ||
              response.headers.contentType?.mimeType !=
                  'application/epub+zip') {
            await response.listen((_) {}).cancel();
            throw const WikisourceContentFailure(
              422,
              '官方导出未返回完整 EPUB。',
              'invalid_export_response',
            );
          }
          final buffer = BytesBuilder(copy: false);
          await for (final chunk in response) {
            if (expired) throw TimeoutException('维基文库整本导出超时。');
            if (buffer.length + chunk.length > limit) {
              throw const WikisourceContentFailure(
                422,
                '官方导出文件超出大小限制。',
                'export_size_limit',
              );
            }
            buffer.add(chunk);
          }
          if (response.contentLength >= 0 &&
              buffer.length != response.contentLength) {
            throw const WikisourceContentFailure(
              422,
              '官方导出文件传输不完整。',
              'export_truncated',
            );
          }
          return buffer.takeBytes();
        })().timeout(
          const Duration(seconds: 35),
          onTimeout: () {
            expired = true;
            request?.abort();
            throw TimeoutException('维基文库整本导出超时。');
          },
        );
    return _verifyOfficialExport(bytes, work);
  }

  static Uint8List _verifyOfficialExport(Uint8List bytes, _Work work) {
    Never reject(String reason) => throw WikisourceContentFailure(
      422,
      '官方导出的目录或正文与该书不一致，未通过整本核验。',
      reason,
    );
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    try {
      if (archive.files.length > 1024) reject('export_entry_limit');
      var expanded = 0;
      final names = <String>{};
      for (final entry in archive.files) {
        if (!names.add(entry.name) ||
            entry.name.startsWith('/') ||
            entry.name.contains('\\') ||
            entry.name.split('/').contains('..') ||
            entry.size > 4 * 1024 * 1024)
          reject('invalid_export_entry');
        expanded += entry.size;
        if (expanded > 16 * 1024 * 1024) reject('export_expansion_limit');
      }
      String read(String path) {
        final file = archive.findFile(path);
        if (file == null || !file.isFile || file.size <= 0)
          reject('missing_export_file');
        return utf8.decode(file.content);
      }

      String resolve(String base, String href) {
        final relative = Uri.tryParse(href);
        if (relative == null ||
            relative.hasScheme ||
            relative.hasAuthority ||
            relative.hasAbsolutePath ||
            relative.path.isEmpty ||
            relative.hasQuery) {
          reject('invalid_export_reference');
        }
        final path = Uri.decodeComponent(
          Uri(path: '/$base').resolveUri(relative).path.substring(1),
        );
        if (!names.contains(path)) reject('missing_export_file');
        return path;
      }

      if (read('mimetype') != 'application/epub+zip')
        reject('invalid_export_mimetype');
      final container = XmlDocument.parse(read('META-INF/container.xml'));
      final opfPath = container
          .findAllElements('rootfile')
          .single
          .getAttribute('full-path');
      if (opfPath == null || !names.contains(opfPath))
        reject('invalid_export_container');
      final package = XmlDocument.parse(read(opfPath));
      final metadata = package.findAllElements('metadata').single;
      final title = metadata
          .findAllElements('title', namespaceUri: '*')
          .single
          .innerText;
      final source = metadata
          .findAllElements('source', namespaceUri: '*')
          .single
          .innerText;
      if (title != work.book.title ||
          Uri.tryParse(source) != work.book.sourceUri) {
        reject('export_identity_mismatch');
      }
      final creators = metadata
          .findAllElements('creator', namespaceUri: '*')
          .toList();
      if (creators.isNotEmpty &&
          !creators.any((node) => node.innerText.trim() == work.book.author)) {
        reject('export_author_mismatch');
      }
      final items = <String, String>{};
      for (final item
          in package.findAllElements('manifest').single.findElements('item')) {
        final id = item.getAttribute('id');
        final href = item.getAttribute('href');
        if (id == null || href == null || items.containsKey(id))
          reject('invalid_export_manifest');
        items[id] = resolve(opfPath, href);
      }
      final spine = <String>[];
      for (final item
          in package.findAllElements('spine').single.findElements('itemref')) {
        final path = items[item.getAttribute('idref')];
        if (path == null || spine.contains(path))
          reject('invalid_export_spine');
        spine.add(path);
      }
      final documents = <String, dom.Document>{};
      for (final path in spine) {
        final doc = html.parse(read(path));
        if (doc.querySelector('script,iframe,object,embed,form') != null ||
            doc
                .querySelectorAll('*')
                .any(
                  (node) => node.attributes.keys.any(
                    (key) => key.toString().toLowerCase().startsWith('on'),
                  ),
                )) {
          reject('unsafe_export_markup');
        }
        documents[path] = doc;
      }
      final roots = documents.entries
          .where(
            (entry) =>
                entry.key != items['title'] &&
                entry.value.querySelector('title')?.text == work.book.title,
          )
          .toList();
      if (roots.length != 1) reject('export_directory_missing');
      final root = roots.single;
      final selected = <String>[];
      var lastPosition = -1;
      for (final chapter in work.chapters) {
        final links = root.value
            .querySelectorAll('a[title][href]')
            .where(
              (node) =>
                  node.attributes['title']?.replaceAll('_', ' ') ==
                  chapter.page,
            );
        final paths = links
            .map((node) => resolve(root.key, node.attributes['href']!))
            .toSet();
        if (paths.length != 1) reject('export_chapter_mapping_missing');
        final path = paths.single;
        final position = spine.indexOf(path);
        if (position <= lastPosition || selected.contains(path))
          reject('export_chapter_order_mismatch');
        final body = documents[path]?.body;
        if (body == null ||
            _chapterBody(
                  '<div class="mw-parser-output">${body.innerHtml}</div>',
                  chapter,
                ) ==
                null) {
          reject('export_chapter_empty');
        }
        selected.add(path);
        lastPosition = position;
      }
      final expected = {
        ...selected,
        root.key,
        ...['title', 'about', 'nav'].map((id) => items[id]).whereType<String>(),
      };
      if (spine.any((path) => !expected.contains(path)))
        reject('export_unexpected_chapter');
      // Some Wikisource headers omit the exporter-specific author field. Fill
      // only missing metadata from the independently verified directory credit.
      if (creators.isEmpty && work.book.author.isNotEmpty) {
        metadata.children.add(
          XmlElement(XmlName.parts('creator', prefix: 'dc'), [], [
            XmlText(work.book.author),
          ]),
        );
        archive.add(ArchiveFile.string(opfPath, package.toXmlString()));
        archive.findFile('mimetype')!.compression = CompressionType.none;
        return Uint8List.fromList(ZipEncoder().encode(archive));
      }
      return bytes;
    } finally {
      archive.clear();
    }
  }

  static String? _chapterBody(String raw, _Chapter chapter) {
    final root = html.parseFragment(raw).querySelector('.mw-parser-output');
    if (root == null ||
        root.querySelector(
              '.error, .mw-ext-cite-error, .prp-index-pagelist-unknown-page, .redirectMsg',
            ) !=
            null)
      return null;
    for (final n in root.querySelectorAll(
      'script,style,link,.ws-summary,#headerContainer,#headertemplate,.licenseContainer,.licensetpl,.noprint,.ws-noexport,.ws-pagenum,.navbox,.mw-editsection,.printfooter,nav,footer',
    )) {
      n.remove();
    }
    Iterable<dom.Node> content = root.nodes;
    if (chapter.anchor.isNotEmpty) {
      final heading = root
          .querySelectorAll('h1,h2,h3,h4,h5,h6')
          .where(
            (h) => h.id == chapter.anchor || h.text.trim() == chapter.anchor,
          )
          .firstOrNull;
      if (heading == null) return null;
      final wrapper = heading.parent?.classes.contains('mw-heading') == true
          ? heading.parent!
          : heading;
      final rank = int.parse(heading.localName!.substring(1));
      final selected = <dom.Node>[];
      var next = wrapper.nextElementSibling;
      while (next != null) {
        final h = next.classes.contains('mw-heading')
            ? next.children.firstOrNull
            : next;
        final level = h?.localName;
        if (level != null &&
            RegExp(r'^h[1-6]$').hasMatch(level) &&
            int.parse(level.substring(1)) <= rank)
          break;
        selected.add(next);
        next = next.nextElementSibling;
      }
      content = selected;
    }
    // Layout-only markup is flattened. Text never imports scripts, CSS, links,
    // images from external hosts, or executable attributes from source HTML.
    final safe = StringBuffer();
    final prose = StringBuffer();
    const tags = {
      'p',
      'br',
      'ol',
      'ul',
      'li',
      'blockquote',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'ruby',
      'rt',
      'rp',
      'em',
      'strong',
      'i',
      'b',
      'small',
      'sup',
      'sub',
      'table',
      'thead',
      'tbody',
      'tr',
      'td',
      'th',
      'pre',
      'hr',
      'div',
    };
    void emit(dom.Node n) {
      if (n is dom.Text) {
        safe.write(_esc(n.data));
        return;
      }
      if (n is! dom.Element) return;
      final tag = n.localName;
      if (tag == 'p' || tag == 'li' || tag == 'pre') prose.write(n.text.trim());
      if (tag == 'br' || tag == 'hr') {
        safe.write('<$tag/>');
        return;
      }
      if (tags.contains(tag)) safe.write('<$tag>');
      for (final child in n.nodes) {
        emit(child);
      }
      if (tags.contains(tag)) safe.write('</$tag>');
    }

    for (final node in content) {
      emit(node);
    }
    return prose.toString().trim().isEmpty ||
            prose.toString().trim() == chapter.label
        ? null
        : safe.toString();
  }

  static String _esc(String value) => const HtmlEscape().convert(value);
  static String _xhtml(String title, String body) =>
      '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh"><head><title>${_esc(title)}</title></head><body>$body</body></html>';
  static Uint8List _epub(_Work work, List<String> documents) {
    final b = work.book;
    final files = Archive()
      ..add(
        ArchiveFile.string('mimetype', 'application/epub+zip')
          ..compression = CompressionType.none,
      );
    void add(String name, String text) {
      files.add(ArchiveFile.string(name, text));
    }

    add(
      'META-INF/container.xml',
      '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    );
    final manifest = StringBuffer();
    final spine = StringBuffer();
    final toc = StringBuffer();
    for (var i = 0; i < documents.length; i++) {
      add('EPUB/c$i.xhtml', documents[i]);
      manifest.write(
        '<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>',
      );
      spine.write('<itemref idref="c$i"/>');
      toc.write(
        '<li><a href="c$i.xhtml">${_esc(work.chapters[i].label)}</a></li>',
      );
    }
    add(
      'EPUB/nav.xhtml',
      _xhtml('目录', '<nav epub:type="toc"><h1>目录</h1><ol>$toc</ol></nav>'),
    );
    final modified =
        DateTime.now().toUtc().toIso8601String().split('.').first + 'Z';
    final source = _esc(b.sourceUri.toString());
    add(
      'EPUB/book.opf',
      '<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">${_esc(b.id)}</dc:identifier><dc:title>${_esc(b.title)}</dc:title><dc:language>zh</dc:language>${b.author.isEmpty ? '' : '<dc:creator>${_esc(b.author)}</dc:creator>'}<dc:source>$source</dc:source><dc:contributor>中文维基文库贡献者</dc:contributor><dc:publisher>小栖整理版（维基文库）</dc:publisher><dc:rights>原作由中文维基文库标注为公有领域；转录整理依据 CC BY-SA 4.0（https://creativecommons.org/licenses/by-sa/4.0/）。各篇附来源修订。</dc:rights><meta property="dcterms:modified">$modified</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>$manifest</manifest><spine>$spine</spine></package>',
    );
    final bytes = ZipEncoder().encode(files);
    if (bytes.length > 4 * 1024 * 1024)
      throw const BookSearchException(422, '整书超出在线排版的大小限制。');
    return Uint8List.fromList(bytes);
  }
}

class _Chapter {
  const _Chapter(this.page, this.anchor, this.label, this.revision);
  final String page, anchor, label;
  final int revision;
}

class _Work {
  const _Work(this.book, this.chapters);
  final BookSearchCandidate book;
  final List<_Chapter> chapters;
}
