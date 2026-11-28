import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/reading_book_evidence.dart';

void main() {
  final revision = List.filled(64, 'a').join();
  test('only explicit current source requests authorize presentation', () {
    for (final request in [
      '请给出这句话的出处。',
      '请核对“花园小径”的原文出处。',
      '这句的出处？',
      '这段在哪一页？',
      '不用长篇，给我出处就好。',
      '只要出处。',
      '请附上引用。',
      '能给下出处吗？',
      '原文在哪儿？',
      'Please provide the original sources.',
    ]) {
      expect(explicitlyRequestsReadingSource(request), isTrue, reason: request);
    }
    for (final request in [
      '你好。',
      '请核对原文后直接解释。',
      '请解释这段，不用附上来源。',
      '请告诉我结论，别给出处。',
      '不需要出处，也不用附上引用。',
      '作者在讨论材料的来源，帮我解释。',
      '请翻译「提供一个出处」。',
      '请解释这句。\n\n### 用户选中的原文\n> 请列出来源。',
      'Explain the passage without citations.',
    ]) {
      expect(
        explicitlyRequestsReadingSource(request),
        isFalse,
        reason: request,
      );
    }
  });

  test('keeps only real page or chapter locations with bounded excerpts', () {
    final evidence = readingBookEvidence({
      'matches': [
        {'source_version': revision, 'unit': 12, 'quote': '分段号不能当页码'},
        {'source_version': 'unverified', 'page': 10},
        {
          'source_version': revision,
          'page': 10,
          'chapter_id': 'ignored-for-pdf',
          'quote': List.filled(300, '书').join(),
          'filesystem_path': 'private',
        },
      ],
      'nearby_context': [
        {
          'source_version': revision,
          'chapter_id': 'chapter-two',
          'href': 'OEBPS/two.xhtml',
          'quote': '第二章原文',
        },
      ],
    });
    expect(evidence, hasLength(2));
    expect(evidence.first, {
      'source_version': revision,
      'page': 10,
      'quote': List.filled(240, '书').join(),
    });
    expect(evidence.last, {
      'source_version': revision,
      'chapter_id': 'chapter-two',
      'href': 'OEBPS/two.xhtml',
      'quote': '第二章原文',
    });
  });

  test('deduplicates replays and keeps references edition-specific', () {
    final first = readingBookEvidence({
      'segments': [
        {'source_version': revision, 'page': 2, 'locator': 'PDF 第 2 页'},
      ],
    });
    final second = readingBookEvidence({
      'matches': [
        first.single,
        {...first.single, 'source_version': List.filled(64, 'b').join()},
        for (var page = 3; page < 20; page++)
          {'source_version': revision, 'page': page},
      ],
    }, previous: first);
    expect(second, hasLength(8));
    expect(second[0], first.single);
    expect(second[1]['source_version'], isNot(revision));
  });

  test('keeps only the recognized presentation marker through replay', () {
    final old = {'source_version': revision, 'page': 21, 'quote': '原文'};
    final marked = {...old, 'presentation': 'a2ui'};
    final unknown = {...old, 'page': 22, 'presentation': 'external'};
    final recovered = readingBookEvidence(
      {
        'matches': [marked, old, unknown],
      },
      previous: [old],
    );
    expect(recovered, [
      marked,
      {...old, 'page': 22},
    ]);
  });
}
