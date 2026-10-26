import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/config/release.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_cloud_sync.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_models.dart';
import 'package:xiaoqi_app/features/capabilities/data/capability_store.dart';
import 'package:xiaoqi_app/pages/extension_market_page.dart';

CapabilityRecord record({
  String id = 'own-skill',
  CapabilityKind kind = CapabilityKind.skill,
  String origin = 'local',
  bool mcp = false,
}) {
  final content = kind == CapabilityKind.skill
      ? '---\nname: reading\ndescription: 阅读材料\n---\n当前版本的完整说明'
      : '{"name":"reading","description":"阅读材料"}';
  return CapabilityRecord(
    id: id,
    kind: kind,
    name: 'reading',
    description: '当前版本简介',
    origin: origin,
    syncState: CapabilitySyncState.synced,
    publicationId: 'published-$id',
    publishedRevision: 2,
    versions: [
      CapabilityVersion(
        id: '$id-v1',
        number: 1,
        content: '旧内容',
        contentHash: 'old',
        createdAt: DateTime.utc(2026, 10, 23),
      ),
      CapabilityVersion(
        id: '$id-v2',
        number: 2,
        content: content,
        contentHash: 'current',
        createdAt: DateTime.utc(2026, 10, 24),
        files: {
          'assets/data.bin': base64Encode([0, 255, 7]),
          if (kind == CapabilityKind.plugin)
            'plugin.json': base64Encode(utf8.encode(content)),
          if (mcp)
            '.mcp.json': base64Encode(
              utf8.encode(
                '{"mcpServers":{"reading":{"type":"http","url":"https://example.com/mcp"}}}',
              ),
            ),
        },
      ),
    ],
    currentVersionId: '$id-v2',
    createdAt: DateTime.utc(2026, 10, 23),
    updatedAt: DateTime.utc(2026, 10, 24),
    presentation: {
      'title': origin == 'local' ? '我的阅读助手' : '他人技能',
      'introduction': '当前版本详细介绍',
    },
  );
}

