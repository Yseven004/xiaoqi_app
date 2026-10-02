import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 将 Android content:// URI 等路径解析为可读的本地文件路径。
class ImagePathResolver {
  ImagePathResolver._();

  /// 若 [path] 已是普通文件路径则原样返回；否则尝试复制到应用临时目录。
  static Future<String> resolveToLocalFile(String path) async {
    if (path.isEmpty) return path;

    // 普通文件路径
    if (!path.startsWith('content://') && !path.startsWith('file://')) {
      return path.split('?').first;
    }

    if (kIsWeb) return path;

    try {
      final uri = Uri.parse(path);
      final bytes = await File.fromUri(uri).readAsBytes();

      final appDir = await getApplicationDocumentsDirectory();
      final tempDir = Directory(p.join(appDir.path, 'photos', 'scanned'));
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }

      final fileName = 'scan_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final destPath = p.join(tempDir.path, fileName);
      await File(destPath).writeAsBytes(bytes);
      return destPath;
    } catch (e) {
      debugPrint('[ImagePathResolver] 无法解析图片路径: $path, $e');
      rethrow;
    }
  }
}
