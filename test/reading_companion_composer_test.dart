import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/capabilities/presentation/capability_tag_text_controller.dart';
import 'package:xiaoqi_app/services/home_chat_model_preferences.dart';
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
              modelSelection: HomeChatModelSelection.initial,
              onModelSelectionChanged: (_) {},
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
}
