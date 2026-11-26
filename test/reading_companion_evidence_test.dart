import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/models/reading_companion_evidence.dart';
import 'package:xiaoqi_app/models/xiaoqi_document.dart';

void main() {
  final version = 'a' * 64;
  final pdf = {'source_version': version, 'page': 17, 'quote': '真实原文'};
  final chapter = {
    'source_version': version,
    'chapter_id': 'discussion',
    'href': 'book/discussion.xhtml',
    'quote': '港口开始开放',
  };

  test('only well-formed original locators survive persistence', () {
    final evidence = ReadingCompanionEvidence.fromPayload([
      {'source_version': 'missing', 'page': 1},
      {...pdf, 'page': -1},
      {...pdf, 'chapter_id': 'intro'},
      pdf,
      pdf,
      chapter,
    ]);
    expect(evidence, hasLength(2));
    final message = AiConversationMessage(
      text: '答复',
      isUser: false,
      createdAt: DateTime(2026),
      readingEvidence: evidence,
    );
    final restored = AiConversationMessage.fromJson(message.toJson());
    expect(restored.readingEvidence.map((entry) => entry.toJson()), [
      {...pdf, 'locator': ''},
      {...chapter, 'locator': ''},
    ]);
    BookSourceRecord source(String hash, String format) => BookSourceRecord(
      id: 1,
      bookId: 1,
      kind: 'file',
      displayName: 'source',
      filePath: '',
      fileSize: 1,
      contentHash: hash,
      status: 'ready',
      format: format,
      createdAt: '',
      updatedAt: '',
    );
    expect(evidence.first.matchesSource(source(version, 'pdf')), isTrue);
    expect(evidence.first.matchesSource(source('b' * 64, 'pdf')), isFalse);
    expect(evidence.first.matchesSource(source(version, 'epub')), isFalse);
  });

  test(
    'EPUB match requires agreement and a unique local quote to highlight',
    () {
      final evidence = ReadingCompanionEvidence.fromJson(chapter)!;
      XiaoqiDocumentChapter fixture(String href, List<String> paragraphs) =>
          XiaoqiDocumentChapter(
            id: 'epub:discussion',
            title: '港口',
            href: href,
            html: '',
            plainText: paragraphs.join(),
            order: 0,
            blocks: [
              for (final (index, text) in paragraphs.indexed)
                XiaoqiDocumentBlock(
                  id: 'b$index',
                  kind: 'paragraph',
                  text: text,
                ),
            ],
          );
      XiaoqiDocument document(XiaoqiDocumentChapter chapter) => XiaoqiDocument(
        format: 'epub',
        title: '本书',
        author: '',
        language: 'zh',
        chapters: [chapter],
      );
      final unique = fixture('book/discussion.xhtml', ['港口\n开始开放。']);
      expect(evidence.resolveChapter(document(unique)), same(unique));
      expect(resolveReadingEvidenceBlock(unique, evidence.quote), (
        blockId: 'b0',
        start: 0,
        end: 7,
      ));
      final conflicting = fixture('book/other.xhtml', ['港口开始开放']);
      expect(evidence.resolveChapter(document(conflicting)), isNull);
      final repeated = fixture('book/discussion.xhtml', ['港口开始开放', '港口开始开放']);
      expect(resolveReadingEvidenceBlock(repeated, evidence.quote), isNull);
      expect(
        uniqueReadingEvidenceRange('港口开始开放港口开始开放', evidence.quote),
        isNull,
      );
    },
  );
}
