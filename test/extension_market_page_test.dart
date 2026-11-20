import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/pages/extension_market_page.dart';
import 'package:xiaoqi_app/features/capabilities/presentation/market_skill_editor.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/events'),
          (_) async => null,
        );
  });

  test(
    'checked skill package keeps its actual name, content and binary attachment',
    () {
      const document =
          '---\nname: test-skill\ndescription: test description\n---\n\nActual instructions';
      final package = Archive()
        ..addFile(ArchiveFile.bytes('bundle/SKILL.md', utf8.encode(document)))
        ..addFile(ArchiveFile.bytes('bundle/assets/data.bin', [0, 255, 7]));
      final draft = skillDraftFromUpload(
        fileName: 'skill.zip',
        bytes: ZipEncoder().encode(package),
        root: 'bundle',
        policy: {
          'max_files': 128,
          'max_file_bytes': 2097152,
          'max_expanded_bytes': 10485760,
        },
      );
      expect(draft.name, 'test-skill');
      expect(draft.content, document);
      expect(base64Decode(draft.files['assets/data.bin']!), [0, 255, 7]);
      expect(draft.files.containsKey('SKILL.md'), isFalse);
    },
  );

  test('checked skill reader refuses traversal before creating a draft', () {
    final package = Archive()
      ..addFile(ArchiveFile.bytes('../SKILL.md', [1, 2, 3]));
    expect(
      () => skillDraftFromUpload(
        fileName: 'skill.zip',
        bytes: ZipEncoder().encode(package),
        root: '',
        policy: {
          'max_files': 128,
          'max_file_bytes': 2097152,
          'max_expanded_bytes': 10485760,
        },
      ),
      throwsFormatException,
    );
  });

  testWidgets(
    'V2 groups MCP under plugins without seeded marketplace entries',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(834, 1194));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const MaterialApp(home: ExtensionMarketPage()));
      await tester.pump();
      expect(find.text('插件'), findsWidgets);
      expect(find.text('MCP'), findsNothing);
      expect(find.text('Scientific Agent Skills'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.text('技能'));
      await tester.tap(find.text('我的'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'not-found');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('请先登录'), findsWidgets);
      expect(find.text('文献综述'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets('companion is a searchable built-in setting under My plugins', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(834, 1194));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: ExtensionMarketPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('已安装'));
    await tester.pumpAndSettle();
    expect(find.text('沉浸伴读'), findsNothing);
    expect(find.text('内置插件'), findsNothing);

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('内置插件'), findsOneWidget);
    expect(find.text('我的插件'), findsOneWidget);
    expect(find.text('登录后查看个人插件'), findsOneWidget);
    expect(find.text('还没有个人插件'), findsNothing);
    expect(find.textContaining('Bad state:'), findsNothing);
    final companionSwitch = find.byType(Switch);
    expect(companionSwitch, findsOneWidget);
    final wasEnabled = tester.widget<Switch>(companionSwitch).value;
    await tester.tap(companionSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(companionSwitch).value, !wasEnabled);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'reading-companion.enabled',
      ),
      !wasEnabled,
    );

    final search = find.byType(TextField);
    await tester.enterText(search, 'AI 伴读');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('沉浸伴读'), findsOneWidget);
    expect(find.text('我的插件'), findsNothing);
    await tester.enterText(search, '找不到的插件');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('沉浸伴读'), findsNothing);
    expect(find.text('没有找到相关内容'), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(find.text('我的插件'), findsOneWidget);
    await tester.tap(companionSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(companionSwitch).value, wasEnabled);
  });

  testWidgets('My plugins remains usable with large text in a narrow window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const ExtensionMarketPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('沉浸伴读'));
    await tester.pumpAndSettle();
    final switchTile = find.byType(SwitchListTile);
    await tester.ensureVisible(switchTile);
    expect(tester.getSize(switchTile).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'chat creation returns an ordinary new-chat request without sending',
    (tester) async {
      ExtensionChatRequest? request;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  request = await Navigator.push<ExtensionChatRequest>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ExtensionMarketPage(
                        initialKind: ExtensionKind.skill,
                      ),
                    ),
                  );
                },
                child: const Text('打开市场'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开市场'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通过聊天创建'));
      await tester.pumpAndSettle();
      expect(request?.selection['id'], 'create-skill');
      expect(request?.selection['type'], 'action');
      expect(request?.prompt, isEmpty);
    },
  );

  testWidgets('invalid GitHub URL stays in the dialog and can be cancelled', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ExtensionMarketPage(initialKind: ExtensionKind.skill),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用编辑器创建'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('import-github-url')),
      'invalid',
    );
    await tester.pump();
    await tester.ensureVisible(find.text('读取内容'));
    await tester.tap(find.text('读取内容'));
    await tester.pumpAndSettle();
    expect(find.textContaining('填写公开 GitHub'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);
    expect(find.text('重新读取'), findsOneWidget);
    await tester.tap(find.text('重新读取'));
    await tester.pumpAndSettle();
    expect(find.textContaining('填写公开 GitHub'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);
    await tester.tap(find.byTooltip('关闭创建'));
    await tester.pumpAndSettle();
    expect(find.text('读取内容'), findsNothing);
  });
}
