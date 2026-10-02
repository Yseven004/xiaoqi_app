import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/note.dart';
import '../models/ocr_layout.dart';
import '../widgets/app_toast.dart';
import 'database_service.dart';

/// 笔记阅读页的通用操作：保存到笔记库 / 分享给他人。
///
/// 生成流程本身已把笔记落库，「保存」用于用户在阅读/微调后手动确认更新；
/// 「分享」优先分享排版 PDF，无 PDF 时退化为标题 + 正文文本。
class NoteActions {
  NoteActions._();

  /// 保存（刷新 updated_at 时间戳），成功后提示「已保存到笔记库」。
  static Future<void> save(BuildContext context, Note note) async {
    try {
      if (note.id != null) {
        await DatabaseService().update(
          note.copyWith(updatedAt: DateTime.now().toIso8601String()),
        );
      }
      if (context.mounted) AppToast.show(context, '已保存到笔记库');
    } catch (e) {
      debugPrint('[NoteActions] 保存失败: $e');
      if (context.mounted) AppToast.show(context, '保存失败，请重试');
    }
  }

  /// 分享：有 PDF 发文件，否则发标题 + 正文（markdown / OCR 文本 / content）。
  static Future<void> share(BuildContext context, Note note) async {
    try {
      final title = note.title.trim().isEmpty ? '我的笔记' : note.title.trim();

      final pdfPath = note.pdfPath.trim();
      if (pdfPath.isNotEmpty && await File(pdfPath).exists()) {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(pdfPath)], text: title, subject: title),
        );
        return;
      }

      final buffer = StringBuffer(title);
      final body = _shareBody(note);
      if (body.isNotEmpty) {
        buffer
          ..writeln()
          ..writeln()
          ..write(body);
      }
      await SharePlus.instance.share(
        ShareParams(text: buffer.toString(), subject: title),
      );
    } catch (e) {
      debugPrint('[NoteActions] 分享失败: $e');
      if (context.mounted) AppToast.show(context, '分享失败，请重试');
    }
  }

  static Future<void> exportMarkdown(BuildContext context, Note note) async {
    try {
      final title = note.title.trim().isEmpty ? '未命名笔记' : note.title.trim();
      final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final directory = await getTemporaryDirectory();
      final file = File(p.join(directory.path, '$safeName.md'));
      final body = _shareBody(note);
      await file.writeAsString('# $title\n\n$body\n', flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/markdown')],
          text: title,
          subject: title,
        ),
      );
    } catch (error) {
      debugPrint('[NoteActions] Markdown 导出失败: $error');
      if (context.mounted) AppToast.show(context, 'Markdown 导出失败，请重试');
    }
  }

  /// 分享正文：优先 OCR markdown，其次块文本，最后 content 字段。
  static String _shareBody(Note note) {
    final raw = note.annotationsJson;
    if (raw != null && raw.isNotEmpty) {
      try {
        final data = AnnotatedNoteData.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        final md = data.markdown.trim();
        if (md.isNotEmpty) return md;
        final blocks = data.ocrLayout
            .map((b) => b.text.trim())
            .where((t) => t.isNotEmpty)
            .join('\n');
        if (blocks.isNotEmpty) return blocks;
      } catch (_) {
        // 落回 content
      }
    }
    return note.content.trim();
  }
}
