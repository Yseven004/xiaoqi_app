import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_models.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_store.dart';
import 'package:xiaoqi_app/pages/extension_market_page.dart';

CapabilityDraft example({
  bool plugin = false,
  bool dependency = false,
}) => CapabilityDraft(
  id: plugin ? 'import-plugin' : 'import-skill',
  kind: plugin ? CapabilityKind.plugin : CapabilityKind.skill,
  name: 'reader',
  description: '读取资料并整理重点',
  content: plugin
      ? '{"name":"reader"}'
      : '---\nname: reader\ndescription: 读取资料\n---\n解释材料',
  presentation: const {'title': '阅读助手'},
  importSource: {
    'type': plugin ? 'archive' : 'document',
    'bytes': plugin ? 131072 : 774,
  },
  files: dependency
      ? {
          '.mcp.json': base64Encode(
            utf8.encode(
              '{"mcpServers":{"reading":{"url":"https://mcp.example.com/reading"}}}',
            ),
          ),
        }
      : const {},
  updatedAt: DateTime.utc(2026, 10, 24),
  cloudOwnerEmail: 'owner@example.com',
);

CapabilityCloudSync cloud({bool authFailure = false}) =>
    CapabilityCloudSync.forTesting(
      MockClient((request) async {
        if (request.url.path.endsWith('/health'))
          return http.Response(
            jsonEncode({
              'release_id': releaseId,
              'api_contract_version': apiContractVersion,
            }),
            200,
          );
        if (request.url.path.endsWith('/import-policy'))
          return http.Response(
            jsonEncode({
              'upload_extensions': ['md', 'zip', 'tgz', 'tar.gz'],
              'max_archive_bytes': 2097152,
              'max_files': 128,
              'max_file_bytes': 2097152,
              'max_expanded_bytes': 10485760,
            }),
            200,
          );
        if (request.url.path.endsWith('/mcp/connections'))
          return http.Response('{"connections":[]}', 200);
        if (request.url.path.endsWith('/mcp/connection-tests'))
          return authFailure
              ? http.Response('{"error":"401 unauthorized"}', 403)
              : http.Response('{"tool_count":2}', 200);
        throw StateError('Unexpected ${request.method} ${request.url.path}');
      }),
    );

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pumpAndSettle();
}

