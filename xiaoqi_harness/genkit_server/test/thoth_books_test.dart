import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/thoth_books.dart';

const _title = 'A Lexicon of Medieval Nordic Law';
const _publisher = '85fd969a-a16c-480b-b641-cb9adf979c3b';
const _work = '0229f930-1e01-40b8-b4a8-03ab57624ced';
const _release = 'https://www.openbookpublishers.com/books/10.11647/obp.0188';
const _archive = 'https://zenodo.org/records/19848341';
const _archiveFile = '$_archive/files/${_work}_book.pdf';
const _filePrefix = 'https://books.openbookpublishers.com/10.11647/obp.0188';

Map<String, Object> _location(
  String url,
  String page, {
  bool canonical = false,
}) => {'canonical': canonical, 'fullTextUrl': url, 'landingPage': page};

Map<String, Object?> _book({Map<String, Object?> changes = const {}}) => {
  'workId': _work,
  'title': _title,
  'fullTitle': _title,
  'workStatus': 'ACTIVE',
  'workType': 'MONOGRAPH',
  'edition': 1,
  'publicationDate': '2020-06-19',
  'landingPage': _release,
  'license': 'http://creativecommons.org/licenses/by/4.0/',
  'imprint': {
    'publisher': {
      'publisherName': 'Open Book Publishers',
      'publisherId': _publisher,
    },
  },
  'languages': [
    {'languageCode': 'ENG'},
  ],
  'contributions': [
    {'fullName': 'Jeffrey Love', 'contributionType': 'AUTHOR'},
    {'fullName': 'Ulrika Djärv', 'contributionType': 'AUTHOR'},
  ],
  'publications': [
    {
      'publicationType': 'PDF',
      'isbn': '978-1-78374-817-4',
      'locations': [
        _location('$_filePrefix.pdf', _release, canonical: true),
        _location(_archiveFile, _archive),
      ],
    },
    {
      'publicationType': 'EPUB',
      'isbn': '978-1-78374-818-1',
      'locations': [_location('$_filePrefix.epub', _release, canonical: true)],
    },
  ],
  ...changes,
};

Future<HttpClient> _client({
  List<Map<String, Object?>>? books,
  int status = HttpStatus.ok,
  String? body,
  void Function(HttpRequest, Object?)? onRequest,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    final payload = await utf8.decoder.bind(request).join();
    onRequest?.call(request, jsonDecode(payload));
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json;
    if (status == HttpStatus.movedTemporarily) {
      request.response.headers.set(HttpHeaders.locationHeader, _release);
    }
    request.response.write(
      body ??
          jsonEncode({
            'data': {
              'books': books ?? [_book()],
            },
          }),
    );
    await request.response.close();
  });
  final client = HttpClient()
    ..connectionFactory = ((_, _, _) =>
        Socket.startConnect(InternetAddress.loopbackIPv4, server.port))
    ..findProxy = (_) => 'DIRECT';
  addTearDown(() => client.close(force: true));
  return client;
}

