import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../features/capabilities/data/capability_cloud_sync.dart';
import '../models/home_chat_attachment.dart';
import 'home_chat_attachment_reader.dart';

List<int> _encodeAttachmentJpeg(
  ({int width, int height, Uint8List pixels}) input,
) => img.encodeJpg(
  img.Image.fromBytes(
    width: input.width,
    height: input.height,
    bytes: input.pixels.buffer,
    bytesOffset: input.pixels.offsetInBytes,
    numChannels: 4,
  ),
  quality: 92,
);

class AttachmentPreparationState {
  const AttachmentPreparationState({
    required this.attachmentId,
    required this.phase,
    required this.label,
    this.progress,
    this.error,
    this.retryable = false,
    this.ready = false,
    this.attachment,
  });

  final String attachmentId;
  final String phase;
  final String label;
  final double? progress;
  final String? error;
  final bool retryable;
  final bool ready;
  final HomeChatAttachment? attachment;
}

class _PreparationOperation {
  _PreparationOperation(this.fingerprint);
  final String fingerprint;
  final abort = Completer<void>();
  String? remoteId;
  String? account;
  bool failed = false;
  late Future<HomeChatAttachment> result;
  bool get cancelled => abort.isCompleted;
}

/// One preparation owner for picker, share, edit, send, and retry entrypoints.
/// Server resources and their completed pages outlive any individual request.
class HomeChatAttachmentPreparer {
  HomeChatAttachmentPreparer({
    CapabilityCloudSync? cloud,
    HomeChatAttachmentReader? reader,
  }) : _cloud = cloud ?? CapabilityCloudSync.instance,
       _reader = reader ?? HomeChatAttachmentReader();

  static const _parserVersion = 'attachment-local-2';
  final CapabilityCloudSync _cloud;
  final HomeChatAttachmentReader _reader;
  final states = ValueNotifier<Map<String, AttachmentPreparationState>>(
    const {},
  );
  final _operations = <String, _PreparationOperation>{};
  final _prepared = <String, HomeChatAttachment>{};
  final _cancellations = <String, Future<void>>{};
  bool _disposed = false;

  HomeChatAttachment? prepared(String attachmentId) => _prepared[attachmentId];

  void markCopying(HomeChatAttachment attachment) {
    if (_disposed || states.value[attachment.id]?.ready == true) return;
    states.value = {
      ...states.value,
      attachment.id: AttachmentPreparationState(
        attachmentId: attachment.id,
        phase: 'copying',
        label: '正在准备文件',
        attachment: attachment,
      ),
    };
  }

  void markCopyFailure(HomeChatAttachment attachment, Object error) {
    if (_disposed) return;
    final message = error is FormatException ? error.message : '无法读取所选文件，请重新选择';
    states.value = {
      ...states.value,
      attachment.id: AttachmentPreparationState(
        attachmentId: attachment.id,
        phase: 'copy_failed',
        label: '准备失败',
        error: message,
        attachment: attachment,
      ),
    };
  }

  void markStopped(HomeChatAttachment attachment) {
    if (_disposed || states.value[attachment.id]?.ready == true) return;
    states.value = {
      ...states.value,
      attachment.id: AttachmentPreparationState(
        attachmentId: attachment.id,
        phase: 'cancelled',
        label: '已停止',
        error: '已停止读取附件，可重试继续',
        retryable: true,
        attachment: attachment,
      ),
    };
  }

  void start(HomeChatAttachment attachment) {
    if (_disposed) return;
    final fingerprint = _fingerprint(attachment);
    final previous = _operations[attachment.id];
    if (previous != null &&
        previous.fingerprint == fingerprint &&
        (_prepared[attachment.id]?.preparationExpiresAt?.isBefore(
              DateTime.now(),
            ) !=
            true)) {
      return;
    }
    if (previous != null) cancel(attachment.id);
    _prepared.remove(attachment.id);
    final operation = _PreparationOperation(fingerprint);
    _operations[attachment.id] = operation;
    _publish(attachment, operation, phase: 'validating', label: '正在准备');
    operation.result = _run(attachment, operation);
    // Eager starts may fail before a send awaits them; retain the error state
    // without emitting an unhandled asynchronous exception.
    unawaited(
      operation.result.then<void>(
        (_) {},
        onError: (Object _, StackTrace stack) {},
      ),
    );
  }

