import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/book_search_query.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

const _owner = 'reader:device';
const _id = 'test-book-search-0001';

final _candidate = BookSearchCandidate(
  id: 'hello-python',
  title: 'Hello 算法',
  author: 'Krahets',
  language: 'zh-Hans',
  edition: 'Python 版',
  format: 'pdf',
  sourceName: '作者发布页',
  sourceUri: Uri.https('books.example', '/hello'),
  license: 'CC BY-NC-SA 4.0',
  licenseUri: Uri.https('books.example', '/license'),
  downloadUri: Uri.https('books.example', '/hello-python.pdf'),
);

void main() {
  late Directory directory;
  late CloudStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('xiaoqi-book-search-');
    store = CloudStore(root: directory.path);
  });

  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  BookSearchService service({
    BookSearchProvider? find,
    BookSearchFileAcquirer? acquire,
    Duration timeout = const Duration(seconds: 2),
    Duration preparationTimeout = const Duration(seconds: 90),
  }) => BookSearchService(
    store: store,
    find: find ?? (_, _) => Stream.value(_candidate),
    acquire:
        acquire ??
        (_, _) async {
          final temp = await Directory.systemTemp.createTemp(
            'book-search-source-',
          );
          return File('${temp.path}/book.pdf')
            ..writeAsBytesSync(List<int>.filled(256, 1));
        },
    searchTimeout: timeout,
    preparationTimeout: preparationTimeout,
  );

  test(
    'stop before a delayed start persists and never dispatches a source',
    () {
      var dispatches = 0;
      final search = service(
        find: (_, _) {
          dispatches++;
          return Stream.value(_candidate);
        },
      );
      expect(search.stop(owner: _owner, id: _id)['status'], 'stopped');
      final restarted = service(
        find: (_, _) {
          dispatches++;
          return Stream.value(_candidate);
        },
      );
      expect(
        restarted.start(owner: _owner, id: _id, query: 'Hello 算法')['status'],
        'stopped',
      );
      expect(dispatches, 0);
    },
  );

  test(
    'shared state survives stop, discards late results and hides URLs',
    () async {
      final entered = Completer<void>();
      final interrupted = Completer<void>();
      final search = service(
        find: (_, cancellation) async* {
          yield BookSearchCandidate(
            id: _candidate.id,
            title: _candidate.title,
            author: _candidate.author,
            language: _candidate.language,
            edition: _candidate.edition,
            format: _candidate.format,
            sourceName: _candidate.sourceName,
            sourceUri: _candidate.sourceUri,
          );
          entered.complete();
          await cancellation.whenCancelled;
          interrupted.complete();
          yield BookSearchCandidate(
            id: 'late-result',
            title: '不应追加',
            author: '示例',
            language: 'zh-Hans',
            edition: '测试版',
            format: 'epub',
            sourceName: '来源',
            sourceUri: Uri.https('books.example'),
          );
        },
      );
      final initial = search.start(owner: _owner, id: _id, query: 'Hello 算法');
      expect(initial['status'], 'searching');
      await entered.future;
      final active = search.read(owner: _owner, id: _id);
      expect(active['revision'], greaterThan(initial['revision']));
      expect(
        (active['candidates'] as List).single,
        isNot(contains('downloadUrl')),
      );
      expect(search.stop(owner: _owner, id: _id)['status'], 'stopped');
      await interrupted.future;
      final stopped = await search.wait(owner: _owner, id: _id);
      expect(stopped['status'], 'stopped');
      expect(stopped['candidates'], hasLength(1));
      expect(
        () =>
            search.resolve(owner: _owner, id: _id, candidateId: _candidate.id),
        throwsA(isA<BookSearchException>()),
      );
    },
  );

  test(
    'owner isolation and idempotent start across service instances',
    () async {
      var dispatches = 0;
      final search = service(
        find: (_, _) {
          dispatches++;
          return Stream.value(_candidate);
        },
      );
      search.start(owner: _owner, id: _id, query: 'Hello 算法');
      final finalState = await search.wait(owner: _owner, id: _id);
      expect(finalState['status'], 'complete');
      final restarted = service();
      expect(
        restarted.start(owner: _owner, id: _id, query: ' Hello 算法 '),
        finalState,
      );
      expect(
        restarted.start(owner: _owner, id: _id, query: '另一部作品')['status'],
        'complete',
      );
      expect(
        () => restarted.read(owner: 'other:device', id: _id),
        throwsA(
          isA<BookSearchException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
      expect(dispatches, 1);
    },
  );

  test(
    'counts five distinct searches and rejects a sixth without dispatch',
    () async {
      var dispatches = 0;
      final search = service(
        find: (query, _) {
          dispatches++;
          return Stream.value(
            BookSearchCandidate(
              id: 'catalog-${query.edition}',
              title: 'Hello 算法',
              author: '靳宇栋',
              language: '简体中文',
              edition: query.edition,
              format: '',
              sourceName: '测试书目',
              sourceUri: Uri.https('books.example', '/catalog'),
              availability: '仅查到书目，未取得完整文件',
            ),
          );
        },
      );

      for (
        var attempt = 1;
        attempt <= BookSearchService.maxSearchAttempts;
        attempt++
      ) {
        final criteria = BookSearchQuery(
          title: 'Hello 算法',
          edition: '版本线索 $attempt',
        );
        search.start(
          owner: _owner,
          id: _id,
          query: criteria.displayText,
          criteria: criteria,
        );
        final result = await search.wait(owner: _owner, id: _id);
        expect(result['attemptsUsed'], attempt);
        expect(
          result['attemptsRemaining'],
          BookSearchService.maxSearchAttempts - attempt,
        );
        expect(
          result['candidates'].every((row) => row['importable'] != true),
          isTrue,
        );
      }

      final exhausted = search.start(
        owner: _owner,
        id: _id,
        query: 'Hello 算法 另一个版次',
        criteria: const BookSearchQuery(title: 'Hello 算法', edition: '另一版'),
      );
      expect(exhausted['exhausted'], isTrue);
      expect(exhausted['attemptsUsed'], 5);
      expect(dispatches, 5);
    },
  );

  test('original user edition, language and format survive a retry', () async {
    final original = BookSearchQuery.constraintsFromUserText(
      '我写 Java，想离线看 krahets 的 Hello 算法，不想用 PDF，请找简中 EPUB。',
    );
    final queries = <BookSearchQuery>[];
    final downloaded = <String>[];
    BookSearchCandidate book(String variant, String language, String format) =>
        BookSearchCandidate(
          id: '$variant-$language-$format',
          title: 'Hello 算法 · $variant 版',
          author: '靳宇栋',
          language: language,
          edition: '1.3.0',
          format: format,
          sourceName: '测试来源',
          sourceUri: Uri.https('books.example', '/hello'),
          downloadUri: Uri.https('books.example', '/sample.$format'),
        );
    final search = service(
      find: (query, _) async* {
        queries.add(query);
        yield book('Python', '简体中文', 'epub');
        yield book('Java', '繁體中文', 'epub');
        yield book('Java', '简体中文', 'pdf');
        if (queries.length > 1) yield book('Java', '简体中文', 'epub');
      },
      acquire: (candidate, _) async {
        downloaded.add(candidate.id);
        final temp = await Directory.systemTemp.createTemp('book-edition-');
        return File('${temp.path}/book.epub')
          ..writeAsBytesSync(List<int>.filled(256, 1));
      },
    );

    search.start(
      owner: _owner,
      id: _id,
      query: 'first search',
      criteria: const BookSearchQuery(title: 'Hello 算法'),
      requiredMatch: original,
    );
    final first = await search.wait(owner: _owner, id: _id);
    expect(first['candidates'], isEmpty);
    expect(first['attemptsUsed'], 1);
    expect(downloaded, isEmpty);

    search.start(
      owner: _owner,
      id: _id,
      query: 'different source spelling and wrong filters',
      criteria: const BookSearchQuery(
        title: 'Hello Algo',
        language: '繁體中文',
        format: 'pdf',
        edition: 'Python',
      ),
    );
    final second = await search.wait(owner: _owner, id: _id);
    expect(second['attemptsUsed'], 2);
    expect(second['candidates'], [containsPair('downloadable', true)]);
    expect(downloaded, isEmpty);
    await search.resolve(owner: _owner, id: _id, candidateId: 'Java-简体中文-epub');
    expect(downloaded, ['Java-简体中文-epub']);
    for (final query in queries) {
      expect(query.edition, 'java');
      expect(query.language, '简体中文');
      expect(query.format, 'epub');
    }
    final agent = search.readForAgent(owner: _owner, id: _id);
    expect(agent['attemptedCriteria'], [for (final q in queries) q.toJson()]);
    expect(second, isNot(contains('attemptedCriteria')));
  });

  test('direct searches also require the requested edition', () async {
    final search = service(
      acquire: (_, _) => throw StateError('wrong edition must not download'),
    );
    search.start(owner: _owner, id: _id, query: '《Hello 算法》简体中文 Java PDF');
    final result = await search.wait(owner: _owner, id: _id);
    expect(result['status'], 'complete');
    expect(result['candidates'], isEmpty);

    const digitalId = 'test-book-search-digital';
    final digital = service();
    digital.start(owner: _owner, id: digitalId, query: '《Hello 算法》中文电子版 PDF');
    final digitalResult = await digital.wait(owner: _owner, id: digitalId);
    expect(digitalResult['candidates'], [containsPair('downloadable', true)]);
  });

  test('only explicit version qualifiers become mandatory', () {
    BookSearchQuery constraints(String text) =>
        BookSearchQuery.constraintsFromUserText(text);
    expect(constraints('找一本 Java 教程，PDF 或 EPUB 都行').toJson(), isEmpty);
    expect(constraints('《Hello 算法》1.2.0').edition, '1.2.0');
    expect(constraints('我只接受 1.2.0，不要 1.3.0').edition, '1.2.0');
    expect(constraints('做 PyTorch 练习，找《动手学深度学习》中文第二版 PDF').toJson(), {
      'format': 'pdf',
      'language': '中文',
      'edition': 'pytorch 第2版',
    });
  });

  test(
    'only an owner resolving a verified edition receives the compiled file',
    () async {
      final candidate = BookSearchCandidate(
        id: 'wikisource-zh-11-12',
        title: '吶喊',
        author: '魯迅',
        language: '中文',
        format: 'epub',
        edition: '电子版',
        sourceUri: Uri.https('zh.wikisource.org', '/wiki/吶喊'),
        sourceName: '中文维基文库',
        inlineEpub: true,
      );
      final search = BookSearchService(
        store: store,
        find: (_, _) => Stream.value(candidate),
        acquire: (book, _) async {
          expect(book.id, candidate.id);
          final temp = await Directory.systemTemp.createTemp('wiki-source-');
          return File('${temp.path}/book.epub')
            ..writeAsBytesSync(List<int>.filled(256, 2));
        },
      );
      search.start(owner: _owner, id: _id, query: '呐喊');
      final snapshot = await search.wait(owner: _owner, id: _id);
      final row = (snapshot['candidates'] as List).single as Map;
      expect(row['downloadable'], isTrue);
      expect(row['preparationRequired'], isTrue);
      expect(row['importable'], isFalse);
      expect(row['verified'], isFalse);
      expect(row.containsKey('fileKey'), isFalse);
      expect(
        () => search.resolve(
          owner: 'other:device',
          id: _id,
          candidateId: candidate.id,
        ),
        throwsA(isA<BookSearchException>()),
      );
      final result = await search.resolve(
        owner: _owner,
        id: _id,
        candidateId: candidate.id,
      );
      expect(result['verified'], isTrue);
      expect(result['fileSha256'], hasLength(64));
      final file = search.verifiedFile(
        owner: _owner,
        id: _id,
        candidateId: candidate.id,
      );
      expect(await file.length(), 256);
      expect(
        (search.read(owner: _owner, id: _id)['candidates'] as List).single,
        containsPair('verified', true),
      );
    },
  );

  test(
    'shared in-flight verification stops when the plug-in is disabled',
    () async {
      final entered = Completer<void>();
      final search = service(
        acquire: (candidate, cancellation) async {
          entered.complete();
          await cancellation.whenCancelled;
          final temp = await Directory.systemTemp.createTemp(
            'book-search-source-',
          );
          return File('${temp.path}/book.pdf')
            ..writeAsBytesSync(List<int>.filled(256, 1));
        },
      );
      search.start(owner: _owner, id: _id, query: 'Hello 算法');
      await search.wait(owner: _owner, id: _id);
      final pending = search.resolve(
        owner: _owner,
        id: _id,
        candidateId: _candidate.id,
      );
      final rejected = expectLater(
        pending,
        throwsA(isA<BookSearchException>()),
      );
      await entered.future;
      search.stopOwner(_owner);
      await rejected;
      expect((await search.wait(owner: _owner, id: _id))['status'], 'stopped');
    },
  );

  test('keeps verified versions when another source fails', () async {
    final search = service(
      find: (_, _) async* {
        yield BookSearchCandidate(
          id: 'book-record',
          title: 'Hello 算法',
          author: '靳宇栋',
          language: '简体中文',
          edition: '书目版',
          format: '',
          sourceName: '测试书目',
          sourceUri: Uri.https('books.example', '/catalog'),
          availability: '仅查到书目，未取得完整文件',
        );
        throw StateError('unavailable');
      },
    );
    search.start(owner: _owner, id: _id, query: 'Hello 算法');
    final finalState = await search.wait(owner: _owner, id: _id);
    expect(finalState['status'], 'complete');
    expect(finalState['partial'], isTrue);
    expect(finalState['candidates'], hasLength(1));
  });

  test(
    'discovery never downloads; restart resolves only the selected file',
    () async {
      var acquired = 0;
      final search = service(
        acquire: (_, _) => throw StateError('no prefetch'),
      );
      search.start(owner: _owner, id: _id, query: 'Hello 算法');
      final snapshot = await search.wait(owner: _owner, id: _id);
      final row = (snapshot['candidates'] as List).single as Map;
      expect(row['downloadable'], isTrue);
      expect(row['verified'], isFalse);
      expect(row['importable'], isFalse);
      expect(row, isNot(contains('verifiedAt')));
      expect(row, isNot(contains('fileSha256')));
      expect(row, isNot(contains('downloadUrl')));
      expect(row['candidateToken'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(
        () => search.verifiedFile(
          owner: _owner,
          id: _id,
          candidateId: _candidate.id,
        ),
        throwsA(isA<BookSearchException>()),
      );

      final restarted = service(
        acquire: (candidate, _) async {
          acquired++;
          expect(candidate.downloadUri, _candidate.downloadUri);
          expect(candidate.licenseUri, _candidate.licenseUri);
          final temp = directory.createTempSync('selected-');
          return File('${temp.path}/book.pdf')
            ..writeAsBytesSync(List.filled(256, 3));
        },
      );
      final result = await restarted.resolve(
        owner: _owner,
        id: _id,
        candidateId: _candidate.id,
      );
      expect(result['candidateToken'], row['candidateToken']);
      expect(result['verified'], isTrue);
      expect(result['importable'], isTrue);
      expect(result['fileLength'], 256);
      expect(result, isNot(contains('downloadUrl')));
      expect(result, isNot(contains('fileKey')));
      expect(
        await restarted.resolve(
          owner: _owner,
          id: _id,
          candidateId: _candidate.id,
        ),
        result,
      );
      expect(acquired, 1);
    },
  );

  test('duplicate clicks join one file acquisition', () async {
    var acquired = 0;
    final release = Completer<File>();
    final search = service(
      acquire: (_, _) {
        acquired++;
        return release.future;
      },
    );
    search.start(owner: _owner, id: _id, query: 'Hello 算法');
    await search.wait(owner: _owner, id: _id);
    final first = search.resolve(
      owner: _owner,
      id: _id,
      candidateId: _candidate.id,
    );
    final second = search.resolve(
      owner: _owner,
      id: _id,
      candidateId: _candidate.id,
    );
    expect(acquired, 1);
    final temp = directory.createTempSync('joined-');
    release.complete(
      File('${temp.path}/book.pdf')..writeAsBytesSync(List.filled(256, 7)),
    );
    expect(await first, await second);
    expect(acquired, 1);
  });

  test('closing after discovery prevents a late download action', () async {
    final search = service(
      acquire: (_, _) => throw StateError('must not download'),
    );
    search.start(owner: _owner, id: _id, query: 'Hello 算法');
    await search.wait(owner: _owner, id: _id);
    expect(search.stop(owner: _owner, id: _id)['status'], 'stopped');
    await expectLater(
      search.resolve(owner: _owner, id: _id, candidateId: _candidate.id),
      throwsA(
        isA<BookSearchException>().having((e) => e.statusCode, 'status', 409),
      ),
    );
  });

  test(
    'stop rejects new transfers of a prepared exact file and preserves saved files',
    () async {
      final search = service();
      search.start(owner: _owner, id: _id, query: 'Hello 算法');
      await search.wait(owner: _owner, id: _id);
      await search.resolve(owner: _owner, id: _id, candidateId: _candidate.id);
      final staged = search.verifiedFile(
        owner: _owner,
        id: _id,
        candidateId: _candidate.id,
      );
      final saved = await staged.copy('${directory.path}/user-saved.pdf');
      search.stop(owner: _owner, id: _id);
      expect(
        () => search.verifiedFile(
          owner: _owner,
          id: _id,
          candidateId: _candidate.id,
        ),
        throwsA(
          isA<BookSearchException>().having(
            (error) => error.statusCode,
            'status',
            409,
          ),
        ),
      );
      expect(await saved.length(), 256);
    },
  );

  test(
    'cancelled acquisition discards and removes a late source file',
    () async {
      final release = Completer<File>();
      final search = service(acquire: (_, _) => release.future);
      search.start(owner: _owner, id: _id, query: 'Hello 算法');
      await search.wait(owner: _owner, id: _id);
      final pending = search.resolve(
        owner: _owner,
        id: _id,
        candidateId: _candidate.id,
      );
      final rejected = expectLater(
        pending,
        throwsA(isA<BookSearchException>()),
      );
      search.stop(owner: _owner, id: _id);
      await rejected;
      final temp = directory.createTempSync('late-');
      release.complete(
        File('${temp.path}/book.pdf')..writeAsBytesSync(List.filled(256, 9)),
      );
      for (var i = 0; i < 100 && temp.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(temp.existsSync(), isFalse);
      final row =
          (search.read(owner: _owner, id: _id)['candidates'] as List).single
              as Map;
      expect(row['verified'], isFalse);
      expect(row, isNot(contains('fileSha256')));
      expect(
        () => search.verifiedFile(
          owner: _owner,
          id: _id,
          candidateId: _candidate.id,
        ),
        throwsA(isA<BookSearchException>()),
      );
    },
  );

  test(
    'failed download can retry the same candidate without another search',
    () async {
      var acquired = 0;
      final search = service(
        acquire: (_, _) async {
          if (++acquired == 1) throw const BookSearchException(502, '书源暂时不可用');
          final temp = directory.createTempSync('retry-');
          return File('${temp.path}/book.pdf')
            ..writeAsBytesSync(List.filled(256, 4));
        },
      );
      search.start(owner: _owner, id: _id, query: 'Hello 算法');
      final snapshot = await search.wait(owner: _owner, id: _id);
      final token = (snapshot['candidates'] as List).single['candidateToken'];
      await expectLater(
        search.resolve(owner: _owner, id: _id, candidateId: _candidate.id),
        throwsA(isA<BookSearchException>()),
      );
      final failed =
          (search.read(owner: _owner, id: _id)['candidates'] as List).single
              as Map;
      expect(failed['downloadable'], isTrue);
      expect(BookSearchService.isExactDownloadable(failed), isFalse);
      expect(failed['verified'], isFalse);
      expect(failed['availability'], '书源暂时不可用');
      expect(failed['candidateToken'], token);
      final resolved = await search.resolve(
        owner: _owner,
        id: _id,
        candidateId: _candidate.id,
      );
      expect(resolved['verified'], isTrue);
      expect(resolved['candidateToken'], token);
      expect(acquired, 2);
      expect(search.read(owner: _owner, id: _id)['attemptsUsed'], 1);
    },
  );

  test(
    'preparation timeout cancels upstream and does not authorize a file',
    () async {
      final release = Completer<File>();
      late BookSearchCancellation cancellation;
      final search = service(
        acquire: (_, signal) {
          cancellation = signal;
          return release.future;
        },
        preparationTimeout: const Duration(milliseconds: 10),
      );
      search.start(owner: _owner, id: _id, query: 'Hello 算法');
      await search.wait(owner: _owner, id: _id);
      await expectLater(
        search.resolve(owner: _owner, id: _id, candidateId: _candidate.id),
        throwsA(
          isA<BookSearchException>().having((e) => e.statusCode, 'status', 408),
        ),
      );
      expect(cancellation.isCancelled, isTrue);
      final row =
          (search.read(owner: _owner, id: _id)['candidates'] as List).single
              as Map;
      expect(row['preparationStatus'], 'timed_out');
      expect(row['verified'], isFalse);
      release.completeError(const BookSearchException(409, 'upstream stopped'));
    },
  );

  group('verified same-edition download fallback', () {
    BookSearchCandidate edition(
      String id, {
      String version = '2nd edition',
      String? translator = 'Reader Example',
      String? publisher = 'Example Press',
      String? year = '2025',
      String format = 'pdf',
      String language = '简体中文',
      String? isbn = '9780306406157',
    }) => BookSearchCandidate(
      id: id,
      title: 'Example Book',
      author: 'Example Author',
      edition: version,
      format: format,
      language: language,
      publisher: publisher,
      publicationYear: year,
      isbn: isbn,
      translator: translator,
      sourceName: '$id archive',
      sourceUri: Uri.https('$id.example', '/book'),
      downloadUri: Uri.https('$id.example', '/book.$format'),
    );

    File downloaded() =>
        File('${directory.createTempSync('whole-').path}/book.pdf')
          ..writeAsBytesSync(List.filled(256, 5));

    test(
      'retries only the same edition and persists its real source',
      () async {
        final first = edition('primary');
        final mirror = edition('mirror');
        final attempts = <String>[];
        var searches = 0;
        final search = service(
          find: (query, _) async* {
            if (++searches == 1) {
              yield first;
              return;
            }
            expect(query.title, 'Example Book');
            expect(query.language, '简体中文');
            expect(query.format, 'pdf');
            yield first;
            yield edition('wrong-version', version: '3rd edition');
            yield edition('wrong-translator', translator: 'Other Translator');
            yield edition('wrong-language', language: '繁體中文');
            yield edition('wrong-format', format: 'epub');
            yield edition('wrong-isbn', isbn: '9780140328721');
            yield mirror;
          },
          acquire: (candidate, _) async {
            attempts.add(candidate.id);
            if (candidate.id == first.id) {
              throw const FormatException('文件下载不完整');
            }
            return downloaded();
          },
        );
        search.start(owner: _owner, id: _id, query: 'Example Book');
        await search.wait(owner: _owner, id: _id);
        Future<Map<String, dynamic>> resolve() =>
            search.resolve(owner: _owner, id: _id, candidateId: first.id);
        final results = await Future.wait([resolve(), resolve()]);
        expect(attempts, [first.id, mirror.id]);
        expect(searches, 2);
        for (final resolved in results) {
          expect(resolved['id'], first.id);
          expect(resolved['sourceUrl'], mirror.sourceUri.toString());
          expect(resolved['sourceName'], mirror.sourceName);
          expect(resolved['verified'], isTrue);
          expect(resolved, isNot(contains('downloadUrl')));
        }
        final snapshot = search.read(owner: _owner, id: _id);
        final candidate = (snapshot['candidates'] as List).single;
        expect(candidate['sourceUrl'], mirror.sourceUri.toString());
        expect(snapshot['attemptsUsed'], 1);
        expect(
          search
              .verifiedFile(owner: _owner, id: _id, candidateId: first.id)
              .readAsBytesSync(),
          List.filled(256, 5),
        );
        expect((await resolve())['sourceUrl'], mirror.sourceUri.toString());
        expect(attempts, [first.id, mirror.id]);
      },
    );

    test('uses a proven mirror when the first transfer stalls', () async {
      final first = edition('primary');
      final mirror = edition('mirror');
      final release = Completer<File>();
      late BookSearchCancellation stalledTransfer;
      final search = service(
        find: (_, _) async* {
          yield first;
          yield mirror;
        },
        acquire: (candidate, cancellation) async {
          if (candidate.id == first.id) {
            stalledTransfer = cancellation;
            cancellation.whenCancelled.then(
              (_) => release.completeError(
                const BookSearchException(409, 'upstream stopped'),
              ),
            );
            return release.future;
          }
          return downloaded();
        },
        preparationTimeout: const Duration(seconds: 1),
      );
      search.start(owner: _owner, id: _id, query: 'Example Book');
      await search.wait(owner: _owner, id: _id);
      final resolved = await search.resolve(
        owner: _owner,
        id: _id,
        candidateId: first.id,
      );
      expect(stalledTransfer.isCancelled, isTrue);
      expect(resolved['sourceUrl'], mirror.sourceUri.toString());
    });

    test('stops substitute discovery when the user closes search', () async {
      final first = edition('primary');
      final discovery = Completer<BookSearchCancellation>();
      final attempts = <String>[];
      var searches = 0;
      final search = service(
        find: (_, cancellation) async* {
          if (++searches == 1) {
            yield first;
            return;
          }
          discovery.complete(cancellation);
          await cancellation.whenCancelled;
          yield edition('too-late');
        },
        acquire: (candidate, _) async {
          attempts.add(candidate.id);
          throw const BookSearchException(502, '书源暂时不可用');
        },
      );
      search.start(owner: _owner, id: _id, query: 'Example Book');
      await search.wait(owner: _owner, id: _id);
      final resolving = expectLater(
        search.resolve(owner: _owner, id: _id, candidateId: first.id),
        throwsA(
          isA<BookSearchException>().having((e) => e.statusCode, 'status', 409),
        ),
      );
      final cancellation = await discovery.future;
      search.stop(owner: _owner, id: _id);
      await resolving;
      expect(cancellation.isCancelled, isTrue);
      expect(attempts, [first.id]);
      expect(search.read(owner: _owner, id: _id)['status'], 'stopped');
    });
  });
}
