import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_store.dart';
import 'package:xiaoqi_app/features/capabilities/presentation/skill_presentation.dart';

import 'extension_creation_isolation_test.dart' as fixture;

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

  testWidgets('empty guide is not input and is restored when input is cleared', (tester) async {
    await fixture.open(tester, draft: fixture.example());
    await tester.tap(find.text('下一步'));
    await fixture.settle(tester);
    final entry = find.byKey(const ValueKey('supplement-description-entry'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await fixture.settle(tester);
    final canvas = find.byKey(const ValueKey('supplement-introduction-canvas'));
    final template = find.byKey(const ValueKey('supplement-introduction-template'));
    final input = tester.widget<TextField>(canvas);
    expect(input.controller!.text, isEmpty);
    expect(input.maxLines, isNull);
    expect(input.maxLength, isNull);
    expect(template, findsOneWidget);
    expect(input.focusNode!.hasFocus, isFalse);

    final longText = List.generate(150, (i) => '第 $i 行：连续编辑自己的详细介绍。').join('\n');
    await tester.enterText(canvas, longText);
    await tester.pumpAndSettle();
    expect(template, findsNothing);
    expect(input.scrollController!.position.maxScrollExtent, greaterThan(0));
    await tester.enterText(canvas, '');
    await tester.pumpAndSettle();
    expect(template, findsOneWidget);
    await tester.tap(find.text('完成'));
    await fixture.settle(tester);
    expect(find.text('添加使用场景与操作说明'), findsOneWidget);
    expect(await CapabilityStore.instance.authoringDrafts('owner@example.com'), isEmpty);
  });

  testWidgets('gallery reorder and deletion preserve old captions in saved data', (tester) async {
    final images = List.generate(3, (i) => {
      'data': Uri.dataFromString(
        '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400">'
        '<rect width="300" height="400" fill="#F${i}F${i}F${i}"/></svg>',
        mimeType: 'image/svg+xml',
      ).toString(),
      'caption': '历史图片说明 $i',
    });
    await fixture.open(tester, draft: fixture.example().copyWith(presentation: {'images': images}));
    await tester.tap(find.text('下一步'));
    await fixture.settle(tester);
    final entry = find.byKey(const ValueKey('supplement-images-entry'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await fixture.settle(tester);
    expect(find.textContaining('历史图片说明'), findsNothing);
    expect(find.text('展示布局'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    final list = tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    list.onReorderItem!(0, 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await fixture.settle(tester);
    await tester.tap(find.text('下一步'));
    await fixture.settle(tester);
    await tester.tap(find.text('保存草稿'));
    await fixture.settle(tester);
    final saved = (await CapabilityStore.instance.authoringDrafts('owner@example.com')).single;
    final savedImages = (saved.presentation['images'] as List).cast<Map>();
    expect(savedImages.map((e) => e['caption']), ['历史图片说明 1', '历史图片说明 2', '历史图片说明 0']);
    expect(savedImages.map((e) => e['data']), [images[1]['data'], images[2]['data'], images[0]['data']]);
    expect(saved.presentation['introduction'], isEmpty);
  });

  testWidgets('six images disable adding and deleting the last restores empty upload', (tester) async {
    final image = Uri.dataFromString(
      '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400">'
      '<rect width="300" height="400" fill="#EEE"/></svg>',
      mimeType: 'image/svg+xml',
    ).toString();
    await fixture.open(tester, draft: fixture.example().copyWith(presentation: {
      'images': List.generate(6, (_) => {'data': image}),
    }));
    await tester.tap(find.text('下一步'));
    await fixture.settle(tester);
    final entry = find.byKey(const ValueKey('supplement-images-entry'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await fixture.settle(tester);
    final add = find.ancestor(of: find.text('添加图片'), matching: find.byType(TextButton));
    expect(tester.widget<TextButton>(add).onPressed, isNull);
    for (var remaining = 6; remaining > 0; remaining--) {
      final remove = find.byKey(const ValueKey('gallery-delete-0'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('gallery-empty-upload')), findsOneWidget);
    expect(find.text('添加第一张图片'), findsOneWidget);
    expect(find.text('已添加 0 / 6 张'), findsOneWidget);
    expect(find.text('横排'), findsNothing);
    expect(find.text('网格'), findsNothing);
    expect(find.byType(ReorderableListView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('default glyph comes from true type and custom SVG covers the frame', (tester) async {
    for (final asset in ['file-text', 'extension', 'mcp']) {
      await tester.pumpWidget(MaterialApp(home: Center(child: SkillPresentationIcon(
        const {'icon_asset': 'research'}, size: 64, defaultAsset: asset,
      ))));
      await tester.pumpAndSettle();
      final path = asset == 'file-text' ? 'file-text.svg'
          : asset == 'extension' ? 'capabilities/extension.svg' : 'mcp_connector.svg';
      expect(find.byWidgetPredicate((w) => w is SvgPicture && w.bytesLoader.toString().contains(path)), findsOneWidget);
      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
      expect(clip.borderRadius, BorderRadius.circular(64 * .22));
    }
    final svg = base64Encode(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 80"><rect width="200" height="80" fill="#222"/></svg>'));
    await tester.pumpWidget(MaterialApp(home: Center(child: SkillPresentationIcon(
      {'icon_data': 'data:image/svg+xml;base64,$svg'}, size: 64,
    ))));
    await tester.pumpAndSettle();
    expect(tester.widgetList<SvgPicture>(find.byType(SvgPicture)).any((w) => w.fit == BoxFit.cover), isTrue);
  });
}
