import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import 'store.dart';

class PdfOcrService {
  PdfOcrService(this.store) {
    _recoverJobs();
    _cleanupTimer = Timer.periodic(const Duration(hours: 1), (_) {
      _pruneExpiredJobsSafely();
    });
  }

  static const _maxPdfBytes = 50 * 1024 * 1024;
  static const _maxPdfPages = 500;
  static const _maxActiveJobs = 3;
  static const _maxTextBytes = 10 * 1024 * 1024;
  static const _jobTtl = Duration(hours: 24);
  static const _uuid = Uuid();

  final CloudStore store;
  final List<String> _queue = [];
  final Map<String, Process> _processes = {};
  late final Timer _cleanupTimer;
  Completer<void>? _currentJobDone;
  bool _draining = false;
  int _activeUploads = 0;

  Future<void> close() async {
    _cleanupTimer.cancel();
    final queuedKeys = List<String>.from(_queue);
    _queue.clear();
    for (final key in queuedKeys) {
      final job = store.get(key);
      if (job == null) continue;
      _updateJob(key, {'status': 'failed', 'message': '服务正在重启，请重新上传'});
      await _deleteDirectory(_jobDirectory(job.value));
    }
    final processes = List<Process>.from(_processes.values);
    for (final process in processes) {
      process.kill();
    }
    final currentJob = _currentJobDone?.future;
    if (currentJob != null) {
      try {
        await currentJob.timeout(const Duration(seconds: 20));
      } on Object {
        for (final process in _processes.values) {
          process.kill(ProcessSignal.sigkill);
        }
        try {
          await currentJob.timeout(const Duration(seconds: 5));
        } on Object {
          // The process was killed; recovery marks this job failed on restart.
        }
      }
    }
  }

  Future<Response> submit(Request request, String tenant) async {
    if (_activeUploads >= 2) return _error('当前正在接收其他 PDF，请稍后重试', 429);
    final mediaType = request.headers['content-type']
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (mediaType != 'application/pdf') {
      return _error('上传内容必须是 PDF 文件', 415);
    }
    final declaredLength = int.tryParse(
      request.headers['content-length'] ?? '',
    );
    if (declaredLength != null && declaredLength > _maxPdfBytes) {
      return _error('PDF 超过 50 MB 限制', 413);
    }

    _activeUploads++;
    final id = _uuid.v4();
    final tenantHash = sha256.convert(utf8.encode(tenant)).toString();
    final directory = Directory(
      p.join(store.root.path, 'pdf-ocr', tenantHash, id),
    );
    try {
      await _pruneExpiredJobs();
      if (_activeJobCount() >= _maxActiveJobs) {
        return _error('OCR 服务正忙，请稍后重试', 429);
      }

      await directory.create(recursive: true);
      final source = File(p.join(directory.path, 'source.pdf'));
      final size = await _savePdfUpload(request, source);
      if (size == 0 || !await _hasPdfSignature(source)) {
        throw const _PdfOcrFailure('文件不是有效的 PDF', 400);
      }

      final info = await _runCommand(
        'pdfinfo',
        [source.path],
        timeout: const Duration(seconds: 45),
        environment: const {'LC_ALL': 'C'},
        processKey: 'upload:$id',
      );
      if (info.exitCode != 0) {
        throw const _PdfOcrFailure('PDF 无法打开，可能已损坏或受密码保护', 400);
      }
      final pageCount = int.tryParse(
        RegExp(
              r'^Pages:\s*(\d+)\s*$',
              multiLine: true,
            ).firstMatch(info.stdout)?.group(1) ??
            '',
      );
      if (pageCount == null || pageCount < 1) {
        throw const _PdfOcrFailure('PDF 页数无法读取', 400);
      }
      if (pageCount > _maxPdfPages) {
        throw const _PdfOcrFailure('PDF 超过 500 页限制，请拆分后重试', 413);
      }

      final key = _jobKey(tenant, id);
      store.put(key, {
        'id': id,
        'tenant_hash': tenantHash,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'queued',
        'page_count': pageCount,
      }, null);
      _queue.add(key);
      unawaited(_drainQueue());
      return _json({
        'id': id,
        'status': 'queued',
        'page_count': pageCount,
      }, 202);
    } on _PdfOcrFailure catch (error) {
      await _deleteDirectory(directory);
      return _error(error.message, error.statusCode);
    } on TimeoutException {
      await _deleteDirectory(directory);
      return _error('PDF 预检超时，请检查文件后重试', 422);
    } on Object catch (error, stack) {
      stderr.writeln(
        'PDF OCR preflight failed (${error.runtimeType}): $error\n$stack',
      );
      await _deleteDirectory(directory);
      return _error('PDF 上传或预检失败，请检查文件后重试', 422);
    } finally {
      _activeUploads--;
    }
  }

