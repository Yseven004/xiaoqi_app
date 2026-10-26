import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/domain/chat_message_presentation.dart';
import 'package:xiaoqi_app/features/capabilities/presentation/capability_tag_text_controller.dart';
import 'package:xiaoqi_app/models/chat_annotation.dart';
import 'package:xiaoqi_app/models/home_chat_attachment.dart';
import 'package:xiaoqi_app/widgets/chat_annotation_controls.dart';
import 'package:xiaoqi_app/widgets/chat_annotation_navigation.dart';

final now = DateTime(2026, 10, 26);
const quote = '排查问题、';
const annotation = ChatAnnotation(id: 'note', quote: quote, comment: '？');
const capability = <String, Object?>{
  'type': 'action',
  'id': 'create-skill',
  'name': '创建技能',
};

AiConversationRecord record(List<AiConversationMessage> messages) =>
    AiConversationRecord(
      id: 'conversation',
      title: '注释讨论',
      messages: messages,
      createdAt: now,
      updatedAt: now,
    );

AiConversationMessage message(
  String id,
  String text, {
  bool isUser = true,
  String? parent,
  String? displayText,
  List<ChatAnnotation> annotations = const [],
  Map<String, Object?>? metadata,
  String? origin,
  List<HomeChatAttachment> attachments = const [],
}) => AiConversationMessage(
  id: id,
  text: text,
  isUser: isUser,
  createdAt: now,
  parentMessageId: parent,
  displayText: displayText,
  annotations: annotations,
  capabilityMetadata: metadata,
  capabilityTagOrigin: origin,
  attachments: attachments,
);

