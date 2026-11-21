import 'dart:io';

import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaoqi_app/models/book_recognition.dart';
import 'package:xiaoqi_app/models/book_source.dart';
import 'package:xiaoqi_app/pages/book_sources_page.dart';
import 'package:xiaoqi_app/services/book_library_service.dart';
import 'package:xiaoqi_app/widgets/book_source_import.dart';

class _Picker extends FilePickerPlatform {
  PlatformFile? selection;
  List<String>? extensions;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    extensions = allowedExtensions;
    return selection;
  }
}

final class _PickedSource extends PlatformFile {
  _PickedSource(this.file);

  final File file;

  @override
  Uri get uri => file.uri;
  @override
  String get name => '本机资料.epub';
  @override
  XFile get xFile => XFile(file.path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Library extends BookLibraryService {
  final sources = <BookSourceRecord>[];
  int? importedBook;
  String? importedPath;
  String? renamed;

  @override
  Future<BookRecord?> getBook(int id) async =>
      BookRecord(id: id, title: '测试读本');

  @override
  Future<List<BookSourceRecord>> listSourcesForBook(int bookId) async =>
      sources.where((source) => source.bookId == bookId).toList();

  @override
  Future<void> renameBookSource({
    required int bookId,
    required int sourceId,
    required String displayName,
  }) async {
    final index = sources.indexWhere(
      (source) => source.id == sourceId && source.bookId == bookId,
    );
    final old = sources[index];
    renamed = displayName;
    sources[index] = _source(
      old.filePath,
      displayName,
      id: old.id,
      bookId: old.bookId,
      format: old.format,
    );
  }

  @override
  Future<BookSourceImportResult> importBookSourceForBook({
    required int bookId,
    required String sourcePath,
    required String displayName,
    required String format,
  }) async {
    importedBook = bookId;
    importedPath = sourcePath;
    final source = _source(
      sourcePath,
      displayName,
      bookId: bookId,
      format: format,
    );
    sources.add(source);
    return BookSourceImportResult(source: source, reusedExisting: false);
  }
}

BookSourceRecord _source(
  String path,
  String name, {
  int id = 15,
  int bookId = 4,
  String format = 'epub',
}) => BookSourceRecord(
  id: id,
  bookId: bookId,
  kind: 'book_file',
  format: format,
  isPrimary: true,
  displayName: name,
  filePath: path,
  fileSize: 512,
  contentHash: 'test-source',
  status: 'ready',
  createdAt: '2026-11-20T21:10:00',
  updatedAt: '2026-11-20T21:10:00',
);

Future<void> _openChooser(WidgetTester tester) async {
  await tester.tap(find.text('导入资料'));
  await tester.pumpAndSettle();
  expect(find.text('本机导入'), findsOneWidget);
  expect(find.text('微信导入'), findsOneWidget);
  expect(find.text('网上找书'), findsOneWidget);
  expect(find.text('扫描/输入 ISBN'), findsNothing);
  expect(find.text('导入中'), findsNothing);
}

Future<void> _awaitUi(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 50 && !finder.tryEvaluate(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsOneWidget);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('local picker cancel leaves the book ready for another import', (
    tester,
  ) async {
    final original = FilePickerPlatform.instance;
    final picker = _Picker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);
    final root = Directory.systemTemp.createTempSync('book-picker-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/picker-cache.epub')
      ..writeAsStringSync('test');
    final library = _Library();
    await tester.pumpWidget(
      MaterialApp(
        home: BookSourcesPage(bookId: 4, bookLibraryService: library),
      ),
    );
    await tester.pumpAndSettle();
    await _openChooser(tester);
    await tester.tap(find.text('本机导入'));
    await tester.pumpAndSettle();
    expect(picker.extensions, ['pdf', 'epub']);
    expect(library.importedBook, isNull);
    expect(find.text('导入中'), findsNothing);
    picker.selection = _PickedSource(file);
    await _openChooser(tester);
    await tester.tap(find.text('本机导入'));
    await _awaitUi(tester, find.text('本机资料.epub'));
    expect(library.importedBook, 4);
    expect(library.importedPath, file.path);
  });

  testWidgets('online search switches modes and closes on a narrow display', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(320, 630));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = _Library();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: BookSourcesPage(bookId: 4, bookLibraryService: library),
      ),
    );
    await tester.pumpAndSettle();
    await _openChooser(tester);
    await tester.ensureVisible(find.text('网上找书'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('网上找书'));
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    final dialogBounds = tester.getRect(dialog);
    expect(find.text('想找哪本书？'), findsOneWidget);
    expect(find.text('帮我找《Hello 算法》中文版 ↗'), findsOneWidget);
    expect(find.text('查找《测试读本》'), findsOneWidget);
    expect(find.text('AI 对话'), findsOneWidget);
    expect(find.text('直接搜索'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.enterText(find.byType(TextField), '找中文电子书');
    await tester.tap(find.text('直接搜索'));
    await tester.pumpAndSettle();
    expect(tester.getRect(dialog), dialogBounds);
    expect(find.byTooltip('搜索'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '测试读本',
    );
    expect(find.text('想找哪本书？'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(find.text('AI 对话'));
    await tester.pumpAndSettle();
    expect(find.text('找中文电子书'), findsOneWidget);
    expect(library.sources, isEmpty);

    await tester.tap(find.text('直接搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(find.text('请先登录个人账号'), findsOneWidget);
    expect(find.byType(A2uiSurface), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('还没有导入资料'), findsOneWidget);
    await _openChooser(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Wechat captures only a book file during the scoped guide', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('book-share-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/shared.epub')
      ..writeAsStringSync('test');
    final epub = SharedMediaFile(
      path: file.path,
      type: SharedMediaType.file,
      mimeType: 'application/epub+zip',
    );
    final other = SharedMediaFile(
      path: 'https://example.test/book',
      type: SharedMediaType.url,
    );
    final library = _Library();
    await tester.pumpWidget(
      MaterialApp(
        home: BookSourcesPage(bookId: 4, bookLibraryService: library),
      ),
    );
    await tester.pumpAndSettle();
    expect(routeExistingBookSharedMedia([epub]), [epub]);
    await _openChooser(tester);
    await tester.tap(find.text('微信导入'));
    await tester.pumpAndSettle();
    expect(find.text('选择已保存文件'), findsOneWidget);
    expect(routeExistingBookSharedMedia([other]), [other]);
    expect(routeExistingBookSharedMedia([other, epub]), [other]);
    await _awaitUi(tester, find.text('shared.epub'));
    expect(library.importedBook, 4);
    expect(library.importedPath, file.path);
    expect(routeExistingBookSharedMedia([epub]), [epub]);
    await _openChooser(tester);
    await tester.tap(find.text('微信导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(routeExistingBookSharedMedia([epub]), [epub]);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('inline pencil opens keyboard and saves the same source id', (
    tester,
  ) async {
    final library = _Library()..sources.add(_source('', '电子书原文'));
    await tester.pumpWidget(
      MaterialApp(
        home: BookSourcesPage(bookId: 4, bookLibraryService: library),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑资料名称'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(find.byType(TextField), ' ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('请输入资料名称'), findsOneWidget);
    expect(library.renamed, isNull);
    await tester.enterText(find.byType(TextField), '  电子书校订版  ');
    await tester.tap(find.text('导入资料'));
    await tester.pumpAndSettle();
    expect(find.text('本机导入'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('电子书原文'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑资料名称'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '  电子书校订版  ',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('电子书校订版'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('编辑资料名称'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(library.renamed, '电子书校订版');
    expect(library.sources.single.id, 15);
    expect(library.sources.single.filePath, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing Android keyboard restores the original name row', (
    tester,
  ) async {
    final library = _Library()
      ..sources.addAll([_source('', '电子书原文'), _source('', '阅读笔记', id: 16)]);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        home: BookSourcesPage(bookId: 4, bookLibraryService: library),
      ),
    );
    await tester.pumpAndSettle();
    final pencils = find.byTooltip('编辑资料名称');
    final editor = find.byType(TextField);
    for (final index in [0, 1]) {
      await tester.tap(pencils.at(index));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      if (index == 1) await tester.enterText(editor, '未保存的笔记新名称');
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      expect(pencils, findsNWidgets(2));
      expect(find.text('电子书原文'), findsOneWidget);
      expect(find.text('阅读笔记'), findsOneWidget);
      expect(library.renamed, isNull);
    }

    await tester.tap(pencils.last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(editor).controller!.text, '未保存的笔记新名称');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
    expect(pencils, findsNWidgets(2));
    expect(library.sources.last.displayName, '未保存的笔记新名称');
    expect(library.sources.last.id, 16);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
