import 'dart:convert';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/book_search_web_page.dart';
import 'package:xml/xml.dart';

const _publisherBook = '''
<main typeof="schema:Book">
  <h1 property="schema:name">Analects</h1>
  <span property="schema:author" typeof="schema:Person">
    <span property="schema:name">Confucius</span>
  </span>
  <section property="schema:workExample" typeof="schema:Book">
    <meta property="schema:inLanguage" content="en-GB">
    <meta property="schema:bookEdition" content="2nd edition">
    <span property="schema:translator" typeof="schema:Person">
      <span property="schema:name">James Legge</span>
    </span>
    <link property="schema:license" href="https://creativecommons.org/publicdomain/zero/1.0/">
    <div property="schema:encoding" typeof="schema:MediaObject">
      <meta property="schema:encodingFormat" content="application/epub+zip">
      <a property="schema:contentUrl" href="/downloads/analects.epub">EPUB</a>
    </div>
  </section>
</main>
''';

void main() {
  final page = Uri.https('press.example', '/books/analects');
  const query = BookSearchQuery(
    title: 'Analects',
    author: 'Confucius',
    language: '英文',
    format: 'epub',
  );

  test('extracts only explicit JSON-LD book encodings', () {
    final pageHtml = utf8.encode('''
      <script type="application/ld+json">
      {"@graph":[
        {"@type":"Book","name":"Analects","author":{"name":"Confucius"},
         "translator":{"name":"James Legge"},"bookEdition":"2nd edition",
         "inLanguage":"en","license":{"@id":"https://creativecommons.org/publicdomain/zero/1.0/"},
         "encoding":{"@type":"MediaObject","encodingFormat":"application/epub+zip",
                     "contentUrl":"/download/analects.epub?v=2"}},
        {"@type":"Chapter","name":"Analects","license":"https://creativecommons.org/licenses/by/4.0/",
         "encoding":{"@type":"MediaObject","encodingFormat":"application/epub+zip",
                     "contentUrl":"/chapter.epub"}}
      ]}
      </script>
    ''');
    final book = BookSearchWebPage.editions(pageHtml, page, query).single;
    expect(book.downloadUri, page.resolve('/download/analects.epub?v=2'));
    expect(book.translator, 'James Legge');
    expect(BookSearchWebPage.permitsDownload(book), isTrue);
  });

  test('binds catalogue links to the matching local book card', () {
    final pageHtml = utf8.encode('''
      <html lang="zh-HK"><body>
      <p>All books on this platform use <a href="https://creativecommons.org/licenses/by-nc-nd/4.0/">CC</a>.</p>
      <div><h2>人民的西湖：下集</h2>
      <p>何其亮 著・萬芷均 譯 <br>香港中文大學出版社 2024</p>
      <ul><li><a href="/books/west-lake.pdf">下載PDF</a></li></ul></div>
      <div><h2>其他圖書</h2><p>某作者 著 香港大學出版社 2025</p>
      <ul><li><a href="/books/other.pdf">下載PDF</a></li></ul></div>
      </body></html>
    ''');
    final book = BookSearchWebPage.editions(
      pageHtml,
      page,
      const BookSearchQuery(
        title: '人民的西湖',
        author: '何其亮',
        translator: '萬芷均',
        language: '繁體中文',
        format: 'pdf',
        edition: '2024',
      ),
    ).single;
    expect(book.downloadUri, page.resolve('/books/west-lake.pdf'));
    expect(book.publisher, '香港中文大學出版社');
    expect(book.publicationYear, '2024');
  });

  test('uses the book-level encoding from a previously unseen publisher', () {
    final candidate = BookSearchWebPage.editions(
      utf8.encode(_publisherBook),
      page,
      query,
    ).single;
    expect(candidate.author, 'Confucius');
    expect(candidate.translator, 'James Legge');
    expect(candidate.edition, '2nd edition');
    expect(candidate.license, 'CC0 1.0');
    expect(candidate.downloadUri, page.resolve('/downloads/analects.epub'));
    expect(BookSearchWebPage.permitsDownload(candidate), isTrue);
    final opf = XmlDocument.parse('''
      <package xmlns:dc="http://purl.org/dc/elements/1.1/">
        <metadata><dc:title>Analects</dc:title><dc:creator>Confucius</dc:creator>
          <dc:language>en-GB</dc:language><dc:contributor id="translator">James Legge</dc:contributor>
          <meta refines="#translator" property="role">trl</meta></metadata>
      </package>
      ''');
    expect(BookSearchWebPage.matchesPublication(candidate, opf), isTrue);
    final wrong = XmlDocument.parse(
      opf.toXmlString().replaceAll('Analects', 'Another Work'),
    );
    expect(BookSearchWebPage.matchesPublication(candidate, wrong), isFalse);
    final differentTranslator = XmlDocument.parse(
      opf.toXmlString().replaceAll('James Legge', 'Another Translator'),
    );
    expect(
      BookSearchWebPage.matchesPublication(candidate, differentTranslator),
      isFalse,
    );
  });

  test('preserves only the explicit translator as a file requirement', () {
    final request = BookSearchQuery.fromTool({
      'title': 'Analects',
      'translator': 'James Legge',
    }, userText: '请找《论语》James Legge（理雅各）的英译整本 EPUB。');
    final retry = const BookSearchQuery(title: 'The Analects')
        .withRequiredMatch(
          BookSearchQuery.fromStoredConstraints(request.toJson()),
        );
    expect(retry.matchesTranslator('James Legge'), isTrue);
    expect(retry.matchesTranslator('D. C. Lau'), isFalse);
    expect(retry.matchesTranslator(null), isFalse);
    expect(
      BookSearchWebPage.editions(
        utf8.encode(_publisherBook.replaceAll('James Legge', 'D. C. Lau')),
        page,
        retry,
      ),
      isEmpty,
    );
  });

  test(
    'uses the published OpenSearch template without accepting unrelated paths',
    () {
      final catalog = BookSearchWebPage.standardCatalog(query)!;
      expect(catalog.queryParameters['query'], 'Analects');
      final html = utf8.encode('''
      <a property="schema:url" href="/ebooks/confucius/analects/james-legge"></a>
      <a property="schema:url" href="https://example.org/ebooks/confucius/analects"></a>
      <a property="schema:url" href="/ebooks/confucius"></a>
    ''');
      expect(BookSearchWebPage.catalogPages(html, catalog), [
        catalog.resolve('/ebooks/confucius/analects/james-legge'),
      ]);
    },
  );

  test(
    'rejects a chapter, excerpt, different language or unrelated file origin',
    () {
      for (final fixture in [
        _publisherBook.replaceAll('schema:workExample', 'schema:hasPart'),
        _publisherBook.replaceAll('analects.epub', 'analects-preview.epub'),
        _publisherBook.replaceAll('en-GB', 'zh-Hant'),
        _publisherBook.replaceAll(
          '/downloads/analects.epub',
          'https://mirror.example/book.epub',
        ),
        _publisherBook.replaceAll('creativecommons.org', 'press.example'),
      ]) {
        expect(
          BookSearchWebPage.editions(utf8.encode(fixture), page, query),
          isEmpty,
        );
      }
    },
  );

  test('follows only an immediate public continuation for the same file', () {
    final file = page.resolve('/downloads/analects.epub');
    Uri? follow(String href) => BookSearchWebPage.downloadRefresh(
      utf8.encode('<meta http-equiv="refresh" content="0; url=$href">'),
      file,
    );
    expect(follow('?source=download'), file.replace(query: 'source=download'));
    expect(follow('https://private.example/else?source=download'), isNull);
    expect(follow('/downloads/other.epub?source=download'), isNull);
    expect(follow('?source=login'), isNull);
  });
}
