import 'package:archive/archive.dart';

class DocumentArchiveSafety {
  const DocumentArchiveSafety._();

  static void preflightZip(
    List<int> bytes, {
    required int maxEntries,
    required int maxExpandedBytes,
  }) {
    final directory = ZipDirectory();
    try {
      directory.read(InputMemoryStream(bytes));
    } on Object {
      throw const FormatException('Office 文件压缩目录损坏，无法安全读取');
    }
    if (directory.totalCentralDirectoryEntries > maxEntries ||
        directory.fileHeaders.length > maxEntries) {
      throw const FormatException('Office 文件包含过多压缩条目');
    }

    var expandedBytes = 0;
    final paths = <String>{};
    for (final header in directory.fileHeaders) {
      final path = header.filename.replaceAll('\\', '/');
      if (path.startsWith('/') ||
          path.contains(':') ||
          path.split('/').any((segment) => segment == '..')) {
        throw const FormatException('Office 文件包含不安全的压缩路径');
      }
      if (!paths.add(path)) {
        throw const FormatException('Office 文件包含重复压缩路径');
      }
      final size = header.uncompressedSize;
      if (size < 0 || size > maxExpandedBytes - expandedBytes) {
        throw const FormatException('Office 文件解压后过大，无法安全读取');
      }
      expandedBytes += size;
    }
  }
}
