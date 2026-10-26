import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import 'store.dart';

/// A recoverable attachment resource, independent of the chat request lifetime.
class AttachmentService {
  AttachmentService(this.store, {AttachmentCommandRunner? commandRunner})
    : _commandRunner = commandRunner {
    _initialization = _recover();
    _cleanup = Timer.periodic(const Duration(hours: 1), (_) {
      unawaited(_prune().catchError((Object _) {}));
    });
  }

  static const maxFileBytes = 50 * 1024 * 1024;
  static const maxTextBytes = 10 * 1024 * 1024;
  static const maxPdfPages = 500;
  static const parserProfile = 'pages-v1-poppler-tesseract-chi_sim+eng-2200';
  static const ttl = Duration(hours: 24);
  static const _uuid = Uuid();
  final CloudStore store;
  final AttachmentCommandRunner? _commandRunner;
  late final Future<void> _initialization;
  late final Timer _cleanup;
  final _queue = <String>[];
  final _work = <String, _AttachmentWork>{};
  final _processes = <String, Process>{};
  final _commits = <String, Completer<void>>{};
  bool _draining = false;
  bool _closed = false;
  int _uploads = 0;
  String? _runningKey;
  Completer<void>? _drainDone;

  Future<Response> upload(Request request, String tenant) => _respond(() async {
    await _initialization;
    _ensureOpen();
    if (_uploads >= 2) {
      throw const AttachmentFailure(
        '正在接收其他附件，请稍后重试',
        code: 'upload_busy',
        statusCode: 429,
        retryable: true,
      );
    }
    final rawName = request.headers['x-xiaoqi-filename'] ?? '';
    String name;
    try {
      name = p.basename(Uri.decodeComponent(rawName)).trim();
    } on FormatException {
      throw const AttachmentFailure(
        '附件文件名无效',
        code: 'invalid_name',
        statusCode: 400,
      );
    }
    if (name.isEmpty || name.length > 512 || name.contains('\u0000')) {
      throw const AttachmentFailure(
        '附件文件名无效',
        code: 'invalid_name',
        statusCode: 400,
      );
    }
    final mime = (request.headers['content-type'] ?? '')
        .split(';')
        .first
        .trim()
        .toLowerCase();
    final kind = _kind(name, mime);
    final length = int.tryParse(request.headers['content-length'] ?? '');
    if (length != null && (length < 1 || length > maxFileBytes)) {
      throw const AttachmentFailure(
        '附件大小必须在 1 字节至 50 MB 之间',
        code: 'file_limit',
        statusCode: 413,
      );
    }
    final expectedHash = request.headers['x-xiaoqi-sha256']?.toLowerCase();
    if (expectedHash != null &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedHash)) {
      throw const AttachmentFailure(
        '附件校验值无效',
        code: 'invalid_hash',
        statusCode: 400,
      );
    }
    final tenantHash = _tenantHash(tenant);
    final staging = Directory(p.join(_root.path, '.upload-${_uuid.v4()}'));
    final watch = Stopwatch()..start();
    _uploads++;
    try {
      await staging.create(recursive: true);
      final source = File(p.join(staging.path, 'source'));
      final digest = _AttachmentDigestSink();
      final hashing = sha256.startChunkedConversion(digest);
      final output = source.openWrite();
      var total = 0;
      try {
        await for (final bytes in request.read()) {
          total += bytes.length;
          if (total > maxFileBytes) {
            throw const AttachmentFailure(
              '附件超过 50 MB 限制',
              code: 'file_limit',
              statusCode: 413,
            );
          }
          hashing.add(bytes);
          output.add(bytes);
          // Backpressure prevents a fast upload from buffering 50 MB in memory.
          await output.flush();
        }
      } finally {
        hashing.close();
        await output.close();
      }
      if (total == 0 || (length != null && total != length)) {
        throw const AttachmentFailure(
          '附件上传不完整，请重试',
          code: 'incomplete_upload',
          statusCode: 400,
          retryable: true,
        );
      }
      final hash = digest.value!.toString();
      if (expectedHash != null && expectedHash != hash) {
        throw const AttachmentFailure(
          '附件校验失败，请重试上传',
          code: 'hash_mismatch',
          statusCode: 400,
          retryable: true,
        );
      }
      final header = await source
          .openRead(0, total < 1024 ? total : 1024)
          .fold<List<int>>([], (a, b) => a..addAll(b));
      if (kind == 'pdf' && !String.fromCharCodes(header).contains('%PDF-')) {
        throw const AttachmentFailure(
          '文件不是有效的 PDF',
          code: 'invalid_pdf',
          statusCode: 400,
        );
      }
      final detectedMime = kind == 'image'
          ? lookupMimeType(name, headerBytes: header)
          : mime;
      if (kind == 'image' && !_isImageHeader(header, detectedMime)) {
        throw const AttachmentFailure(
          '图片格式无效或不支持',
          code: 'invalid_image',
          statusCode: 415,
        );
      }
      final id = sha256
          .convert(utf8.encode('$tenantHash|$hash|$kind|$parserProfile'))
          .toString();
      final key = _key(tenant, id);
      while (_commits.containsKey(key)) {
        await _commits[key]!.future;
      }
      final committing = Completer<void>();
      _commits[key] = committing;
      try {
        final cached = store.get(key);
        if (cached != null && await _source(cached.value).exists()) {
          _patch(key, {
            'expires_at': DateTime.now().add(ttl).millisecondsSinceEpoch,
          });
          if (kind == 'pdf' &&
              cached.value['status'] != 'ready' &&
              !_work.containsKey(key))
            _schedule(key, mode: 'overview');
          final result = await _snapshot(key);
          return _json({...result, 'cache_hit': true});
        }
        final directory = Directory(p.join(_root.path, tenantHash, id));
        await directory.create(recursive: true);
        await source.rename(p.join(directory.path, 'source'));
        final now = DateTime.now();
        final record = <String, dynamic>{
          'id': id,
          'tenant_hash': tenantHash,
          'name': name,
          'kind': kind,
          'mime_type': detectedMime?.isNotEmpty == true
              ? detectedMime
              : 'application/octet-stream',
          'sha256': hash,
          'parser_profile': parserProfile,
          'size': total,
          'created_at': now.millisecondsSinceEpoch,
          'expires_at': now.add(ttl).millisecondsSinceEpoch,
          'status': kind == 'image' ? 'ready' : 'uploaded',
          'phase': kind == 'image' ? 'ready' : 'uploaded',
          'ready': kind == 'image',
          'coverage': kind == 'image' ? 'full' : 'partial',
          'page_count': kind == 'image' ? 1 : 0,
          'completed_pages': <int>[],
          'selected_pages': <int>[],
          'timings_ms': {'upload': watch.elapsedMilliseconds},
        };
        if (cached == null) {
          store.put(key, record, null);
        } else {
          store.put(key, record, cached.revision);
        }
        if (kind == 'pdf') _schedule(key, mode: 'overview');
        return _json(await _snapshot(key), 202);
      } finally {
        _commits.remove(key);
        committing.complete();
      }
    } finally {
      _uploads--;
      await _delete(staging);
    }
  });

  Future<Response> status(String tenant, String id) => _respond(() async {
    await _initialization;
    return _json(await _snapshot(_existingKey(tenant, id)));
  });

  Future<Response> submitSegments(Request request, String tenant, String id) =>
      _respond(() async {
        await _initialization;
        final key = _existingKey(tenant, id);
        final record = store.get(key)!.value;
        if (record['kind'] != 'document') {
          throw const AttachmentFailure(
            '该附件由服务器解析，不接受客户端片段',
            code: 'segments_not_allowed',
            statusCode: 400,
          );
        }
        final body = await _body(request, maxTextBytes * 2 + 1024 * 1024);
        final raw = body['segments'];
        if (raw is! List ||
            raw.isEmpty ||
            raw.length > 10000 ||
            body['full'] is! bool) {
          throw const AttachmentFailure(
            '附件片段格式无效',
            code: 'invalid_segments',
            statusCode: 400,
          );
        }
        final segments = <Map<String, dynamic>>[];
        final seen = <int>{};
        var bytes = 0;
        for (final item in raw) {
          if (item is! Map ||
              item['index'] is! int ||
              item['text'] is! String ||
              item['locator'] is! String) {
            throw const AttachmentFailure(
              '附件片段格式无效',
              code: 'invalid_segments',
              statusCode: 400,
            );
          }
          final index = item['index'] as int;
          final text = item['text'] as String;
          final locator = item['locator'] as String;
          if (index < 0 ||
              index >= 10000 ||
              !seen.add(index) ||
              locator.length > 512) {
            throw const AttachmentFailure(
              '附件片段序号或位置无效',
              code: 'invalid_segments',
              statusCode: 400,
            );
          }
          bytes += utf8.encode(text).length;
          if (bytes > maxTextBytes) {
            throw const AttachmentFailure(
              '附件文字超过 10 MB 限制',
              code: 'text_limit',
              statusCode: 413,
            );
          }
          segments.add({
            'index': index,
            'page': index + 1,
            'locator': locator,
            'text': text,
            'source': 'client',
          });
        }
        segments.sort(
          (a, b) => (a['index'] as int).compareTo(b['index'] as int),
        );
        if (body['full'] == true &&
            List.generate(
              segments.length,
              (i) => i,
            ).any((i) => !seen.contains(i))) {
          throw const AttachmentFailure(
            '完整附件的片段序号不连续',
            code: 'invalid_segments',
            statusCode: 400,
          );
        }
        for (final segment in segments) {
          await _saveSegment(record, segment);
        }
        final completed = segments.map((s) => s['page'] as int).toList();
        _patch(key, {
          'status': 'ready',
          'phase': 'ready',
          'ready': true,
          'coverage': body['full'] == true ? 'full' : 'partial',
          'page_count': completed.last,
          'completed_pages': completed,
          'selected_pages': completed,
          'text_bytes': bytes,
          'error_code': null,
          'message': null,
          'retryable': false,
        });
        return _json(await _snapshot(key));
      });

  Future<Response> read(Request request, String tenant, String id) =>
      _respond(() async {
        await _initialization;
        final key = _existingKey(tenant, id);
        final body = await _body(request, 16 * 1024);
        final mode = body['mode']?.toString() ?? 'overview';
        final pages = _parsePages(body['pages']);
        _validateMode(mode);
        _schedule(
          key,
          mode: mode,
          query: body['query']?.toString() ?? '',
          pages: pages,
        );
        return _json(await _snapshot(key), 202);
      });

  Future<Response> cancel(String tenant, String id) => _respond(() async {
    await _initialization;
    final key = _existingKey(tenant, id);
    _cancel(key);
    return _json(await _snapshot(key));
  });

  /// Resolve only the requested pages; unrelated OCR requests never block this waiter.
  Future<Map<String, dynamic>> material(
    String tenant,
    String id, {
    String mode = 'overview',
    String query = '',
    List<int> pages = const [],
  }) async {
    await _initialization;
    _ensureOpen();
    _validateMode(mode);
    final key = _existingKey(tenant, id);
    var record = store.get(key)!.value;
    List<int>? requestedPages;
    if (record['kind'] == 'pdf') {
      final reading = _schedule(key, mode: mode, query: query, pages: pages);
      await reading.done.future;
      requestedPages = reading.selected;
      record = store.get(key)!.value;
    } else if (record['kind'] == 'document' && record['ready'] != true) {
      throw const AttachmentFailure(
        '附件文字仍在准备，请稍后重试',
        code: 'attachment_not_ready',
        statusCode: 409,
        retryable: true,
      );
    }
    final selected =
        requestedPages ?? await _selected(record, mode, query, pages);
    final segments = await _segments(
      record,
      selected,
      maxCharacters: mode == 'pages'
          ? maxTextBytes
          : mode == 'full'
          ? 160000
          : 48000,
    );
    final supplied = segments.map((s) => s['page']).toSet();
    return {
      'id': record['id'],
      'name': record['name'],
      'kind': record['kind'],
      'mime_type': record['mime_type'],
      'coverage': record['coverage'],
      'read_pages': supplied.toList(),
      'completed_pages': record['completed_pages'],
      'total_pages': record['page_count'],
      'text_truncated':
          segments.any((s) => s['truncated'] == true) ||
          selected.any((p) => !supplied.contains(p)),
      'search_incomplete': mode == 'query' && record['coverage'] != 'full',
      'next_pages':
          List.generate(
                (record['page_count'] as num?)?.toInt() ?? 0,
                (i) => i + 1,
              )
              .where((page) => !_ints(record['completed_pages']).contains(page))
              .take(8)
              .toList(),
      'segments': segments,
      'text': segments
          .map((s) => '[${s['locator']}; ${s['source']}]\n${s['text']}')
          .join('\n\n'),
      'timings_ms': record['timings_ms'],
    };
  }

  Future<Map<String, dynamic>> scriptMaterial(String tenant, String id) async {
    await _initialization;
    _ensureOpen();
    final record = store.get(_existingKey(tenant, id))!.value;
    final file = _source(record);
    if (await file.length() > 20 * 1024 * 1024) {
      throw const FormatException('脚本处理的附件不能超过 20 MB，请拆分资料后再试');
    }
    return {
      'name': record['name'],
      'base64': base64Encode(await file.readAsBytes()),
    };
  }

  Future<Map<String, dynamic>> imagePart(String tenant, String id) async {
    await _initialization;
    final record = store.get(_existingKey(tenant, id))!.value;
    if (record['kind'] != 'image') {
      throw const AttachmentFailure(
        '附件不是图片',
        code: 'not_image',
        statusCode: 400,
      );
    }
    final bytes = await _source(record).readAsBytes();
    return {
      'type': 'image_url',
      'image_url': {
        'url': 'data:${record['mime_type']};base64,${base64Encode(bytes)}',
      },
    };
  }

  Future<void> close() async {
    _closed = true;
    _cleanup.cancel();
    await _initialization;
    for (final key in _work.keys.toList()) {
      _cancel(key);
    }
    final done = _drainDone?.future;
    if (done != null) {
      try {
        await done.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        for (final process in _processes.values) {
          process.kill(ProcessSignal.sigkill);
        }
      }
    }
  }

  _AttachmentRead _schedule(
    String key, {
    required String mode,
    String query = '',
    List<int> pages = const [],
  }) {
    _ensureOpen();
    final record = store.get(key)!.value;
    final done = Completer<void>();
    final result = _AttachmentRead(mode, query, pages, done);
    // API callers do not await completion; consume errors without changing the Future.
    unawaited(done.future.catchError((Object _) {}));
    if (record['kind'] != 'pdf') {
      done.complete();
      return result;
    }
    final previousWork = _work[key];
    final work = _work.putIfAbsent(key, _AttachmentWork.new);
    work.requests.add(result);
    work.requests.sort(
      (a, b) => (a.mode == 'full' ? 1 : 0).compareTo(b.mode == 'full' ? 1 : 0),
    );
    if (!_queue.contains(key) && (_runningKey != key || previousWork == null))
      _queue.add(key);
    _patch(key, {
      'status': 'queued',
      'phase': 'queued',
      'ready': false,
      'error_code': null,
      'message': null,
      'retryable': false,
    });
    unawaited(_drain());
    return result;
  }

  Future<void> _drain() async {
    if (_draining || _closed) return;
    _draining = true;
    final done = _drainDone = Completer<void>();
    try {
      while (_queue.isNotEmpty && !_closed) {
        final key = _queue.removeAt(0);
        final work = _work[key];
        if (work == null || work.cancelled) continue;
        _runningKey = key;
        try {
          final queuedAt = work.queuedAt;
          var record = store.get(key)!.value;
          final timings = Map<String, dynamic>.from(
            record['timings_ms'] as Map? ?? {},
          );
          timings.putIfAbsent(
            'queue',
            () => DateTime.now().difference(queuedAt).inMilliseconds,
          );
          _patch(key, {
            'status': 'processing',
            'phase': 'extracting',
            'timings_ms': timings,
          });
          if (record['native_extracted'] != true) {
            await _extractNative(key, work);
            _checkActive(key, work);
            record = store.get(key)!.value;
          }
          final completed = _ints(record['completed_pages']).toSet();
          final needed = <int>[];
          for (final request in work.requests.toList()) {
            request.selected ??= await _selected(
              record,
              request.mode,
              request.query,
              request.pages,
            );
            for (final page in request.selected!) {
              if (!completed.contains(page) && !needed.contains(page))
                needed.add(page);
            }
          }
          final allSelected =
              work.requests
                  .expand((r) => r.selected ?? const <int>[])
                  .toSet()
                  .toList()
                ..sort();
          _patch(key, {'selected_pages': allSelected});
          await _completeReady(key, work, completed);
          if (needed.isNotEmpty && work.requests.isNotEmpty) {
            final page = needed.first;
            _patch(key, {'phase': 'ocr', 'current_page': page});
            await _ocrPage(key, work, page);
            _checkActive(key, work);
            record = store.get(key)!.value;
            await _completeReady(
              key,
              work,
              _ints(record['completed_pages']).toSet(),
            );
          }
          _checkActive(key, work);
          record = store.get(key)!.value;
          final isFull =
              _ints(record['completed_pages']).length ==
              (record['page_count'] as int);
          if (work.requests.isEmpty) {
            final readable = await _hasReadableText(record);
            _checkActive(key, work);
            if (work.requests.isNotEmpty) {
              if (!_queue.contains(key)) _queue.add(key);
              continue;
            }
            if (!readable) {
              throw const AttachmentFailure(
                '没有识别出可读取文字，请检查扫描质量或选择其他页面',
                code: 'no_readable_text',
                statusCode: 422,
                retryable: true,
              );
            }
            _patch(key, {
              'status': 'ready',
              'phase': 'ready',
              'ready': true,
              'coverage': isFull ? 'full' : 'partial',
              'current_page': null,
            });
            _work.remove(key);
          } else {
            // One page per turn keeps a long full read from starving a new overview.
            if (!_queue.contains(key)) _queue.add(key);
          }
        } on Object catch (error) {
          if (!work.cancelled) {
            final failure = _failure(error);
            _patch(key, {
              'status': 'failed',
              'phase': 'failed',
              'ready': false,
              'error_code': failure.code,
              'message': failure.message,
              'retryable': failure.retryable,
            });
            for (final request in work.requests) {
              if (!request.done.isCompleted)
                request.done.completeError(failure);
            }
            _work.remove(key);
          }
        } finally {
          _runningKey = null;
        }
      }
    } finally {
      _draining = false;
      done.complete();
      if (identical(_drainDone, done)) _drainDone = null;
    }
  }

  Future<void> _extractNative(String key, _AttachmentWork work) async {
    final watch = Stopwatch()..start();
    final record = store.get(key)!.value;
    final directory = _directory(record);
    final source = _source(record);
    final info = await _run(
      'pdfinfo',
      [source.path],
      directory,
      const Duration(seconds: 30),
    );
    _checkActive(key, work);
    if (info.exitCode != 0 ||
        RegExp(r'^Encrypted:\s+yes', multiLine: true).hasMatch(info.stdout)) {
      throw const AttachmentFailure(
        'PDF 无法打开，可能损坏或受密码保护',
        code: 'invalid_or_encrypted_pdf',
        statusCode: 422,
      );
    }
    final count = int.tryParse(
      RegExp(
            r'^Pages:\s*(\d+)\s*$',
            multiLine: true,
          ).firstMatch(info.stdout)?.group(1) ??
          '',
    );
    if (count == null || count < 1)
      throw const AttachmentFailure(
        '无法读取 PDF 页数',
        code: 'invalid_pdf',
        statusCode: 422,
      );
    if (count > maxPdfPages)
      throw const AttachmentFailure(
        'PDF 超过 500 页限制，请拆分后重试',
        code: 'page_limit',
        statusCode: 413,
      );
    _patch(key, {'page_count': count});
    final textFile = File(p.join(directory.path, 'native.txt'));
    final extraction = await _run(
      'pdftotext',
      ['-layout', '-enc', 'UTF-8', source.path, textFile.path],
      directory,
      const Duration(seconds: 45),
    );
    _checkActive(key, work);
    if (extraction.exitCode != 0 || !await textFile.exists()) {
      throw const AttachmentFailure(
        'PDF 文字提取失败',
        code: 'native_extraction_failed',
        statusCode: 422,
        retryable: true,
      );
    }
    if (await textFile.length() > maxTextBytes)
      throw const AttachmentFailure(
        '附件文字超过 10 MB 限制',
        code: 'text_limit',
        statusCode: 413,
      );
    final texts = (await textFile.readAsString()).split('\f');
    if (texts.length > count && texts.last.trim().isEmpty) texts.removeLast();
    if (texts.length > count)
      throw const AttachmentFailure(
        'PDF 文字页码异常',
        code: 'page_alignment',
        statusCode: 422,
      );
    final completed = _ints(record['completed_pages']).toSet();
    var textBytes = (record['text_bytes'] as num?)?.toInt() ?? 0;
    for (var i = 0; i < count && i < texts.length; i++) {
      final text = texts[i].trim();
      if (text.isEmpty || completed.contains(i + 1)) continue;
      await _saveSegment(record, {
        'index': i,
        'page': i + 1,
        'locator': '第 ${i + 1} 页',
        'text': text,
        'source': 'native',
      });
      completed.add(i + 1);
      textBytes += utf8.encode(text).length;
    }
    _checkActive(key, work);
    final timings = Map<String, dynamic>.from(
      store.get(key)!.value['timings_ms'] as Map,
    );
    timings['extract'] =
        (timings['extract'] as num? ?? 0) + watch.elapsedMilliseconds;
    _patch(key, {
      'native_extracted': true,
      'completed_pages': completed.toList()..sort(),
      'text_bytes': textBytes,
      'timings_ms': timings,
    });
  }

  Future<void> _ocrPage(String key, _AttachmentWork work, int page) async {
    final watch = Stopwatch()..start();
    final record = store.get(key)!.value;
    final directory = _directory(record);
    final prefix = p.join(directory.path, 'render-$page');
    final image = File('$prefix.pgm');
    try {
      final rendering = await _run(
        'pdftoppm',
        [
          '-f',
          '$page',
          '-l',
          '$page',
          '-singlefile',
          '-scale-to',
          '2200',
          '-gray',
          _source(record).path,
          prefix,
        ],
        directory,
        const Duration(seconds: 30),
      );
      _checkActive(key, work);
      if (rendering.exitCode != 0 ||
          !await image.exists() ||
          await image.length() > 8 * 1024 * 1024) {
        throw const AttachmentFailure(
          'PDF 页面渲染失败，请重试',
          code: 'page_render_failed',
          statusCode: 422,
          retryable: true,
        );
      }
      final blank = await _blankPgm(image);
      var text = '';
      if (!blank) {
        final ocr = await _run(
          'tesseract',
          [image.path, 'stdout', '-l', 'chi_sim+eng', '--psm', '3'],
          directory,
          const Duration(seconds: 90),
        );
        _checkActive(key, work);
        if (ocr.exitCode != 0)
          throw const AttachmentFailure(
            '页面文字识别失败，已保留其他页面，请重试',
            code: 'ocr_failed',
            statusCode: 422,
            retryable: true,
          );
        text = ocr.stdout.trim();
      }
      _checkActive(key, work);
      final current = store.get(key)!.value;
      final bytes =
          (current['text_bytes'] as num? ?? 0) + utf8.encode(text).length;
      if (bytes > maxTextBytes)
        throw const AttachmentFailure(
          '附件文字超过 10 MB 限制',
          code: 'text_limit',
          statusCode: 413,
        );
      await _saveSegment(record, {
        'index': page - 1,
        'page': page,
        'locator': '第 $page 页',
        'text': text,
        'source': blank ? 'blank' : 'ocr',
      });
      final completed = _ints(current['completed_pages']).toSet()..add(page);
      final timings = Map<String, dynamic>.from(current['timings_ms'] as Map);
      timings['ocr'] =
          (timings['ocr'] as num? ?? 0) + watch.elapsedMilliseconds;
      _patch(key, {
        'completed_pages': completed.toList()..sort(),
        'text_bytes': bytes,
        'timings_ms': timings,
      });
    } finally {
      if (await image.exists()) await image.delete();
    }
  }

  Future<List<int>> _selected(
    Map<String, dynamic> record,
    String mode,
    String query,
    List<int> pages,
  ) async {
    final count = (record['page_count'] as num?)?.toInt() ?? 0;
    if (pages.isNotEmpty) {
      if (pages.length > (mode == 'full' ? maxPdfPages : 8) ||
          pages.any((n) => n < 1 || n > count)) {
        throw const AttachmentFailure(
          '读取页码无效，每次最多读取 8 页',
          code: 'invalid_pages',
          statusCode: 400,
        );
      }
      return pages.toSet().toList()..sort();
    }
    if (mode == 'full') return List.generate(count, (i) => i + 1);
    if (count == 0 || record['kind'] == 'image') return const [];
    final candidates = _overviewCandidates(count);
    if (mode == 'overview') {
      final readable = <int>[];
      for (final page in candidates) {
        if ((await _loadSegment(
              record,
              page,
            ))?['text']?.toString().trim().isNotEmpty ==
            true)
          readable.add(page);
      }
      final target = count < 3 ? count : 3;
      if (readable.length >= target) return readable..sort();
      final selected = readable.toSet();
      for (final page in candidates) {
        if (selected.length >= target) break;
        selected.add(page);
      }
      return selected.toList()..sort();
    }
    if (mode == 'query' && query.trim().isNotEmpty) {
      final terms = RegExp(
        r'[\p{L}\p{N}]{2,}',
        unicode: true,
      ).allMatches(query.toLowerCase()).map((m) => m.group(0)!).toSet();
      final ranked = <(int, int)>[];
      for (final page in _ints(record['completed_pages'])) {
        final segment = await _loadSegment(record, page);
        final text = segment?['text']?.toString().toLowerCase() ?? '';
        var score = terms.where(text.contains).length;
        if (score > 0) ranked.add((page, score));
      }
      ranked.sort((a, b) => b.$2.compareTo(a.$2));
      if (ranked.isNotEmpty)
        return ranked.take(8).map((x) => x.$1).toList()..sort();
      final completed = _ints(record['completed_pages']).toSet();
      final unread = List.generate(
        count,
        (i) => i + 1,
      ).where((page) => !completed.contains(page)).take(8).toList();
      if (unread.isNotEmpty) return unread;
    }
    return candidates..sort();
  }

  static List<int> _overviewCandidates(int count) {
    if (count < 1) return const [];
    final selected = <int>{1, if (count > 1) 2};
    // Front matter plus distributed representatives, never document-specific pages.
    for (final fraction in const [
      0.5,
      0.25,
      1.0,
      0.75,
      0.875,
      0.125,
      0.375,
      0.625,
    ]) {
      if (selected.length >= 8) break;
      selected.add(1 + ((count - 1) * fraction).round());
    }
    for (var page = 1; page <= count && selected.length < 8; page++) {
      selected.add(page);
    }
    return selected.toList();
  }

  Future<void> _completeReady(
    String key,
    _AttachmentWork work,
    Set<int> completed,
  ) async {
    final ready = work.requests
        .where(
          (request) =>
              request.selected != null &&
              request.selected!.every(completed.contains),
        )
        .toList();
    if (ready.isEmpty) return;
    final record = store.get(key)!.value;
    _patch(key, {
      'coverage': completed.length == record['page_count'] ? 'full' : 'partial',
    });
    for (final request in ready) {
      var readable = 0;
      for (final page in request.selected!) {
        if ((await _loadSegment(
              record,
              page,
            ))?['text']?.toString().trim().isNotEmpty ==
            true)
          readable++;
      }
      _checkActive(key, work);
      final count = (record['page_count'] as num).toInt();
      final target = count < 3 ? count : 3;
      if (request.mode == 'overview' &&
          readable < target &&
          request.selected!.length < 8) {
        final extra = _overviewCandidates(
          count,
        ).where((page) => !request.selected!.contains(page)).firstOrNull;
        if (extra != null) {
          request.selected!.add(extra);
          continue;
        }
      }
      if (!request.done.isCompleted) {
        if (readable > 0 || request.mode == 'pages') {
          request.done.complete();
        } else {
          request.done.completeError(
            const AttachmentFailure(
              '没有识别出可读取文字，请检查扫描质量或选择其他页面',
              code: 'no_readable_text',
              statusCode: 422,
              retryable: true,
            ),
          );
        }
      }
      work.requests.remove(request);
    }
  }

  void _cancel(String key) {
    final work = _work.remove(key);
    if (work != null) {
      work.cancelled = true;
      for (final request in work.requests) {
        if (!request.done.isCompleted)
          request.done.completeError(
            const AttachmentFailure(
              '已取消附件阅读，已完成的内容仍可重试使用',
              code: 'cancelled',
              statusCode: 409,
              retryable: true,
            ),
          );
      }
    }
    _queue.removeWhere((item) => item == key);
    _processes[key]?.kill();
    _patch(key, {
      'status': 'cancelled',
      'phase': 'cancelled',
      if (store.get(key)?.value['kind'] == 'pdf') 'ready': false,
      'current_page': null,
      'error_code': 'cancelled',
      'message': '已取消阅读，已完成的内容已保留',
      'retryable': true,
    });
  }

  void _checkActive(String key, _AttachmentWork work) {
    if (_closed || work.cancelled || !identical(_work[key], work)) {
      throw const AttachmentFailure(
        '附件阅读已取消',
        code: 'cancelled',
        statusCode: 409,
        retryable: true,
      );
    }
  }

  Future<AttachmentCommandResult> _run(
    String executable,
    List<String> arguments,
    Directory directory,
    Duration timeout,
  ) async {
    if (_commandRunner != null)
      return _commandRunner(
        executable,
        arguments,
        timeout: timeout,
        workingDirectory: directory.path,
      );
    final key = _runningKey!;
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: directory.path,
      environment: {
        'LC_ALL': 'C.UTF-8',
        'OMP_THREAD_LIMIT': '1',
        'OMP_NUM_THREADS': '1',
        'HOME': directory.path,
        'TMPDIR': directory.path,
        'TMP': directory.path,
        'TEMP': directory.path,
      },
    );
    _processes[key] = process;
    if (_closed || _work[key] == null) process.kill();
    var total = 0;
    final output = <int>[];
    final stdoutDone = process.stdout.forEach((chunk) {
      total += chunk.length;
      if (total <= maxTextBytes)
        output.addAll(chunk);
      else
        process.kill();
    });
    // Diagnostics may contain private document data; consume them without logging.
    final stderrDone = process.stderr.drain<void>();
    try {
      final code = await process.exitCode.timeout(timeout);
      await Future.wait([stdoutDone, stderrDone]);
      if (total > maxTextBytes)
        throw const AttachmentFailure(
          '解析输出超过 10 MB 限制',
          code: 'text_limit',
          statusCode: 413,
        );
      return AttachmentCommandResult(
        code,
        utf8.decode(output, allowMalformed: true),
      );
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
      throw const AttachmentFailure(
        '该页面处理超时，已完成内容已保留，请重试或选择较少页面',
        code: 'parse_timeout',
        statusCode: 422,
        retryable: true,
      );
    } finally {
      if (identical(_processes[key], process)) _processes.remove(key);
    }
  }

  Future<bool> _blankPgm(File file) async {
    final bytes = await file.readAsBytes();
    var offset = 0;
    String token() {
      while (offset < bytes.length) {
        if (bytes[offset] == 35) {
          while (offset < bytes.length && bytes[offset] != 10) {
            offset++;
          }
        } else if (bytes[offset] <= 32) {
          offset++;
        } else {
          break;
        }
      }
      final start = offset;
      while (offset < bytes.length && bytes[offset] > 32) {
        offset++;
      }
      return ascii.decode(bytes.sublist(start, offset), allowInvalid: true);
    }

    if (token() != 'P5') return false;
    final width = int.tryParse(token()) ?? 0;
    final height = int.tryParse(token()) ?? 0;
    final maximum = int.tryParse(token());
    if (width < 1 || height < 1 || maximum != 255 || offset >= bytes.length)
      return false;
    if (bytes[offset] == 13 &&
        offset + 1 < bytes.length &&
        bytes[offset + 1] == 10)
      offset++;
    offset++;
    final pixels = width * height;
    if (bytes.length - offset < pixels) return false;
    final allowed = (pixels * 0.00002).round().clamp(8, 100);
    var dark = 0;
    for (var i = offset; i < offset + pixels; i++) {
      if (bytes[i] < 220 && ++dark > allowed) return false;
    }
    return true;
  }

  Future<Map<String, dynamic>> _snapshot(String key) async {
    final record = store.get(key)!.value;
    final selected = _ints(record['selected_pages']);
    final pages = selected.isNotEmpty
        ? selected
        : _ints(record['completed_pages']).take(8).toList();
    return {
      for (final field in const [
        'id',
        'name',
        'kind',
        'mime_type',
        'status',
        'phase',
        'ready',
        'coverage',
        'page_count',
        'completed_pages',
        'selected_pages',
        'current_page',
        'timings_ms',
        'error_code',
        'message',
        'retryable',
        'expires_at',
      ])
        if (record.containsKey(field)) field: record[field],
      'segments': await _segments(
        record,
        pages.take(8).toList(),
        maxCharacters: 24000,
      ),
    };
  }

  Future<List<Map<String, dynamic>>> _segments(
    Map<String, dynamic> record,
    List<int> pages, {
    required int maxCharacters,
  }) async {
    final segments = <Map<String, dynamic>>[];
    var remaining = maxCharacters;
    for (final page in pages) {
      if (remaining <= 0) break;
      final segment = await _loadSegment(record, page);
      if (segment == null) continue;
      final text = segment['text'] as String;
      final limit = text.length < remaining ? text.length : remaining;
      segments.add({
        ...segment,
        'text': text.substring(0, limit),
        if (limit < text.length) 'truncated': true,
      });
      remaining -= limit;
    }
    return segments;
  }

  Future<bool> _hasReadableText(Map<String, dynamic> record) async {
    for (final page in _ints(record['completed_pages'])) {
      if ((await _loadSegment(
            record,
            page,
          ))?['text']?.toString().trim().isNotEmpty ==
          true)
        return true;
    }
    return false;
  }

  Future<void> _saveSegment(
    Map<String, dynamic> record,
    Map<String, dynamic> segment,
  ) async {
    final file = _segmentFile(record, segment['page'] as int);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(segment), flush: true);
    await temporary.rename(file.path);
  }

  Future<Map<String, dynamic>?> _loadSegment(
    Map<String, dynamic> record,
    int page,
  ) async {
    final file = _segmentFile(record, page);
    if (!await file.exists()) return null;
    return (jsonDecode(await file.readAsString()) as Map)
        .cast<String, dynamic>();
  }

  Future<void> _recover() async {
    await _root.create(recursive: true);
    for (final entry in _root.listSync()) {
      if (entry is Directory && p.basename(entry.path).startsWith('.upload-'))
        await _delete(entry);
    }
    for (final (key, document) in store.list('attachment/', limit: 10000)) {
      final record = document.value;
      if (record['status'] == 'queued' || record['status'] == 'processing') {
        _patch(key, {
          'status': 'uploaded',
          'phase': 'interrupted',
          'ready': false,
          'retryable': true,
          'error_code': 'server_restarted',
          'message': '服务重启，已完成内容已保留，可继续阅读',
        });
      }
      final directory = _directory(record);
      if (await directory.exists()) {
        await for (final file in directory.list(recursive: true)) {
          if (file is File &&
              (file.path.endsWith('.tmp') ||
                  RegExp(r'render-\d+\.pgm$').hasMatch(file.path)))
            await file.delete();
        }
      }
    }
    await for (final tenantDirectory in _root.list()) {
      if (tenantDirectory is! Directory ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(p.basename(tenantDirectory.path)))
        continue;
      await for (final resourceDirectory in tenantDirectory.list()) {
        if (resourceDirectory is! Directory ||
            !RegExp(
              r'^[a-f0-9]{64}$',
            ).hasMatch(p.basename(resourceDirectory.path)))
          continue;
        final key =
            'attachment/${p.basename(tenantDirectory.path)}/${p.basename(resourceDirectory.path)}';
        if (store.get(key) == null) await _delete(resourceDirectory);
      }
    }
    await _prune();
  }

  Future<void> _prune() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final (key, document) in store.list('attachment/', limit: 10000)) {
      if ((document.value['expires_at'] as num? ?? 0) > now ||
          _work.containsKey(key))
        continue;
      await _delete(_directory(document.value));
      store.delete(key);
    }
  }

  String _existingKey(String tenant, String id) {
    final key = _key(tenant, id);
    final record = store.get(key);
    if (record == null ||
        (record.value['expires_at'] as num? ?? 0) <=
            DateTime.now().millisecondsSinceEpoch) {
      throw const AttachmentFailure(
        '附件不存在或已过期，请从原文件重新准备',
        code: 'attachment_expired',
        statusCode: 404,
        retryable: true,
      );
    }
    return key;
  }

  String _key(String tenant, String id) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id))
      throw const AttachmentFailure(
        '附件 ID 无效',
        code: 'invalid_id',
        statusCode: 400,
      );
    return 'attachment/${_tenantHash(tenant)}/$id';
  }

  void _patch(String key, Map<String, dynamic> values) {
    final current = store.get(key);
    if (current != null)
      store.put(key, {...current.value, ...values}, current.revision);
  }

  Directory get _root => Directory(p.join(store.root.path, 'attachments'));
  Directory _directory(Map<String, dynamic> record) => Directory(
    p.join(_root.path, record['tenant_hash'] as String, record['id'] as String),
  );
  File _source(Map<String, dynamic> record) =>
      File(p.join(_directory(record).path, 'source'));
  File _segmentFile(Map<String, dynamic> record, int page) =>
      File(p.join(_directory(record).path, 'pages', '$page.json'));
  static String _tenantHash(String tenant) =>
      sha256.convert(utf8.encode(tenant)).toString();
  static List<int> _ints(Object? value) => (value as List? ?? const [])
      .whereType<num>()
      .map((n) => n.toInt())
      .toList();

  static String _kind(String name, String mime) {
    final extension = p.extension(name).toLowerCase();
    if (extension == '.pdf' &&
        (mime == 'application/pdf' || mime == 'application/octet-stream'))
      return 'pdf';
    if (const [
          '.png',
          '.jpg',
          '.jpeg',
          '.webp',
          '.gif',
          '.bmp',
        ].contains(extension) &&
        (mime.startsWith('image/') || mime == 'application/octet-stream'))
      return 'image';
    if (const [
      '.txt',
      '.md',
      '.markdown',
      '.html',
      '.htm',
      '.docx',
      '.pptx',
      '.xlsx',
      '.epub',
    ].contains(extension))
      return 'document';
    throw const AttachmentFailure(
      '不支持该附件格式',
      code: 'unsupported_format',
      statusCode: 415,
    );
  }

  static bool _isImageHeader(List<int> bytes, String? mime) {
    bool starts(List<int> prefix) =>
        bytes.length >= prefix.length &&
        List.generate(
          prefix.length,
          (i) => i,
        ).every((i) => bytes[i] == prefix[i]);
    return switch (mime) {
      'image/png' => starts([137, 80, 78, 71, 13, 10, 26, 10]),
      'image/jpeg' => starts([255, 216, 255]),
      'image/gif' => starts(ascii.encode('GIF8')),
      'image/bmp' => starts(ascii.encode('BM')),
      'image/webp' =>
        starts(ascii.encode('RIFF')) &&
            bytes.length >= 12 &&
            ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP',
      _ => false,
    };
  }

  static void _validateMode(String mode) {
    if (!const ['overview', 'query', 'pages', 'full'].contains(mode))
      throw const AttachmentFailure(
        '附件阅读模式无效',
        code: 'invalid_mode',
        statusCode: 400,
      );
  }

  static List<int> _parsePages(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List ||
        raw.length > maxPdfPages ||
        raw.any((n) => n is! int || n < 1))
      throw const AttachmentFailure(
        '读取页码无效',
        code: 'invalid_pages',
        statusCode: 400,
      );
    return raw.cast<int>();
  }

  static Future<Map<String, dynamic>> _body(
    Request request,
    int maximum,
  ) async {
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      if (bytes.length + chunk.length > maximum)
        throw const AttachmentFailure(
          '请求超过大小限制',
          code: 'request_limit',
          statusCode: 413,
        );
      bytes.addAll(chunk);
    }
    try {
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map) throw const FormatException();
      return body.cast<String, dynamic>();
    } on FormatException {
      throw const AttachmentFailure(
        '请求 JSON 无效',
        code: 'invalid_json',
        statusCode: 400,
      );
    }
  }

  void _ensureOpen() {
    if (_closed)
      throw const AttachmentFailure(
        '服务正在重启，请稍后重试',
        code: 'service_restarting',
        statusCode: 503,
        retryable: true,
      );
  }

  static AttachmentFailure _failure(Object error) => error is AttachmentFailure
      ? error
      : AttachmentFailure(
          error is TimeoutException
              ? '附件处理超时，已完成内容已保留，请重试'
              : '附件处理失败，已完成内容已保留，请重试',
          code: error is TimeoutException ? 'parse_timeout' : 'parse_failed',
          statusCode: 422,
          retryable: true,
        );

  static Future<Response> _respond(Future<Response> Function() action) async {
    try {
      return await action();
    } on Object catch (error) {
      final failure = _failure(error);
      return _json({
        'error': {
          'code': failure.code,
          'message': failure.message,
          'retryable': failure.retryable,
        },
      }, failure.statusCode);
    }
  }

  Future<void> _delete(Directory directory) async {
    if (!p.isWithin(p.absolute(_root.path), p.absolute(directory.path)))
      throw StateError('Attachment cleanup escaped its storage directory');
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  static Response _json(Object body, [int status = 200]) => Response(
    status,
    body: jsonEncode(body),
    headers: const {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'private, no-store',
    },
  );
}

class AttachmentFailure implements Exception {
  const AttachmentFailure(
    this.message, {
    required this.code,
    required this.statusCode,
    this.retryable = false,
  });
  final String message;
  final String code;
  final int statusCode;
  final bool retryable;
  @override
  String toString() => message;
}

typedef AttachmentCommandRunner =
    Future<AttachmentCommandResult> Function(
      String executable,
      List<String> arguments, {
      required Duration timeout,
      required String workingDirectory,
    });

class AttachmentCommandResult {
  const AttachmentCommandResult(this.exitCode, [this.stdout = '']);
  final int exitCode;
  final String stdout;
}

class _AttachmentWork {
  final queuedAt = DateTime.now();
  final requests = <_AttachmentRead>[];
  bool cancelled = false;
}

class _AttachmentRead {
  _AttachmentRead(this.mode, this.query, this.pages, this.done);
  final String mode;
  final String query;
  final List<int> pages;
  final Completer<void> done;
  List<int>? selected;
}

class _AttachmentDigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
