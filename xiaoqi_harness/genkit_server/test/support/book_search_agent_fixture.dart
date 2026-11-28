import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xiaoqi_genkit_server/src/agent_runtime.dart';
import 'package:xiaoqi_genkit_server/src/book_search_plugin.dart';
import 'package:xiaoqi_genkit_server/src/book_search_service.dart';
import 'package:xiaoqi_genkit_server/src/image_service.dart';
import 'package:xiaoqi_genkit_server/src/store.dart';

Future<void> main(List<String> args) async {
  final temp = await Directory.systemTemp.createTemp('xiaoqi-book-agent-');
  final store = CloudStore(root: temp.path);
  const owner = 'device/personal/book-search-test';
  const search = 'test-book-search-turn';
  const task = 'book-search-agent-turn';
  const userText = '帮我找《Hello 算法》1.2.0';
  store.put(owner, {}, null);
  store.put('task/personal/$task', {
    'status': 'running',
    'artifacts': [],
  }, null);
  var attempts = 0;
  var acquisitions = 0;
  final ordinary = args.contains('ordinary');
  final alternate = args.contains('alternate');
  final downloadable = alternate || args.contains('downloadable');
  final correction = args.contains('correction');
  final plugin = BookSearchPlugin(
    store,
    find: (query, cancellation) async* {
      attempts++;
      if (correction) {
        cancellation.report({
          'source': 'books.example',
          'stage': 'extract',
          'reason': 'no_matching_book_file_evidence',
        });
      }
      if (alternate && attempts > 1) return;
      yield BookSearchCandidate(
        id: alternate ? 'verified-alternate' : 'catalog-$attempts',
        title: 'Hello 算法',
        author: '靳宇栋',
        language: '简体中文',
        edition: alternate ? '1.3.0' : query.edition,
        format: downloadable ? 'pdf' : '',
        sourceName: '测试书目',
        sourceUri: Uri.https('books.example', '/catalog/$attempts'),
        availability: downloadable ? null : '仅查到书目，未取得完整文件',
        downloadUri: downloadable
            ? Uri.https('books.example', '/book.pdf')
            : null,
        alternateEdition: alternate,
      );
    },
    inspect: correction
        ? (source, query, cancellation) async* {
            if (source != Uri.https('books.example', '/catalog/1')) {
              throw StateError('Unexpected source');
            }
            yield BookSearchCandidate(
              id: 'checked-release',
              title: 'Hello 算法',
              author: '靳宇栋',
              language: '简体中文',
              edition: query.edition,
              format: 'pdf',
              sourceName: '测试原始来源',
              sourceUri: source,
              downloadUri: Uri.https('books.example', '/verified.pdf'),
            );
          }
        : null,
    acquire: (_, _) async {
      acquisitions++;
      final directory = await Directory.systemTemp.createTemp(
        'book-agent-file-',
      );
      return File('${directory.path}/book.pdf')
        ..writeAsBytesSync(List<int>.filled(256, 1));
    },
  );
  final runtime = GenkitXiaoqiAgentRuntime(
    store,
    ImageService(store),
    bookSearch: plugin,
  );
  final events = <Map<String, Object?>>[];
  try {
    if (args.firstOrNull == 'reading-citations') {
      const account = 'fixture-account';
      const bookId = 'ready-book';
      _seedReadyBook(store, readingBookOwner('personal', account), bookId);
      final captured = <Map<String, Object?>>[];
      const questions = ['把“花园小径”翻成英文。', '请核对“花园小径”的原文出处。'];
      for (final (index, question) in questions.indexed) {
        final taskId = 'citation-$index';
        store.put('task/personal/$taskId', {
          'status': 'running',
          'annotation_account': account,
        }, null);
        final turnEvents = <Map<String, Object?>>[];
        final result = await runtime.runAgentTurn(
          tenantId: 'personal',
          taskId: taskId,
          request: {
            '_authenticated_device_key': owner,
            '_reading_discussion': true,
            'reasoning_level': 'low',
            'current_turn_text': question,
            'materials': [
              {
                'id': 'fixture-material',
                'reading_book_id': bookId,
                'kind': 'document',
                'name': '测试用书',
              },
            ],
          },
          messages: [
            Message(role: Role.user, content: [TextPart(text: question)]),
          ],
          onChunk: (_) {},
          onProcessEvent: turnEvents.add,
          cancellation: CancellationController().token,
        );
        captured.add({'text': result.text, 'events': turnEvents});
      }
      stdout.writeln('RESULT:${jsonEncode({'turns': captured})}');
      return;
    }
    if (args.firstOrNull == 'reasoning') {
      final turns = (jsonDecode(args[1]) as List).cast<Map>();
      final answers = <String>[];
      for (final (index, turn) in turns.indexed) {
        final taskId = 'reasoning-$index';
        const prompt = '请解释一句话。';
        store.put('task/personal/$taskId', {'status': 'running'}, null);
        final result = await runtime.runAgentTurn(
          tenantId: 'personal',
          taskId: taskId,
          request: {
            '_authenticated_device_key': owner,
            'current_turn_text': prompt,
            ...turn.cast<String, Object?>(),
          },
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: prompt)],
            ),
          ],
          onChunk: (_) {},
          onProcessEvent: (_) {},
          cancellation: CancellationController().token,
        );
        answers.add(result.text);
      }
      stdout.writeln('RESULT:${jsonEncode({'answers': answers})}');
      return;
    }
    final result = await runtime.runAgentTurn(
      tenantId: 'personal',
      taskId: task,
      request: {
        '_authenticated_device_key': owner,
        if (!ordinary) 'book_search_id': search,
        'model_id': 'mimo-v2.6-flash',
        'current_turn_text': userText,
      },
      messages: [
        Message(
          role: Role.user,
          content: [TextPart(text: userText)],
        ),
      ],
      onChunk: (_) {},
      onProcessEvent: events.add,
      cancellation: CancellationController().token,
    );
    final operations = store
        .get('task/personal/$task')
        ?.value['scope_operations'];
    stdout.writeln(
      'RESULT:${jsonEncode({'text': result.text, if (!ordinary) 'search': runtime.bookSearch.searches.read(owner: owner, id: search), 'starts': events.where((event) => event['type'] == 'tool_started' && event['tool'] == 'find_book_material').length, 'attempts': attempts, 'acquisitions': acquisitions, 'operation_count': (operations as Map?)?.length})}',
    );
  } finally {
    store.close();
    await temp.delete(recursive: true);
  }
}

