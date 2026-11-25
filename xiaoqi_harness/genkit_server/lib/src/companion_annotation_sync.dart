import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import 'store.dart';

class CompanionAnnotationSyncService {
  CompanionAnnotationSyncService(this._store);

  final CloudStore _store;
  final _uploads = <String, Future<void>>{};
  final _lastPrune = <String, DateTime>{};
  static const _maxMedia = 50 * 1024 * 1024;
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static final _id = RegExp(r'^[a-f0-9]{32}$');
  static const _mimeTypes = {
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/heic',
    'image/heif',
    'audio/mp4',
  };

  Future<Response> pull(Request request, String account) => _respond(() async {
    final query = request.url.queryParameters;
    final after = int.tryParse(query['cursor'] ?? '0');
    final through = int.tryParse(query['through'] ?? '');
    if (after == null ||
        after < 0 ||
        (query.containsKey('through') && through == null)) {
      throw const FormatException('同步游标无效');
    }
    _prune(account);
    return _json(_store.companionAnnotations.pull(account, after, through));
  });

  Future<Response> push(Request request, String account) => _respond(() async {
    final raw = await _read(request, 1024 * 1024);
    final input = jsonDecode(utf8.decode(raw));
    if (input is! Map<String, dynamic>) throw const FormatException('同步操作无效');
    final operationId = _require(input.remove('operation_id'), _id, '同步操作编号无效');
    _require(input['book_key'], _digest, '书籍关联无效');
    if (input['kind'] != 'book' && input['kind'] != 'note' ||
        input['generation'] is! int ||
        (input['generation'] as int) < 0 ||
        input['deleted'] is! bool) {
      throw const FormatException('同步类型或版本无效');
    }
    if (input['visibility'] != null && input['visibility'] != 'private') {
      throw const FormatException('本版仅支持私密注释');
    }
    if (input['kind'] == 'note') _validateNote(input);
    final result = _store.companionAnnotations.apply(
      account,
      operationId,
      sha256.convert(raw).toString(),
      input,
    );
    _prune(account);
    return _json(result);
  });

  void _validateNote(Map<String, dynamic> input) {
    _require(input['id'], _id, '注释编号无效');
    _require(input['revision'], _id, '注释版本无效');
    _require(input['device'], _id, '设备标识无效');
    _require(input['selector'], _digest, '选区标识无效');
    _require(input['source_hash'], _digest, '资料版本无效');
    final editedAt = input['edited_at'];
    if (editedAt is! int || editedAt <= 0 || editedAt > 9007199254740991) {
      throw const FormatException('编辑时间无效');
    }
    if (input['deleted'] == true) return;
    final selection = input['selection'];
    final text = input['text'];
    final media = input['media'];
    if (selection is! Map ||
        selection['quote'] is! String ||
        (selection['quote'] as String).trim().isEmpty ||
        selection['anchor'] is! String ||
        selection['source_version'] is! String ||
        selection['locator'] is! String ||
        text is! String ||
        media is! List ||
        (text.isEmpty && media.isEmpty)) {
      throw const FormatException('注释内容无效');
    }
    bool validAnchor(Object? raw) {
      if (raw is! String) return false;
      final anchor = jsonDecode(raw);
      if (anchor is! Map ||
          anchor['source_id'] != input['source_hash'] ||
          (anchor['block_id'] != null && anchor['block_id'] is! String) ||
          (anchor['character_offset'] != null &&
              anchor['character_offset'] is! int)) {
        return false;
      }
      return switch (anchor['kind']) {
        'pdf' =>
          anchor['page'] is int &&
              (anchor['page'] as int) > 0 &&
              (anchor['page_fraction'] == null ||
                  anchor['page_fraction'] is num),
        'flow' =>
          anchor['chapter_id'] is String &&
              (anchor['chapter_id'] as String).isNotEmpty,
        _ => false,
      };
    }

    if (!validAnchor(selection['anchor']) ||
        (selection['end_anchor'] != null &&
            !validAnchor(selection['end_anchor'])) ||
        (selection['translation_version'] != null &&
            selection['translation_version'] is! String) ||
        (selection['view'] != null && selection['view'] is! String)) {
      throw const FormatException('注释定位无效');
    }
    for (final name in ['start_offset', 'end_offset']) {
      final offset = selection[name];
      if (offset != null && (offset is! int || offset < 0)) {
        throw const FormatException('注释定位无效');
      }
    }
    final hashes = selection['pdf_page_text_hashes'];
    if (hashes != null &&
        (hashes is! Map ||
            hashes.entries.any(
              (entry) =>
                  int.tryParse(entry.key.toString()) == null ||
                  entry.value is! String,
            ))) {
      throw const FormatException('注释定位无效');
    }
    for (final item in media) {
      if (item is! Map ||
          !_mimeTypes.contains(item['mime']) ||
          item['size'] is! int ||
          (item['size'] as int) <= 0 ||
          (item['size'] as int) > _maxMedia) {
        throw const FormatException('注释附件无效');
      }
      _require(item['digest'], _digest, '注释附件摘要无效');
    }
    input['media'] = [
      for (final item in media)
        {'digest': item['digest'], 'mime': item['mime'], 'size': item['size']},
    ];
  }