void main() {
  test('local snapshot is immutable and survives copies and persistence', () {
    final pending = [annotation];
    final runtimeText = appendChatAnnotations('', pending);
    final original = message(
      'u',
      runtimeText,
      displayText: '',
      annotations: pending,
      metadata: capability,
      origin: 'inherited',
    );
    pending.clear();
    final restored = AiConversationMessage.fromJson(
      jsonDecode(jsonEncode(original.toJson())),
    );
    expect(restored.text, runtimeText);
    expect(restored.displayText, '');
    expect(restored.annotations.single.toJson(), annotation.toJson());
    expect(() => restored.annotations.clear(), throwsUnsupportedError);
    final changed = restored.copyWith(agentTaskPending: true);
    expect(changed.annotations.single.id, annotation.id);
    expect(changed.capabilityMetadata, capability);
    expect(changed.capabilityTagOrigin, 'inherited');
    final ui = presentChatMessage(record([restored]), restored);
    expect(ui.text, isEmpty);
    expect(ui.annotations, hasLength(1));
    expect(ui.capability, isNull);
  });

  test('mixed annotations expose only the real user text', () {
    final m = message(
      'u',
      appendChatAnnotations('解释这些', [annotation]),
      displayText: '解释这些',
      annotations: [annotation],
    );
    final ui = presentChatMessage(record([m]), m);
    expect(ui.text, '解释这些');
    expect(m.text, contains('我的评论：？'));
    expect(m.copyWith(text: 'changed').displayText, '解释这些');
  });

  test('legacy serializer is recognized without rewriting the original', () {
    final source = message('a', '我能帮助你$quote改进界面。', isUser: false);
    final m = message(
      'u',
      appendChatAnnotations('', [annotation]),
      parent: source.id,
    );
    final saved = jsonEncode(m.toJson());
    final ui = presentChatMessage(record([source, m]), m);
    expect(ui.text, isEmpty);
    expect(ui.annotations.single.comment, '？');
    expect(ui.annotations.single.messageId, source.id);
    expect(
      ui.annotations.single.sourceHash,
      sha256.convert(utf8.encode(source.text)).toString(),
    );
    expect(jsonEncode(m.toJson()), saved);
  });

  test(
    'legacy multiline quote and comment keep numbering and typed prefix',
    () {
      final notes = [
        const ChatAnnotation(id: 'a', quote: '第一行\n第二行', comment: '第一条\n补充'),
        annotation,
      ];
      final m = message('u', appendChatAnnotations('逐项说明', notes));
      final ui = presentChatMessage(record([m]), m);
      expect(ui.text, '逐项说明');
      expect(ui.annotations.map((a) => a.quote), ['第一行\n第二行', quote]);
      expect(ui.annotations.first.comment, '第一条\n补充');
    },
  );

  test('ambiguous legacy source never acquires an invented link', () {
    final first = message('a1', quote, isUser: false);
    final second = message('a2', quote, isUser: false, parent: first.id);
    final m = message(
      'u',
      appendChatAnnotations('', [annotation]),
      parent: second.id,
    );
    final ui = presentChatMessage(record([first, second, m]), m);
    expect(ui.annotations.single.messageId, isNull);
    expect(ui.annotations.single.quote, quote);
  });

  test('malformed legacy tail remains ordinary visible text', () {
    final raw =
        '${appendChatAnnotations('', [annotation])}\n\n[注释 7] arbitrary';
    final m = message('u', raw);
    final ui = presentChatMessage(record([m]), m);
    expect(ui.text, raw);
    expect(ui.annotations, isEmpty);
  });

  test('legacy image numbering retains separate attachment identities', () {
    final attachments = [
      for (final id in ['a', 'b'])
        HomeChatAttachment(
          id: id,
          name: '$id.png',
          path: '/$id.png',
          mimeType: 'image/png',
          byteLength: 1,
          source: 'gallery',
        ),
    ];
    final notes = [
      for (final a in attachments)
        ChatAnnotation(
          id: a.id,
          attachmentId: a.id,
          x: .25,
          y: .75,
          comment: a.id,
        ),
    ];
    final m = message(
      'u',
      appendChatAnnotations(
        '',
        notes,
        attachmentNames: {for (final a in attachments) a.id: a.name},
      ),
      attachments: attachments,
    );
    final ui = presentChatMessage(record([m]), m);
    expect(ui.annotations.map((a) => a.attachmentId), ['a', 'b']);
    expect(ui.annotations.first.x, .25);
  });

  test('explicit reselection is visible while inherited followups are not', () {
    final first = message('u1', '创建', metadata: capability, origin: 'explicit');
    final followup = message(
      'u2',
      '？',
      metadata: capability,
      origin: 'inherited',
    );
    final reselected = message(
      'u3',
      '？',
      metadata: capability,
      origin: 'explicit',
    );
    final r = record([first, followup, reselected]);
    expect(presentChatMessage(r, first).capability, capability);
    expect(presentChatMessage(r, followup).capability, isNull);
    expect(presentChatMessage(r, reselected).capability, capability);
    expect(followup.capabilityMetadata, capability);
  });

  test('only proven legacy workflow inheritance is hidden', () {
    final first = message(
      'u1',
      '创建',
      metadata: {...capability, 'composer_text_offset': 0},
    );
    final answer = message('a', '还需要内容', parent: first.id, isUser: false);
    final followup = message(
      'u2',
      '？',
      parent: answer.id,
      metadata: capability,
    );
    final r = record([first, answer, followup]);
    expect(presentChatMessage(r, first).capability, isNotNull);
    expect(presentChatMessage(r, followup).capability, isNull);
    final unknown = message('unknown', '？', metadata: capability);
    expect(
      presentChatMessage(record([unknown]), unknown).capability,
      capability,
    );
  });

  test(
    'composer origin survives drafts and edits without changing runtime metadata',
    () {
      final controller = CapabilityTagTextController();
      addTearDown(controller.dispose);
      controller.setMessage('？', capability);
      final payload = controller.messageMetadata();
      expect(controller.hasExplicitCapability, isTrue);
      controller.setMessage('？', payload, isExplicit: false);
      expect(controller.hasExplicitCapability, isFalse);
      expect(controller.messageMetadata(), payload);
      final draft = controller.snapshot();
      controller.setMessage('别的', null);
      controller.restore(draft);
      expect(controller.hasExplicitCapability, isFalse);
      expect(controller.messageMetadata(), payload);
      controller.insertCapability(capability);
      expect(controller.hasExplicitCapability, isTrue);
      expect(controller.messageText, '？');
    },
  );

  test('capability origin does not change persisted execution scope', () {
    const skill = {'type': 'skill', 'id': 's', 'version_id': 'v1'};
    final a = message('a', '开始', metadata: skill, origin: 'explicit');
    final b = message('b', '？', metadata: skill, origin: 'inherited');
    final r = AiConversationRecord.fromJson(record([a, b]).toJson());
    expect(r.activeCapabilityMetadata, skill);
    expect(r.messages.last.capabilityScopeOperation, 'inherit');
  });

  test('reply links are scoped to this question snapshot', () {
    final text = presentChatAnnotationReply(
      ':xiaoqi-annotation{index="1"}\n第一条\n\n:xiaoqi-annotation{index="2"}\n第二条',
      questionId: 'turn with spaces',
      annotationCount: 2,
    );
    expect(
      text,
      contains('[注释 1](xiaoqi-annotation:1?question=turn+with+spaces)'),
    );
    expect(text, contains('[注释 2]'));
    expect(text, isNot(contains(':xiaoqi-annotation{')));
  });

  test('visible annotation section titles become blue-link targets', () {
    final text = presentChatAnnotationReply(
      '### 注释 1\n第一段\n\n**注释 2**\n第二段',
      questionId: 'turn-visible-headings',
      annotationCount: 2,
    );
    expect(
      text,
      contains('[注释 1](xiaoqi-annotation:1?question=turn-visible-headings)'),
    );
    expect(
      text,
      contains('[注释 2](xiaoqi-annotation:2?question=turn-visible-headings)'),
    );
    expect(text, isNot(contains('### 注释 1')));
    expect(text, contains('第一段 [注释 1]'));
    expect(text, contains('第二段 [注释 2]'));
  });

  test('missing bindings never produce an aggregate source footer', () {
    final text = presentChatAnnotationReply(
      '模型没有输出注释标题的回答',
      questionId: 'turn-without-headings',
      annotationCount: 2,
    );
    expect(text, '模型没有输出注释标题的回答');
    expect(
      presentChatAnnotationReply(
        '模型正在生成',
        questionId: 'turn-without-headings',
        annotationCount: 2,
        isStreaming: true,
      ),
      '模型正在生成',
    );
  });

  test('each paragraph keeps its own trailing annotation link', () {
    final text = presentChatAnnotationReply(
      '第一条的回答。【注释 1】\n\n第二条的回答。【注释 2】\n\n第一条补充。【注释 1】',
      questionId: 'q',
      annotationCount: 2,
    );
    expect(
      text,
      '第一条的回答。 [注释 1](xiaoqi-annotation:1?question=q)\n\n第二条的回答。 [注释 2](xiaoqi-annotation:2?question=q)\n\n第一条补充。 [注释 1](xiaoqi-annotation:1?question=q)',
    );
    expect(text, isNot(contains('相关注释')));
    expect(
      presentChatAnnotationReply(
        '`【注释 1】`',
        questionId: 'q',
        annotationCount: 1,
      ),
      '`【注释 1】`',
    );
  });

  test('remote current-turn content carries formatting on reused sessions', () {
    final original = <String, Object?>{'role': 'user', 'content': '请解释注释'};
    final request = chatAnnotationRequestMessage(original, annotationCount: 2);
    expect(request['content'], contains('段落末尾'));
    expect(request['content'], contains('有效编号 1 至 2'));
    expect(original['content'], '请解释注释');
    final media = <String, Object?>{
      'role': 'user',
      'content': [
        {'type': 'text', 'text': '本轮原文'},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,test'},
        },
      ],
    };
    final prepared = chatAnnotationRequestMessage(media, annotationCount: 1);
    expect((prepared['content'] as List).take(2), media['content']);
    expect((prepared['content'] as List).last['text'], contains('有效编号 1 至 1'));
    expect(
      chatAnnotationRequestMessage(original, annotationCount: 0),
      same(original),
    );
  });

  test(
    'unknown, overflowing and partial marker indices never become links',
    () {
      for (final index in ['0', '3', '999999999999999999999999999']) {
        final text = presentChatAnnotationReply(
          ':xiaoqi-annotation{index="$index"}\n内容',
          questionId: 'q',
          annotationCount: 2,
        );
        expect(text, contains('引用不可用'));
        expect(text, isNot(contains('](xiaoqi-annotation:$index')));
      }
      expect(
        presentChatAnnotationReply(
          '正常内容\n:xiaoqi-annotation{ind',
          questionId: 'q',
          annotationCount: 2,
          isStreaming: true,
        ),
        '正常内容\n',
      );
    },
  );

  test(
    'quoted protocol in fenced, inline and indented code remains literal',
    () {
      for (final text in [
        '```text\n:xiaoqi-annotation{index="1"}\n```',
        '` :xiaoqi-annotation{index="1"}`',
        '    :xiaoqi-annotation{index="1"}',
      ]) {
        expect(
          presentChatAnnotationReply(text, questionId: 'q', annotationCount: 1),
          contains(text),
        );
      }
    },
  );

  test('ordinary colon text is not mistaken for a partial directive', () {
    expect(
      presentChatAnnotationReply('说明：\n:', questionId: '', annotationCount: 0),
      '说明：\n:',
    );
  });

  testWidgets('reused SVGs render independently at 64px', (tester) async {
    const assets = [
      ('comment', 'assets/icons/chat_annotations/comment.svg'),
      ('close', 'assets/icons/chat_note_editor/x.svg'),
      ('edit', 'assets/images/home_message_edit.svg'),
      ('trash', 'assets/icons/chat_note_editor/trash.svg'),
      ('pin', 'assets/icons/chat_annotations/pin.svg'),
    ];
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.white,
              child: SizedBox(
                width: 500,
                height: 112,
                child: Row(
                  children: [
                    for (final (label, path) in assets)
                      SizedBox(
                        width: 100,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SvgPicture.asset(
                              path,
                              width: 64,
                              height: 64,
                              semanticsLabel: label,
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsNWidgets(5));
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('EXPORT_ANNOTATION_ASSET_PREVIEW')) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/test_artifacts/chat-annotation-icons.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });

  test('copying a reply exposes section titles instead of machine markup', () {
    final q = message(
      'q',
      'runtime',
      displayText: '',
      annotations: [annotation],
    );
    final a = message(
      'a',
      ':xiaoqi-annotation{index="1"}\n答复',
      parent: q.id,
      isUser: false,
    );
    expect(chatReplyPlainText(record([q, a]), a), '答复 注释 1');
  });

  testWidgets(
    'markdown source links stay blue and dispatch the bound question',
    (tester) async {
      String? tapped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GptMarkdown(
              presentChatAnnotationReply(
                '答复内容。【注释 1】',
                questionId: 'original-question',
                annotationCount: 1,
              ),
              styleSheet: const GptMarkdownStyleSheet(
                link: LinkStyle(color: Colors.black),
              ),
              inlineLinkBuilder: chatAnnotationLinkSpan,
              onLinkTap: (url, _) => tapped = url,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is RichText &&
                  widget.text.toPlainText().contains('注释 1'),
            )
            .first,
      );
      final start = paragraph.text.toPlainText().indexOf('注释 1');
      final box = paragraph
          .getBoxesForSelection(
            TextSelection(
              baseOffset: start,
              extentOffset: start + '注释 1'.length,
            ),
          )
          .first;
      await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
      expect(
        Uri.parse(tapped!).queryParameters['question'],
        'original-question',
      );
      var blue = false;
      void inspect(InlineSpan span) {
        if (span is TextSpan &&
            span.text == '注释 1' &&
            span.style?.color == const Color(0xFF3B82F6)) {
          blue = true;
        }
      }

      final richTexts = find.byWidgetPredicate((widget) => widget is RichText);
      for (final text in tester.widgetList<RichText>(richTexts)) {
        inspect(text.text);
        text.text.visitChildren((child) {
          inspect(child);
          return true;
        });
      }
      expect(
        blue,
        isTrue,
        reason: tester
            .widgetList<RichText>(richTexts)
            .map((text) => text.text.toStringDeep())
            .join('\n'),
      );
    },
  );

  testWidgets(
    'long annotation details remain scrollable at enlarged font size',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final notes = List.generate(
        24,
        (i) => ChatAnnotation(
          id: '$i',
          quote: '这是一段较长的原文，需要完整显示。' * 5,
          comment: '多行评论\n' * 5,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              textScaler: TextScaler.linear(1.5),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showChatAnnotationReview(context, annotations: notes),
                child: const Text('查看'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('注释 24'),
        500,
        scrollable: find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(Scrollable),
        ),
        maxScrolls: 60,
      );
      expect(find.text('注释 24'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sent detail uses labelled fields, no edit controls or keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ChatAnnotationCountChip(
                count: 1,
                onTap: () => showChatAnnotationReview(
                  context,
                  annotations: [annotation],
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('1 条注释'), findsOneWidget);
      await tester.tap(find.text('1 条注释'));
      await tester.pumpAndSettle();
      expect(find.text('已发送注释'), findsOneWidget);
      expect(find.text('注释 1'), findsOneWidget);
      expect(find.text('所选文本：'), findsOneWidget);
      expect(find.text('评论：'), findsOneWidget);
      expect(find.text(quote), findsOneWidget);
      expect(find.byTooltip('编辑评论'), findsNothing);
      expect(find.byTooltip('移除注释'), findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
      final material = find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first;
      expect(tester.getSize(material).width, closeTo(390 * .82, 1));
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testWidgets(
    'draft detail edits the same annotation and removes without renumbering data',
    (tester) async {
      List<ChatAnnotation> saved = [annotation];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showChatAnnotationReview(
                  context,
                  annotations: saved,
                  onChanged: (values) => saved = values,
                  onEditComment: (_, a) async => '${a.comment}修改',
                ),
                child: const Text('查看'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('编辑评论'));
      await tester.pumpAndSettle();
      expect(saved.single.id, annotation.id);
      expect(saved.single.comment, '？修改');
      await tester.tap(find.byTooltip('移除注释'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.text('暂无注释'), findsOneWidget);
    },
  );

  testWidgets('highlight-only source navigation never creates a draft pin', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTextAnnotationLayer(
            annotations: const [],
            highlight: annotation,
            onTapAnnotation: (_, _) {},
            child: const Text('前文$quote后文'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatAnnotationPin), findsNothing);
    expect(find.byType(Positioned), findsOneWidget);
  });

  testWidgets(
    'lazy navigation mounts a far offscreen row with variable heights',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final ids = List.generate(140, (i) => '$i');
      final anchors = <String, GlobalKey>{};
      final heights = <String, double>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: scroll,
              itemCount: ids.length,
              itemBuilder: (_, i) => SizedBox(
                key: anchors.putIfAbsent('$i', GlobalKey.new),
                height: i % 11 == 0 ? 1100 : 80.0 + i % 4 * 50,
                child: Text('row $i'),
              ),
            ),
          ),
        ),
      );
      for (final target in ['120', '3']) {
        var completed = false;
        var revealed = false;
        final result =
            revealChatMessage(
              messageId: target,
              messageIds: ids,
              anchors: anchors,
              heights: heights,
              controller: scroll,
              cancelled: () => false,
            ).then((v) {
              revealed = v;
              completed = true;
            });
        for (var i = 0; i < 110 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(completed, isTrue);
        await result;
        expect(revealed, isTrue, reason: 'target $target');
        expect(find.text('row $target'), findsOneWidget);
      }
      expect(
        await revealChatMessage(
          messageId: '130',
          messageIds: ids,
          anchors: anchors,
          heights: heights,
          controller: scroll,
          cancelled: () => true,
        ),
        isFalse,
      );
    },
  );
}
