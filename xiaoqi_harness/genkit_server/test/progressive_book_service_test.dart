import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/progressive_book_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

class _Worker implements BookWorker {
  _Worker(this.units, this.emit);

  final List<Map<String, dynamic>> units;
  final Future<void> Function(List<int>, void Function(Map<String, dynamic>))
  emit;

  @override
  Future<Map<String, dynamic>> catalog() async => {
    'type': 'catalog',
    'units': units,
    'sections': [],
  };

  @override
  Future<void> batch(
    List<int> ids,
    void Function(Map<String, dynamic>) onUnit,
  ) => emit(ids, onUnit);

  @override
  void stop() {}

  @override
  Future<void> close() async {}
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var i = 0; i < 400; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Book did not finish in the allotted time');
}

void main() {
  late Directory root;
  late File original;
  late CloudStore store;
  late Database db;
  late ProgressiveBookService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reading-book-test-');
    original = await File(
      p.join(root.path, 'fixture'),
    ).writeAsString('original');
    store = CloudStore(root: p.join(root.path, 'store'));
    db = sqlite3.open(store.database.path);
  });

  tearDown(() async {
    await service.close();
    db.close();
    store.close();
    await root.delete(recursive: true);
  });

  test('publishes sparse evidence and prioritizes the newest chapter', () async {
    final first = Completer<void>();
    final second = Completer<void>();
    final advance = Completer<void>();
    final finish = Completer<void>();
    final batches = <List<int>>[];
    service = ProgressiveBookService(
      store,
      db,
      workerFactory: (_, _) async => _Worker(
        [
          for (var i = 1; i <= 8; i++)
            {'id': i, 'item_id': 'c$i', 'href': 'c$i.xhtml', 'locator': '章$i'},
        ],
        (ids, emit) async {
          batches.add(ids);
          if (batches.length == 1) {
            first.complete();
            await advance.future;
          }
          if (batches.length == 2) {
            second.complete();
            await finish.future;
          }
          for (final id in ids) {
            emit({
              'id': id,
              'status': 'ready',
              'locator': '第$id章',
              'markdown': id == 1
                  ? '滑铁卢大学和女王大学都是她的候选。\n\n这两所大学吸引了她。'
                  : '目录段落参考编号$id。',
            });
          }
        },
      ),
    );
    final record = await service.ingest(
      tenant: 'a',
      bookKey: 'book',
      version: 'v1',
      format: 'epub',
      original: original,
    );
    final id = record['id'] as String;
    try {
      await first.future.timeout(const Duration(seconds: 4));
      expect(
        service.prioritize(
          'a',
          id,
          instance: 'reader',
          sequence: 1,
          chapterId: 'c3',
        ),
        isTrue,
      );
      expect(
        service.prioritize(
          'a',
          id,
          instance: 'reader',
          sequence: 3,
          chapterId: 'epub:c7',
        ),
        isTrue,
      );
      service.prioritize(
        'a',
        id,
        instance: 'reader',
        sequence: 2,
        chapterId: 'c4',
      );
      advance.complete();
      await second.future.timeout(const Duration(seconds: 4));
      expect(batches[0], [1]);
      expect(batches[1].first, 7);
      expect(service.status('a', id)?['completed_units'], [1]);
      expect(service.search('b', id, query: '滑铁卢'), isNull);
      final evidence = service.search('a', id, query: '滑铁卢大学')!;
      expect(evidence['coverage'], 'partial');
      expect(evidence['search_status'], 'matched');
      expect((evidence['matches'] as List).single['locator'], '第1章');
      expect(
        service.search('a', id, query: '女王', chapterId: 'c1')?['search_status'],
        'matched',
      );
      final contextual = service.search(
        'a',
        id,
        selection: '这两所大学吸引了她。',
        chapterId: 'c1',
        query: '不能命中的问题',
      )!;
      expect(contextual['search_status'], 'no_match');
      expect(
        (contextual['nearby_context'] as List).single['quote'],
        contains('滑铁卢'),
      );
      expect(
        service.search('a', id, chapterId: 'c7')?['search_status'],
        'not_ready',
      );
    } finally {
      if (!advance.isCompleted) advance.complete();
      if (!finish.isCompleted) finish.complete();
    }
    await _waitFor(() => service.status('a', id)?['status'] == 'complete');
    expect(service.lookup('a', 'book', 'v1')?['completed_units'], [
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
    ]);
    expect(await service.revoke('a', id), isTrue);
    expect(service.search('a', id, query: '滑铁卢'), isNull);
    expect(
      db.select('SELECT count(*) AS n FROM reading_book_passages').single['n'],
      0,
    );
    expect(
      db.select(
        "SELECT rowid FROM reading_book_fts WHERE reading_book_fts MATCH '滑铁卢'",
      ),
      isEmpty,
    );
  });

  test('distinguishes skipped and unready explicit PDF pages', () async {
    final advance = Completer<void>();
    final second = Completer<void>();
    service = ProgressiveBookService(
      store,
      db,
      workerFactory: (_, _) async => _Worker(
        [
          {'id': 1, 'page': 1, 'locator': '第1页'},
          {'id': 2, 'page': 2, 'locator': '第2页'},
          {'id': 3, 'page': 3, 'locator': '第3页'},
        ],
        (ids, emit) async {
          if (!ids.contains(1)) {
            second.complete();
            await advance.future;
          }
          for (final id in ids) {
            emit({
              'id': id,
              'status': id == 3 ? 'no_text' : 'ready',
              if (id != 3) 'markdown': '有文字的第$id页。',
            });
          }
        },
      ),
    );
    final record = await service.ingest(
      tenant: 'a',
      bookKey: 'book',
      version: 'v1',
      format: 'pdf',
      original: original,
    );
    final id = record['id'] as String;
    try {
      await second.future.timeout(const Duration(seconds: 4));
      expect(
        service.search('a', id, pages: [2])?['search_status'],
        'not_ready',
      );
      expect(service.search('a', id, pages: [1])?['search_status'], 'matched');
      final read = service.readUnitBatch('a', id, units: [1, 2])!;
      expect(read['read_pages'], [1]);
      expect(read['source_text_truncated'], isTrue);
      expect(read['text'], contains('有文字的第1页。'));
    } finally {
      advance.complete();
    }
    await _waitFor(() => service.status('a', id)?['status'] == 'complete');
    expect(service.search('a', id, pages: [3])?['search_status'], 'no_text');
    expect(service.search('a', id, page: 3)?['search_status'], 'no_text');
    final complete = service.readUnitBatch('a', id, units: [1, 2, 3])!;
    expect(complete['read_pages'], [1, 2]);
    expect(complete['skipped_units'], [3]);
    expect(complete['source_text_truncated'], isFalse);
  });

  test(
    'retry after shutdown reuses committed passages and immutable identity',
    () async {
      final units = [
        {'id': 1, 'page': 1, 'locator': '第1页'},
        {'id': 2, 'page': 2, 'locator': '第2页'},
      ];
      service = ProgressiveBookService(
        store,
        db,
        workerFactory: (_, _) async => _Worker(units, (ids, emit) async {
          if (ids.first != 1) throw const FormatException('simulated crash');
          emit({'id': 1, 'status': 'ready', 'markdown': '应保留的正文。'});
        }),
      );
      Future<Map<String, dynamic>> upload({bool Function()? isAllowed}) =>
          service.ingest(
            tenant: 'a',
            bookKey: 'book',
            version: 'v1',
            format: 'pdf',
            original: original,
            isAllowed: isAllowed,
          );
      await expectLater(upload(isAllowed: () => false), throwsStateError);
      expect(service.lookup('a', 'book', 'v1'), isNull);
      final id = (await upload())['id'] as String;
      await _waitFor(() => service.status('a', id)?['status'] == 'failed');
      expect(
        service.search('a', id, query: '保留的正文')?['search_status'],
        'matched',
      );
      await service.close();

      final parsed = <int>[];
      service = ProgressiveBookService(
        store,
        db,
        workerFactory: (_, _) async => _Worker(units, (ids, emit) async {
          for (final unit in ids) {
            parsed.add(unit);
            emit({'id': unit, 'status': 'ready', 'markdown': '重试后可查。'});
          }
        }),
      );
      expect((await upload())['id'], id);
      await _waitFor(() => service.status('a', id)?['status'] == 'complete');
      expect(parsed, [2]);
      expect(
        service.search('a', id, query: '保留的正文')?['search_status'],
        'matched',
      );
      expect(
        service.search('a', id, query: '重试后可查')?['search_status'],
        'matched',
      );
      await original.writeAsString('a different original');
      await expectLater(upload(), throwsFormatException);
      expect(service.status('a', id)?['completed_units'], [1, 2]);
    },
  );
}
