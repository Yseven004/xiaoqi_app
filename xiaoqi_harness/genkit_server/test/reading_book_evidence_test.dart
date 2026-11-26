import 'package:test/test.dart';
import 'package:xiaoqi_genkit_server/src/reading_book_evidence.dart';

void main() {
  final revision = List.filled(64, 'a').join();

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
}
