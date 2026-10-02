import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/note.dart';
import '../models/captured_page.dart';
import '../plugins/document_recognition/document_recognition_plugin.dart';
import '../utils/image_path_resolver.dart';
import 'database_service.dart';

/// 书页识别生成服务——App 与【数据库 + 文档识别插件】之间的唯一网关。
///
/// UI 层只读取 Note 进行渲染，任何持久化与识别请求都必须经过本服务。
/// 流程：
///   拍照 → 文档识别插件（OCR + 版面分析 → BookPageDocument）
///        → insert 笔记（含段落、样式、页眉/侧栏与页码）
class NoteGenerationService {
  NoteGenerationService._();

  /// 运行识别流程但不入库，返回草稿供确认页审阅后一次性落库。
  static Future<Note> prepareAnnotationNote(
    CapturedPage page, {
    void Function(String stage)? onProgress,
    DocumentRecognitionPlugin? plugin,
  }) {
    return generateAnnotationNote(
      page.path,
      onProgress: onProgress,
      plugin: plugin,
      dbInserter: (_) async => -1,
      dbUpdater: (_) async => 0,
      pageGroupId: page.pageGroupId,
      pageGroupIndex: page.pageGroupIndex,
      isDoublePage: page.isDoublePage,
      sourcePhotoPath: page.sourcePhotoPath,
      capturedAt: page.capturedAt,
      captureBatchId: page.captureBatchId,
      captureSequence: page.captureSequence,
    );
  }

  // ===========================================================================
  // 识别 + 首次插入
  // ===========================================================================

  /// 对 [photoPath] 指向的照片执行文档识别并入库，返回带 markdown 的 Note。
  ///
  /// 标题取自首个 type=title 的块，否则固定为 '我的笔记'。
  /// [onProgress] 接收阶段提示。其余可选参数用于测试注入。
  static Future<Note> generateAnnotationNote(
    String photoPath, {
    void Function(String stage)? onProgress,
    DocumentRecognitionPlugin? plugin,
    Future<int> Function(Note note)? dbInserter,
    Future<int> Function(Note note)? dbUpdater,
    Directory? originalStorageDir,
    String? pageGroupId,
    int? pageGroupIndex,
    bool isDoublePage = false,
    String sourcePhotoPath = '',
    String? capturedAt,
    String? captureBatchId,
    int? captureSequence,
  }) async {
    final localPath = await ImagePathResolver.resolveToLocalFile(photoPath);
    final originalPath = await _persistOriginalImage(
      localPath,
      baseDir: originalStorageDir,
    );

    onProgress?.call('正在识别书页……');
    // A split half needs perspective correction just like a single-page shot,
    // but only a page-sized quadrilateral may be used. Otherwise an exercise
    // box inside the page can be mistaken for the page itself.
    final recognizer =
        plugin ??
        resolveDocumentRecognitionPlugin(
          dewarp: true,
          strictPageDewarp: isDoublePage,
        );
    final result = await recognizer.recognize(localPath);
    debugPrint(
      '[NoteGeneration] markdown chars=${result.markdown.length} '
      'blocks=${result.blocks.length} display=${result.displayImagePath} '
      'diagnostics=${result.diagnostics}',
    );

    final document = result.document;

    // 标题取首个 title 块（去掉 VLM 输出的 # 前缀）
    String title = '我的笔记';
    for (final b in result.blocks) {
      if (b.isTitle && b.text.trim().isNotEmpty) {
        title = _cleanTitleText(b.text);
        break;
      }
    }

    final now = capturedAt ?? DateTime.now().toIso8601String();
    final note = Note(
      type: 'annotated_note',
      title: title,
      // 用户可编辑正文只保存纯文本；Markdown 仅留在结构数据的兼容字段。
      content: document.plainText,
      photoPath: result.displayImagePath,
      originalPhotoPath: originalPath,
      annotationsJson: jsonEncode(document.toJson()),
      pageGroupId: pageGroupId,
      pageGroupIndex: pageGroupIndex,
      isDoublePage: isDoublePage,
      sourcePhotoPath: sourcePhotoPath,
      captureBatchId: captureBatchId,
      groupId: pageGroupId,
      groupIndex: pageGroupIndex,
      capturedAt: capturedAt,
      captureSequence: captureSequence,
      createdAt: now,
      updatedAt: now,
    );

    final inserter =
        dbInserter ?? ((Note n) async => DatabaseService().insertNote(n));
    final id = await inserter(note);
    return note.copyWith(id: id);
  }

