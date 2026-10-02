import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef PageImagePicker = Future<XFile?> Function(ImageSource source);
typedef PageImageIdGenerator = String Function();

/// Metadata returned after a source image has been copied into app storage.
class PageImageAsset {
  const PageImageAsset({
    required this.relativePath,
    required this.originalName,
    required this.pixelWidth,
    required this.pixelHeight,
  });

  final String relativePath;
  final String originalName;
  final int pixelWidth;
  final int pixelHeight;
}

/// Imports page images without putting binary data into the notes database.
///
/// The picker and documents directory are injectable so editor tests can use
/// deterministic in-memory fixtures and never invoke a platform picker.
class PageImageAssetStore {
  PageImageAssetStore({
    PageImagePicker? picker,
    Future<Directory> Function()? documentsDirectory,
    PageImageIdGenerator? idGenerator,
  }) : _picker =
           picker ?? ((source) => ImagePicker().pickImage(source: source)),
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _idGenerator =
           idGenerator ??
           (() => DateTime.now().microsecondsSinceEpoch.toString());

  final PageImagePicker _picker;
  final Future<Directory> Function() _documentsDirectory;
  final PageImageIdGenerator _idGenerator;

  Future<PageImageAsset?> pickAndStore(ImageSource source) async {
    final picked = await _picker(source);
    if (picked == null) return null;
    return store(picked);
  }

  Future<PageImageAsset> store(XFile source) async {
    final bytes = await source.readAsBytes();
    if (bytes.isEmpty) throw const FormatException('图片内容为空');

    return storeBytes(
      bytes,
      extension: _safeExtension(source.path),
      originalName: p.basename(source.path),
    );
  }

  /// Stores generated image bytes in the same private page-image directory as
  /// imported assets. This is used by temporary AI source screenshots so the
  /// database stores only a relative path, never binary data.
  Future<PageImageAsset> storeBytes(
    Uint8List bytes, {
    String extension = '.png',
    String originalName = 'generated.png',
  }) async {
    if (bytes.isEmpty) throw const FormatException('图片内容为空');

    final dimensions = await _readDimensions(bytes);
    final documents = await _documentsDirectory();
    final directory = Directory(p.join(documents.path, 'page_images'));
    await directory.create(recursive: true);

    final normalizedExtension = extension.startsWith('.')
        ? 'generated$extension'
        : 'generated.$extension';
    final safeExtension = _safeExtension(normalizedExtension);
    final id = _idGenerator();
    final relativePath = p.join('page_images', '$id$safeExtension');
    final target = File(p.join(documents.path, relativePath));
    try {
      // XFile may be backed by a content URI, so writing the bytes is more
      // reliable than assuming source.path is a normal filesystem path.
      await target.writeAsBytes(bytes, flush: true);
    } on FileSystemException {
      rethrow;
    }

    return PageImageAsset(
      relativePath: relativePath.replaceAll('\\', '/'),
      originalName: originalName,
      pixelWidth: dimensions.$1,
      pixelHeight: dimensions.$2,
    );
  }

  Future<File?> resolve(String relativePath) async {
    final documents = await _documentsDirectory();
    final normalized = p.normalize(relativePath.replaceAll('/', p.separator));
    if (p.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('..${p.separator}')) {
      return null;
    }
    final file = File(p.join(documents.path, normalized));
    return await file.exists() ? file : null;
  }

  Future<void> delete(String relativePath) async {
    final file = await resolve(relativePath);
    if (file != null && await file.exists()) await file.delete();
  }

  Future<(int, int)> _readDimensions(Uint8List bytes) async {
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      frame = await codec.getNextFrame();
      return (frame.image.width, frame.image.height);
    } on Exception catch (error) {
      throw FormatException('无法读取图片', error);
    } finally {
      frame?.image.dispose();
      codec?.dispose();
    }
  }

  String _safeExtension(String path) {
    final extension = p.extension(path).toLowerCase();
    if (RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) return extension;
    return '.jpg';
  }
}
