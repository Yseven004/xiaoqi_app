import '../models/ocr_layout.dart';
import '../models/xiaoqi_document.dart';

/// 把书页编辑器的投影结果合并回资料文档的原始块列表。
///
/// 合并必须**幂等**：同一份编辑器输出反复合并，块的数量和 id 都不能变化。
/// 2026-09-14 的卡顿/ANR 事故就是这里不幂等造成的：旧实现把编辑器投影出的
/// 段落按位置消费一遍，再把没消费完的段落全部追加到章节末尾，于是每次保存
/// 都把整份段落表复制一份（58 → 103 → 197 → 385 → … → 6025 块），正文工作台
/// 和编辑页随后在 UI 线程上被拖死。
class BookSourceBlockMerger {
  const BookSourceBlockMerger._();

  /// 富对象块。文本编辑器不能重建它们（表格/图片/公式的载荷不在投影里），
  /// 因此始终按原样保留，绝不用段落文本去顶替。
  static const Set<String> richKinds = {
    'table',
    'image',
    'figure',
    'chart',
    'math',
    'formula',
  };

  static bool isRichBlock(XiaoqiDocumentBlock block) =>
      richKinds.contains(block.kind);

  static bool isEditableBlock(XiaoqiDocumentBlock block) =>
      block.kind != 'page_break' && !isRichBlock(block);

  /// 合并编辑器结果。
  ///
  /// 原始块列表是骨架：
  /// * 投影里有同 id 的可编辑块 → 采用编辑器文本，其余属性仍取原始块；
  /// * 投影里没有（投影会跳过 page_break、空文本块和章节标题）→ 原样保留，
  ///   不再借用别的段落文本；
  /// * 富对象块 → 原样保留；
  /// * 只有投影里出现了原始文档从未有过的 id 时才追加，并且只追加一次。
  static List<XiaoqiDocumentBlock> merge(
    List<XiaoqiDocumentBlock> original,
    List<OcrBlock> editedBlocks,
  ) {
    if (original.isEmpty) return _fromProjection(editedBlocks);
    final editedBySourceId = <String, OcrBlock>{};
    for (final block in editedBlocks) {
      final sourceId = block.sourceId.trim();
      if (sourceId.isEmpty) continue;
      editedBySourceId[sourceId] = block;
    }
    final knownIds = <String>{};
    final result = <XiaoqiDocumentBlock>[];
    for (final block in original) {
      knownIds.add(block.id);
      final edited = editedBySourceId[block.id];
      if (edited == null || !isEditableBlock(block)) {
        result.add(block);
        continue;
      }
      result.add(_withText(block, edited.text));
    }
    for (final block in editedBlocks) {
      final sourceId = block.sourceId.trim();
      if (sourceId.isEmpty || knownIds.contains(sourceId)) continue;
      if (block.isFurniture || block.isTitle) continue;
      final kind = _kindFor(block.type);
      // 富对象在投影里只剩展示数据，重建会丢掉 assetId / 行结构，宁可跳过。
      if (richKinds.contains(kind)) continue;
      result.add(
        XiaoqiDocumentBlock(
          id: sourceId,
          kind: kind,
          text: block.text,
          attributes: block.attributes,
        ),
      );
      knownIds.add(sourceId);
    }
    return result;
  }

  /// 原始文档没有块（例如整份资料只有一个合成章节）时，直接按投影顺序建块。
  /// 这里保留投影的 source id，下一次保存就能按 id 命中，不会再长出重复块。
  static List<XiaoqiDocumentBlock> _fromProjection(List<OcrBlock> editedBlocks) {
    final usedIds = <String>{};
    final result = <XiaoqiDocumentBlock>[];
    for (var index = 0; index < editedBlocks.length; index++) {
      final block = editedBlocks[index];
      if (block.isFurniture || block.isTitle) continue;
      final kind = _kindFor(block.type);
      if (richKinds.contains(kind)) continue;
      final text = block.text.replaceAll('\r\n', '\n').trim();
      if (text.isEmpty) continue;
      var id = block.sourceId.trim();
      if (id.isEmpty || usedIds.contains(id)) {
        var candidate = 'paragraph-$index';
        var suffix = 0;
        while (usedIds.contains(candidate)) {
          candidate = 'paragraph-$index-${++suffix}';
        }
        id = candidate;
      }
      usedIds.add(id);
      result.add(
        XiaoqiDocumentBlock(
          id: id,
          kind: kind,
          text: text,
          attributes: block.attributes,
        ),
      );
    }
    return result;
  }

  static XiaoqiDocumentBlock _withText(
    XiaoqiDocumentBlock block,
    String text,
  ) => XiaoqiDocumentBlock(
    id: block.id,
    kind: block.kind,
    text: text,
    level: block.level,
    language: block.language,
    sourceLocator: block.sourceLocator,
    assetId: block.assetId,
    attributes: block.attributes,
    originalPageLabel: block.originalPageLabel,
  );

