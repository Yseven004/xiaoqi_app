import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/wikisource_books.dart';

void main() {
  late HttpServer server;
  late HttpClient client;
  const query = BookSearchQuery(title: '测试集', author: '鲁迅', format: 'epub');
  const title = '測試集';
  var licensed = true;
  var includeChapter = true;
  var emptyBody = false;
  var wrongTitle = false;
  var secondRev = 75;
  final upstreamResponses = <int>[];
  final actions = <String>[];
  Map page(
    String name,
    int id,
    int revision,
    String content, {
    bool pd = true,
  }) => {
    'ns': 0,
    'title': name,
    'pageid': id,
    'categories': [
      if (pd) {'title': 'Category:PD-old-80-1923'},
    ],
    'revisions': [
      {
        'revid': revision,
        'slots': {
          'main': {'content': content},
        },
      },
    ],
  };
  setUp(() async {
    licensed = true;
    includeChapter = true;
    emptyBody = false;
    wrongTitle = false;
    secondRev = 75;
    upstreamResponses.clear();
    actions.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient()
      ..connectionFactory = ((_, _, _) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
      ..findProxy = (_) => 'DIRECT';
    server.listen((r) async {
      expect(r.uri.path, '/w/api.php');
      expect(
        r.headers.value(HttpHeaders.userAgentHeader),
        contains('https://'),
      );
      final q = r.uri.queryParameters;
      actions.add(q['action']!);
      if (upstreamResponses.isNotEmpty) {
        r.response.statusCode = upstreamResponses.removeAt(0);
        await r.response.close();
        return;
      }
      final Map payload;
      if (q['action'] == 'parse') {
        final n = int.parse(q['oldid']!);
        final name = switch (n) {
          73 => title,
          74 => '第一章',
          _ => '第二章',
        };
        final body = n == 73
            ? '<div class="mw-heading"><h2 id="序">序</h2></div><div><p>这里是序言。</p></div><div class="mw-heading"><h2>另一区域</h2></div><p>排除在序言之外。</p>'
            : '<div id="headerContainer"><p>站点导航</p></div><script>evil()</script><div class="licenseContainer"><p>版权模板。</p></div>' +
                  (emptyBody && n == secondRev
                      ? ''
                      : '<p>${name}的正文 &amp; 内容。</p>');
        payload = {
          'parse': {
            'title': wrongTitle && n == 74 ? '别的作品' : name,
            'revid': n,
            'text': '<div class="mw-parser-output">$body</div>',
          },
        };
      } else if (q['titles']!.contains('第一章')) {
        payload = {
          'query': {
            'redirects': [
              {'from': '第二章旧名', 'to': '第二章'},
            ],
            'pages': [
              page('第一章', 43, 74, '第一章的正文。'),
              if (includeChapter) page('第二章', 44, secondRev, '第二章的正文。'),
            ],
          },
        };
      } else {
        payload = {
          'query': {
            'pages': [
              {'ns': 102, 'title': 'Author:魯迅'},
              page(
                title,
                42,
                73,
                '{{header\n| author = [[Author:魯迅|魯迅]]\n| 民 = 12\n}}\n<div class="ws-summary">* [[#序|序]]\n* [[第一章]]\n* [[第二章旧名|第二章]]</div>\n== 序 ==\n这里是序言。',
                pd: licensed,
              ),
            ],
          },
        };
      }
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode(payload));
      await r.response.close();
    });
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  test(
    'retries a transient gateway once and respects access/rate limits',
    () async {
      upstreamResponses.add(502);
      expect(await WikisourceBooks.find(client, query), isNotNull);
      expect(actions, ['query', 'query', 'query']);
      for (final status in [401, 403, 429]) {
        actions.clear();
        upstreamResponses.add(status);
        await expectLater(
          WikisourceBooks.find(client, query),
          throwsA(isA<BookSearchException>()),
        );
        expect(actions, ['query']);
      }
    },
  );

  test(
    'packages all published entries, foreword and real text with revision attribution',
    () async {
      final b = (await WikisourceBooks.find(client, query))!;
      expect(b.title, title);
      expect(b.author, '魯迅');
      expect(b.publicationYear, '1923');
      expect(b.inlineEpub, true);
      expect(b.sourceUri, Uri.https('zh.wikisource.org', '/wiki/$title'));
      expect(b.downloadUri, isNull);
      expect(WikisourceBooks.owns(b), isTrue);
      expect(actions, ['query', 'query']);
      final archive = ZipDecoder().decodeBytes(
        await WikisourceBooks.build(client, b),
      );
      String read(String name) => utf8.decode(archive.findFile(name)!.content);
      expect(archive.files.first.name, 'mimetype');
      expect(archive.files.first.compression, CompressionType.none);
      expect(read('mimetype'), 'application/epub+zip');
      final opf = XmlDocument.parse(read('EPUB/book.opf'));
      expect(
        opf.findAllElements('source', namespaceUri: '*').single.innerText,
        '${b.sourceUri}',
      );
      expect(opf.findAllElements('itemref').length, 3);
      expect(
        XmlDocument.parse(
          read('EPUB/nav.xhtml'),
        ).findAllElements('a').map((s) => s.innerText),
        ['序', '第一章', '第二章'],
      );
      final ch = XmlDocument.parse(read('EPUB/c1.xhtml'));
      expect(ch.findAllElements('p').first.innerText, '第一章的正文 & 内容。');
      expect(ch.innerText, isNot(contains('导航')));
      expect(ch.innerText, isNot(contains('版权模板')));
      expect(
        ch.findAllElements('a').single.getAttribute('href'),
        contains('oldid=74'),
      );
      expect(read('EPUB/c0.xhtml'), isNot(contains('排除在序言之外')));
      expect(ch.findAllElements('script'), isEmpty);
    },
  );
  test(
    'unlicensed or incomplete directories cannot advertise a complete book',
    () async {
      licensed = false;
      expect(await WikisourceBooks.find(client, query), isNull);
      licensed = true;
      includeChapter = false;
      expect(await WikisourceBooks.find(client, query), isNull);
      expect(
        WikisourceBooks.supports(
          const BookSearchQuery(title: title, isbn: '9781234567897'),
        ),
        isFalse,
      );
      expect(
        WikisourceBooks.supports(
          const BookSearchQuery(title: title, format: 'pdf'),
        ),
        isFalse,
      );
    },
  );
  test(
    'changed revisions, wrong pages or empty chapters reject the entire import',
    () async {
      final b = (await WikisourceBooks.find(client, query))!;
      secondRev = 76;
      await expectLater(
        WikisourceBooks.build(client, b),
        throwsA(isA<BookSearchException>()),
      );
      secondRev = 75;
      wrongTitle = true;
      await expectLater(
        WikisourceBooks.build(client, b),
        throwsA(isA<BookSearchException>()),
      );
      wrongTitle = false;
      emptyBody = true;
      await expectLater(
        WikisourceBooks.build(client, b),
        throwsA(isA<BookSearchException>()),
      );
    },
  );
}
