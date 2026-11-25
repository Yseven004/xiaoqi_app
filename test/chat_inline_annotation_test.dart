import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:xiaoqi_app/models/chat_annotation.dart';
import 'package:xiaoqi_app/widgets/chat_annotated_markdown.dart';
import 'package:xiaoqi_app/widgets/chat_annotation_controls.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    String text,
    List<ChatAnnotation> annotations, {
    double width = 300,
    void Function(ChatAnnotation, Offset)? onTap,
    void Function(String, String)? onLink,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: ChatTextAnnotationLayer(
                annotations: annotations,
                annotationNumbers: {
                  for (var i = 0; i < annotations.length; i++)
                    annotations[i].id: i + 1,
                },
                onTapAnnotation: onTap ?? (_, _) {},
                child: SelectionArea(
                  child: Container(
                    key: const ValueKey('source'),
                    child: ChatAnnotatedMarkdown(
                      markdown: GptMarkdown(
                        text,
                        style: const TextStyle(fontSize: 16, height: 1.55),
                        animation: GptMarkdownAnimation.none,
                        isStreaming: false,
                        blockAnimation: GptMarkdownBlockAnimation.none,
                        useDollarSignsForLatex: false,
                        onLinkTap: onLink,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  List<Rect> boxes(WidgetTester tester, ChatAnnotation annotation) {
    final root = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('source')),
    );
    return chatTextQuoteBoxes(
      root,
      annotation,
    ).map((r) => r.shift(root.localToGlobal(Offset.zero))).toList();
  }

  testWidgets(
    'full line reserves real space and reflows without covering any text',
    (tester) async {
      const a = ChatAnnotation(id: 'a', quote: '目标文字', startOffset: 8);
      const text = '这是前面的内容。目标文字。这里继续未选中的正文。';
      await show(tester, text, [a], width: 150);
      final pin = tester.getRect(find.byType(ChatInlineAnnotationPin));
      for (final box in boxes(
        tester,
        const ChatAnnotation(id: 'all', quote: text),
      )) {
        expect(pin.overlaps(box), isFalse, reason: '$pin overlaps $box');
      }
      expect(find.byType(ChatInlineAnnotationPin), findsOneWidget);
      expect(boxes(tester, a), isNotEmpty);
    },
  );

  testWidgets('old rendered offsets choose the second repeated quote', (
    tester,
  ) async {
    const a = ChatAnnotation(id: 'a', quote: '重复片段', startOffset: 10);
    await show(tester, '重复片段在前。\n\n重复片段在后。', [a]);
    final pin = tester.getRect(find.byType(ChatInlineAnnotationPin));
    final selected = boxes(tester, a).last;
    expect((pin.center.dy - selected.center.dy).abs(), lessThan(5));
    expect(pin.left, greaterThanOrEqualTo(selected.right));
    final first = boxes(
      tester,
      const ChatAnnotation(id: 'first', quote: '重复片段', startOffset: 0),
    ).last;
    expect(pin.top, greaterThan(first.bottom));
  });

  testWidgets('two annotations ending on the same line occupy distinct slots', (
    tester,
  ) async {
    const one = ChatAnnotation(id: 'one', quote: '同一段', startOffset: 0);
    const two = ChatAnnotation(id: 'two', quote: '段', startOffset: 2);
    String? opened;
    await show(tester, '同一段文字继续。', [one, two], onTap: (a, _) => opened = a.id);
    final first = find.byKey(const ValueKey('inline-annotation:one'));
    final second = find.byKey(const ValueKey('inline-annotation:two'));
    expect(tester.getRect(first).overlaps(tester.getRect(second)), isFalse);
    await tester.tap(second);
    expect(opened, 'two');
  });

  testWidgets(
    'emphasis links and inline code survive insertion and link remains tappable',
    (tester) async {
      const a = ChatAnnotation(id: 'a', quote: '强调链接', startOffset: 2);
      String? opened;
      String? url;
      await show(
        tester,
        '前文 **强调[链接](https://example.com)** 与 `code`。',
        [a],
        onTap: (a, _) => opened = a.id,
        onLink: (value, _) => url = value,
      );
      expect(boxes(tester, a), isNotEmpty);
      final link = boxes(
        tester,
        const ChatAnnotation(id: 'link', quote: '链接'),
      ).first;
      await tester.tapAt(link.center);
      expect(url, 'https://example.com');
      await tester.tap(find.byType(ChatInlineAnnotationPin));
      expect(opened, 'a');
      final paragraphs = tester
          .renderObjectList<RenderObject>(
            find.byWidgetPredicate((widget) => widget is RenderObjectWidget),
          )
          .whereType<RenderParagraph>();
      expect(
        paragraphs.any(
          (p) => p is InlineCodeDecoration && p.inlineCodeRuns.isNotEmpty,
        ),
        isTrue,
      );
      final text = paragraphs
          .map((p) => p.text.toPlainText(includePlaceholders: false))
          .join();
      expect(text, contains('强调链接'));
      expect(text, isNot(contains('**')));
    },
  );

  testWidgets(
    'heading and list quotes use official block rebuilding and remain locatable',
    (tester) async {
      const a = ChatAnnotation(id: 'a', quote: '列表目标', startOffset: 4);
      await show(tester, '## 标题\n\n- 列表目标\n- 下一项\n\n普通正文', [a]);
      expect(find.byType(ChatInlineAnnotationPin), findsOneWidget);
      expect(boxes(tester, a), isNotEmpty);
      final pin = tester.getRect(find.byType(ChatInlineAnnotationPin));
      expect(pin.overlaps(boxes(tester, a).last), isFalse);
    },
  );

  testWidgets('messages without annotations retain original markdown widget', (
    tester,
  ) async {
    await show(tester, '**原有消息**', []);
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(find.byType(ChatInlineAnnotationPin), findsNothing);
  });

  testWidgets(
    'opaque code quote keeps highlight without an overlapping fallback pin',
    (tester) async {
      const a = ChatAnnotation(
        id: 'code',
        quote: 'print(value);',
        startOffset: 0,
      );
      await show(tester, '```dart\nprint(value);\n```', [a]);
      expect(find.byType(ChatInlineAnnotationPin), findsNothing);
      expect(find.byType(ChatAnnotationPin), findsNothing);
      expect(boxes(tester, a), isNotEmpty);
    },
  );

  testWidgets(
    'quote across paragraphs has the same concatenated selectable offsets',
    (tester) async {
      const a = ChatAnnotation(id: 'cross', quote: '第一段第二段', startOffset: 0);
      await show(tester, '第一段\n\n第二段', [a]);
      expect(find.byType(ChatInlineAnnotationPin), findsOneWidget);
      expect(boxes(tester, a).length, greaterThanOrEqualTo(2));
    },
  );
}
