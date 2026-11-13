import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/widgets/chat_message_scroll_view.dart';
import 'package:xiaoqi_app/widgets/chat_annotation_navigation.dart';

void main() {
  testWidgets(
    'short content aligns before paint and resets on conversation switch',
    (tester) async {
      final controller = ScrollController(keepScrollOffset: false);
      addTearDown(controller.dispose);
      var conversation = 0;
      var height = 100.0;
      var key = GlobalKey();
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return ChatMessageScrollView(
                  key: ValueKey(conversation),
                  controller: controller,
                  slivers: [
                    SliverList.list(
                      children: [
                        SizedBox(
                          key: key,
                          height: height,
                          child: const Text('message'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      expect(tester.getTopLeft(find.byKey(key)).dy, closeTo(0, .1));
      update(() => height = 250);
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(key)).dy, closeTo(0, .1));
      update(() => height = 900);
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(key)).dy, lessThan(0));
      expect(controller.position.maxScrollExtent, greaterThan(0));
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      final animation = controller.animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.linear,
      );
      await tester.pump(const Duration(milliseconds: 50));
      update(() {
        conversation++;
        key = GlobalKey();
        height = 100;
      });
      await tester.pumpAndSettle();
      await animation;
      expect(controller.offset, 0);
      expect(tester.getTopLeft(find.byKey(key)).dy, closeTo(0, .1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('short conversation is top aligned on its first frame', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageScrollView(
            controller: controller,
            slivers: [
              SliverList.list(
                children: [
                  SizedBox(key: key, height: 100, child: const Text('reply')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.getTopLeft(find.byKey(key)).dy, closeTo(0, .1));
    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long replies retain reading position and bottom remains zero', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final keys = List.generate(80, (_) => GlobalKey());
    var height = 1500.0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ChatMessageScrollView(
                controller: controller,
                slivers: [
                  SliverList.builder(
                    itemCount: keys.length,
                    itemBuilder: (_, index) => SizedBox(
                      key: keys[index],
                      height: index == 0 ? height : 200,
                      child: Text('message $index'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    expect(find.byType(Text).evaluate().length, lessThan(20));
    controller.jumpTo(400);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(keys[0])).dy;
    update(() => height += 200);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(keys[0])).dy, closeTo(before, .5));
    controller.jumpTo(0);
    await tester.pump();
    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reverse lazy navigation finds distant messages in both directions',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final ids = List.generate(80, (i) => '$i');
      final anchors = <String, GlobalKey>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatMessageScrollView(
              controller: controller,
              slivers: [
                SliverList.builder(
                  itemCount: ids.length,
                  itemBuilder: (_, i) {
                    final id = ids[ids.length - 1 - i];
                    return SizedBox(
                      key: anchors.putIfAbsent(id, GlobalKey.new),
                      height: i % 9 == 0 ? 900 : 150,
                      child: Text('row $id'),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
      for (final target in ['65', '2']) {
        bool? result;
        final future = revealChatMessage(
          messageId: target,
          messageIds: ids.reversed.toList(),
          anchors: anchors,
          heights: {},
          controller: controller,
          cancelled: () => false,
        ).then((value) => result = value);
        for (var i = 0; i < 120 && result == null; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(result, isTrue);
        await future;
        expect(find.text('row $target'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
