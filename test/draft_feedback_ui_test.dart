import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_models.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_store.dart';
import 'package:xiaoqi_app/features/capabilities/presentation/market_skill_editor.dart';
import 'package:xiaoqi_app/pages/extension_market_page.dart';

class _FailingDraftWrites extends InMemorySharedPreferencesStore {
  _FailingDraftWrites() : super.withData({});
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'owner@example.com';
  final store = CapabilityStore.instance;
  CapabilityDraft draft() => CapabilityDraft(
    id: 'feedback',
    name: 'reading',
    description: '阅读材料',
    content: '---\nname: reading\ndescription: 阅读材料\n---\n说明正文',
    presentation: {'title': '阅读助手'},
    cloudOwnerEmail: owner,
    updatedAt: DateTime.utc(2026, 10, 24),
  );
  http.Response reply(Object value, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(value)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  http.Response health() => reply({
    'release_id': releaseId,
    'api_contract_version': apiContractVersion,
  });
  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, CapabilityCloudSync cloud) async {
    await tester.binding.setSurfaceSize(const Size(834, 1194));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarketSkillEditor(draft: draft(), cloud: cloud),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
  }

  TextButton button(WidgetTester tester, String text) =>
      tester.widget<TextButton>(
        find
            .ancestor(of: find.text(text), matching: find.byType(TextButton))
            .first,
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.clearSkillPreviews();
    FlutterSecureStorage.setMockInitialValues({
      'xiaoqi.capabilities.device_token.v1': 'test-token',
      'xiaoqi.auth.method.v1': 'email',
      'xiaoqi.auth.email.v1': owner,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/events'),
          (_) async => null,
        );
  });

