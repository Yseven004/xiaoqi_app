import '../../config/api_config.dart';
import '../../models/ocr_layout.dart';
import 'mock_document_recognizer.dart';
import 'routed_document_recognizer.dart';
import 'vlm_document_recognizer.dart';

/// 文档识别插件统一接口。
///
/// 所有实现返回独立书页结构；下游批注/共读只消费结构化正文，不再承担 OCR
/// 段落重建和排版判断。
abstract interface class DocumentRecognitionPlugin {
  /// 识别 [imagePath] 指向的书页图片，返回结构化书页。
  Future<DocumentRecognitionResult> recognize(String imagePath);
}

/// 按当前配置选择识别实现。
///
/// Mock 只能由 `USE_MOCK_DOCUMENT_RECOGNITION=true` 显式开启，供开发期
/// UI 联调使用。缺少 VLM 密钥时仍返回真实识别器，由它把配置错误明确返回
/// 给页面；绝不能把固定演示文本伪装成用户照片的识别结果。
///
/// [dewarp] is disabled for pages already produced by double-page splitting:
/// their complete half-page is authoritative, while a generic single-page
/// detector may otherwise select an inner table or callout box.
DocumentRecognitionPlugin resolveDocumentRecognitionPlugin({
  bool dewarp = true,
  bool strictPageDewarp = false,
}) {
  if (ApiConfig.useMockDocumentRecognition) {
    return MockDocumentRecognizer();
  }
  if (ApiConfig.useFastDocumentOcr) {
    return RoutedDocumentRecognizer(
      dewarp: dewarp,
      strictPageDewarp: strictPageDewarp,
    );
  }
  return VlmDocumentRecognizer(
    enablePreprocess: dewarp,
    strictPageDewarp: strictPageDewarp,
  );
}

/// 一次文档识别的完整结果。
class DocumentRecognitionResult {
  const DocumentRecognitionResult({
    required this.markdown,
    required this.blocks,
    required this.displayImagePath,
    this.pageNumber,
    this.rawResponse,
    this.diagnostics,
    this.pageDocument,
  });

  /// 兼容 Markdown：仅供旧数据读取、导出和旧插件回退使用。
  /// 正式界面输出应消费 [pageDocument] / [blocks]。
  final String markdown;

  /// 兼容层：按阅读顺序排列的文本块；新识别器直接提供它们。
  final List<OcrBlock> blocks;

  /// 展示底图：预处理后的拉平/增强图路径。
  final String displayImagePath;

  /// 页码（识别器尽力提取，可能为 null）。
  final String? pageNumber;

  /// 模型原始返回（留档排查用）。
  final String? rawResponse;

  /// Non-content processing path and timing, used for diagnostics only.
  final Map<String, Object?>? diagnostics;

  /// 正式书页结构。旧识别器未传入时由兼容字段即时构造。
  final BookPageDocument? pageDocument;

  BookPageDocument get document =>
      pageDocument ??
      BookPageDocument(
        blocks: blocks,
        pageNumber: pageNumber,
        compatibilityMarkdown: markdown,
      );

  DocumentRecognitionResult copyWith({
    String? markdown,
    List<OcrBlock>? blocks,
    String? displayImagePath,
    String? pageNumber,
    String? rawResponse,
    Map<String, Object?>? diagnostics,
    BookPageDocument? pageDocument,
  }) {
    return DocumentRecognitionResult(
      markdown: markdown ?? this.markdown,
      blocks: blocks ?? this.blocks,
      displayImagePath: displayImagePath ?? this.displayImagePath,
      pageNumber: pageNumber ?? this.pageNumber,
      rawResponse: rawResponse ?? this.rawResponse,
      diagnostics: diagnostics ?? this.diagnostics,
      pageDocument: pageDocument ?? this.pageDocument,
    );
  }
}