  /// 并发识别每一页，成功后按输入顺序一次性入库。
  /// 输入顺序被保留，与响应到达顺序无关。
  static Future<List<Note>> generateBatch(
    List<CapturedPage> pages, {
    void Function(int completed, int total)? onProgress,
    void Function(int index, String stage)? onPageProgress,
  }) async {
    if (pages.isEmpty) return const [];
    final completed = <int>{};
    final futures = <Future<Note?>>[];
    for (var i = 0; i < pages.length; i++) {
      final index = i;
      final page = pages[i];
      futures.add(() async {
        try {
          final note = await generateAnnotationNote(
            page.path,
            pageGroupId: page.pageGroupId,
            pageGroupIndex: page.pageGroupIndex,
            isDoublePage: page.isDoublePage,
            sourcePhotoPath: page.sourcePhotoPath,
            capturedAt: page.capturedAt,
            captureBatchId: page.captureBatchId,
            captureSequence: page.captureSequence,
            dbInserter: (note) async {
              return -(index + 1);
            },
            dbUpdater: (_) async => 0,
            onProgress: (stage) => onPageProgress?.call(index, stage),
          );
          return note;
        } catch (error) {
          debugPrint('[NoteGeneration] batch page $index failed: $error');
          onPageProgress?.call(index, '生成失败');
          return null;
        } finally {
          completed.add(index);
          onProgress?.call(completed.length, pages.length);
        }
      }());
    }
    final results = await Future.wait(futures);
    final successful = <Note>[];
    for (var i = 0; i < results.length; i++) {
      final note = results[i];
      if (note != null) successful.add(note);
    }
    successful.sort((a, b) {
      final sa = a.captureSequence ?? 1 << 30;
      final sb = b.captureSequence ?? 1 << 30;
      if (sa != sb) return sa.compareTo(sb);
      final ga = a.groupIndex ?? a.pageGroupIndex ?? 1 << 30;
      final gb = b.groupIndex ?? b.pageGroupIndex ?? 1 << 30;
      return ga.compareTo(gb);
    });
    if (successful.isEmpty) return const [];
    final ids = await DatabaseService().insertNotesBatch(successful);
    return [
      for (var i = 0; i < successful.length; i++)
        successful[i].copyWith(id: ids[i]),
    ];
  }

  // ===========================================================================
  // 内部工具
  // ===========================================================================

  /// 去掉 VLM/Markdown 污染在标题前的 # 前缀。
  static String _cleanTitleText(String text) {
    return text.replaceFirst(RegExp(r'^#+\s*'), '').trim();
  }

  static Future<String> _persistOriginalImage(
    String sourcePath, {
    Directory? baseDir,
  }) async {
    try {
      final source = File(sourcePath);
      if (!await source.exists() || await source.length() == 0) {
        return sourcePath;
      }
      final docs = baseDir ?? await getApplicationDocumentsDirectory();
      final outDir = Directory(p.join(docs.path, 'photos', 'original'));
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }
      final normalizedSource = p.normalize(source.absolute.path);
      final normalizedDir = p.normalize(outDir.absolute.path);
      if (p.isWithin(normalizedDir, normalizedSource)) {
        return sourcePath;
      }
      final extension = p.extension(sourcePath).isEmpty
          ? '.jpg'
          : p.extension(sourcePath);
      final destination = p.join(
        outDir.path,
        'original_${DateTime.now().microsecondsSinceEpoch}$extension',
      );
      await source.copy(destination);
      return destination;
    } catch (e) {
      debugPrint('[NoteGeneration] original persistence failed: $e');
      return sourcePath;
    }
  }
}
