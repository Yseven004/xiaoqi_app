import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/models/reader_pagination.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/services/reader_pagination_preferences.dart';
import 'package:xiaoqi_app/widgets/reading_companion.dart';

import 'companion_pdf_preparation_support.dart';

const _paperCapture = ValueKey('companion-pdf-paper-capture');

void main() {
  testWidgets('PDF outline keeps only the current branch open initially', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await const ReaderPaginationPreferences().saveAnchor(
      bookId: 1,
      anchor: const PdfReaderAnchor(sourceId: '1', pageNumber: 2),
    );
    final source = await _pdfSource(tester);
    try {
      await _openReader(tester, source);
      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();

      final firstPart = find.text('第一部分');
      final firstChapter = find.text('第一章');
      final secondChapter = find.text('第二章');
      expect(firstPart, findsOneWidget);
      expect(firstChapter, findsNothing);
      expect(secondChapter, findsOneWidget);
      expect(find.text('正在读 · 第 2 页'), findsOneWidget);
      expect(
        tester.getTopLeft(secondChapter).dx,
        greaterThan(tester.getTopLeft(find.text('第二部分')).dx),
      );

      final collapsed = find.byTooltip('展开章节');
      await tester.ensureVisible(collapsed);
      await tester.tap(collapsed.hitTestable());
      await tester.pumpAndSettle();
      expect(firstChapter, findsOneWidget);
      final expand = find.bySemanticsLabel('展开目录');
      await tester.drag(expand, const Offset(0, -420));
      await tester.pumpAndSettle();
      expect(firstChapter, findsOneWidget);

      final heading = find.bySemanticsLabel('收起目录');
      final top = tester.getTopLeft(heading);
      final title = find.text('outline.pdf');
      final outlineTitle = find.descendant(
        of: heading,
        matching: find.text('目录'),
      );
      expect(
        tester.getTopLeft(find.text('章节')).dx,
        tester.getTopLeft(outlineTitle).dx,
      );
      expect(find.text('测试目录'), findsNothing);
      final titlePosition = tester.getTopLeft(title);
      final list = find.ancestor(
        of: secondChapter,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(list).position;
      final offset = position.pixels;
      await tester.drag(secondChapter, const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(offset));
      expect(tester.getTopLeft(heading), top);
      expect(tester.getTopLeft(title), titlePosition);

      await tester.tap(find.text('注释'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('展开注释'), findsOneWidget);
      expect(find.text('章节'), findsNothing);
      expect(find.text('暂无注释'), findsOneWidget);
    } finally {
      await _closeReader(tester);
    }
  });

  testWidgets('PDF display shows supported settings and clears its override', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({
      'reading-companion.brightness': .8,
    });
    final brightnessChanges = <double?>[];
    const channel = MethodChannel('xiaoqi_app/runtime_config');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setCompanionBrightness') {
        brightnessChanges.add(call.arguments['brightness'] as double?);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    try {
      final source = await _pdfSource(tester);
      await _openReader(tester, source);
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();

      for (final label in ['字号', '行距', '边距', '排版', '打开电子书']) {
        expect(find.text(label), findsNothing);
      }
      final day = find.widgetWithText(TextButton, '白天');
      final night = find.widgetWithText(TextButton, '暗夜');
      Color? fill(Finder button) =>
          tester.widget<TextButton>(button).style?.backgroundColor?.resolve({});
      expect(fill(day), const Color(0xFF262626));
      expect(fill(night), Colors.transparent);
      final paper =
          tester.getRect(find.byType(PdfViewer)).topCenter +
          const Offset(0, 350);
      expect(await _paperRed(tester, paper), greaterThan(200));
      await tester.tap(night);
      await tester.pumpAndSettle();
      expect(fill(day), Colors.transparent);
      expect(fill(night), const Color(0xFFE6E3DC));
      expect(await _paperRed(tester, paper), lessThan(65));

      final slider = find.byType(Slider);
      final marker = find.bySemanticsLabel('恢复默认亮度');
      final markerCenter = tester.getCenter(marker);
      expect(markerCenter.dy, tester.getCenter(slider).dy);
      expect(tester.widget<Slider>(slider).value, .8);
      await tester.tapAt(markerCenter);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, .65);
      expect(brightnessChanges, [.8, null]);

      final gesture = await tester.startGesture(markerCenter);
      await gesture.moveBy(const Offset(32, 0));
      await gesture.moveBy(const Offset(36, 0));
      await tester.pump();
      final draft = tester.widget<Slider>(slider).value;
      expect(draft, greaterThan(.65));
      expect(
        brightnessChanges.last,
        draft,
        reason: 'Window brightness changes before the finger lifts',
      );
      final updatesBeforeRelease = brightnessChanges.length;
      await gesture.up();
      await tester.pumpAndSettle();
      expect(brightnessChanges.length, updatesBeforeRelease);

      await tester.tapAt(markerCenter);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, .65);
      expect(brightnessChanges.last, isNull);
      expect(
        (await SharedPreferences.getInstance()).getDouble(
          'reading-companion.brightness',
        ),
        isNull,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await _closeReader(tester);
    }
  });
}

