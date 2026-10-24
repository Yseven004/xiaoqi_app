import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/features/capabilities/presentation/market_ui.dart';

void main() {
  testWidgets('touching a button dismisses focus and runs its first tap', (
    tester,
  ) async {
    final focus = FocusNode();
    final controller = TextEditingController(text: '保留内容');
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarketInputFocusScope(
            child: Column(
              children: [
                TextField(focusNode: focus, controller: controller),
                TextButton(onPressed: () => presses++, child: const Text('继续')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.tap(find.text('继续'));
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    expect(presses, 1);
    expect(controller.text, '保留内容');
  });

  testWidgets('blank taps dismiss focus; another field receives focus', (
    tester,
  ) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarketInputFocusScope(
            child: Column(
              children: [
                TextField(focusNode: first),
                TextField(focusNode: second),
                const Expanded(
                  child: SizedBox.expand(
                    child: ColoredBox(
                      key: Key('blank'),
                      color: Colors.transparent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.tap(find.byType(TextField).last);
    await tester.pump();
    expect(first.hasFocus, isFalse);
    expect(second.hasFocus, isTrue);
    await tester.tap(find.byKey(const Key('blank')));
    await tester.pump();
    expect(second.hasFocus, isFalse);
  });

  testWidgets('keyboard dismissal releases only an empty focused field', (
    tester,
  ) async {
    final focus = FocusNode();
    final controller = TextEditingController();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarketInputFocusScope(
            child: TextField(focusNode: focus, controller: controller),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    tester.view.resetViewInsets();
    await tester.pump();
    await tester.pump();
    expect(focus.hasFocus, isFalse);

    await tester.enterText(find.byType(TextField), '保留内容');
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    tester.view.resetViewInsets();
    await tester.pump();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    expect(controller.text, '保留内容');
  });
}