CapabilityCloudSync cloudFor(List<CapabilityRecord> records) =>
    CapabilityCloudSync.forTesting(
      MockClient((request) async {
        final path = request.url.path;
        final Object body;
        if (path.endsWith('/health')) {
          body = {
            'release_id': releaseId,
            'api_contract_version': apiContractVersion,
          };
        } else if (path.endsWith('/capabilities')) {
          body = {'items': records.map((r) => r.toJson()).toList()};
        } else if (path.endsWith('/skill-market') ||
            path.contains('/skill-market/')) {
          final own = records.first;
          final publication = {
            'id': own.publicationId,
            'capability_id': own.id,
            'is_owner': true,
            'name': own.name,
            'description': own.description,
            'kind': own.kind.name,
            'presentation': own.presentation,
          };
          body = path.endsWith('/skill-market')
              ? {
                  'items': [publication],
                }
              : {'publication': publication};
        } else {
          body = {
            'items': [],
            'max_archive_bytes': 2097152,
            'upload_extensions': ['zip', 'md'],
          };
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/events'),
          (_) async => null,
        );
  });

  for (final kind in CapabilityKind.values) {
    test('editing $kind takes current version and keeps source metadata', () {
      final current = record(kind: kind);
      final saved = CapabilityDraft.fromRecord(current).copyWith(
        content: '旧草稿不能覆盖当前版本',
        creationMode: kind == CapabilityKind.plugin ? 'mcp' : 'import',
        importSource: {'type': 'archive', 'bytes': 131072},
      );
      final edit = CapabilityDraft.fromRecord(current, savedDraft: saved);
      expect(edit.content, current.currentVersion!.content);
      expect(edit.files, current.currentVersion!.files);
      expect(edit.presentation, current.presentation);
      expect(edit.targetCapabilityId, current.id);
      expect(edit.creationMode, saved.creationMode);
      expect(edit.importSource, saved.importSource);
    });
  }

  test('installed packages cannot become editable author works', () {
    for (final origin in ['github', 'upload', 'market']) {
      expect(
        () => CapabilityDraft.fromRecord(record(origin: origin)),
        throwsFormatException,
      );
    }
  });

  test('missing version content cannot open an empty author editor', () {
    expect(
      () => CapabilityDraft.fromRecord(
        record().copyWith(versions: [], currentVersionId: 'missing'),
      ),
      throwsFormatException,
    );
  });

  testWidgets(
    'published editor restores upload and current data over stale draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(834, 1194));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final current = record();
      await tester.runAsync(
        () => CapabilityStore.instance.saveAuthoringDraft(
          CapabilityDraft.fromRecord(current).copyWith(
            content: '过期草稿',
            cloudOwnerEmail: 'owner@example.com',
            presentation: {'title': '过期名称'},
            importSource: {'type': 'archive', 'bytes': 131072},
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showExtensionCreation(
                  context,
                  record: current,
                  cloud: cloudFor([current]),
                ),
                child: const Text('编辑作品'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑作品'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前版本 v'), findsNothing);
      expect(find.text('我的阅读助手'), findsOneWidget);
      expect(find.text('128 KB'), findsOneWidget);
      expect(find.text('过期名称'), findsNothing);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(
        fields.map((f) => f.controller?.text),
        containsAll(['我的阅读助手', '当前版本简介']),
      );
      await tester.tap(find.text('详细介绍（可选）'));
      await tester.pumpAndSettle();
      expect(find.text('当前版本详细介绍'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'MCP editing restores its canvas and reuses the private connection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(834, 1194));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final current = record(kind: CapabilityKind.plugin, mcp: true);
      await tester.runAsync(
        () => CapabilityStore.instance.saveAuthoringDraft(
          CapabilityDraft.fromRecord(
            current,
          ).copyWith(creationMode: 'mcp', cloudOwnerEmail: 'owner@example.com'),
        ),
      );
      Map<String, dynamic>? tested;
      final cloud = CapabilityCloudSync.forTesting(
        MockClient((request) async {
          Object body = {'items': []};
          if (request.url.path.endsWith('/health')) {
            body = {
              'release_id': releaseId,
              'api_contract_version': apiContractVersion,
            };
          } else if (request.url.path.endsWith('/mcp/connections')) {
            body = {
              'items': [
                {
                  'id': 'private-reading',
                  'name': 'reading',
                  'url': 'https://example.com/mcp',
                },
              ],
            };
          } else if (request.url.path.endsWith('/mcp/connection-tests')) {
            tested = Map<String, dynamic>.from(jsonDecode(request.body));
            body = {'tool_count': 1};
          }
          return http.Response(jsonEncode(body), 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showExtensionCreation(
                  context,
                  record: current,
                  cloud: cloud,
                ),
                child: const Text('编辑 MCP'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑 MCP'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('mcp-server-url')))
            .controller!
            .text,
        'https://example.com/mcp',
      );
      expect(find.textContaining('当前版本 v'), findsNothing);
      await tester.ensureVisible(find.text('测试连接'));
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      expect(tested?['id'], 'private-reading');
      expect(tested?.containsKey('bearer_token'), isFalse);
      expect(find.text('连接成功'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('public menu hides edit; personal author menu restores it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(834, 1194));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final own = record();
    final installed = record(id: 'other', origin: 'upload');
    for (final item in [own, installed]) {
      await CapabilityStore.instance.applyRemote(item);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionMarketPage(
          initialKind: ExtensionKind.skill,
          cloud: cloudFor([own, installed]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('管理 我的阅读助手'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
    );
    await tester.tap(find.byTooltip('管理 我的阅读助手'));
    await tester.pumpAndSettle();
    expect(find.text('编辑技能'), findsNothing);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多 我的阅读助手 操作'));
    await tester.pumpAndSettle();
    expect(find.text('编辑技能'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回技能'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('个人'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('管理 他人技能'));
    await tester.pumpAndSettle();
    expect(find.text('编辑技能'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('管理 我的阅读助手'));
    await tester.pumpAndSettle();
    expect(find.text('编辑技能'), findsOneWidget);
    await tester.tap(find.text('编辑技能'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前版本 v'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