  Future<Response> status(String tenant, String id) async {
    final key = _jobKey(tenant, id);
    final job = store.get(key);
    if (job == null) return _error('OCR 任务不存在或已过期', 404);
    if (job.value['status'] != 'completed') {
      return _json(_publicStatus(job.value));
    }

    final resultFile = File(
      p.join(_jobDirectory(job.value).path, 'result.txt'),
    );
    if (!await resultFile.exists()) {
      _updateJob(key, {'status': 'failed', 'message': '识别结果已过期，请重新上传'});
      return _json({'id': id, 'status': 'failed', 'message': '识别结果已过期，请重新上传'});
    }
    final pages = _pageTexts(
      await resultFile.readAsString(),
      (job.value['page_count'] as num?)?.toInt() ?? 0,
    );
    return _json({..._publicStatus(job.value), 'pages': pages});
  }

  Future<Response> delete(String tenant, String id) async {
    final key = _jobKey(tenant, id);
    final job = store.get(key);
    _queue.remove(key);
    final process = _processes.remove(key);
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on Object {}
    }
    if (job != null) {
      store.delete(key);
      await _deleteDirectory(_jobDirectory(job.value));
    }
    return _json({'id': id, 'deleted': true});
  }

  int _activeJobCount() => store
      .list('pdf-ocr-job/', limit: 10000)
      .where(
        (entry) =>
            entry.$2.value['status'] == 'queued' ||
            entry.$2.value['status'] == 'processing',
      )
      .length;

  Future<int> _savePdfUpload(Request request, File destination) async {
    final sink = destination.openWrite();
    var total = 0;
    try {
      await for (final chunk in request.read()) {
        total += chunk.length;
        if (total > _maxPdfBytes) {
          throw const _PdfOcrFailure('PDF 超过 50 MB 限制', 413);
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      return total;
    } on Object {
      await sink.close();
      rethrow;
    }
  }

  Future<bool> _hasPdfSignature(File file) async {
    final bytes = await file
        .openRead(0, 1024)
        .fold<List<int>>([], (result, chunk) => result..addAll(chunk));
    return String.fromCharCodes(bytes).contains('%PDF-');
  }

  Future<void> _drainQueue() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final key = _queue.removeAt(0);
        final job = store.get(key);
        if (job == null) continue;
        _updateJob(key, {'status': 'processing'});
        final jobDone = Completer<void>();
        _currentJobDone = jobDone;
        try {
          await _processJob(key, job.value);
        } on Object catch (error, stack) {
          stderr.writeln(
            'PDF OCR processing failed (${error.runtimeType}): $error\n$stack',
          );
          _updateJob(key, {
            'status': 'failed',
            'message': 'PDF 识别失败，请检查文件或拆分后重试',
          });
          await _deleteDirectory(_jobDirectory(job.value));
        } finally {
          jobDone.complete();
          if (identical(_currentJobDone, jobDone)) _currentJobDone = null;
        }
      }
    } finally {
      _draining = false;
      if (_queue.isNotEmpty) unawaited(_drainQueue());
    }
  }

  Future<void> _processJob(String key, Map<String, dynamic> job) async {
    final directory = _jobDirectory(job);
    final input = File(p.join(directory.path, 'source.pdf'));
    final output = File(p.join(directory.path, 'searchable.pdf'));
    final textFile = File(p.join(directory.path, 'result.txt'));
    final ocr = await _runCommand(
      'ocrmypdf',
      [
        '--skip-text',
        '--output-type',
        'pdf',
        '--optimize',
        '0',
        '--jobs',
        '1',
        '--max-image-mpixels',
        '20',
        '--tesseract-timeout',
        '120',
        '-l',
        'chi_sim+eng',
        input.path,
        output.path,
      ],
      timeout: const Duration(hours: 2),
      environment: {
        'LC_ALL': 'C.UTF-8',
        'HOME': directory.path,
        'TMPDIR': directory.path,
        'TMP': directory.path,
        'TEMP': directory.path,
      },
      processKey: key,
    );
    if (ocr.exitCode != 0 || !await output.exists()) {
      throw const _PdfOcrFailure('OCRmyPDF 未能处理该文件', 422);
    }

    final extraction = await _runCommand(
      'pdftotext',
      ['-layout', '-enc', 'UTF-8', output.path, textFile.path],
      timeout: const Duration(minutes: 2),
      environment: const {'LC_ALL': 'C.UTF-8'},
      processKey: key,
    );
    if (extraction.exitCode != 0 || !await textFile.exists()) {
      throw const _PdfOcrFailure('OCR 文字提取失败', 422);
    }
    if (await textFile.length() > _maxTextBytes) {
      throw const _PdfOcrFailure('识别结果过大，请拆分 PDF 后重试', 413);
    }
    final text = await textFile.readAsString();
    final pages = _pageTexts(text, (job['page_count'] as num).toInt());
    if (pages.every((page) => page.trim().isEmpty)) {
      throw const _PdfOcrFailure('没有识别出可读取文字，请检查扫描质量', 422);
    }

    await input.delete();
    await output.delete();
    _updateJob(key, {'status': 'completed'});
  }

  Future<_CommandResult> _runCommand(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
    String? processKey,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: {
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'LC_ALL': 'C.UTF-8',
        ...?environment,
      },
      includeParentEnvironment: false,
      runInShell: false,
    );
    if (processKey != null) _processes[processKey] = process;
    final stdout = process.stdout.transform(utf8.decoder).join();
    var diagnostics = '';
    final stderrDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) {
          diagnostics += chunk;
          if (diagnostics.length > 4096)
            diagnostics = diagnostics.substring(diagnostics.length - 4096);
        });
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      await stderrDone;
      if (exitCode != 0) {
        stderr.writeln(
          'PDF OCR command $executable failed (exit $exitCode): $diagnostics',
        );
      }
      return _CommandResult(exitCode, await stdout);
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 10));
      } on Object {}
      throw TimeoutException('Command timed out');
    } finally {
      if (processKey != null && identical(_processes[processKey], process)) {
        _processes.remove(processKey);
      }
    }
  }

  List<String> _pageTexts(String text, int expectedPages) {
    final pages = text.split('\f');
    if (pages.length > expectedPages && pages.last.trim().isEmpty) {
      pages.removeLast();
    }
    if (pages.length > expectedPages) {
      throw const _PdfOcrFailure('识别结果页数异常，请重新上传 PDF', 422);
    }
    while (pages.length < expectedPages) {
      pages.add('');
    }
    // Page alignment is kept by pdftotext's form-feed separators; do not trim
    // internal empty entries because they correspond to blank PDF pages.
    return pages
        .take(expectedPages)
        .map((page) => page.trim())
        .toList(growable: false);
  }

  Map<String, Object?> _publicStatus(Map<String, dynamic> job) => {
    'id': job['id'],
    'status': job['status'],
    'page_count': job['page_count'],
    if (job['message'] != null) 'message': job['message'],
  };

  Directory _jobDirectory(Map<String, dynamic> job) => Directory(
    p.join(
      store.root.path,
      'pdf-ocr',
      job['tenant_hash']?.toString() ?? '',
      job['id']?.toString() ?? '',
    ),
  );

  String _jobKey(String tenant, String id) {
    if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) {
      throw const FormatException('OCR 任务 ID 无效');
    }
    return 'pdf-ocr-job/$tenant/$id';
  }

  void _updateJob(String key, Map<String, Object?> patch) {
    final current = store.get(key);
    if (current == null) return;
    store.put(key, {...current.value, ...patch}, current.revision);
  }

  void _recoverJobs() {
    for (final (key, job) in store.list('pdf-ocr-job/', limit: 10000)) {
      final createdAt = job.value['created_at'] as int? ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - createdAt >
          _jobTtl.inMilliseconds) {
        store.delete(key);
        _deleteDirectorySync(_jobDirectory(job.value));
      } else if (job.value['status'] == 'queued' ||
          job.value['status'] == 'processing') {
        store.put(key, {
          ...job.value,
          'status': 'failed',
          'message': '服务重启中断了 OCR，请重新上传',
        }, job.revision);
        _deleteDirectorySync(_jobDirectory(job.value));
      }
    }
  }

  Future<void> _pruneExpiredJobs() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final (key, job) in store.list('pdf-ocr-job/', limit: 10000)) {
      final createdAt = job.value['created_at'] as int? ?? 0;
      if (now - createdAt > _jobTtl.inMilliseconds) {
        store.delete(key);
        await _deleteDirectory(_jobDirectory(job.value));
      }
    }
  }

  void _pruneExpiredJobsSafely() {
    unawaited(
      _pruneExpiredJobs().catchError((Object _) {
        stderr.writeln('PDF OCR expired-job cleanup failed');
      }),
    );
  }

  Future<void> _deleteDirectory(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on Object {}
  }

  void _deleteDirectorySync(Directory directory) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } on Object {}
  }

  static Response _json(Object? value, [int status = 200]) => Response(
    status,
    body: jsonEncode(value),
    headers: const {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'private, no-store',
    },
  );

  static Response _error(String message, int status) => _json({
    'error': {'message': message},
  }, status);
}

class _PdfOcrFailure implements Exception {
  const _PdfOcrFailure(this.message, this.statusCode);

  final String message;
  final int statusCode;
}

class _CommandResult {
  const _CommandResult(this.exitCode, this.stdout);

  final int exitCode;
  final String stdout;
}
