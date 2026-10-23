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
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'three steps preserve the frame; viewing stays inline and editing focuses',
    (tester) async {
      await open(tester);
      final frame = tester.getRect(find.byType(Scaffold).last);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(Scaffold).last), frame);
      expect(find.text('完整的介绍'), findsNothing);
      await tester.tap(find.text('详细介绍（可选）'));
      await tester.pumpAndSettle();
      expect(find.text('完整的介绍'), findsOneWidget);
      expect(find.text('一句话简介'), findsOneWidget);
      await tester.tap(find.text('编辑详细介绍'));
      await tester.pumpAndSettle();
      expect(find.text('一句话简介'), findsNothing);
      expect(find.text('下一步'), findsNothing);
      expect(tester.getRect(find.byType(Scaffold).last), frame);
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
      expect(find.byType(TextField), findsNothing);
      expect(find.text('修改后的介绍'), findsOneWidget);
      final saved = (await CapabilityStore.instance.authoringDrafts(
        'owner@example.com',
      )).single;
      expect(saved.presentation['introduction'], '修改后的介绍');
      expect(saved.presentation['image_layout'], 'horizontal');
      expect(tester.takeException(), isNull);
    },
  );

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
      await open(tester, plugin: true, cloud: cloud);
      await tester.tap(find.text('MCP连接配置（创建MCP连接器时须填写）'));
      await tester.pumpAndSettle();
      final address = find.widgetWithText(TextField, '服务器地址');
      await tester.enterText(address, 'https://example.com/mcp');
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
    for (final layout in ['horizontal', 'grid']) {
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
                  'assets/icons/extensions/gallery-$layout.svg',
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
