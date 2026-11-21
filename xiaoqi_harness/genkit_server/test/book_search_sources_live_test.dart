import 'dart:io';

import 'package:test/test.dart';
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
      final results = await sources
          .search(query, BookSearchCancellation())
          .toList();
      final book = results.single;
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

  test('does not substitute a different edition', () async {
    for (final query in ['Hello 算法 1.2.0', '动手学深度学习 第一版', 'Hello 算法 纸质书']) {
      expect(
        await sources.search(query, BookSearchCancellation()).toList(),
        isEmpty,
      );
    }
  });
}