  Future<Response> upload(Request request, String account, String digest) =>
      _respond(() async {
        _require(digest, _digest, '注释附件摘要无效');
        final mime = request.headers[HttpHeaders.contentTypeHeader];
        if (!_mimeTypes.contains(mime)) {
          throw const FormatException('注释附件格式无效');
        }
        final declared = int.tryParse(
          request.headers[HttpHeaders.contentLengthHeader] ?? '',
        );
        if (declared != null && (declared <= 0 || declared > _maxMedia)) {
          throw const FormatException('注释附件大小不受支持');
        }
        final key = _object(account, digest);
        final temporaryDir = await Directory.systemTemp.createTemp(
          'xiaoqi-annotation-upload-',
        );
        try {
          final file = File(p.join(temporaryDir.path, 'media'));
          final fileOut = file.openWrite();
          final header = BytesBuilder(copy: false);
          var length = 0;
          try {
            await for (final chunk in request.read()) {
              length += chunk.length;
              if (length > _maxMedia) throw const FormatException('注释附件过大');
              if (header.length < 32)
                header.add(chunk.take(32 - header.length).toList());
              fileOut.add(chunk);
            }
          } finally {
            await fileOut.close();
          }
          if (length == 0 ||
              (declared != null && declared != length) ||
              !_matches(header.takeBytes(), mime!) ||
              (await sha256.bind(file.openRead()).first).toString() != digest) {
            throw const FormatException('注释附件内容或摘要不匹配');
          }
          final previous = _uploads[key];
          if (previous != null) {
            try {
              await previous;
            } catch (_) {
              /* retry an interrupted concurrent upload */
            }
          }
          final writing = _uploads.putIfAbsent(key, () async {
            if (!_store.taskBlobFile(key).existsSync()) {
              await _store.putTaskBlobFile(key, file);
            }
            final existing = _store.companionAnnotations.media(account, digest);
            if (existing != null &&
                existing.mime != mime &&
                {
                  existing.mime,
                  mime,
                }.difference({'image/heic', 'image/heif'}).isNotEmpty) {
              throw const FormatException('注释附件格式不匹配');
            }
            _store.companionAnnotations.recordMedia(
              account,
              digest,
              existing?.mime ?? mime,
              length,
            );
          });
          try {
            await writing;
          } finally {
            if (identical(_uploads[key], writing)) _uploads.remove(key);
          }
          final saved = _store.companionAnnotations.media(account, digest)!;
          return _json({
            'digest': digest,
            'size': saved.size,
            'mime': saved.mime,
          }, 201);
        } finally {
          await temporaryDir.delete(recursive: true);
        }
      });

  Future<Response> download(String account, String digest) =>
      _respond(() async {
        _require(digest, _digest, '注释附件摘要无效');
        final media = _store.companionAnnotations.media(account, digest);
        final file = _store.taskBlobFile(_object(account, digest));
        if (media == null || !file.existsSync())
          return _json({'error': '注释附件不存在'}, 404);
        return Response.ok(
          file.openRead(),
          headers: {
            HttpHeaders.contentTypeHeader: media.mime,
            HttpHeaders.contentLengthHeader: media.size.toString(),
            HttpHeaders.cacheControlHeader: 'private, no-store',
          },
        );
      });

  void _prune(String account) {
    final now = DateTime.now();
    final last = _lastPrune[account];
    if (last != null && now.difference(last) < const Duration(hours: 1)) return;
    _lastPrune[account] = now;
    try {
      for (final digest in _store.companionAnnotations.pruneMedia(account)) {
        final key = _object(account, digest);
        if (_uploads.containsKey(key)) continue;
        _store.deleteTaskBlob(key);
        _store.companionAnnotations.forgetMedia(account, digest);
      }
    } on Object {
      // The cursor and receipt are already committed. Retry cleanup later.
    }
  }

  static bool _matches(List<int> first, String mime) {
    bool starts(List<int> magic, [int offset = 0]) =>
        first.length >= magic.length + offset &&
        Iterable<int>.generate(
          magic.length,
        ).every((i) => first[i + offset] == magic[i]);
    bool containsBrand(Set<String> brands) {
      for (var byte = 8; byte + 4 <= first.length; byte += 4) {
        if (byte != 12 &&
            brands.contains(
              String.fromCharCodes(first.sublist(byte, byte + 4)),
            )) {
          return true;
        }
      }
      return false;
    }

    return switch (mime) {
      'image/jpeg' => starts([255, 216, 255]),
      'image/png' => starts([137, 80, 78, 71, 13, 10, 26, 10]),
      'image/gif' =>
        starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a')),
      'image/webp' =>
        starts(ascii.encode('RIFF')) && starts(ascii.encode('WEBP'), 8),
      'audio/mp4' =>
        starts(ascii.encode('ftyp'), 4) &&
            containsBrand({'M4A ', 'mp42', 'isom', 'mp41', 'mp4a'}),
      'image/heic' || 'image/heif' =>
        starts(ascii.encode('ftyp'), 4) &&
            containsBrand({'mif1', 'msf1', 'heic', 'heix', 'hevc', 'hevx'}),
      _ => false,
    };
  }

  static String _object(String account, String digest) =>
      'companion-annotation-media/$account/$digest';

  static String _require(Object? value, RegExp pattern, String message) {
    if (value is! String || !pattern.hasMatch(value))
      throw FormatException(message);
    return value;
  }

  static Future<Uint8List> _read(Request request, int maximum) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      if (bytes.length + chunk.length > maximum) {
        throw const FormatException('同步操作过大');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static Future<Response> _respond(Future<Response> Function() action) async {
    try {
      return await action();
    } on FormatException catch (error) {
      return _json({'error': error.message}, 400);
    } on Object {
      return _json({'error': '私密注释同步暂时不可用'}, 503);
    }
  }

  static Response _json(Map<String, Object?> body, [int status = 200]) =>
      Response(
        status,
        body: jsonEncode(body),
        headers: {
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );
}
