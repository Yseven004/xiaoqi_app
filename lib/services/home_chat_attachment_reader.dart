import 'dart:io';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import '../models/home_chat_attachment.dart';
import 'docx_document_service.dart';
import 'document_archive_safety.dart';
import 'epub_document_service.dart';
import 'text_document_service.dart';

class HomeChatAttachmentReader {
  Future<List<String>> read(HomeChatAttachment attachment) async {
    if (!await File(attachment.path).exists()) {
      throw FormatException('找不到文件：${attachment.name}');
    }
    final extension = attachment.name.split('.').last.toLowerCase();
    if (attachment.isImage) return const [];
    switch (extension) {
      case 'pdf':
        return _pdf(attachment.path);
      case 'epub':
      final doc = await const EpubDocumentService().parseFile(attachment.path);
        return _split('${attachment.name}\n${doc.chapters.map((c) => c.plainText).join('\n')}');
      case 'docx':
        final doc = await const DocxDocumentService().parseFile(attachment.path);
        return _split('${attachment.name}\n${doc.chapters.map((c) => c.plainText).join('\n')}');
      case 'pptx':
        return _officeZip(attachment.path, 'ppt/slides/slide', 'pptx');
      case 'xlsx':
        return _officeZip(attachment.path, 'xl/worksheets/sheet', 'xlsx');
      case 'txt':
      case 'md':
      case 'markdown':
        final doc = await const TextDocumentService().parseFile(
          attachment.path,
          format: extension == 'md' ? 'markdown' : extension,
        );
        return _split(doc.chapters.map((c) => c.plainText).join('\n'));
      default:
        throw FormatException('暂不支持 AI 读取 .$extension 文件');
    }
  }

  Future<List<String>> _pdf(String path) async {
    final document = await PdfDocument.openFile(path);
    try {
      final chunks = <String>[];
      for (var i = 0; i < document.pages.length; i++) {
        final text = (await document.pages[i].loadText())?.fullText.trim() ?? '';
        if (text.isEmpty) {
          chunks.add('[第 ${i + 1} 页为扫描页，请结合附加页面图像识别]');
        } else {
          chunks.addAll(_split('[第 ${i + 1} 页]\n$text'));
        }
      }
      return chunks;
    } finally {
      document.dispose();
    }
  }

  Future<List<String>> readScannedPageImages(HomeChatAttachment attachment) async {
    if (attachment.name.split('.').last.toLowerCase() != 'pdf') return const [];
    final document = await PdfDocument.openFile(attachment.path);
    final pages = <String>[];
    try {
      final root = await getApplicationSupportDirectory();
      final directory = Directory('${root.path}/home_chat_attachments/pdf_pages');
      await directory.create(recursive: true);
      for (var i = 0; i < document.pages.length; i++) {
        final raw = await document.pages[i].loadText();
        if (raw?.fullText.trim().isNotEmpty == true) continue;
        final size = document.pages[i].width > document.pages[i].height
            ? (800.0, 600.0)
            : (600.0, 800.0);
        final rendered = await document.pages[i].render(
          fullWidth: size.$1,
          fullHeight: size.$2,
          backgroundColor: 0xffffffff,
        );
        if (rendered == null) throw FormatException('PDF 第 ${i + 1} 页无法转为图片');
        try {
          final raster = img.Image.fromBytes(
            width: rendered.width,
            height: rendered.height,
            bytes: rendered.pixels.buffer,
            numChannels: 4,
            order: img.ChannelOrder.bgra,
          );
          final path = '${directory.path}/${attachment.id}_page_${i + 1}.jpg';
          await File(path).writeAsBytes(img.encodeJpg(raster, quality: 88), flush: true);
          pages.add(path);
        } finally {
          rendered.dispose();
        }
      }
    } finally {
      document.dispose();
    }
    return pages;
  }

  Future<List<String>> _officeZip(String path, String prefix, String type) async {
    final input = File(path);
    if (await input.length() > 50 * 1024 * 1024) {
      throw const FormatException('Office 文件超过 50 MB，无法安全读取');
    }
    final bytes = await input.readAsBytes();
    DocumentArchiveSafety.preflightZip(
      bytes,
      maxEntries: 10000,
      maxExpandedBytes: 250 * 1024 * 1024,
    );
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.files.length > 10000 ||
        archive.files.fold<int>(0, (sum, item) => sum + item.size) > 250 * 1024 * 1024) {
      throw const FormatException('Office 文件解压后过大，无法安全读取');
    }
    final sharedStrings = <String>[];
    final sharedFile = archive.files.where((f) => f.name == 'xl/sharedStrings.xml').firstOrNull;
    if (type == 'xlsx' && sharedFile != null) {
      final xml = XmlDocument.parse(String.fromCharCodes(sharedFile.content as List<int>));
      for (final entry in xml.findAllElements('si')) {
        sharedStrings.add(entry.findAllElements('t').map((t) => t.innerText).join());
      }
    }
    final files = archive.files
        .where((f) => f.isFile && f.name.startsWith(prefix) && f.name.endsWith('.xml'))
        .toList()
      ..sort((a, b) => _number(a.name).compareTo(_number(b.name)));
    if (files.isEmpty) throw const FormatException('文档中没有可读取的内容');
    final output = <String>[];
    for (final file in files) {
      final xml = XmlDocument.parse(String.fromCharCodes(file.content as List<int>));
      final label = type == 'pptx' ? '幻灯片 ${_number(file.name)}' : '工作表 ${_number(file.name)}';
      final text = type == 'pptx'
          ? xml.findAllElements('t').map((node) => node.innerText.trim()).where((value) => value.isNotEmpty).join('\n')
          : xml.findAllElements('row').map((row) {
              final values = <String>[];
              for (final cell in row.findAllElements('c')) {
                final ref = cell.getAttribute('r') ?? '?';
                final rawValue = cell.findElements('v').firstOrNull?.innerText ??
                    cell.findAllElements('t').map((node) => node.innerText).join();
                final typeAttr = cell.getAttribute('t');
                var value = rawValue;
                if (typeAttr == 's') {
                  final sharedIndex = int.tryParse(rawValue);
                  value = sharedIndex != null &&
                          sharedIndex >= 0 &&
                          sharedIndex < sharedStrings.length
                      ? sharedStrings[sharedIndex]
                      : '';
                }
                if (value.isNotEmpty) values.add('$ref=$value');
              }
              return values.join(' | ');
            }).where((line) => line.isNotEmpty).join('\n');
      if (text.isNotEmpty) output.addAll(_split('[$label]\n$text'));
    }
    return output;
  }

  int _number(String path) =>
      int.tryParse(RegExp(r'(\d+)(?=\.xml$)').firstMatch(path)?.group(1) ?? '') ?? 0;

  List<String> _split(String text) {
    const limit = 6000;
    final normalized = text.trim();
    if (normalized.isEmpty) throw const FormatException('文件中没有可读取的文字');
    final chunks = <String>[];
    for (var start = 0; start < normalized.length; start += limit) {
      chunks.add(normalized.substring(start, (start + limit).clamp(0, normalized.length)));
    }
    return chunks;
  }
}
