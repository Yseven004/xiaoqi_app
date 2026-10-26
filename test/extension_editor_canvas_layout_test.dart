import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_store.dart';

import 'extension_creation_isolation_test.dart' as fixture;

Future<void> captureSupplement(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_SUPPLEMENT')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('.codex-artifacts/supplement-info-2026-10-25')
        ..createSync(recursive: true);
      await File('${directory.path}/$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in ['NotoSansCJKSC', 'Ahem']) {
      await (FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
          .load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CapabilityStore.instance.clearSkillPreviews();
    FlutterSecureStorage.setMockInitialValues({
      'xiaoqi.capabilities.device_token.v1': 'test-token',
      'xiaoqi.auth.method.v1': 'email',
      'xiaoqi.auth.email.v1': 'owner@example.com',
    });
  });

  for (final size in [const Size(992, 1586), const Size(390, 844)]) {
    testWidgets('approved supplement and empty editors fit $size', (tester) async {
      await fixture.open(tester, size: size, draft: fixture.example().copyWith(
        name: 'xiaoqi-summary-device-test',
        description: '将用户提供的短文整理为三条中文要点。',
        presentation: const {'title': 'xiaoqi-summary-device-test'},
      ));
      await tester.tap(find.text('下一步'));
      await fixture.settle(tester);
      final informationFrame = tester.getRect(find.byType(Scaffold).last);
      await captureSupplement(tester, 'overview-${size.width.toInt()}');
      final descriptionEntry = find.byKey(const ValueKey('supplement-description-entry'));
      await tester.ensureVisible(descriptionEntry);
      await tester.tap(descriptionEntry);
      await fixture.settle(tester);
      final descriptionFrame = tester.getRect(find.byType(Scaffold).last);
      final canvas = find.byKey(const ValueKey('supplement-introduction-canvas'));
      expect(descriptionFrame.width, informationFrame.width);
      expect(descriptionFrame.top, informationFrame.top);
      expect(tester.getRect(canvas).height, greaterThan(100));
      expect(tester.getRect(canvas).bottom, lessThan(descriptionFrame.bottom));
      expect(find.byKey(const ValueKey('supplement-introduction-template')), findsOneWidget);
      await captureSupplement(tester, 'introduction-${size.width.toInt()}');
      final footerBeforeKeyboard = tester.getRect(find.text('返回后保留已填写内容'));

      tester.view.viewInsets = FakeViewPadding(bottom: 280 * tester.view.devicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.getRect(canvas).bottom, lessThanOrEqualTo(size.height - 280));
      expect(tester.getRect(find.text('返回后保留已填写内容')), footerBeforeKeyboard);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await fixture.settle(tester);

      final imagesEntry = find.byKey(const ValueKey('supplement-images-entry'));
      await tester.ensureVisible(imagesEntry);
      await tester.tap(imagesEntry);
      await fixture.settle(tester);
      expect(find.byKey(const ValueKey('gallery-empty-upload')), findsOneWidget);
      expect(find.text('已添加 0 / 6 张'), findsOneWidget);
      expect(find.text('添加第一张图片'), findsOneWidget);
      expect(find.byType(ReorderableListView), findsNothing);
      expect(find.byWidgetPredicate((w) => w is SvgPicture &&
          w.bytesLoader.toString().contains('gallery-empty-stack')), findsOneWidget);
      await captureSupplement(tester, 'gallery-empty-${size.width.toInt()}');
      expect(tester.takeException(), isNull);
    });

    testWidgets('large images use remaining height and grid adapts at $size', (tester) async {
      final image = Uri.dataFromString(
        '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400">'
        '<rect width="300" height="400" fill="#F0F0F2"/></svg>',
        mimeType: 'image/svg+xml',
      ).toString();
      await fixture.open(tester, size: size, draft: fixture.example().copyWith(
        presentation: {
          'images': List.generate(3, (i) => {'data': image, 'caption': '旧说明 $i'}),
        },
      ));
      await tester.tap(find.text('下一步'));
      await fixture.settle(tester);
      final entry = find.byKey(const ValueKey('supplement-images-entry'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await fixture.settle(tester);
      final frame = tester.getRect(find.byType(Scaffold).last);
      final strip = tester.getRect(find.byType(ReorderableListView));
      expect(frame.bottom - strip.bottom, inInclusiveRange(8, 24));
      expect(strip.height, greaterThan(100));
      expect(find.textContaining('旧说明'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      await captureSupplement(tester, 'gallery-${size.width.toInt()}');

      await tester.tap(find.byKey(const ValueKey('gallery-layout-grid')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('gallery-grid')), findsOneWidget);
      expect(tester.getRect(find.byType(Scaffold).last), frame);
      await captureSupplement(tester, 'gallery-grid-${size.width.toInt()}');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a single grid image keeps the first column size and origin', (tester) async {
    final image = Uri.dataFromString(
      '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400">'
      '<rect width="300" height="400" fill="#EEE"/></svg>',
      mimeType: 'image/svg+xml',
    ).toString();
    await fixture.open(tester, size: const Size(992, 1586),
      draft: fixture.example().copyWith(presentation: {
        'image_layout': 'grid',
        'images': List.generate(2, (_) => {'data': image}),
      }));
    await tester.tap(find.text('下一步'));
    await fixture.settle(tester);
    final entry = find.byKey(const ValueKey('supplement-images-entry'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await fixture.settle(tester);
    final grid = tester.getRect(find.byKey(const ValueKey('gallery-grid')));
    final firstBefore = tester.getRect(find.byType(LongPressDraggable<int>).first);
    expect(firstBefore.left, grid.left);
    expect(firstBefore.top, grid.top);
    expect(firstBefore.width, greaterThan(grid.width * .45));
    await tester.tap(find.byKey(const ValueKey('gallery-delete-1')));
    await fixture.settle(tester);
    expect(tester.getRect(find.byType(LongPressDraggable<int>).first), firstBefore);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(992, 1586), const Size(390, 844)]) {
    testWidgets('introduction expands to an independent near-fullscreen canvas at $size', (tester) async {
      await fixture.open(tester, size: size, draft: fixture.example());
      await tester.tap(find.text('下一步'));
      await fixture.settle(tester);
      final entry = find.byKey(const ValueKey('supplement-description-entry'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await fixture.settle(tester);
      final canvas = find.byKey(const ValueKey('supplement-introduction-canvas'));
      final text = List.generate(120, (i) => '第 $i 行介绍').join('\n');
      await tester.enterText(canvas, text);
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(canvas);
      final normal = tester.getRect(find.byType(Scaffold).last);
      final normalCanvas = tester.getRect(canvas);
      final selection = input.controller!.selection;
      await tester.tap(find.byKey(const ValueKey('supplement-introduction-expand')));
      await tester.pumpAndSettle();
      final expanded = tester.getRect(find.byType(Scaffold).last);
      expect(expanded.width, greaterThan(normal.width));
      expect(expanded.height, greaterThan(normal.height));
      expect(expanded.left, closeTo(12, .01));
      expect(size.width - expanded.right, closeTo(12, .01));
      expect(expanded.top, closeTo(12, .01));
      expect(size.height - expanded.bottom, closeTo(12, .01));
      expect(expanded.contains(tester.getRect(find.text('详细介绍')).center), isTrue);
      expect(expanded.contains(tester.getRect(find.text('完成')).center), isTrue);
      expect(find.text('介绍内容'), findsNothing);
      expect(find.text('返回后保留已填写内容'), findsOneWidget);
      expect(tester.getRect(canvas).height, greaterThan(normalCanvas.height));
      expect(tester.getRect(canvas).top, lessThan(normalCanvas.top));
      expect(tester.widget<TextField>(canvas).controller, same(input.controller));
      expect(input.controller!.text, text);
      expect(input.controller!.selection, selection);
      expect(input.scrollController!.position.maxScrollExtent, greaterThan(0));
      await tester.tap(find.byKey(const ValueKey('supplement-introduction-expand')));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(Scaffold).last), normal);
      expect(tester.getRect(canvas), normalCanvas);
      expect(input.controller!.text, text);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('gallery controls adapt to enlarged phone text', (tester) async {
    final image = Uri.dataFromString(
      '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400">'
      '<rect width="300" height="400" fill="#EEE"/></svg>',
      mimeType: 'image/svg+xml',
    ).toString();
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await fixture.open(tester, size: const Size(390, 844),
      draft: fixture.example().copyWith(presentation: {'images': [{'data': image}]}));
    await tester.tap(find.text('下一步'));
    await fixture.settle(tester);
    final entry = find.byKey(const ValueKey('supplement-images-entry'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await fixture.settle(tester);
    final toggle = tester.getRect(find.byKey(const ValueKey('gallery-layout-horizontal')));
    final add = tester.getRect(find.text('添加图片'));
    expect(add.top, greaterThan(toggle.bottom));
    expect(tester.takeException(), isNull);
  });
}