void _seedReadyBook(CloudStore store, String tenant, String bookId) {
  // Stay independent of the optional Python worker while exercising the real
  // SQLite search, authorization and evidence projection on the runtime path.
  store.progressiveBooks.status(tenant, bookId);
  final db = sqlite3.open(store.database.path);
  try {
    final catalog = jsonEncode({
      'units': [
        {'id': 21, 'page': 21, 'locator': 'PDF 第 21 页'},
      ],
    });
    final version = 'b' * 64;
    db.execute('''
      INSERT INTO reading_book_sources
        (id, tenant, book_key, version, format, sha256, original_key,
         generation, status, catalog, updated)
      VALUES (?, ?, ?, ?, 'pdf', ?, 'fixture.pdf', 'test', 'complete', ?, 0)
    ''', [bookId, tenant, 'a' * 64, version, version, catalog]);
    db.execute('''
      INSERT INTO reading_book_units (source, unit, state, bytes)
      VALUES (?, 21, 'ready', 100)
    ''', [bookId]);
    db.execute('''
      INSERT INTO reading_book_passages (source, unit, part, locator, quote, searchable)
      VALUES (?, 21, 0, 'PDF 第 21 页', '沿着花园小径走到了门口。', '沿着花园小径走到了门口。')
    ''', [bookId]);
  } finally {
    db.close();
  }
}
