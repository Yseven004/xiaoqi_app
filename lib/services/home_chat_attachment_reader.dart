import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../models/home_chat_attachment.dart';
import 'docx_document_service.dart';
import 'document_archive_safety.dart';
import 'epub_document_service.dart';
import 'html_article_document_service.dart';
import 'text_document_service.dart';

Future<List<String>> _readAttachmentLocally(HomeChatAttachment attachment) =>
    HomeChatAttachmentReader()._readLocal(attachment);

class HomeChatAttachmentReader {
  Future<List<String>> read(
    HomeChatAttachment attachment, {
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() == true) {
      throw const FormatException('已停止读取附件');
    }
    // File/ZIP/XML work runs away from the UI isolate. The closure captures
    // only the immutable attachment; it never calls platform plugins.
    final result = await Isolate.run(() => _readAttachmentLocally(attachment));
    if (isCancelled?.call() == true) {
      throw const FormatException('已停止读取附件');
    }
    return result;
  }

  Future<List<String>> _readLocal(HomeChatAttachment attachment) async {
    if (!await File(attachment.path).exists()) {
      throw FormatException('找不到文件：${attachment.name}');
    }
    final extension = attachment.name.split('.').last.toLowerCase();
    if (attachment.isImage) return const [];
    if (await File(attachment.path).length() > 50 * 1024 * 1024) {
      throw const FormatException('附件超过 50 MB，无法安全读取');
    }
    if (const ['epub', 'docx', 'pptx', 'xlsx'].contains(extension)) {
      DocumentArchiveSafety.preflightZip(
        await File(attachment.path).readAsBytes(),
        maxEntries: 10000,
        maxExpandedBytes: 250 * 1024 * 1024,
      );
    }
    switch (extension) {
      case 'pdf':
        if (attachment.extractedText.trim().isNotEmpty) {
          return _split(attachment.extractedText);
        }
        throw const FormatException('PDF 请通过附件准备流程读取');
      case 'epub':
        final doc = await const EpubDocumentService().parseFile(
          attachment.path,
        );
        return _split(
          '${attachment.name}\n${doc.chapters.map((c) => c.plainText).join('\n')}',
        );
      case 'docx':
        final doc = await const DocxDocumentService().parseFile(
          attachment.path,
        );
        return _split(
          '${attachment.name}\n${doc.chapters.map((c) => c.plainText).join('\n')}',
        );
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
      case 'html':
      case 'htm':
        final source = await File(attachment.path).readAsString();
        final doc = const HtmlArticleDocumentService().parse(
          source,
          sourceUrl: Uri.file(attachment.path).toString(),
        );
        return _split(doc.chapters.map((c) => c.plainText).join('\n'));
      default:
        throw FormatException('暂不支持 AI 读取 .$extension 文件');
    }
  }

  /// Historical callers may still ask for page images. PDF extraction and OCR
  /// now have a single server owner, so no duplicate client rendering occurs.
  Future<List<String>> readScannedPageImages(
    HomeChatAttachment attachment,
  ) async => const [];

  Future<List<String>> _officeZip(
    String path,
    String prefix,
    String type,
  ) async {
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
        archive.files.fold<int>(0, (sum, item) => sum + item.size) >
            250 * 1024 * 1024) {
      throw const FormatException('Office 文件解压后过大，无法安全读取');
    }
    final sharedStrings = <String>[];
    final sharedFile = archive.files
        .where((f) => f.name == 'xl/sharedStrings.xml')
        .firstOrNull;
    if (type == 'xlsx' && sharedFile != null) {
      final xml = XmlDocument.parse(
        utf8.decode(sharedFile.content as List<int>),
      );
      for (final entry in xml.findAllElements('si')) {
        sharedStrings.add(
          entry.findAllElements('t').map((t) => t.innerText).join(),
        );
      }
    }
    final files =
        archive.files
            .where(
              (f) =>
                  f.isFile &&
                  f.name.startsWith(prefix) &&
                  f.name.endsWith('.xml'),
            )
            .toList()
          ..sort((a, b) => _number(a.name).compareTo(_number(b.name)));
    if (files.isEmpty) throw const FormatException('文档中没有可读取的内容');
    final output = <String>[];
    for (final file in files) {
      final xml = XmlDocument.parse(utf8.decode(file.content as List<int>));
      final label = type == 'pptx'
          ? '幻灯片 ${_number(file.name)}'
          : '工作表 ${_number(file.name)}';
      final text = type == 'pptx'
          ? xml
                .findAllElements('t')
                .map((node) => node.innerText.trim())
                .where((value) => value.isNotEmpty)
                .join('\n')
          : xml
                .findAllElements('row')
                .map((row) {
                  final values = <String>[];
                  for (final cell in row.findAllElements('c')) {
                    final ref = cell.getAttribute('r') ?? '?';
                    final rawValue =
                        cell.findElements('v').firstOrNull?.innerText ??
                        cell
                            .findAllElements('t')
                            .map((node) => node.innerText)
                            .join();
                    final typeAttr = cell.getAttribute('t');
                    var value = rawValue;
                    if (typeAttr == 's') {
                      final sharedIndex = int.tryParse(rawValue);
                      value =
                          sharedIndex != null &&
                              sharedIndex >= 0 &&
                              sharedIndex < sharedStrings.length
                          ? sharedStrings[sharedIndex]
                          : '';
                    }
                    if (value.isNotEmpty) values.add('$ref=$value');
                  }
                  return values.join(' | ');
                })
                .where((line) => line.isNotEmpty)
                .join('\n');
      if (text.isNotEmpty) output.addAll(_split('[$label]\n$text'));
    }
    return output;
  }

  int _number(String path) =>
      int.tryParse(
        RegExp(r'(\d+)(?=\.xml$)').firstMatch(path)?.group(1) ?? '',
      ) ??
      0;

  List<String> _split(String text) {
    const limit = 6000;
    final normalized = text.trim();
    if (normalized.isEmpty) throw const FormatException('文件中没有可读取的文字');
    final chunks = <String>[];
    for (var start = 0; start < normalized.length; start += limit) {
      chunks.add(
        normalized.substring(
          start,
          (start + limit).clamp(0, normalized.length),
        ),
      );
    }
    return chunks;
  }
}