Future<int?> _paperRed(WidgetTester tester, Offset point) =>
    tester.runAsync(() async {
      final capture = find.byKey(_paperCapture);
      final local = point - tester.getTopLeft(capture);
      final boundary = tester.renderObject<RenderRepaintBoundary>(capture);
      final image = await boundary.toImage();
      try {
        final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return rgba!.getUint8(
          (local.dy.round() * image.width + local.dx.round()) * 4,
        );
      } finally {
        image.dispose();
      }
    });

Future<void> _openReader(WidgetTester tester, BookSourceRecord source) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1280);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final reply = ValueNotifier('');
  addTearDown(reply.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        key: _paperCapture,
        child: ReadingCompanion(
          bookId: 1,
          library: BookLibraryService(),
          messages: const [],
          streamingReply: reply,
          composerBuilder: (history) => history,
          onPassageOpened: (_) {},
          target: ReadingCompanionTarget(
            title: '测试目录',
            source: source,
            sources: [source],
          ),
        ),
      ),
    ),
  );
  final directory = find.ancestor(
    of: find.text('目录'),
    matching: find.byType(InkWell),
  );
  bool ready() {
    final pdf = tester
        .widgetList<PdfViewer>(find.byType(PdfViewer))
        .firstOrNull
        ?.controller;
    return pdf != null &&
        pdf.isReady &&
        pdf.document.pages.every((page) => page.isLoaded) &&
        tester
            .widgetList<InkWell>(directory)
            .any((button) => button.onTap != null);
  }

  for (var frame = 0; frame < 100 && !ready(); frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue);
  // Native PDF work needs wall time. A spinning toolbar keeps scheduling
  // frames, so pumpAndSettle alone can exhaust its fake clock first.
  final loading = find.byType(CircularProgressIndicator);
  for (var frame = 0; frame < 600 && loading.evaluate().isNotEmpty; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(loading, findsNothing);
}

Future<void> _closeReader(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
  await finishCompanionPdfPreparation(tester);
  for (var index = 0; index < 5; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<BookSourceRecord> _pdfSource(WidgetTester tester) async {
  final directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('companion-outline-'),
  ))!;
  final previousCache = Pdfrx.cacheDirectoryPath;
  Pdfrx.cacheDirectoryPath = directory.path;
  addTearDown(() async {
    Pdfrx.cacheDirectoryPath = previousCache;
    for (var attempt = 0; ; attempt++) {
      try {
        await directory.delete(recursive: true);
        break;
      } on FileSystemException catch (error) {
        if (!Platform.isWindows ||
            error.osError?.errorCode != 32 ||
            attempt >= 20) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });
  final file = File('${directory.path}/outline.pdf');
  await tester.runAsync(() => file.writeAsString(_threePagePdf()));
  return BookSourceRecord(
    id: 1,
    bookId: 1,
    kind: 'book_file',
    displayName: 'outline.pdf',
    filePath: file.path,
    fileSize: 0,
    contentHash: '',
    status: 'ready',
    isPrimary: true,
    catalogJson: jsonEncode([
      {'id': 'part1', 'title': '第一部分', 'level': 1},
      {
        'id': 'ch1',
        'title': '第一章',
        'level': 1,
        'parent_id': 'part1',
        'pdf_page': 1,
      },
      {'id': 'part2', 'title': '第二部分', 'level': 1},
      {
        'id': 'ch2',
        'title': '第二章',
        'level': 1,
        'parent_id': 'part2',
        'pdf_page': 2,
      },
      for (var number = 1; number <= 25; number++)
        {'id': 'appendix$number', 'title': '附录 $number', 'pdf_page': 3},
    ]),
    createdAt: '',
    updatedAt: '',
  );
}

String _threePagePdf() {
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count 3 /Kids [3 0 R 4 0 R 5 0 R] >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Contents 6 0 R >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Contents 6 0 R >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Contents 6 0 R >>',
    '<< /Length 0 >>\nstream\nendstream',
  ];
  final output = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(output.length);
    output.write('${index + 1} 0 obj\n${objects[index]}\nendobj\n');
  }
  final xref = output.length;
  final size = offsets.length + 1;
  output.write('xref\n0 $size\n0000000000 65535 f \n');
  for (final offset in offsets) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size $size /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return output.toString();
}
