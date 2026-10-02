import '../../models/ocr_layout.dart';
import 'document_recognition_plugin.dart';
import 'markdown_blocks_codec.dart';

/// Mock 文档识别实现：仅在开发期显式开启时返回固定书页数据。
///
/// 与原阿里云 OCR Mock 数据同一本书（第六章 面对恐惧）。它保留 Markdown
/// 输入，以覆盖历史兼容转换路径；真实识别的主输出仍是结构化书页。
class MockDocumentRecognizer implements DocumentRecognitionPlugin {
  MockDocumentRecognizer({this.delay = const Duration(milliseconds: 600)});

  final Duration delay;

  static const String _mockMarkdown =
      '# 第六章 面对恐惧\n'
      '\n'
      '恐惧并不是敌人的声音，而是我们自己内心深处的不安被放大了。'
      '它常常伪装成理性的劝阻，让我们停在舒适区里。\n'
      '\n'
      '当你学会与恐惧对话，它就不再是阻碍，而成为通向勇气的路标。\n'
      '\n'
      '- 承认恐惧的存在，而不是逃避它。\n'
      '- 每天做一件让你稍微紧张的小事。\n'
      '\n'
      '> 勇气不是没有恐惧，而是带着恐惧依然前行。\n'
      '\n'
      '记住，每一次直面恐惧，你都在重塑自己的力量边界。\n'
      '\n'
      '— 91 —';

  @override
  Future<DocumentRecognitionResult> recognize(String imagePath) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return DocumentRecognitionResult(
      markdown: _mockMarkdown,
      blocks: MarkdownBlocksCodec.fromMarkdown(_mockMarkdown),
      displayImagePath: imagePath,
      rawResponse: _mockMarkdown,
    );
  }

  /// 供显式 Mock 联调测试读取的固定块数据。
  static List<OcrBlock> mockBlocks() =>
      MarkdownBlocksCodec.fromMarkdown(_mockMarkdown);
}
