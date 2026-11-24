import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/models/book_recognition.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/pages/book_sources_page.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';

void main() {
  for (final (name, size, populated, scale) in [
    ('tablet header', const Size(800, 1280), true, 1.0),
    ('phone empty state', const Size(320, 720), false, 1.0),
    ('large-text phone empty state', const Size(320, 630), false, 1.6),
  ]) {
    testWidgets('book source menu opens below the $name import button', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: BookSourcesPage(
            bookId: 4,
            bookLibraryService: _Library(populated),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = find.byWidgetPredicate((widget) => widget is FilledButton);
      final anchor = tester.getRect(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      final pointer = find.byWidgetPredicate((widget) {
        if (widget is! SvgPicture) return false;
        final loader = widget.bytesLoader;
        return loader is SvgAssetLoader &&
            loader.assetName == 'assets/images/book_import_menu_pointer.svg';
      });
      final card = find.ancestor(
        of: find.text('支持 PDF、EPUB'),
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.elevation == 12,
        ),
      );
      final menu = tester.getRect(card);
      expect(tester.getRect(pointer).top, closeTo(anchor.bottom, .01));
      expect(tester.getRect(pointer).center.dx, closeTo(anchor.center.dx, .01));
      expect(menu.top, closeTo(anchor.bottom + 14, .01));
      expect(menu.left, greaterThanOrEqualTo(16));
      expect(menu.right, lessThanOrEqualTo(size.width - 16));
      if (populated) expect(menu.right, closeTo(anchor.right, .01));
      expect(find.text('本机导入'), findsOneWidget);
      expect(find.text('微信导入'), findsOneWidget);
      expect(find.text('网上找书'), findsOneWidget);
      expect(find.text('扫描/输入 ISBN'), findsNothing);
      expect(find.byTooltip('关闭'), findsNothing);
      if (scale > 1) {
        final online = find.text('网上找书').hitTestable();
        expect(online, findsNothing);
        final scrollView = find.descendant(
          of: card,
          matching: find.byType(SingleChildScrollView),
        );
        await tester.drag(scrollView, const Offset(0, -320));
        await tester.pumpAndSettle();
        expect(online, findsOneWidget);
        expect(tester.getRect(card), menu);
        await tester.tap(online);
        await tester.pumpAndSettle();
        expect(find.text('想找哪本书？'), findsOneWidget);
        expect(find.byTooltip('发送'), findsOneWidget);
        expect(pointer, findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('想找哪本书？'), findsNothing);
        expect(tester.takeException(), isNull);
        return;
      }

      await tester.tapAt(Offset(size.width / 2, 12));
      await tester.pumpAndSettle();
      expect(pointer, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

class _Library extends BookLibraryService {
  _Library(this.populated);

  final bool populated;

  @override
  Future<BookRecord?> getBook(int id) async =>
      BookRecord(id: id, title: '测试读本');

  @override
  Future<List<BookSourceRecord>> listSourcesForBook(int bookId) async => [
    if (populated)
      BookSourceRecord(
        id: 1,
        bookId: bookId,
        kind: 'book_file',
        displayName: '导入资料夹具.pdf',
        filePath: 'unopened-fixture.pdf',
        fileSize: 1,
        contentHash: 'fixture',
        status: 'ready',
        isPrimary: true,
        createdAt: '2026-11-20T23:27:00',
        updatedAt: '2026-11-20T23:27:00',
      ),
  ];
}
