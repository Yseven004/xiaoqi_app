import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/wikisource_books.dart';

void main() {
  const title = '测试长篇';
  String chapter(int n) => '$title/第${n.toString().padLeft(3, '0')}回';
  late HttpServer server;
  late HttpClient client;
  var fault = '';
  var exportStatus = 200;
  var exportCalls = 0;
  var parseCalls = 0;
  Completer<void>? exportEntered;

  Map<String, dynamic> page(String name, int index) => {
    'ns': 0,
    'title': name,
    'pageid': index + 1,
    'categories': [
      if (index == 0) {'title': 'Category:PD-old'},
    ],
    'revisions': [
      {
        'revid': index + 100,
        'slots': {
          'main': {
            'content': index == 0
                ? '{{header\n| author = 作者甲\n}}\n<div class="ws-summary">${[for (var i = 1; i <= 40; i++) '* [[${chapter(i)}]]'].join('\n')}</div>'
                : '这是该章节的完整正文。',
          },
        },
      },
    ],
  };
  List<int> export() {
    final archive = Archive();
    void add(String name, String text) =>
        archive.add(ArchiveFile.string(name, text));
    archive.add(
      ArchiveFile.string('mimetype', 'application/epub+zip')
        ..compression = CompressionType.none,
    );
    add(
      'META-INF/container.xml',
      '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    );
    final order = [for (var i = 1; i <= 40; i++) i];
    if (fault == 'order') order.setAll(0, [2, 1]);
    add(
      'OPS/book.opf',
      '<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>$title</dc:title><dc:source>https://zh.wikisource.org/wiki/${fault == 'identity' ? '别的作品' : title}</dc:source>'
          '${fault == 'author' ? '<dc:creator>错误作者</dc:creator>' : ''}</metadata>'
          '<manifest><item id="title" href="title.xhtml" media-type="application/xhtml+xml"/><item id="root" href="root.xhtml" media-type="application/xhtml+xml"/>'
          '${[for (var i = 1; i <= 40; i++) '<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>'].join()}'
          '</manifest><spine><itemref idref="title"/><itemref idref="root"/>${fault == 'directory_only' ? '' : [for (final i in order) '<itemref idref="c$i"/>'].join()}</spine></package>',
    );
    add(
      'OPS/title.xhtml',
      '<html><head><title>$title</title></head><body><h1>$title</h1></body></html>',
    );
    add(
      'OPS/root.xhtml',
      '<html><head><title>$title</title></head><body>'
          '${[for (var i = 1; i <= 40; i++) '<a href="c$i.xhtml" title="${chapter(i)}">第$i回</a>'].join()}'
          '</body></html>',
    );
    for (var i = 1; i <= 40; i++) {
      if (fault == 'missing_file' && i == 40) continue;
      add(
        'OPS/c$i.xhtml',
        '<html><head><title>第$i回</title></head><body>'
            '${fault == 'stub' && i == 40 ? '<div class="noprint"><p>站点导航</p></div>' : '<p>这是第$i回的完整正文，包含原书实际段落。</p>'}'
            '${fault == 'script' && i == 40 ? '<script>bad()</script>' : ''}</body></html>',
      );
    }
    if (fault == 'oversized') add('OPS/big.txt', 'x' * (4 * 1024 * 1024 + 1));
    return ZipEncoder().encode(archive);
  }

  setUp(() async {
    fault = '';
    exportStatus = 200;
    exportCalls = 0;
    parseCalls = 0;
    exportEntered = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient()
      ..connectionFactory = ((_, _, _) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
      ..findProxy = (_) => 'DIRECT';
    server.listen((request) async {
      final q = request.uri.queryParameters;
      if (request.uri.path == '/') {
        exportCalls++;
        expect(q, {'lang': 'zh', 'page': title, 'format': 'epub'});
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          contains('XiaoqiBookSearch'),
        );
        if (exportEntered != null) {
          exportEntered!.complete();
          return;
        }
        request.response.statusCode = exportStatus;
        request.response.headers.contentType = ContentType(
          'application',
          'epub+zip',
        );
        if (exportStatus == 200) request.response.add(export());
      } else {
        if (q['action'] == 'parse') parseCalls++;
        expect(q['action'], 'query');
        final names = q['titles']!.split('|');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'query': {
              'pages': [
                for (final name in names)
                  page(
                    name,
                    name == title
                        ? 0
                        : int.parse(RegExp(r'第(\d+)回').firstMatch(name)![1]!),
                  ),
              ],
            },
          }),
        );
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  test(
    'long flat directories use a distinct complete official edition with source author',
    () async {
      final candidate = (await WikisourceBooks.find(
        client,
        const BookSearchQuery(title: title),
      ))!;
      expect(candidate.id, startsWith('wikisource-zh-export-'));
      expect(candidate.edition, '维基文库官方导出版');
      expect(WikisourceBooks.owns(candidate), isTrue);
      expect(exportCalls, 0);
      final bytes = await WikisourceBooks.build(client, candidate);
      final zip = ZipDecoder().decodeBytes(bytes);
      final opf = XmlDocument.parse(
        utf8.decode(zip.findFile('OPS/book.opf')!.content),
      );
      expect(
        opf.findAllElements('creator', namespaceUri: '*').single.innerText,
        '作者甲',
      );
      expect(opf.findAllElements('itemref').length, 42);
      expect(exportCalls, 1);
      expect(parseCalls, 0);
    },
  );
  for (final failure in [
    'directory_only',
    'missing_file',
    'identity',
    'author',
    'order',
    'stub',
    'script',
    'oversized',
  ]) {
    test(
      'rejects official export $failure without falling back to expensive parse',
      () async {
        final candidate = (await WikisourceBooks.find(
          client,
          const BookSearchQuery(title: title),
        ))!;
        fault = failure;
        await expectLater(
          WikisourceBooks.build(client, candidate),
          throwsA(isA<BookSearchException>()),
        );
        expect(exportCalls, 1);
        expect(parseCalls, 0);
      },
    );
  }
  test(
    'honors exporter refusal without retries or another export path',
    () async {
      final candidate = (await WikisourceBooks.find(
        client,
        const BookSearchQuery(title: title),
      ))!;
      exportStatus = 403;
      await expectLater(
        WikisourceBooks.build(client, candidate),
        throwsA(isA<WikisourceHttpFailure>()),
      );
      expect(exportCalls, 1);
      expect(parseCalls, 0);
    },
  );
  test(
    'closing the shared source client interrupts a pending official export',
    () async {
      final candidate = (await WikisourceBooks.find(
        client,
        const BookSearchQuery(title: title),
      ))!;
      exportEntered = Completer<void>();
      final pending = WikisourceBooks.build(client, candidate);
      final assertion = expectLater(pending, throwsA(isA<Exception>()));
      await exportEntered!.future;
      client.close(force: true);
      await assertion;
      expect(exportCalls, 1);
      expect(parseCalls, 0);
    },
  );
}
