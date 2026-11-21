import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'book_search_query.dart';
import 'book_search_service.dart';

/// Imports public-domain collections from the published MediaWiki directory.
class WikisourceBooks {
  static const _host = 'zh.wikisource.org';
  static const _ua =
      'XiaoqiBookSearch/1.0 (https://github.com/Yseven004; Chinese ebook import)';
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
      RegExp(r'^wikisource-zh-\d+-\d+-[a-f0-9]{24}$').hasMatch(book.id);

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
          error is! HttpException)
        rethrow;
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
      if (response.statusCode != 200 || response.contentLength > limit) {
        final status = response.statusCode;
        final retryAfter = response.headers.value(HttpHeaders.retryAfterHeader);
        await response.listen((_) {}).cancel();
        if ({502, 503, 504}.contains(status) && retryAfter == null) {
          throw HttpException('维基文库网关暂不可用。', uri: uri);
        }
        throw const BookSearchException(503, '维基文库暂不可用。');
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
      'prop': 'revisions|categories',
      'rvprop': 'ids|content',
      'rvslots': 'main',
      'cllimit': 'max',
    });
    if (result['query']?['pages'] is! List)
      throw const FormatException('维基文库缺少作品修订。');
    return result['query'] as Map;
  }

  static bool _licensed(Map page) {
    final categories = (page['categories'] as List? ?? []).whereType<Map>().map(
      (e) => e['title'].toString(),
    );
    return categories.any(
          (s) =>
              RegExp(r'^Category:PD(?:-|$)', caseSensitive: false).hasMatch(s),
        ) &&
        !categories.any(
          (s) =>
              RegExp(r'消歧|待刪|待删|未完成|未完結|節選|节选|摘錄|摘录|侵權|侵权|殘篇|残篇').hasMatch(s),
        );
  }

  static Map? _revision(Map? page) =>
      (page?['revisions'] as List?)?.whereType<Map>().firstOrNull;

  static Future<BookSearchCandidate?> find(
    HttpClient client,
    BookSearchQuery criteria,
  ) async => (await _work(client, criteria))?.book;

  static Future<_Work?> _work(
    HttpClient client,
    BookSearchQuery criteria,
  ) async {
    if (!supports(criteria)) return null;
    final result = await _pages(client, [
      criteria.title,
      if (_title(criteria.author)) 'Author:${criteria.author}',
    ]);
    final pages = (result['pages'] as List).whereType<Map>();
    final root = pages
        .where((p) => p['ns'] == 0 && p['missing'] != true)
        .firstOrNull;
    if (root == null || !_licensed(root)) return null;
    final rev = _revision(root);
    final text = rev?['slots']?['main']?['content'];
    final title = root['title'];
    if (text is! String ||
        title is! String ||
        !_title(title) ||
        root['pageid'] is! int ||
        rev?['revid'] is! int)
      return null;
    final header = RegExp(
      r'\{\{\s*(?:header|標題|标题)\s*\|([\s\S]*?)\}\}',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    if (header == null) return null;
    final authorRaw =
        RegExp(
          r'\|\s*(?:author|作者)\s*=\s*((?:\[\[[^\]\n]+\]\]|[^\n}|\[])+)',
          caseSensitive: false,
        ).firstMatch('|$header')?.group(1)?.trim() ??
        '';
    final author = authorRaw.replaceAllMapped(
      RegExp(
        r'\[\[(?:Author:|作者:)?([^\]|]+)(?:\|([^\]]+))?\]\]',
        caseSensitive: false,
      ),
      (m) => m[2] ?? m[1]!,
    );
    if (criteria.author.isNotEmpty && criteria.author != author) {
      final canonical = pages
          .where((p) => p['ns'] == 102 && p['missing'] != true)
          .firstOrNull?['title'];
      if (canonical is! String || canonical.split(':').last != author)
        return null;
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
    final links = <({String page, String anchor, String label})>[];
    // A standalone transcribed work can have a verified run of scanned pages
    // and no table of contents. Its own title identifies its only spine item.
    if (dir == null) {
      if (!RegExp(
            r'<pages\b[^>]+\bindex\s*=',
            caseSensitive: false,
          ).hasMatch(text) ||
          RegExp(r'目錄|目录|目次|消歧|節選|节选|摘錄|摘录').hasMatch(text))
        return null;
      links.add((page: title, anchor: '', label: title));
    }
    for (final l in RegExp(
      r'\[\[([^\]|\n]+)(?:\|([^\]\n]+))?\]\]',
    ).allMatches(dir ?? '')) {
      final parts = l[1]!.trim().split('#');
      if (parts.length > 2) return null;
      var page = parts.first.replaceAll('_', ' ').trim();
      final anchor = parts.length == 2 ? parts.last.trim() : '';
      if (page.startsWith('/')) page = '$title$page';
      if (page.isEmpty) page = title;
      if (!page.split('/').every(_title) ||
          (anchor.isNotEmpty && !_title(anchor)))
        return null;
      if (page == title && anchor.isEmpty) return null;
      links.add((
        page: page,
        anchor: anchor,
        label:
            l[2]?.trim() ?? (anchor.isNotEmpty ? anchor : page.split('/').last),
      ));
    }
    if (links.isEmpty || links.length > 250) return null;
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
    for (final link in links) {
      var key = link.page;
      for (var i = 0; i < 5 && aliases.containsKey(key); i++) {
        key = aliases[key]!;
      }
      final page = byName[key];
      final chapterRev = _revision(page);
      final original = chapterRev?['slots']?['main']?['content'];
      if (page == null ||
          original is! String ||
          chapterRev?['revid'] is! int ||
          !_licensed(page))
        return null;
      // A linked directory, redlink, or chapter stub cannot stand in for a leaf.
      if (key != title &&
          RegExp(
            r'ws-summary|^\s*==+\s*(目錄|目录|目次)\s*==+',
            multiLine: true,
          ).hasMatch(original))
        return null;
      if (link.anchor.isNotEmpty &&
          !RegExp(
            r'^=+[ \t]*' + RegExp.escape(link.anchor) + r'[ \t]*=+[ \t]*$',
            multiLine: true,
          ).hasMatch(original))
        return null;
      chapters.add(
        _Chapter(key, link.anchor, link.label, chapterRev!['revid'] as int),
      );
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
      r'\|\s*(?:year|年)\s*=\s*([0-9]{4})(?:年|\s|$)',
    ).firstMatch('|$header')?.group(1);
    final republic = int.tryParse(
      RegExp(r'\|\s*民\s*=\s*([0-9]{1,3})\b').firstMatch('|$header')?.group(1) ??
          '',
    );
    final source = _source(title);
    return _Work(
      BookSearchCandidate(
        id: 'wikisource-zh-${root['pageid']}-$revisionId-$fingerprint',
        title: title,
        author: author,
        language: '中文',
        edition: '小栖整理版（维基文库）',
        format: 'epub',
        sourceName: '中文维基文库',
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
      throw const BookSearchException(409, '作品或章节修订已更新，请重新查找。');
    final documents = <String>[];
    var total = 0;
    for (final c in work.chapters) {
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
        throw const BookSearchException(409, '目录与正文修订不一致。');
      }
      final body = _chapterBody(parsed['text'] as String, c);
      if (body == null) throw BookSearchException(422, '${c.label} 缺少可核实的正文。');
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