  testWidgets(
    'saving unlocks immediately; conflict has one recovery entry and a fixed frame',
    (tester) async {
      final entered = Completer<void>(), upload = Completer<http.Response>();
      Map<String, dynamic>? sent;
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          sent = Map<String, dynamic>.from(
            (jsonDecode(request.body) as Map)['draft'] as Map,
          );
          entered.complete();
          return upload.future;
        }),
      );
      await open(tester, cloud);
      final frame = tester.getRect(find.byType(Scaffold).last);
      await tester.tap(find.text('保存草稿'));
      await flush(tester);
      await tester.runAsync(
        () => entered.future.timeout(const Duration(seconds: 2)),
      );
      await tester.pumpAndSettle();
      expect(
        (await store.authoringDrafts(owner)).single.content,
        contains('说明正文'),
      );
      expect(find.text('正在同步，你可以继续编辑。'), findsOneWidget);
      expect(button(tester, '保存草稿').onPressed, isNotNull);
      expect(button(tester, '上一步').onPressed, isNotNull);
      expect(button(tester, '确认发布').onPressed, isNull);
      expect(tester.getRect(find.byType(Scaffold).last), frame);

      upload.complete(
        reply({
          'error': {
            'current': {...sent!, 'content': '云端的其他修改', 'cloud_revision': 2},
          },
        }, 409),
      );
      await flush(tester);
      expect(find.byKey(const ValueKey('draft-save-feedback')), findsOneWidget);
      expect(find.text('草稿已保存在本机。'), findsOneWidget);
      expect(find.text('云端版本有变化，暂未同步。'), findsOneWidget);
      expect(find.text('处理同步'), findsOneWidget);
      expect(find.text('重试同步'), findsNothing);
      expect(find.textContaining('另一设备'), findsNothing);
      expect(button(tester, '确认发布').onPressed, isNull);
      expect(tester.getRect(find.byType(Scaffold).last), frame);
      await tester.tap(find.text('处理同步'));
      await tester.pumpAndSettle();
      expect(find.text('另存为新草稿'), findsOneWidget);
      expect(find.text('查看云端版本'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed local write is never presented as a saved draft', (
    tester,
  ) async {
    final cloud = CapabilityCloudSync.forTesting(
      MockClient((_) async => health()),
    );
    await open(tester, cloud);
    final original = SharedPreferencesStorePlatform.instance;
    addTearDown(() => SharedPreferencesStorePlatform.instance = original);
    SharedPreferencesStorePlatform.instance = _FailingDraftWrites();
    await tester.tap(find.text('保存草稿'));
    await flush(tester);
    expect(
      find.text('未保存成功'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
    );
    expect(find.text('重试保存'), findsOneWidget);
    expect(find.text('草稿已保存'), findsNothing);
    expect(find.text('草稿已保存在本机。'), findsNothing);
    expect(button(tester, '确认发布').onPressed, isNull);
    expect(button(tester, '上一步').onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'closing unsaved edits asks once and does not persist on discard',
    (tester) async {
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((_) async => health()),
      );
      await open(tester, cloud);
      await tester.tap(find.text('上一步'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '未保存的修改');
      await tester.tap(find.byTooltip('关闭创建'));
      await tester.pumpAndSettle();
      expect(find.text('有未保存修改'), findsOneWidget);
      expect(find.text('保存后退出'), findsOneWidget);
      expect(await store.authoringDrafts(owner), isEmpty);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('未保存的修改'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭创建'));
      await tester.pumpAndSettle();
      expect(find.text('不保存退出'), findsNothing);
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      expect(await store.authoringDrafts(owner), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a slow installed-list read keeps local entries visible and never uploads drafts',
    (tester) async {
      final local = draft().copyWith(syncIssue: DraftSyncIssue.conflict);
      await store.saveAuthoringDraft(local);
      await store.commitDraft(local);
      final entered = Completer<void>(), pending = Completer<http.Response>();
      var draftRequests = 0, mcpRequests = 0;
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          if (request.url.path == '/health') return health();
          if (request.url.path.contains('drafts')) draftRequests++;
          if (request.url.path.contains('mcp')) mcpRequests++;
          if (request.url.path.endsWith('/capabilities')) {
            entered.complete();
            return pending.future;
          }
          return reply({'items': []});
        }),
      );
      await tester.binding.setSurfaceSize(const Size(834, 1194));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ExtensionMarketPage(
            initialKind: ExtensionKind.skill,
            cloud: cloud,
          ),
        ),
      );
      await flush(tester);
      await tester.runAsync(
        () => entered.future.timeout(const Duration(seconds: 2)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('个人'));
      await tester.pumpAndSettle();
      expect(find.text('本机已保存 · 同步待处理'), findsOneWidget);
      expect(find.bySemanticsLabel('正在加载扩展'), findsNothing);
      expect(draftRequests, 0);
      expect(mcpRequests, 0);
      pending.complete(reply({'items': []}));
      await flush(tester);
      expect(find.textContaining('安装记录同步失败'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing also protects unsaved edits in the other creation page',
    (tester) async {
      final firstController = MarketSkillEditorController();
      final secondController = MarketSkillEditorController();
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((_) async => health()),
      );
      var index = 0;
      late StateSetter update;
      await tester.binding.setSurfaceSize(const Size(834, 1194));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return IndexedStack(
                  index: index,
                  children: [
                    MarketSkillEditor(
                      key: const ValueKey('first'),
                      draft: draft(),
                      cloud: cloud,
                      active: index == 0,
                      controller: firstController,
                      otherEditor: secondController,
                    ),
                    MarketSkillEditor(
                      key: const ValueKey('second'),
                      cloud: cloud,
                      active: index == 1,
                      controller: secondController,
                      otherEditor: firstController,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '另一页未保存的修改');
      update(() => index = 1);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭创建'));
      await tester.pumpAndSettle();
      expect(find.text('有未保存修改'), findsOneWidget);
      expect(find.textContaining('另一创建页有未保存修改'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      update(() => index = 0);
      await tester.pumpAndSettle();
      expect(find.text('另一页未保存的修改'), findsOneWidget);
      expect(await store.authoringDrafts(owner), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
