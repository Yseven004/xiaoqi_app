import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/book_source.dart';
import '../models/home_chat_attachment.dart';
import 'book_library_service.dart';
import 'home_chat_attachment_preparer.dart';

class ReadingTaskMaterialIssue {
  const ReadingTaskMaterialIssue(this.sourceName, this.message);

  final String sourceName;
  final String message;
}

class ReadingTaskMaterialResult {
  const ReadingTaskMaterialResult({
    this.materials = const [],
    this.issues = const [],
  });

  final List<Map<String, Object?>> materials;
  final List<ReadingTaskMaterialIssue> issues;
}

/// Sends the selected book's original sources through the authenticated
/// attachment API. The server converts each file to Markdown with MarkItDown.
class ReadingTaskMaterials {
  ReadingTaskMaterials({CapabilityCloudSync? cloud})
    : _cloud = cloud ?? CapabilityCloudSync.instance,
      _attachments = HomeChatAttachmentPreparer(
        cloud: cloud,
        attachmentProfile: readingBookMarkItDownAttachmentProfile,
      );

  final CapabilityCloudSync _cloud;
  final HomeChatAttachmentPreparer _attachments;
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;

  Future<ReadingTaskMaterialResult> prepare({
    required BookLibraryService library,
    required int bookId,
    bool Function()? isCancelled,
  }) {
    final operation = _pending.then(
      (_) => _prepare(
        library: library,
        bookId: bookId,
        isCancelled: () => _disposed || isCancelled?.call() == true,
      ),
    );
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<ReadingTaskMaterialResult> _prepare({
    required BookLibraryService library,
    required int bookId,
    required bool Function() isCancelled,
  }) async {
    if (isCancelled()) return const ReadingTaskMaterialResult();
    final sources = await library.listSourcesForBook(bookId);
    if (sources.isEmpty || isCancelled()) {
      return const ReadingTaskMaterialResult();
    }

    final materials = <Map<String, Object?>>[];
    final issues = <ReadingTaskMaterialIssue>[];
    final authorization = (await _cloud
        .authenticatedHeaders())['Authorization'];
    if (authorization == null) throw StateError('登录状态已失效，请重新登录');

    for (final source in sources) {
      if (isCancelled()) return const ReadingTaskMaterialResult();
      final title = _sourceTitle(source);
      final format = normalizeBookSourceFormat(source.format);
      final mimeType = switch (format) {
        'pdf' => 'application/pdf',
        'epub' => 'application/epub+zip',
        _ => null,
      };
      if (mimeType == null) {
        issues.add(ReadingTaskMaterialIssue(title, '阅读任务支持转换 PDF 和 EPUB'));
        continue;
      }
      if (source.status != 'ready') {
        issues.add(ReadingTaskMaterialIssue(title, '资料尚未就绪'));
        continue;
      }
      try {
        final stat = await File(source.filePath).stat();
        if (stat.type != FileSystemEntityType.file) {
          throw const _ReadingTaskMaterialFailure('找不到原文件，请重新导入');
        }
        final stamp = _sourceStamp(source, stat);
        final attachment = HomeChatAttachment(
          id: 'reading-book-$stamp',
          name: '$title.$format',
          path: source.filePath,
          mimeType: mimeType,
          byteLength: stat.size,
          source: 'reading_task',
        );
        await _checkSession(authorization);
        if (isCancelled()) return const ReadingTaskMaterialResult();
        final prepared = await _attachments.prepare(
          attachment,
          isCancelled: isCancelled,
          expectedAuthorization: authorization,
        );
        await _checkSession(authorization);
        if (isCancelled()) return const ReadingTaskMaterialResult();

        final current = (await library.listSourcesForBook(
          source.bookId,
        )).where((item) => item.id == source.id).firstOrNull;
        if (current == null ||
            _sourceStamp(current, await File(current.filePath).stat()) !=
                stamp) {
          throw const _ReadingTaskMaterialFailure('资料已更新，请重新发送问题');
        }
        final remoteId = prepared.remoteAttachmentId;
        if (remoteId == null ||
            remoteId.isEmpty ||
            prepared.preparationPhase != 'ready' ||
            prepared.preparationCoverage != 'full') {
          throw const _ReadingTaskMaterialFailure('正文资料读取尚未完成');
        }
        materials.add({
          'id': attachment.id,
          'name': '$title.md',
          'attachment_id': remoteId,
          'kind': 'document',
        });
        if (prepared.preparationSkippedPages > 0) {
          issues.add(
            ReadingTaskMaterialIssue(
              title,
              '已同步可读取的正文。有 ${prepared.preparationSkippedPages} 页没有可提取的文字。',
            ),
          );
        }
      } on _ReadingTaskAccountChanged {
        rethrow;
      } on Object catch (error) {
        if (error is AttachmentCloudException &&
            error.code == 'account_changed') {
          throw const _ReadingTaskAccountChanged();
        }
        if (isCancelled()) return const ReadingTaskMaterialResult();
        issues.add(ReadingTaskMaterialIssue(title, _materialError(error)));
      }
    }
    await _checkSession(authorization);
    return ReadingTaskMaterialResult(
      materials: List.unmodifiable(materials),
      issues: List.unmodifiable(issues),
    );
  }

  Future<void> _checkSession(String authorization) async {
    try {
      final headers = await _cloud.authenticatedHeaders();
      if (headers['Authorization'] == authorization) return;
    } on StateError {
      // A signed-out session cannot reference the converted materials.
    }
    throw const _ReadingTaskAccountChanged();
  }

  String _sourceStamp(BookSourceRecord source, FileStat stat) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            source.bookId,
            source.id,
            source.filePath,
            source.displayName,
            source.format,
            source.status,
            source.updatedAt,
            source.contentHash,
            source.sourceVersionId,
            stat.size,
            stat.modified.microsecondsSinceEpoch,
          ]),
        ),
      )
      .toString();

  String _sourceTitle(BookSourceRecord source) {
    final cleaned = source.displayName
        .replaceAll(RegExp(r'[\x00-\x1f\x7f/\\]'), ' ')
        .replaceFirst(RegExp(r'\.(pdf|epub)$', caseSensitive: false), '')
        .trim();
    return cleaned.isEmpty
        ? '阅读资料'
        : String.fromCharCodes(cleaned.runes.take(120));
  }

  String _materialError(Object error) => switch (error) {
    _ReadingTaskMaterialFailure(:final message) => message,
    AttachmentCloudException(code: 'no_readable_text') => '没有可提取的文字',
    AttachmentCloudException(code: 'invalid_size') => '原始资料为空或超过 256 MB 限制',
    AttachmentCloudException(code: 'unexpected_attachment_profile') =>
      '服务端暂未提供所需的 Markdown 转换',
    AttachmentCloudException(code: 'attachment_not_ready') =>
      '正文资料仍在准备，请重新发送问题',
    AttachmentCloudException() => '正文同步失败，请重新发送问题重试',
    FormatException() => '无法整理正文，请检查原文件后重试',
    _ => '正文同步失败，请重新发送问题重试',
  };

  Future<void> dispose() {
    if (_disposed) return _pending;
    _disposed = true;
    _attachments.dispose();
    return _pending;
  }
}

class _ReadingTaskAccountChanged extends FormatException {
  const _ReadingTaskAccountChanged() : super('账号已变更，请重新发送问题');
}

class _ReadingTaskMaterialFailure extends FormatException {
  const _ReadingTaskMaterialFailure(super.message);
}
