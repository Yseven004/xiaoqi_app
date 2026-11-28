import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/ai_study_annotation/data/ai_conversation_history.dart';
import 'package:xiaoqi_app/features/capabilities/presentation/capability_tag_text_controller.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/home_chat_model_preferences.dart';
import 'package:xiaoqi_app/widgets/home_chat_model_selector.dart';
import 'package:xiaoqi_app/widgets/reading_companion.dart';
import 'package:xiaoqi_app/widgets/reading_companion_composer.dart';

void main() {
  testWidgets('an explicitly selected capability can be sent without text', (
    tester,
  ) async {
    final controller = CapabilityTagTextController();
    final focusNode = FocusNode();
    final sendingEnabled = ValueNotifier(true);
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    addTearDown(sendingEnabled.dispose);
    var sends = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: sendingEnabled,
            builder: (context, enabled, _) => ReadingCompanionComposer(
              controller: controller,
              focusNode: focusNode,
              reasoningSelection: HomeChatModelSelection.initial,
              onReasoningChanged: (_) {},
              onSend: () => sends++,
              onStop: () {},
              onAddAttachment: (_) {},
              onDrawingSelected: () {},
              onCapabilitySelected: controller.insertCapability,
              onInstallSkills: () {},
              onInstallPlugins: () {},
              onInstallMcp: () {},
              onManageMcp: () {},
              signedIn: true,
              sendingEnabled: enabled,
            ),
          ),
        ),
      ),
    );

    final sendButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '发送',
    );
    bool canSend() => tester.widget<IconButton>(sendButton).onPressed != null;

    expect(canSend(), isFalse);
    const action = {'type': 'action', 'id': 'create-image', 'name': '创建图像'};
    controller.setMessage('', action, isExplicit: false);
    await tester.pump();
    expect(canSend(), isFalse);

    controller.clearCapabilities();
    controller.insertCapability(action);
    await tester.pump();
    expect(controller.messageText, isEmpty);
    expect(canSend(), isTrue);
    await tester.tap(sendButton);
    expect(sends, 1);

    sendingEnabled.value = false;
    await tester.pump();
    expect(canSend(), isFalse);

    sendingEnabled.value = true;
    controller.clearCapabilities();
    await tester.pump();
    expect(canSend(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('companion changes reasoning without changing model or draft', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var selection = HomeChatModelSelection.initial;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ReadingCompanionComposer(
              controller: controller,
              focusNode: focusNode,
              reasoningSelection: selection,
              onReasoningChanged: (value) =>
                  setState(() => selection = selection.withReasoning(value)),
              onSend: () {},
              onStop: () {},
              onAddAttachment: (_) {},
              onDrawingSelected: () {},
              onCapabilitySelected: (_) {},
              onInstallSkills: () {},
              onInstallPlugins: () {},
              onInstallMcp: () {},
              onManageMcp: () {},
              signedIn: true,
            ),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '继续读');
    await tester.tap(find.byTooltip('思考强度 高'));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isFalse);
    expect(controller.text, '继续读');
    expect(find.byType(HomeChatModelMenuSurface), findsOneWidget);
    expect(find.byType(HomeChatReasoningPicker), findsOneWidget);
    expect(find.byType(HomeChatModelPickerPanel), findsNothing);
    expect(find.text('中'), findsNothing);

    await tester.tap(find.text('最高'));
    await tester.pumpAndSettle();
    expect(selection.model, HomeChatModelOption.deepSeek);
    expect(selection.reasoningLevel, HomeChatReasoningLevel.max);
    expect(find.byTooltip('思考强度 最高'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('companion places live and saved processes with their answers', (
    tester,
  ) async {
    final library = BookLibraryService();
    final companion = GlobalKey<ReadingCompanionState>();
    final streamingReply = ValueNotifier('');
    addTearDown(streamingReply.dispose);
    final question = AiConversationMessage(
      text: '读到哪里了？',
      isUser: true,
      createdAt: DateTime(2026),
    );
    final answer = AiConversationMessage(
      text: '读到第三章',
      isUser: false,
      createdAt: DateTime(2026),
      isIncomplete: true,
      agentProcessSummary: '上次阅读已停止',
    );

    Future<void> showDiscussion({bool active = false, String? continuingId}) =>
        tester.pumpWidget(
          MaterialApp(
            home: ReadingCompanion(
              key: companion,
              bookId: null,
              library: library,
              messages: [question, answer],
              streamingReply: streamingReply,
              liveAgentProcess: active ? const Text('正在阅读') : null,
              continuingReplyId: continuingId,
              savedAgentProcessBuilder: (message) =>
                  Text(message.agentProcessSummary!),
              composerBuilder: (history) => history,
              onPassageOpened: (_) {},
            ),
          ),
        );

    await showDiscussion();
    companion.currentState!.openHistoryChat();
    await tester.pumpAndSettle();
    expect(find.text('上次阅读已停止'), findsOneWidget);

    await showDiscussion(active: true);
    expect(find.text('正在阅读'), findsOneWidget);
    expect(find.text('上次阅读已停止'), findsOneWidget);

    await showDiscussion(active: true, continuingId: answer.id);
    expect(find.text('正在阅读'), findsOneWidget);
    expect(find.text('上次阅读已停止'), findsNothing);
    streamingReply.value = '第三章，接着是第四章。';
    await tester.pump();
    expect(find.text('读到第三章，接着是第四章。', findRichText: true), findsOneWidget);
    expect(find.text('第三章，接着是第四章。', findRichText: true), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('saved reasoning values resolve to real provider modes', () {
    expect(
      HomeChatReasoningLevelLabel.parse('medium'),
      HomeChatReasoningLevel.high,
    );
    expect(
      HomeChatModelSelection.initial
          .withModel(HomeChatModelOption.mimo)
          .reasoningLevel,
      HomeChatReasoningLevel.enabled,
    );
    expect(
      HomeChatModelOption.mimo.normalize(HomeChatReasoningLevel.low),
      HomeChatReasoningLevel.enabled,
    );
    expect(HomeChatModelOption.mimo.reasoningLevels, [
      HomeChatReasoningLevel.none,
      HomeChatReasoningLevel.enabled,
    ]);
  });

  testWidgets('home model menu exposes the selected provider controls', (
    tester,
  ) async {
    var selection = HomeChatModelSelection.initial;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Align(
              alignment: Alignment.bottomRight,
              child: SizedBox.square(
                dimension: 48,
                child: HomeChatModelSelector(
                  selection: selection,
                  onChanged: (value) => setState(() => selection = value),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text(HomeChatModelOption.deepSeek.name), findsNothing);
    await tester.tap(find.byType(HomeChatModelSelector));
    await tester.pumpAndSettle();
    expect(find.byType(HomeChatModelMenuSurface), findsOneWidget);
    expect(find.text('最高'), findsOneWidget);

    await tester.tap(find.text(HomeChatModelOption.mimo.name));
    await tester.pumpAndSettle();
    expect(find.text('最高'), findsNothing);
    expect(find.text('开启'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    expect(selection.model, HomeChatModelOption.mimo);
    expect(selection.reasoningLevel, HomeChatReasoningLevel.none);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
