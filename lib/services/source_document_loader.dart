import 'dart:io';

import '../models/book_source.dart';
import '../models/xiaoqi_document.dart';
import 'docx_document_service.dart';
import 'epub_document_service.dart';
import 'html_article_document_service.dart';
import 'text_document_service.dart';
import 'web_article_source_service.dart';

/// Single dispatch point for structured source documents.
///
/// PDF keeps its existing viewer/catalog path. This loader only owns formats
/// that produce XiaoqiDocument and are consumed by the structured reader and
/// AI adapter.
class SourceDocumentLoader {
  const SourceDocumentLoader({
    this.text = const TextDocumentService(),
    this.epub = const EpubDocumentService(),
    this.docx = const DocxDocumentService(),
    this.html = const HtmlArticleDocumentService(),
  });

  final TextDocumentService text;
  final EpubDocumentService epub;
  final DocxDocumentService docx;
  final HtmlArticleDocumentService html;

  Future<XiaoqiDocument> parseFile(
    String filePath, {
    required String format,
  }) {
    final normalized = normalizeBookSourceFormat(format);
    switch (normalized) {
      case 'epub':
        return epub.parseFile(filePath);
      case 'txt':
      case 'markdown':
        return text.parseFile(filePath, format: normalized);
      case 'docx':
        return docx.parseFile(filePath);
      case 'html':
        return _parseHtml(filePath);
      default:
        throw UnsupportedError('暂不支持整理 .$normalized 文件');
    }
  }

  static bool isStructuredFormat(String? format) =>
      const {'epub', 'txt', 'markdown', 'docx', 'html'}.contains(
        normalizeBookSourceFormat(format ?? ''),
      );

  Future<XiaoqiDocument> _parseHtml(String filePath) async {
    final source = await File(filePath).readAsString();
    if (WebArticleSourceService.looksLikeAccessChallenge(source)) {
      throw const FormatException('网页需要完成验证，无法整理为正式资料');
    }
    return html.parse(
      source,
      sourceUrl: Uri.file(filePath).toString(),
    );
  }
}