void main() {
  test(
    'finds a whole digital edition and its independent official deposit',
    () async {
      final client = await _client(
        onRequest: (request, payload) {
          expect(request.method, 'POST');
          expect(request.requestedUri.host, 'api.thoth.pub');
          expect(request.uri.path, '/graphql');
          expect(
            request.headers.value(HttpHeaders.userAgentHeader),
            'XiaoqiBookSearch/1.0',
          );
          expect((payload as Map)['variables'], {
            'title': _title,
            'publishers': [_publisher],
          });
        },
      );
      final candidates = await ThothBooks.search(
        client,
        const BookSearchQuery(
          title: _title,
          author: 'Jeffrey Love',
          edition: '1st edition',
          language: '英文',
          format: 'pdf',
          isbn: '9781783748174',
        ),
      );

      expect(candidates.map((candidate) => candidate.sourceName), [
        ThothBooks.archiveSourceName,
        ThothBooks.sourceName,
      ]);
      expect(candidates.map((candidate) => candidate.downloadUri.toString()), [
        _archiveFile,
        '$_filePrefix.pdf',
      ]);
      expect(candidates.map((candidate) => candidate.id).toSet(), hasLength(2));
      for (final candidate in candidates) {
        expect(candidate.title, _title);
        expect(candidate.author, 'Jeffrey Love、Ulrika Djärv');
        expect(candidate.edition, '第1版');
        expect(candidate.publicationYear, '2020');
        expect(candidate.isbn, '9781783748174');
        expect(candidate.license, 'CC BY 4.0');
        expect(ThothBooks.permitsDownload(candidate), isTrue);
      }
    },
  );

  test(
    'keeps the original CC BY 3.0 attribution and permits its deposited PDF',
    () async {
      final client = await _client(
        books: [
          _book(
            changes: {
              'license': 'http://creativecommons.org/licenses/by/3.0/',
              'workType': 'EDITED_BOOK',
              'contributions': [
                {'fullName': 'Editor A', 'contributionType': 'EDITOR'},
                {'fullName': 'Editor B', 'contributionType': 'EDITOR'},
                {'fullName': 'Foreword C', 'contributionType': 'FOREWORD_BY'},
              ],
            },
          ),
        ],
      );
      final candidates = await ThothBooks.search(
        client,
        const BookSearchQuery(title: _title, author: 'Editor A', format: 'pdf'),
      );
      final deposit = candidates.singleWhere(
        (book) => book.sourceName == ThothBooks.archiveSourceName,
      );
      expect(deposit.license, 'CC BY 3.0');
      expect(
        deposit.licenseUri.toString(),
        'https://creativecommons.org/licenses/by/3.0/',
      );
      expect(deposit.author, 'Editor A、Editor B（编）');
      expect(deposit.downloadUri.toString(), _archiveFile);
      expect(ThothBooks.permitsDownload(deposit), isTrue);
    },
  );

  test(
    'honors the electronic edition ISBN, language, format, and author',
    () async {
      final client = await _client();
      final epub = await ThothBooks.search(
        client,
        const BookSearchQuery(
          title: _title,
          format: 'epub',
          isbn: '9781783748181',
        ),
      );
      expect(epub.single.downloadUri.toString(), '$_filePrefix.epub');
      expect(ThothBooks.permitsDownload(epub.single), isTrue);

      for (final query in const [
        BookSearchQuery(title: _title, edition: '第2版'),
        BookSearchQuery(title: _title, isbn: '9781783748181', format: 'pdf'),
        BookSearchQuery(title: _title, language: '中文'),
        BookSearchQuery(title: _title, author: 'Other Author'),
        BookSearchQuery(title: 'A Lexicon'),
      ]) {
        expect(
          await ThothBooks.search(client, query),
          isEmpty,
          reason: query.toJson().toString(),
        );
      }
    },
  );

  test(
    'requires an active whole book, authorized publisher, and explicit license',
    () async {
      for (final changes in <Map<String, Object?>>[
        {'workType': 'BOOK_CHAPTER'},
        {'workStatus': 'FORTHCOMING'},
        {'edition': null},
        {'license': 'https://creativecommons.org/licenses/by-nc/4.0/'},
        {'license': 'https://creativecommons.org/licenses/by-nc/3.0/'},
        {'license': 'https://example.com/licenses/by/3.0/'},
        {
          'imprint': {
            'publisher': {
              'publisherName': 'Open Book Publishers',
              'publisherId': 'different',
            },
          },
        },
      ]) {
        final client = await _client(books: [_book(changes: changes)]);
        expect(
          await ThothBooks.search(client, const BookSearchQuery(title: _title)),
          isEmpty,
          reason: changes.toString(),
        );
      }
    },
  );

  test(
    'accepts only declared edition files and the matching archive record',
    () async {
      final client = await _client(
        books: [
          _book(
            changes: {
              'publications': [
                {
                  'publicationType': 'PDF',
                  'locations': [
                    _location('$_filePrefix.pdf', _release),
                    _location(
                      '$_filePrefix-sample.pdf',
                      _release,
                      canonical: true,
                    ),
                    _location(
                      '$_filePrefix.pdf',
                      '$_release/other',
                      canonical: true,
                    ),
                    _location(
                      _archiveFile,
                      'https://zenodo.org/records/19848342',
                    ),
                  ],
                },
              ],
            },
          ),
        ],
      );
      expect(
        await ThothBooks.search(client, const BookSearchQuery(title: _title)),
        isEmpty,
      );

      expect(
        ThothBooks.permitsDownload(
          BookSearchCandidate(
            id: 'thoth-obp-0188-$_work-zenodo-19848341-pdf',
            title: _title,
            author: 'Jeffrey Love',
            language: '英文',
            edition: '第1版',
            format: 'pdf',
            sourceName: ThothBooks.archiveSourceName,
            sourceUri: Uri.parse(_archive),
            downloadUri: Uri.parse('$_archive/files/another_book.pdf'),
            publisher: ThothBooks.sourceName,
            license: 'CC BY 4.0',
            licenseUri: Uri.parse(
              'https://creativecommons.org/licenses/by/4.0/',
            ),
          ),
        ),
        isFalse,
      );
    },
  );

  test(
    'reports HTTP, malformed JSON, and invalid GraphQL responses separately',
    () async {
      const query = BookSearchQuery(title: _title);
      final redirect = await _client(status: HttpStatus.movedTemporarily);
      await expectLater(
        ThothBooks.search(redirect, query),
        throwsA(
          isA<ThothHttpFailure>().having(
            (error) => error.statusCode,
            'status',
            302,
          ),
        ),
      );
      final brokenJson = await _client(body: '{');
      await expectLater(
        ThothBooks.search(brokenJson, query),
        throwsFormatException,
      );
      final graphQlError = await _client(
        body: '{"errors":[],"data":{"books":[]}}',
      );
      await expectLater(
        ThothBooks.search(graphQlError, query),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Thoth 书目响应结构无效。',
          ),
        ),
      );
    },
  );
}