  /// 投影类型 → 文档块类型。富对象类型在上面已被拦掉。
  static String _kindFor(String type) {
    switch (type) {
      case 'table':
        return 'table';
      case 'chart':
        return 'chart';
      case 'figure':
        return 'image';
      case 'formula':
        return 'math';
      case 'list_item':
        return 'list_item';
      case 'quote':
        return 'quote';
      case 'code':
        return 'code';
      case 'secondary':
        return 'secondary';
      default:
        return 'paragraph';
    }
  }
}

/// 保存前的结构健全性检查。
///
/// 这是 2026-09-14 事故的第二道防线：即使合并逻辑将来又出错，也不允许把
/// 明显被写坏的派生文档写进书库。检查只看结构事实，不看文本内容，因此不会
/// 拦下正常的编辑。
class DerivedDocumentGuard {
  const DerivedDocumentGuard._();

  /// 一次保存相对上一次允许的最大块增长率。真实编辑不会成倍增加块数，
  /// 而这次事故每次保存都会把块数翻倍（约 1.9 倍且持续增长）。
  static const double maxGrowthRatio = 1.5;

  /// 增长率检查的豁免下限：小幅波动不算异常。
  static const int minGrowthDelta = 24;

  /// 返回拒绝保存的原因；结构正常时返回 `null`。
  static String? rejectionReason(
    XiaoqiDocument next, {
    XiaoqiDocument? previous,
  }) {
    final duplicate = _firstDuplicateBlockId(next);
    if (duplicate != null) {
      return '这份资料的结构出现重复块（$duplicate），已取消保存以免损坏原有内容。'
          '请重新导入原始文件后再编辑。';
    }
    if (previous == null) return null;
    final before = blockCount(previous);
    final after = blockCount(next);
    if (!exceedsGrowthLimit(before: before, after: after)) return null;
    return '保存后正文块数从 $before 涨到 $after，超过正常编辑范围，已取消保存'
        '以免损坏原有内容（原文件仍是可用的）。如果确实要新增这么多内容，'
        '请分段保存或重新导入原始文件。';
  }

  static int blockCount(XiaoqiDocument document) => document.chapters.fold<int>(
    0,
    (count, chapter) => count + chapter.blocks.length,
  );

  /// 是否超过允许的增长上限。
  static bool exceedsGrowthLimit({required int before, required int after}) {
    if (before <= 0 || after <= before) return false;
    final delta = after - before;
    return delta >= minGrowthDelta && after / before > maxGrowthRatio;
  }

  static String? _firstDuplicateBlockId(XiaoqiDocument document) {
    final seen = <String>{};
    for (final chapter in document.chapters) {
      for (final block in chapter.blocks) {
        final id = block.id.trim();
        if (id.isEmpty) continue;
        if (!seen.add(id)) return id;
      }
    }
    return null;
  }

  /// 块数达到这个规模后，正文工作台一次分页就要做上万次排版测量，读取时需要
  /// 重新解析原始文件做一次对照。低于这个规模的资料只做免费的结构检查。
  static const int baselineCheckBlockCount = 1200;

  /// 文本重复率检查的最小样本与阈值。被写坏的派生文档里 6022 条非空段落只有
  /// 48 个不同文本（重复率 99%），正常书籍几乎不会出现这种情况。
  static const int repeatedTextMinBlocks = 300;
  static const double repeatedTextRatio = .6;

  /// 是否需要花一次重新解析的代价去对照原始文件。
  static bool needsBaselineCheck(XiaoqiDocument document) {
    if (_firstDuplicateBlockId(document) != null) return true;
    final count = blockCount(document);
    if (count >= baselineCheckBlockCount) return true;
    if (count < repeatedTextMinBlocks) return false;
    return _isTextRepetitionHeavy(document);
  }

  /// 已经写坏的派生文档。
  ///
  /// 判定必须谨慎，因为读取时可能直接回退到原始文件：只有结构本身不可能正常
  /// （块 id 重复）或文本重复率异常且相对原始文件明显膨胀时才成立。正常的
  /// 大量编辑、解析器升级导致的块数变化都不会命中。
  static bool looksPoisoned(XiaoqiDocument document, {XiaoqiDocument? baseline}) {
    if (_firstDuplicateBlockId(document) != null) return true;
    final repeated = _isTextRepetitionHeavy(document);
    if (baseline == null) return repeated;
    if (!repeated) return false;
    return exceedsGrowthLimit(
      before: blockCount(baseline),
      after: blockCount(document),
    );
  }

  static bool _isTextRepetitionHeavy(XiaoqiDocument document) {
    final counts = <String, int>{};
    var nonEmpty = 0;
    for (final chapter in document.chapters) {
      for (final block in chapter.blocks) {
        final text = block.text.trim();
        if (text.isEmpty) continue;
        nonEmpty++;
        counts[text] = (counts[text] ?? 0) + 1;
      }
    }
    if (nonEmpty < repeatedTextMinBlocks) return false;
    return counts.length / nonEmpty < 1 - repeatedTextRatio;
  }
}
