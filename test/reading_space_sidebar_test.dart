import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';
import 'package:xiaoqi_app/models/book_library_item.dart';
import 'package:xiaoqi_app/models/book_library_query.dart';
import 'package:xiaoqi_app/models/book_recognition.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/reading_task_context.dart';
import 'package:xiaoqi_app/widgets/reading_space_sidebar.dart';

void main() {
  testWidgets(
    'companion history dates follow use and excerpts fit one line at 200% text',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final history = AiConversationHistoryService(
        preferences: await SharedPreferences.getInstance(),
      );
      final excerpt = '窗外的原文\n第二行很长，需要在窄屏上省略结尾';
      final oldDate = DateTime(2025, 3, 8);
      final newerDate = DateTime(2025, 3, 9);
      final openDate = DateTime(2025, 3, 10);
      for (final fromPassage in [false, true]) {
        final sent = fromPassage ? oldDate : newerDate;
        await history.save(
          AiConversationRecord(
            id: fromPassage ? 'passage' : 'free',
            title: fromPassage ? '关于景物的提问' : '全书结构',
            bookId: 1,
            bookName: '测试书',
            readingCompanion: true,
            createdAt: sent,
            updatedAt: sent,
            companionOpenedAt: fromPassage ? openDate : null,
            messages: [
              AiConversationMessage(
                isUser: true,
                text: '怎么理解？',
                createdAt: sent,
                readingPassage: fromPassage
                    ? readingPassageMarkdown(
                        source: '测试书.epub',
                        locator: '章节一',
                        text: excerpt,
                      )
                    : null,
              ),
            ],
          ),
        );
      }
      await tester.binding.setSurfaceSize(const Size(320, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      AiConversationRecord? opened;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: ReadingSpaceSidebar(
              companionMode: true,
              historyService: history,
              bookLibraryService: _Library(),
              onOpenConversation: (record) => opened = record,
              onOpenBook: (_) {},
              onOpenLibrary: () {},
              onNewConversation: () {},
              onOpenExtensionMarket: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('展开测试书'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('对话记录'));
      await tester.pumpAndSettle();
      final quote = find.text(excerpt.replaceAll('\n', ' '));
      final title = find.text('关于景物的提问');
      final nextDate = find.text('2025年3月9日');
      expect(quote, findsOneWidget);
      expect(tester.widget<Text>(quote).maxLines, 1);
      expect(tester.widget<Text>(quote).overflow, TextOverflow.ellipsis);
      expect(
        tester.getTopLeft(title).dy,
        greaterThan(tester.getTopLeft(find.text('2025年3月10日')).dy),
      );
      expect(
        tester.getTopLeft(quote).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
      );
      expect(
        tester.getTopLeft(nextDate).dy,
        greaterThan(tester.getTopLeft(quote).dy),
      );
      expect(
        tester.getTopLeft(find.text('全书结构')).dy,
        greaterThan(tester.getTopLeft(nextDate).dy),
      );
      expect(find.text('2025年3月8日'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.bySemanticsLabel('搜索阅读空间'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '窗外');
      await tester.pumpAndSettle();
      expect(title.hitTestable(), findsOneWidget);
      expect(quote.hitTestable(), findsOneWidget);
      expect(find.text('全书结构').hitTestable(), findsNothing);
      await tester.tap(title.hitTestable());
      expect(opened?.id, 'passage');
      expect(tester.takeException(), isNull);
    },
  );
}

class _Library extends BookLibraryService {
  @override
  Future<List<BookLibraryItem>> listBooks({
    BookLibraryQuery query = const BookLibraryQuery(),
  }) async => const [
    BookLibraryItem(
      book: BookRecord(id: 1, title: '测试书'),
      noteCount: 0,
      recognizedPageCount: 0,
      activeDaysInLast30Days: 0,
      isPinned: false,
      categories: [],
    ),
  ];
}
