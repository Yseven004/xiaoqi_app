import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/book_search_sources.dart';

void main() {
  final enabled = Platform.environment['XIAOQI_BOOK_SEARCH_LIVE'] == '1';
  final testProxy = Platform.environment['XIAOQI_BOOK_SEARCH_TEST_PROXY'];
  final sources = BookSearchSources(
    clientFactory: testProxy == null
        ? null
        : () => HttpClient()..findProxy = (_) => 'PROXY $testProxy',
  );
  final samples = <(String, String, String, String, String, String)>[
    (
      'Hello 算法 Python PDF',
      'Hello 算法 · Python 版',
      '靳宇栋（krahets）',
      '1.3.0',
      'pdf',
      'github.com',
    ),
    (
      'Hello 算法 Java EPUB',
      'Hello 算法 · Java 版',
      '靳宇栋（krahets）',
      '1.3.0',
      'epub',
      'github.com',
    ),
    (
      '动手学深度学习 PyTorch',
      '动手学深度学习 · PyTorch 版',
      'Aston Zhang、Zachary C. Lipton、Mu Li、Alexander J. Smola',
      '中文第 2 版 · 2.0.0',
      'pdf',
      'zh-v2.d2l.ai',
    ),
    (
      'Pro Git 中文 EPUB',
      'Pro Git',
      'Scott Chacon、Ben Straub',
      '简体中文第 2 版 · 2.1.80',
      'epub',
      'github.com',
    ),
  ];
  for (final (query, title, author, edition, format, host) in samples) {
    test(query, () async {
      final book = await sources
          .search(query, BookSearchCancellation())
          .firstWhere((candidate) => candidate.downloadUri != null);
      expect(book.title, title);
      expect(book.author, author);
      expect(book.edition, edition);
      expect(book.language, '简体中文');
      expect(book.format, format);
      expect(book.sourceUri.host, host);
      expect(book.licenseUri, isNotNull);
      expect(
        await sources.verify(book, BookSearchCancellation()),
        book.downloadUri,
      );
    }, skip: !enabled);
  }

  test(
    'resolves the Chinese Wikisource complete EPUB for a work outside the publisher catalog',
    () async {
      final books = sources.searchByCriteria(
        const BookSearchQuery(title: '呐喊', author: '鲁迅', format: 'epub'),
        BookSearchCancellation(),
      );
      final book = await books.firstWhere((item) => item.inlineEpub);
      expect(book.title, '吶喊');
      expect(book.author, '魯迅');
      expect(book.publicationYear, '1923');
      expect(book.sourceUri.host, 'zh.wikisource.org');
      final bytes = await sources.buildEpub(book, BookSearchCancellation());
      final epub = ZipDecoder().decodeBytes(bytes);
      final nav = XmlDocument.parse(
        utf8.decode(epub.findFile('EPUB/nav.xhtml')!.content),
      );
      expect(nav.findAllElements('a').length, 15);
      expect(nav.findAllElements('a').first.innerText, '自序');
      expect(nav.findAllElements('a').last.innerText, '社戲');
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final (queryTitle, requestedAuthor, sourceTitle, author, chapterCount)
      in [('朝花夕拾', '鲁迅', '朝花夕拾', '魯迅', 12), ('庄子', '庄周', '莊子', '莊子', 33)]) {
    test(
      'downloads and compiles every published Wikisource chapter of $queryTitle',
      () async {
        final cancellation = BookSearchCancellation();
        final book = await sources
            .searchByCriteria(
              BookSearchQuery(
                title: queryTitle,
                author: requestedAuthor,
                format: 'epub',
              ),
              cancellation,
            )
            .firstWhere((candidate) => candidate.inlineEpub);
        expect(book.title, sourceTitle);
        expect(book.author, author);
        expect(
          book.sourceUri,
          Uri.https('zh.wikisource.org', '/wiki/$sourceTitle'),
        );
        final bytes = await sources.buildEpub(book, cancellation);
        final archive = ZipDecoder().decodeBytes(bytes);
        final opf = XmlDocument.parse(
          utf8.decode(archive.findFile('EPUB/book.opf')!.content),
        );
        expect(opf.findAllElements('itemref').length, chapterCount);
        for (var i = 0; i < chapterCount; i++) {
          final document = XmlDocument.parse(
            utf8.decode(archive.findFile('EPUB/c$i.xhtml')!.content),
          );
          expect(document.findAllElements('p').length, greaterThan(1));
          expect(
            document.findAllElements('a').single.getAttribute('href'),
            contains('oldid='),
          );
        }
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'Open Library distinguishes edition metadata from a downloadable file',
    () async {
      final results = await sources
          .search('活着', BookSearchCancellation())
          .toList();
      final edition = results.singleWhere(
        (book) => book.isbn == '9787506365437',
      );
      expect(edition.title, '活着');
      expect(edition.author, '余华');
      expect(edition.edition, '作家出版社 · 2012');
      expect(
        edition.sourceUri.toString(),
        'https://openlibrary.org/books/OL33426721M',
      );
      expect(edition.downloadUri, isNull);
      expect(
        sources.verify(edition, BookSearchCancellation()),
        throwsA(isA<BookSearchException>()),
      );
    },
    skip: !enabled,
  );
}
