import 'dart:convert';
import 'dart:io';

import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import '../models/note_attachment.dart';
import 'companion_annotation_store.dart';
import 'companion_annotation_sync.dart';
import 'database_service.dart';

class CompanionAnnotationLibrary {
  const CompanionAnnotationLibrary();

  Future<int> copyToLibrary(
    CompanionAnnotation annotation, {
    required String scope,
  }) async {
    final db = DatabaseService();
    final existing = await db.existingCompanionAnnotationSnapshotId(
      scope: scope,
      annotationId: annotation.id,
      revision: annotation.revision,
    );
    if (existing != null) return existing;
    final selection = annotation.selection;
    final timestamp = DateTime.now().toIso8601String();
    final paths = [
      for (final path in annotation.audio) (path: path, kind: 'audio'),
      for (final path in annotation.images) (path: path, kind: 'image'),
    ];
    final attachments = <NoteAttachment>[];
    Directory? staging;
    var committed = false;
    try {
      if (paths.isNotEmpty) {
        try {
          await CompanionAnnotationSync.instance.ensureMedia(scope, annotation);
        } catch (_) {
          throw const FormatException('图片或录音尚未下载，请联网后重试');
        }
        final documents = await getApplicationDocumentsDirectory();
        final directory = Directory(p.join(documents.path, 'note_attachments'));
        await directory.create(recursive: true);
        staging = await directory.createTemp('companion_snapshot_');
        for (final (index, item) in paths.indexed) {
          final source = File(item.path);
          if (!await source.exists()) {
            throw const FormatException('图片或录音尚未下载，请联网后重试');
          }
          final extension = p.extension(item.path).toLowerCase();
          final mime = _mimeTypes[extension];
          if (mime == null || !mime.startsWith('${item.kind}/')) {
            throw const FormatException('图片或录音格式不支持');
          }
          final length = await source.length();
          if (length == 0) throw const FormatException('图片或录音文件不完整');
          final target = await source.copy(
            p.join(staging.path, '$index$extension'),
          );
          if (await target.length() != length) {
            throw const FormatException('附件复制不完整，请重试');
          }
          attachments.add(
            NoteAttachment(
              name: item.kind == 'audio' ? '录音$extension' : '图片$extension',
              relativePath: p.relative(target.path, from: documents.path),
              kind: item.kind,
              mimeType: mime,
              position: index,
              createdAt: timestamp,
            ),
          );
        }
      }
      final text = [
        '引文\n${selection.quote}',
        if (annotation.text.isNotEmpty) annotation.text,
      ].join('\n\n');
      final delta = [
        {'insert': '$text\n'},
        for (final attachment in attachments) ...[
          {
            'insert': quill.BlockEmbed.custom(
              quill.CustomBlockEmbed(
                'note_attachment',
                jsonEncode({
                  'name': attachment.name,
                  'relativePath': attachment.relativePath,
                  'kind': attachment.kind,
                  'mimeType': attachment.mimeType,
                }),
              ),
            ).toJson(),
          },
          {'insert': '\n'},
        ],
      ];
      final saved = await db.saveCompanionAnnotationSnapshot(
        scope: scope,
        annotationId: annotation.id,
        revision: annotation.revision,
        bookId: selection.bookId,
        sourceId: selection.sourceId,
        selection: selection.toJson(),
        note: Note(
          type: 'text',
          title: selection.locator.isEmpty ? '书内注释' : selection.locator,
          content: text,
          contentDelta: jsonEncode(delta),
          sourceType: 'companion_annotation_snapshot',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
        attachments: attachments,
      );
      committed = saved.created;
      return saved.noteId;
    } finally {
      if (!committed && staging != null) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          // The copy attempt has no published database row.
        }
      }
    }
  }

  static const _mimeTypes = {
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',
    '.webp': 'image/webp',
    '.heic': 'image/heic',
    '.heif': 'image/heif',
    '.gif': 'image/gif',
    '.m4a': 'audio/mp4',
  };
}
