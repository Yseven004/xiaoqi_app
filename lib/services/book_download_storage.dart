import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef BookDownloadSaver =
    Future<void> Function({
      required File file,
      required String displayName,
      required String format,
      required String sha256,
    });

/// Publishes a verified file to user-visible storage, independent of book cache.
Future<void> saveVerifiedBookToDownloads({
  required File file,
  required String displayName,
  required String format,
  required String sha256,
}) async {
  if (!const {'pdf', 'epub'}.contains(format) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
    throw const FormatException('下载文件信息无效');
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    final uri = await const MethodChannel('xiaoqi_app/book_downloads')
        .invokeMethod<String>('saveVerifiedBook', {
          'sourcePath': file.path,
          'displayName': displayName,
          'format': format,
          'sha256': sha256,
        });
    if (uri == null || !uri.startsWith('content://media/')) {
      throw const FileSystemException('系统未确认下载文件已保存');
    }
    return;
  }
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.fuchsia) {
    throw UnsupportedError('此平台暂不支持自动保存到系统下载目录');
  }
  final downloads = await getDownloadsDirectory();
  if (downloads == null) throw const FileSystemException('系统下载目录不可用');
  await saveVerifiedBookToDownloadDirectory(
    directory: downloads,
    file: file,
    displayName: displayName,
    format: format,
    expectedSha256: sha256,
  );
}

/// Native desktop file storage; receives an explicit directory for I/O tests.
@visibleForTesting
Future<File> saveVerifiedBookToDownloadDirectory({
  required Directory directory,
  required File file,
  required String displayName,
  required String format,
  required String expectedSha256,
}) async {
  if (!const {'pdf', 'epub'}.contains(format) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256)) {
    throw const FormatException('下载文件信息无效');
  }
  final root = Directory(p.join(directory.path, '小栖'));
  await root.create(recursive: true);
  final name = _safeStem(displayName, format);
  // Content-addressed suffix makes retries stable without replacing another book.
  final target = File(
    p.join(root.path, '$name-${expectedSha256.substring(0, 12)}.$format'),
  );
  if (await target.exists()) {
    if ((await sha256.bind(target.openRead()).first).toString() ==
        expectedSha256) {
      return target;
    }
  }
  final staging = await root.createTemp('.小栖下载-');
  final staged = File(p.join(staging.path, 'book.$format'));
  try {
    await file.copy(staged.path);
    if ((await sha256.bind(staged.openRead()).first).toString() !=
        expectedSha256) {
      throw const FormatException('保存的下载文件校验失败');
    }
    var destination = target;
    // Never replace a user-edited or unrelated existing file.
    for (var suffix = 1; await destination.exists(); suffix++) {
      if ((await sha256.bind(destination.openRead()).first).toString() ==
          expectedSha256) {
        return destination;
      }
      destination = File(
        p.join(
          root.path,
          '$name-${expectedSha256.substring(0, 12)} ($suffix).$format',
        ),
      );
    }
    // A desktop retry is serialized by the existing one-import-at-a-time UI.
    return await staged.rename(destination.path);
  } finally {
    await staging.delete(recursive: true);
  }
}

String _safeStem(String displayName, String format) {
  var value = displayName.trim();
  if (value.toLowerCase().endsWith('.$format')) {
    value = value.substring(0, value.length - format.length - 1);
  }
  value = value.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\:*?"<>|]'), '_');
  final limited = StringBuffer();
  var bytes = 0;
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    bytes += utf8.encode(character).length;
    if (bytes > 180) break;
    limited.write(character);
  }
  value = limited.toString().replaceAll(RegExp(r'[. ]+$'), '');
  if (value.isEmpty ||
      RegExp(
        r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
        caseSensitive: false,
      ).hasMatch(value)) {
    return '电子书';
  }
  return value;
}
