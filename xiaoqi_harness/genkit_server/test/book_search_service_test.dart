import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
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
    BookSearchVerifier? verify,
    Duration timeout = const Duration(seconds: 2),
  }) => BookSearchService(
    store: store,
    find: find ?? (_, _) => Stream.value(_candidate),
    verify: verify ?? (_, _) async => _candidate.downloadUri!,
    searchTimeout: timeout,
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
          yield _candidate;
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
      final resolved = await search.resolve(
        owner: _owner,
        id: _id,
        candidateId: _candidate.id,
      );
      expect(resolved['downloadUrl'], _candidate.downloadUri.toString());
      expect(resolved['edition'], 'Python 版');
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
        () => restarted.start(owner: _owner, id: _id, query: '另一部作品'),
        throwsA(
          isA<BookSearchException>().having((e) => e.statusCode, 'status', 409),
        ),
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
        verify: (_, _) =>
            throw StateError('Only direct downloads need an external file URL'),
        buildEpub: (book, _) async {
          expect(book.id, candidate.id);
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      search.start(owner: _owner, id: _id, query: '呐喊');
      final snapshot = await search.wait(owner: _owner, id: _id);
      final row = (snapshot['candidates'] as List).single as Map;
      expect(row['importable'], isTrue);
      expect(row.containsKey('epubBase64'), isFalse);
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
      expect(result['epubBase64'], 'AQID');
      expect(result['sha256'], hasLength(64));
      expect(search.read(owner: _owner, id: _id), snapshot);
    },
  );

  test(
    'shared in-flight verification stops when the plug-in is disabled',
    () async {
      final entered = Completer<void>();
      final search = service(
        verify: (candidate, cancellation) async {
          entered.complete();
          await cancellation.whenCancelled;
          return candidate.downloadUri!;
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
      expect(identical(first, second), isTrue);
      final rejected = expectLater(
        first,
        throwsA(
          isA<BookSearchException>().having((e) => e.statusCode, 'status', 403),
        ),
      );
      await entered.future;
      search.stopOwner(_owner);
      await rejected;
    },
  );

  test('keeps verified versions when another source fails', () async {
    final search = service(
      find: (_, _) async* {
        yield _candidate;
        throw StateError('unavailable');
      },
    );
    search.start(owner: _owner, id: _id, query: 'Hello 算法');
    final finalState = await search.wait(owner: _owner, id: _id);
    expect(finalState['status'], 'complete');
    expect(finalState['partial'], isTrue);
    expect(finalState['candidates'], hasLength(1));
  });
}