  Future<HomeChatAttachment> prepare(
    HomeChatAttachment attachment, {
    bool Function()? isCancelled,
  }) async {
    if (_disposed) throw const FormatException('附件准备已关闭');
    start(attachment);
    var operation = _operations[attachment.id]!;
    final account = (await _cloud.signedInEmail)?.trim().toLowerCase() ?? '';
    if (operation.cancelled ||
        operation.failed ||
        (operation.account != null && operation.account != account)) {
      retry(attachment);
      operation = _operations[attachment.id]!;
    }
    final current = operation;
    Timer? cancellation;
    if (isCancelled != null) {
      if (isCancelled()) cancel(attachment.id);
      cancellation = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (isCancelled()) cancel(attachment.id);
      });
    }
    try {
      return await Future.any<HomeChatAttachment>([
        current.result,
        current.abort.future.then<HomeChatAttachment>((_) => throw _cancelled),
      ]);
    } finally {
      cancellation?.cancel();
    }
  }

  static const _cancelled = AttachmentCloudException(
    '已停止读取附件，可重试继续',
    code: 'cancelled',
    retryable: true,
  );

  void cancel(String attachmentId) {
    final operation = _operations[attachmentId];
    if (operation == null || operation.cancelled) return;
    final old = states.value[attachmentId];
    if (old?.ready == true) return;
    operation.abort.complete();
    if (!_disposed && old != null && !old.ready) {
      states.value = {
        ...states.value,
        attachmentId: AttachmentPreparationState(
          attachmentId: attachmentId,
          phase: 'cancelled',
          label: '已停止',
          error: _cancelled.message,
          retryable: true,
          attachment: old.attachment,
        ),
      };
    }
    final id = operation.remoteId;
    if (id != null && old?.ready != true) {
      final cancellation = _cloud
          .cancelAttachment(id)
          .catchError((Object _) {});
      _cancellations[attachmentId] = cancellation;
      unawaited(cancellation);
    }
  }

  void retry(HomeChatAttachment attachment) {
    cancel(attachment.id);
    _operations.remove(attachment.id);
    _prepared.remove(attachment.id);
    start(attachment);
  }

  bool _current(
    HomeChatAttachment attachment,
    _PreparationOperation operation,
  ) =>
      !_disposed &&
      !operation.cancelled &&
      identical(_operations[attachment.id], operation);

  void _check(HomeChatAttachment attachment, _PreparationOperation operation) {
    if (!_current(attachment, operation)) throw _cancelled;
  }

  void _publish(
    HomeChatAttachment attachment,
    _PreparationOperation operation, {
    required String phase,
    required String label,
    double? progress,
    String? error,
    bool retryable = false,
    bool ready = false,
  }) {
    if (!_current(attachment, operation)) return;
    states.value = {
      ...states.value,
      attachment.id: AttachmentPreparationState(
        attachmentId: attachment.id,
        phase: phase,
        label: label,
        progress: progress,
        error: error,
        retryable: retryable,
        ready: ready,
        attachment: attachment,
      ),
    };
  }

  Future<HomeChatAttachment> _run(
    HomeChatAttachment original,
    _PreparationOperation operation,
  ) async {
    var attachment = original;
    try {
      // Finish an explicit stop before a retry resumes the same cached ID.
      // Otherwise a late DELETE could cancel the newly started read.
      await _cancellations.remove(attachment.id);
      await _validate(attachment);
      _check(attachment, operation);
      final hash = (await sha256.bind(File(attachment.path).openRead()).first)
          .toString();
      attachment = attachment.copyWith(contentHash: hash);
      final account = (await _cloud.signedInEmail)?.trim().toLowerCase() ?? '';
      operation.account = account;
      final cacheKey = sha256
          .convert(utf8.encode('$account|$hash|$_parserVersion|chi_sim+eng'))
          .toString();
      Map<String, dynamic>? snapshot;
      String? id;
      if (account.isNotEmpty) {
        final cached = await _loadCache(attachment, cacheKey);
        id = cached?['id']?.toString();
      }
      // Model metadata is persisted with chat history. A matching content hash
      // permits its reference to recover after app restart as well.
      if (id == null &&
          original.contentHash == hash &&
          original.preparationExpiresAt?.isAfter(DateTime.now()) == true) {
        id = original.remoteAttachmentId;
      }
      if (id != null && id.isNotEmpty) {
        operation.remoteId = id;
        try {
          snapshot = await _cloud.getAttachment(
            id,
            abortTrigger: operation.abort.future,
          );
        } on AttachmentCloudException catch (error) {
          if (error.statusCode != 404 && error.statusCode != 410) rethrow;
          id = null;
          operation.remoteId = null;
        }
      }
      if (id == null || id.isEmpty) {
        final upload = await _uploadSource(attachment);
        try {
          _check(attachment, operation);
          _publish(
            attachment,
            operation,
            phase: 'uploading',
            label: '正在上传',
            progress: 0,
          );
          snapshot = await _cloud.createAttachment(
            path: upload.path,
            name: upload.name,
            mimeType: upload.mimeType,
            contentHash: upload.path == attachment.path
                ? hash
                : (await sha256.bind(File(upload.path).openRead()).first)
                      .toString(),
            abortTrigger: operation.abort.future,
            onProgress: (sent, total) => _publish(
              attachment,
              operation,
              phase: 'uploading',
              label: '正在上传 ${(sent * 100 / total).floor()}%',
              progress: sent / total,
            ),
          );
          id = snapshot['id']?.toString();
          if (id == null || id.isEmpty) {
            throw const FormatException('服务端没有创建附件资源');
          }
          operation.remoteId = id;
        } finally {
          await _deleteConvertedUpload(upload.path, attachment.path);
        }
      }
      _check(attachment, operation);
      attachment = attachment.copyWith(remoteAttachmentId: id);
      final expires =
          _resourceExpiry(snapshot?['expires_at']) ??
          DateTime.now().add(const Duration(hours: 24));
      attachment = attachment.copyWith(preparationExpiresAt: expires);
      _publish(attachment, operation, phase: 'uploaded', label: '正在解析');
      if (account.isNotEmpty) {
        await _saveCache(attachment, cacheKey, id, expires);
      }
      _check(attachment, operation);
      final extension = attachment.name.split('.').last.toLowerCase();
      if (!attachment.isImage &&
          extension != 'pdf' &&
          snapshot?['ready'] != true) {
        _publish(attachment, operation, phase: 'extracting', label: '正在解析');
        final chunks = await Future.any<List<String>>([
          _reader.read(attachment, isCancelled: () => operation.cancelled),
          operation.abort.future.then<List<String>>((_) => throw _cancelled),
        ]);
        _check(attachment, operation);
        snapshot = await _cloud.submitAttachmentSegments(id, [
          for (var index = 0; index < chunks.length; index++)
            {
              'index': index,
              'locator':
                  RegExp(
                    r'^\[([^\]]+)\]',
                  ).firstMatch(chunks[index])?.group(1) ??
                  '片段 ${index + 1}',
              'text': chunks[index],
            },
        ], abortTrigger: operation.abort.future);
      }
      _check(attachment, operation);
      if (!attachment.isImage) {
        _publish(attachment, operation, phase: 'reading', label: '正在阅读');
        snapshot = await _cloud.readAttachment(
          id,
          abortTrigger: operation.abort.future,
        );
      }
      snapshot = await _cloud.waitForAttachment(
        id,
        initial: snapshot,
        abortTrigger: operation.abort.future,
        isCancelled: () => operation.cancelled,
        onSnapshot: (value) {
          attachment = _withSnapshot(attachment, value);
          final completedPages = value['completed_pages'];
          final selectedPages = value['selected_pages'];
          final completed = completedPages is List && selectedPages is List
              ? completedPages.where(selectedPages.contains).length
              : _count(completedPages);
          final selected = _count(value['selected_pages']);
          final phase = value['phase']?.toString() ?? 'reading';
          final label = switch (phase) {
            'queued' => '排队等待读取',
            'ocr' => selected > 0 ? '正在识别 $completed/$selected 页' : '正在识别',
            'extracting' || 'extract' => '正在解析',
            _ => '正在阅读',
          };
          _publish(
            attachment,
            operation,
            phase: phase,
            label: label,
            progress: selected > 0
                ? (completed / selected).clamp(0.0, 1.0)
                : null,
          );
        },
      );
      _check(attachment, operation);
      attachment = _withSnapshot(
        attachment,
        snapshot,
      ).copyWith(preparationPhase: 'ready');
      _prepared[attachment.id] = attachment;
      _publish(
        attachment,
        operation,
        phase: 'ready',
        label: attachment.isImage ? '已上传' : '已可阅读',
        ready: true,
        progress: 1,
      );
      return attachment;
    } on Object catch (error) {
      operation.failed = true;
      if (_current(attachment, operation)) {
        final retryable = error is AttachmentCloudException
            ? error.retryable
            : error is SocketException ||
                  error is TimeoutException ||
                  error is http.ClientException;
        final message = error is FormatException
            ? error.message
            : error is StateError
            ? error.message.toString()
            : retryable
            ? '附件连接中断，已保留进度，请重试继续'
            : '附件准备失败：$error';
        _publish(
          attachment,
          operation,
          phase: 'failed',
          label: '读取失败',
          error: message,
          retryable: retryable,
        );
      }
      rethrow;
    }
  }

  String _fingerprint(HomeChatAttachment attachment) {
    try {
      final stat = File(attachment.path).statSync();
      return '${attachment.path}|${attachment.name}|${attachment.mimeType}|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    } on FileSystemException {
      return '${attachment.path}|${attachment.name}|${attachment.mimeType}|${attachment.byteLength}';
    }
  }

  static int _count(Object? value) =>
      value is List ? value.length : (value as num?)?.toInt() ?? 0;

  HomeChatAttachment _withSnapshot(
    HomeChatAttachment attachment,
    Map<String, dynamic> value,
  ) {
    final completed = _count(value['completed_pages']);
    final count = (value['page_count'] as num?)?.toInt();
    return attachment.copyWith(
      preparationCoverage: value['coverage']?.toString() ?? '',
      preparationPhase: value['phase']?.toString() ?? '',
      preparationPageCount: count,
      preparationCompletedPages: completed,
      preparationExpiresAt: _resourceExpiry(value['expires_at']),
      sourceLabel: attachment.isImage
          ? '图片'
          : count != null && count > 0
          ? '已读取 $completed/$count 页'
          : '附件',
    );
  }

  DateTime? _resourceExpiry(Object? value) => value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true)
      : DateTime.tryParse(value?.toString() ?? '');

  Future<void> _validate(HomeChatAttachment attachment) async {
    final extension = attachment.name.split('.').last.toLowerCase();
    if (const ['doc', 'ppt', 'xls'].contains(extension)) {
      throw FormatException('请先将 .$extension 转换为 .${extension}x 后再上传');
    }
    if (!attachment.isImage &&
        !const [
          'pdf',
          'epub',
          'docx',
          'pptx',
          'xlsx',
          'txt',
          'md',
          'markdown',
          'html',
          'htm',
        ].contains(extension)) {
      throw FormatException('暂不支持读取 .$extension 文件');
    }
    final file = File(attachment.path);
    if (!await file.exists()) throw FormatException('找不到文件：${attachment.name}');
    final length = await file.length();
    if (length == 0 || length > 50 * 1024 * 1024) {
      throw const FormatException('附件为空或超过 50 MB 限制');
    }
    final handle = await file.open();
    final List<int> header;
    try {
      header = await handle.read(1024);
    } finally {
      await handle.close();
    }
    if (extension == 'pdf' && !latin1.decode(header).contains('%PDF-')) {
      throw const FormatException('文件内容与 PDF 格式不符，文件可能已损坏');
    }
    if (const ['epub', 'docx', 'pptx', 'xlsx'].contains(extension) &&
        (header.length < 4 ||
            header[0] != 0x50 ||
            header[1] != 0x4b ||
            header[2] != 3 ||
            header[3] != 4)) {
      throw const FormatException('文档内容与格式不符，文件可能已损坏或加密');
    }
  }

  Future<({String path, String name, String mimeType})> _uploadSource(
    HomeChatAttachment attachment,
  ) async {
    final extension = attachment.name.split('.').last.toLowerCase();
    if (!attachment.isImage ||
        (!const ['heic', 'heif'].contains(extension) &&
            !const [
              'image/heic',
              'image/heif',
            ].contains(attachment.mimeType))) {
      return (
        path: attachment.path,
        name: attachment.name,
        mimeType: attachment.mimeType,
      );
    }
    _publishImageConversion(attachment);
    try {
      final bytes = await File(attachment.path).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          final scale =
              4096 /
              (descriptor.width > descriptor.height
                  ? descriptor.width
                  : descriptor.height);
          final codec = await descriptor.instantiateCodec(
            targetWidth: scale < 1
                ? (descriptor.width * scale).round()
                : descriptor.width,
            targetHeight: scale < 1
                ? (descriptor.height * scale).round()
                : descriptor.height,
          );
          try {
            final frame = await codec.getNextFrame();
            try {
              final rgba = await frame.image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              if (rgba == null) throw const FormatException('图片无法解码');
              final width = frame.image.width;
              final height = frame.image.height;
              final pixels = rgba.buffer.asUint8List(
                rgba.offsetInBytes,
                rgba.lengthInBytes,
              );
              final jpeg = await compute(_encodeAttachmentJpeg, (
                width: width,
                height: height,
                pixels: pixels,
              ));
              final path = '${attachment.path}.upload.jpg';
              try {
                await File(path).writeAsBytes(jpeg, flush: true);
              } catch (_) {
                await _deleteConvertedUpload(path, attachment.path);
                rethrow;
              }
              final dot = attachment.name.lastIndexOf('.');
              return (
                path: path,
                name:
                    '${dot > 0 ? attachment.name.substring(0, dot) : attachment.name}.jpg',
                mimeType: 'image/jpeg',
              );
            } finally {
              frame.image.dispose();
            }
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } on Object {
      throw const FormatException('当前设备无法读取 HEIC/HEIF 图片，请转换为 JPG 或 PNG 后上传');
    }
  }

  void _publishImageConversion(HomeChatAttachment attachment) {
    final operation = _operations[attachment.id];
    if (operation != null) {
      _publish(attachment, operation, phase: 'converting', label: '正在准备图片');
    }
  }

  Future<void> _deleteConvertedUpload(
    String uploadPath,
    String originalPath,
  ) async {
    if (uploadPath == originalPath) return;
    try {
      await File(uploadPath).delete();
    } on FileSystemException {
      // The conversion file is temporary; cleanup must not mask upload errors.
    }
  }

  File _cacheFile(HomeChatAttachment attachment) =>
      File('${attachment.path}.attachment-preparation.json');

  Future<Map<String, dynamic>?> _loadCache(
    HomeChatAttachment attachment,
    String key,
  ) async {
    try {
      final value = jsonDecode(await _cacheFile(attachment).readAsString());
      if (value is! Map || value['key'] != key) return null;
      final expires = DateTime.tryParse(value['expires_at']?.toString() ?? '');
      if (expires == null || !expires.isAfter(DateTime.now())) return null;
      return value.cast<String, dynamic>();
    } on Object {
      return null;
    }
  }

  Future<void> _saveCache(
    HomeChatAttachment attachment,
    String key,
    String id,
    DateTime expires,
  ) async {
    try {
      await _cacheFile(attachment).writeAsString(
        jsonEncode({
          'key': key,
          'id': id,
          'expires_at': expires.toUtc().toIso8601String(),
        }),
        flush: true,
      );
    } on FileSystemException {
      // The resource reference also persists in chat history; a read-only local
      // directory must not turn successful preparation into a failure.
    }
  }

  void dispose() {
    if (_disposed) return;
    for (final id in _operations.keys.toList()) {
      cancel(id);
    }
    _disposed = true;
    states.dispose();
  }
}
