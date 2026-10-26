import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_models.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_store.dart';
import 'package:xiaoqi_app/features/capabilities/presentation/market_skill_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CapabilityStore.instance.clearSkillPreviews();
    FlutterSecureStorage.setMockInitialValues({
      'xiaoqi.capabilities.device_token.v1': 'test-token',
      'xiaoqi.auth.method.v1': 'email',
      'xiaoqi.auth.email.v1': 'owner@example.com',
    });
  });

  CapabilityDraft draft({bool plugin = false}) => CapabilityDraft(
    id: 'modal-test',
    kind: plugin ? CapabilityKind.plugin : CapabilityKind.skill,
    name: 'reading',
    description: '阅读自己的材料',
    content: plugin
        ? '{"name":"reading"}'
        : '---\nname: reading\ndescription: 阅读自己的材料\n---\n解释材料',
    presentation: {'title': '阅读助手', 'introduction': '完整的介绍'},
    updatedAt: DateTime.utc(2026, 10, 24),
  );

  Future<void> open(
    WidgetTester tester, {
    bool plugin = false,
    bool mcpOnly = false,
    CapabilityCloudSync? cloud,
  }) async {
    await tester.binding.setSurfaceSize(const Size(834, 1194));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarketSkillEditor(
            draft: draft(plugin: plugin),
            cloud: cloud,
            mcpOnly: mcpOnly,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'supplement entries open directly and keep draft edits until explicit save',
    (tester) async {
      final offlineCloud = CapabilityCloudSync.forTesting(
        MockClient((_) async => http.Response('offline', 503)),
      );
      await open(tester, cloud: offlineCloud);
      Size buttonSize(String label) => tester
          .getRect(
            find
                .ancestor(
                  of: find.text(label),
                  matching: find.byType(TextButton),
                )
                .first,
          )
          .size;
      final secondarySize = buttonSize('取消');
      final primarySize = buttonSize('下一步');
      final frame = tester.getRect(find.byType(Scaffold).last);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      final informationFrame = tester.getRect(find.byType(Scaffold).last);
      expect(informationFrame, frame);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('完整的介绍'), findsOneWidget);
      expect(find.text('一句话简介'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('supplement-description-entry')));
      await tester.tap(find.byKey(const ValueKey('supplement-description-entry')));
      await tester.pumpAndSettle();
      expect(find.text('一句话简介'), findsNothing);
      expect(find.text('下一步'), findsNothing);
      expect(tester.getRect(find.byType(Scaffold).last).width, informationFrame.width);
      await tester.enterText(find.byType(TextField), '修改后的介绍');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('修改后的介绍'), findsOneWidget);
      await tester.tap(find.text('下一步'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('确认发布'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '),
      );
      expect(buttonSize('上一步'), secondarySize);
      expect(buttonSize('保存草稿'), secondarySize);
      expect(buttonSize('确认发布'), primarySize);
      expect(find.byType(TextField), findsNothing);
      expect(tester.getRect(find.byType(Scaffold).last), frame);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('修改后的介绍'), findsOneWidget);
      expect(
        await CapabilityStore.instance.authoringDrafts('owner@example.com'),
        isEmpty,
      );
      await tester.tap(find.text('保存草稿'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final saved = (await CapabilityStore.instance.authoringDrafts(
        'owner@example.com',
      )).single;
      expect(saved.presentation['introduction'], '修改后的介绍');
      expect(saved.presentation['image_layout'], 'horizontal');
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpAndSettle();
      final previous = tester.getRect(find.text('上一步'));
      final saveDraft = tester.getRect(find.text('保存草稿'));
      final publish = tester.getRect(find.text('确认发布'));
      expect(previous.top, saveDraft.top);
      expect(publish.top, greaterThan(previous.top));
      expect(buttonSize('上一步'), secondarySize);
      expect(buttonSize('确认发布'), primarySize);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing without saving does not create a draft', (tester) async {
    await open(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('确认发布'), findsOneWidget);

    expect(
      await CapabilityStore.instance.authoringDrafts('owner@example.com'),
      isEmpty,
    );
    await tester.tap(find.byTooltip('关闭创建'));
    await tester.pumpAndSettle();
    expect(
      await CapabilityStore.instance.authoringDrafts('owner@example.com'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('supplement validation stays in its field and canvas', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    const titleError = '填写 1–128 字符的展示名称，可以使用中文。';
    expect(find.text(titleError), findsOneWidget);
    expect(find.text('确认发布'), findsNothing);
    expect(find.text('下一步'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is InputDecorator &&
            widget.decoration.errorText == titleError,
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('supplement-description-entry')));
    await tester.tap(find.byKey(const ValueKey('supplement-description-entry')));
    await tester.pumpAndSettle();
    expect(find.text(titleError), findsNothing);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text(titleError), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'MCP tests do not save, suppress duplicates and expire after editing',
    (tester) async {
      var tests = 0, saves = 0;
      final pending = Completer<http.Response>();
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path.endsWith('/health'))
            return http.Response(
              jsonEncode({
                'release_id': releaseId,
                'api_contract_version': apiContractVersion,
              }),
              200,
            );
          if (request.url.path.endsWith('/mcp/connections')) {
            if (request.method == 'POST') saves++;
            return http.Response('{"connections":[]}', 200);
          }
          if (request.url.path.endsWith('/mcp/connection-tests')) {
            tests++;
            return pending.future;
          }
          throw StateError('Unexpected ${request.url}');
        }),
      );
      await open(tester, plugin: true, mcpOnly: true, cloud: cloud);
      final address = find.byKey(const ValueKey('mcp-server-url'));
      await tester.enterText(address, 'https://example.com/mcp');
      await tester.pump();
      await tester.ensureVisible(find.text('测试连接'));
      await tester.tap(find.text('测试连接'));
      await tester.pump();
      await tester.tap(find.text('测试中…'));
      await tester.pump();
      expect(tests, 1);
      expect(saves, 0);
      pending.complete(http.Response('{"tool_count":2}', 200));
      await tester.pumpAndSettle();
      expect(find.text('连接成功'), findsOneWidget);
      await tester.enterText(address, 'https://other.example.com/mcp');
      await tester.pumpAndSettle();
      expect(find.text('连接成功'), findsNothing);
      expect(saves, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('layout SVGs render independently at 64 pixels', (tester) async {
    for (final layout in ['gallery-empty-stack', 'presentation-icon-frame', 'gallery-drag', 'supplement-progress']) {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 64,
                height: 64,
                child: SvgPicture.asset(
                  'assets/icons/extension_market/detail/$layout.svg',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${Directory.systemTemp.path}/xiaoqi-gallery-$layout.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    }
  });
}
