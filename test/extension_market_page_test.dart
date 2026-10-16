import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiaoqi_app/pages/extension_market_page.dart';

void main() {
  testWidgets('扩展市场主流程不使用路由转圈并支持筛选', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1048, 1501));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({
      'xiaoqi_extension_market_installed_v1': ['paper-reader'],
    });

    await tester.pumpWidget(const MaterialApp(home: ExtensionMarketPage()));
    await tester.pump();

    expect(find.text('扩展市场'), findsOneWidget);
    expect(find.text('论文精读'), findsWidgets);
    expect(find.text('推荐试用'), findsOneWidget);
    expect(find.text('论文检索'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('插件'));
    await tester.pump();
    expect(find.text('论文精读工作台'), findsWidgets);
    expect(find.text('Scientific Agent Skills'), findsOneWidget);

    await tester.tap(find.text('我创建的'));
    await tester.pump();
    expect(find.text('还没有创建的扩展'), findsOneWidget);
    expect(find.textContaining('作者作品页在 V1 先保持空状态。'), findsOneWidget);
  });

  testWidgets('GitHub 导入弹窗的取消和检查都能安全关闭', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MaterialApp(home: ExtensionMarketPage()));
    await tester.pump();

    await tester.tap(find.text('创建/导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从公开 GitHub 导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('创建/导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从公开 GitHub 导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始检查'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