Future<void> open(
  WidgetTester tester, {
  CapabilityDraft? draft,
  bool authFailure = false,
  Size size = const Size(834, 1251),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansCJKSC'),
      builder: (context, child) =>
          RepaintBoundary(key: const ValueKey('capture'), child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          backgroundColor: const Color(0xFFBBBBBB),
          body: TextButton(
            onPressed: () => showExtensionCreation(
              context,
              draft: draft,
              cloud: cloud(authFailure: authFailure),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await settle(tester);
}

Future<void> capture(WidgetTester tester, String state) async {
  if (!const bool.fromEnvironment('CAPTURE_CREATION')) return;
  final render = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('.codex-artifacts/creation-2026-10-24')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$state.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader('NotoSansCJKSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
    await loader.load();
    final fallback = FontLoader('Ahem')
      ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
    await fallback.load();
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

  test(
    'skill preview excludes plugins and sync preserves local source identity',
    () async {
      final store = CapabilityStore.instance;
      final skill = example(),
          plugin = example(plugin: true).copyWith(creationMode: 'mcp');
      await store.saveAuthoringDraft(skill);
      await store.saveAuthoringDraft(plugin);
      expect(
        (await store.skillPreviews(
          accountEmail: 'owner@example.com',
        )).map((d) => d.id),
        [skill.id],
      );
      expect(
        await store.skillPreview(plugin.id, accountEmail: 'owner@example.com'),
        isNull,
      );
      final remote = CapabilityDraft.fromJson(
        plugin.toJson(includeLocalMetadata: false),
      ).copyWith(cloudOwnerEmail: plugin.cloudOwnerEmail, cloudRevision: 2);
      final merged = await store.applySyncedAuthoringDraft(plugin, remote);
      expect(merged.creationMode, 'mcp');
      expect(merged.importSource, plugin.importSource);
      expect(
        plugin.toJson(includeLocalMetadata: false).containsKey('creation_mode'),
        isFalse,
      );
      await expectLater(
        store.applySyncedAuthoringDraft(skill, remote),
        throwsStateError,
      );
      expect((await store.authoringDrafts('owner@example.com')).length, 2);
    },
  );

  testWidgets(
    'independent canvases retain inputs, reject both sources, and recover after removal',
    (tester) async {
      await open(tester, draft: example());
      expect(find.text('774 B'), findsOneWidget);
      expect(find.text('已识别 MCP 服务'), findsNothing);
      final importFooter = tester.getRect(find.text('下一步'));
      await tester.tap(find.text('连接 MCP 服务'));
      await settle(tester);
      expect(tester.getRect(find.text('下一步')), importFooter);
      expect(find.text('774 B'), findsNothing);
      expect(find.text('测试连接'), findsNothing);
      final address = find.byKey(const ValueKey('mcp-server-url'));
      await tester.enterText(address, 'https://mcp.example.com/reading');
      await tester.pump();
      await tester.ensureVisible(find.text('测试连接'));
      await tester.tap(find.text('测试连接'));
      await settle(tester);
      expect(find.text('连接成功'), findsOneWidget);
      expect(find.text('测试连接'), findsNothing);
      await tester.tap(find.text('下一步'));
      await tester.pump();
      expect(find.textContaining('均有配置信息'), findsOneWidget);
      await tester.tap(find.text('导入技能'));
      await settle(tester);
      expect(find.text('774 B'), findsOneWidget);
      await tester.tap(find.byTooltip('移除文件'));
      await tester.pump();
      expect(find.text('774 B'), findsNothing);
      expect(find.text('读取内容'), findsOneWidget);
      await tester.tap(find.text('连接 MCP 服务'));
      await settle(tester);
      expect(
        tester.widget<TextField>(address).controller!.text,
        'https://mcp.example.com/reading',
      );
      expect(find.text('连接成功'), findsOneWidget);
      await tester.tap(find.text('下一步'));
      await settle(tester);
      expect(find.text('一句话简介'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'approved import, dependent MCP and independent MCP states render',
    (tester) async {
      await open(tester, draft: example());
      await capture(tester, 'import-skill');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await open(tester, draft: example(plugin: true, dependency: true));
      expect(find.text('已识别 MCP 服务'), findsOneWidget);
      final tabRect = tester.getRect(find.text('导入插件'));
      await tester.enterText(
        find.byKey(const ValueKey('mcp-token')),
        'test-token',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('测试连接'));
      await tester.tap(find.text('测试连接'));
      await settle(tester);
      expect(find.text('连接成功'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('mcp-server-url')),
        const Offset(0, 700),
      );
      await tester.pumpAndSettle();
      await capture(tester, 'dependent-mcp');
      await tester.drag(
        find.byKey(const ValueKey('mcp-server-url')),
        const Offset(0, -150),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('导入插件')), tabRect);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await open(tester);
      await capture(tester, 'import-empty');
      await tester.tap(find.text('连接 MCP 服务'));
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('mcp-server-url')),
        'https://mcp.example.com/reading',
      );
      await tester.enterText(
        find.byKey(const ValueKey('mcp-token')),
        'test-token',
      );
      await tester.pump();
      await tester.tap(find.text('测试连接'));
      await settle(tester);
      await capture(tester, 'independent-mcp');
      await tester.tap(find.text('下一步'));
      await settle(tester);
      expect(find.text('一句话简介'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'authentication failure stays at token field and blocks advancing',
    (tester) async {
      await open(tester, authFailure: true);
      await tester.tap(find.text('连接 MCP 服务'));
      await settle(tester);
      final address = find.byKey(const ValueKey('mcp-server-url'));
      final token = find.byKey(const ValueKey('mcp-token'));
      await tester.enterText(address, 'https://mcp.example.com/reading');
      await tester.pump();
      await tester.tap(find.text('测试连接'));
      await settle(tester);
      expect(tester.widget<TextField>(token).decoration!.errorText, isNotNull);
      expect(tester.widget<TextField>(address).decoration!.errorText, isNull);
      await tester.tap(find.text('下一步'));
      await tester.pump();
      expect(find.text('一句话简介'), findsNothing);
      expect(tester.widget<TextField>(address).decoration!.errorText, isNull);
    },
  );

  testWidgets('fixed SVG assets render at 64 pixels', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: const ValueKey('capture'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final asset in [
                  'assets/icons/capabilities/mcp_connector.svg',
                  'assets/icons/extension_market/detail/archive.svg',
                  'assets/icons/extension_market/detail/connection-success.svg',
                ])
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SvgPicture.asset(asset, width: 64, height: 64),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await capture(tester, 'asset-previews-64');
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone form has no overflow and retains fixed switches', (
    tester,
  ) async {
    await open(tester, size: const Size(390, 844));
    expect(find.text('导入技能'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('连接 MCP 服务'));
    await settle(tester);
    expect(find.byKey(const ValueKey('mcp-server-url')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
