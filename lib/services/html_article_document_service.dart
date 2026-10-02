import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/xiaoqi_document.dart';

/// Converts a static HTML snapshot into the shared document model.
///
/// This intentionally parses DOM only. Scripts, styles, forms, embeds and
/// event attributes are removed before any text is exposed to the reader or
/// an AI adapter.
class HtmlArticleDocumentService {
  const HtmlArticleDocumentService();

  XiaoqiDocument parse(
    String source, {
    required String sourceUrl,
    String snapshotHash = '',
  }) {
    final document = html_parser.parse(source);
    _sanitize(document);
    final root = _articleRoot(document);
    final title =
        _metadata(document, 'og:title') ??
        document.querySelector('h1')?.text.trim() ??
        document.querySelector('title')?.text.trim() ??
        Uri.tryParse(sourceUrl)?.host ??
        '网页文章';
    final author =
        _metadata(document, 'author') ??
        _metadata(document, 'article:author') ??
        '';
    final blocks = <XiaoqiDocumentBlock>[];
    final pageBreakCount = _collectBlocks(
      root,
      blocks,
      sourceUrl: sourceUrl,
      snapshotHash: snapshotHash,
    );
    if (blocks.isEmpty) {
      throw const FormatException('网页中没有找到可读正文');
    }
    final plainText = blocks
        .map((block) => block.text)
        .where((text) => text.trim().isNotEmpty)
        .join('\n\n');
    return XiaoqiDocument(
      format: 'html',
      title: title,
      author: author,
      language: document.documentElement?.attributes['lang'] ?? '',
      chapters: [
        XiaoqiDocumentChapter(
          id: 'html:chapter:0',
          title: title,
          href: sourceUrl,
          sourceLocator: snapshotHash.isEmpty
              ? sourceUrl
              : '$sourceUrl#snapshot=$snapshotHash',
          html: '',
          plainText: plainText,
          order: 0,
          blocks: List.unmodifiable(blocks),
        ),
      ],
      originalPageCount: pageBreakCount == 0 ? null : pageBreakCount + 1,
    );
  }

  String sanitizeForArchive(
    String source, {
    required String sourceUrl,
    String snapshotHash = '',
  }) {
    final document = html_parser.parse(source);
    _sanitize(document, preservePresentation: true);
    _annotateBlockIds(_articleRoot(document), snapshotHash);
    final head = document.head;
    if (head != null) {
      if (head.querySelector('meta[name="viewport"]') == null) {
        head.children.add(
          dom.Element.tag('meta')
            ..attributes['name'] = 'viewport'
            ..attributes['content'] =
                'width=device-width, initial-scale=1, viewport-fit=cover',
        );
      }
      head.children.removeWhere(
        (element) =>
            element.localName == 'meta' &&
            element.attributes['http-equiv']?.toLowerCase() ==
                'content-security-policy',
      );
      head.children.insert(
        0,
        dom.Element.tag('meta')
          ..attributes['http-equiv'] = 'Content-Security-Policy'
          ..attributes['content'] =
              "default-src 'none'; img-src data:; style-src 'unsafe-inline' data:; font-src data:; script-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'",
      );
    }
    return document.outerHtml;
  }

  void _sanitize(dom.Document document, {bool preservePresentation = false}) {
    final removable = <String>[
      'script',
      'noscript',
      'template',
      'form',
      'input',
      'button',
      'textarea',
      'select',
      'iframe',
      'object',
      'embed',
      'canvas',
      'svg',
      'base',
    ];
    if (!preservePresentation) removable.add('style');
    for (final element in document.querySelectorAll(removable.join(', '))) {
      element.remove();
    }
    for (final element in document.querySelectorAll('meta[http-equiv]')) {
      if (element.attributes['http-equiv']?.toLowerCase() == 'refresh') {
        element.remove();
      }
    }
    for (final element in document.querySelectorAll('*')) {
      final unsafeAttributes = element.attributes.keys
          .map((key) => key.toString())
          .where(
            (name) =>
                name.toLowerCase().startsWith('on') ||
                (!preservePresentation && name.toLowerCase() == 'style'),
          )
          .toList(growable: false);
      for (final name in unsafeAttributes) {
        element.attributes.remove(name);
      }
      final href = element.attributes['href'];
      if (href != null && !_isSafeLink(href, allowData: false)) {
        element.attributes.remove('href');
      }
      final src = element.attributes['src'];
      if (src != null && !_isSafeLink(src, allowData: true)) {
        element.attributes.remove('src');
      }
      element.attributes.remove('srcset');
      if (preservePresentation && element.localName == 'style') {
        element.text = element.text.replaceAll(
          RegExp(r'@import[^;]+;', caseSensitive: false),
          '',
        );
      }
    }
  }

  dom.Element _articleRoot(dom.Document document) {
    final candidates = <dom.Element>[
      ...document.querySelectorAll('article'),
      ...document.querySelectorAll('main'),
      ...document.querySelectorAll('[role="main"]'),
    ];
    if (candidates.isEmpty) return document.body ?? document.documentElement!;
    candidates.sort((a, b) => _score(b).compareTo(_score(a)));
    return candidates.first;
  }

  double _score(dom.Element element) {
    final textLength = element.text.trim().length.toDouble();
    final linksLength = element
        .querySelectorAll('a')
        .fold<int>(0, (total, link) => total + link.text.trim().length);
    return textLength -
        linksLength * 1.8 +
        element.querySelectorAll('p').length * 40;
  }

  int _collectBlocks(
    dom.Element root,
    List<XiaoqiDocumentBlock> blocks, {
    required String sourceUrl,
    required String snapshotHash,
  }) {
    var pageNumber = 1;
    String pageLabel(dom.Element marker) {
      for (final key in const ['aria-label', 'title', 'data-page']) {
        final value = marker.attributes[key]?.trim();
        if (value != null && value.isNotEmpty) return value;
      }
      final text = marker.text.trim();
      return text.isEmpty ? '${pageNumber + 1}' : text;
    }

    void visit(dom.Node node) {
      if (node is! dom.Element) return;
      final tag = node.localName?.toLowerCase() ?? '';
      final locator = snapshotHash.isEmpty
          ? '$sourceUrl#block-${blocks.length}'
          : '$sourceUrl#snapshot=$snapshotHash&block=${blocks.length}';
      if (_isPageBreak(node)) {
        blocks.add(
          XiaoqiDocumentBlock(
            id: _blockId(snapshotHash, blocks.length),
            kind: 'page_break',
            text: '',
            originalPageLabel: pageLabel(node),
            sourceLocator: locator,
          ),
        );
        pageNumber++;
        node.remove();
        return;
      }
      final isBlock = const {
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
        'p',
        'li',
        'blockquote',
        'pre',
        'code',
        'table',
      }.contains(tag);
      if (isBlock) {
        final nestedMarkers = node
            .querySelectorAll('*')
            .where(_isPageBreak)
            .toList(growable: false);
        for (final marker in nestedMarkers) {
          blocks.add(
            XiaoqiDocumentBlock(
              id: _blockId(snapshotHash, blocks.length),
              kind: 'page_break',
              text: '',
              originalPageLabel: pageLabel(marker),
              sourceLocator: locator,
            ),
          );
          pageNumber++;
          marker.remove();
        }
      }
      if (tag == 'h1' ||
          tag == 'h2' ||
          tag == 'h3' ||
          tag == 'h4' ||
          tag == 'h5' ||
          tag == 'h6') {
        _addTextBlock(
          blocks,
          node,
          kind: 'heading',
          level: int.tryParse(tag.substring(1)) ?? 1,
          locator: locator,
          snapshotHash: snapshotHash,
        );
        return;
      }
      if (tag == 'p') {
        _addTextBlock(
          blocks,
          node,
          kind: 'paragraph',
          locator: locator,
          snapshotHash: snapshotHash,
        );
        return;
      }
      if (tag == 'li') {
        _addTextBlock(
          blocks,
          node,
          kind: 'list_item',
          locator: locator,
          snapshotHash: snapshotHash,
        );
        return;
      }
      if (tag == 'blockquote') {
        _addTextBlock(
          blocks,
          node,
          kind: 'quote',
          locator: locator,
          snapshotHash: snapshotHash,
        );
        return;
      }
      if (tag == 'pre' || tag == 'code') {
        _addTextBlock(
          blocks,
          node,
          kind: 'code',
          locator: locator,
          snapshotHash: snapshotHash,
        );
        return;
      }
      if (tag == 'hr') {
        blocks.add(
          XiaoqiDocumentBlock(
            id: _blockId(snapshotHash, blocks.length),
            kind: 'divider',
            text: '',
            sourceLocator: locator,
          ),
        );
        return;
      }
      if (tag == 'table') {
        _addTableBlock(blocks, node, locator, snapshotHash: snapshotHash);
        return;
      }
      if (tag == 'img') {
        final alt = node.attributes['alt']?.trim() ?? '';
        final src = node.attributes['src']?.trim() ?? '';
        if (alt.isNotEmpty || src.isNotEmpty) {
          blocks.add(
            XiaoqiDocumentBlock(
              id: _blockId(snapshotHash, blocks.length),
              kind: 'image',
              text: alt.isEmpty ? '网页图片' : alt,
              sourceLocator: locator,
              attributes: {if (src.isNotEmpty) 'src': src},
            ),
          );
        }
        return;
      }
      for (final child in List<dom.Element>.from(node.children)) {
        visit(child);
      }
    }

    visit(root);
    return pageNumber - 1;
  }

  bool _isPageBreak(dom.Element element) {
    final type = element.attributes['epub:type'] ?? '';
    final role = element.attributes['role'] ?? '';
    return type.split(RegExp(r'\s+')).contains('pagebreak') ||
        role == 'doc-pagebreak';
  }

  void _addTextBlock(
    List<XiaoqiDocumentBlock> blocks,
    dom.Element element, {
    required String kind,
    required String locator,
    required String snapshotHash,
    int level = 0,
  }) {
    final text = element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return;
    final rawHref = element.querySelector('a[href]')?.attributes['href'];
    final href = rawHref == null ? null : _resolveSafeLink(rawHref, locator);
    blocks.add(
      XiaoqiDocumentBlock(
        id: _blockId(snapshotHash, blocks.length),
        kind: kind,
        text: text,
        level: level,
        sourceLocator: locator,
        attributes: {if (href != null) 'link': href},
      ),
    );
  }

  void _addTableBlock(
    List<XiaoqiDocumentBlock> blocks,
    dom.Element table,
    String locator, {
    required String snapshotHash,
  }) {
    final rows = <List<String>>[];
    for (final row in table.querySelectorAll('tr')) {
      final cells = row
          .querySelectorAll('th, td')
          .map((cell) => cell.text.replaceAll(RegExp(r'\s+'), ' ').trim())
          .toList(growable: false);
      if (cells.isNotEmpty) rows.add(cells);
    }
    if (rows.isEmpty) return;
    blocks.add(
      XiaoqiDocumentBlock(
        id: _blockId(snapshotHash, blocks.length),
        kind: 'table',
        text: rows.map((row) => row.join(' | ')).join('\n'),
        sourceLocator: locator,
        attributes: {
          'rows': rows.map((row) => row.join('\u001f')).join('\u001e'),
        },
      ),
    );
  }

  String? _metadata(dom.Document document, String key) {
    final byProperty = document
        .querySelector('meta[property="$key"]')
        ?.attributes['content']
        ?.trim();
    if (byProperty != null && byProperty.isNotEmpty) return byProperty;
    return document
        .querySelector('meta[name="$key"]')
        ?.attributes['content']
        ?.trim();
  }

  String _blockId(String snapshotHash, int index) => snapshotHash.isEmpty
      ? 'html:block:$index'
      : 'html:$snapshotHash:block:$index';

  void _annotateBlockIds(dom.Element root, String snapshotHash) {
    var index = 0;
    void visit(dom.Node node) {
      if (node is! dom.Element) return;
      final tag = node.localName?.toLowerCase() ?? '';
      final isBlock =
          tag == 'h1' ||
          tag == 'h2' ||
          tag == 'h3' ||
          tag == 'h4' ||
          tag == 'h5' ||
          tag == 'h6' ||
          tag == 'p' ||
          tag == 'li' ||
          tag == 'blockquote' ||
          tag == 'pre' ||
          tag == 'code' ||
          tag == 'hr' ||
          tag == 'table' ||
          tag == 'img';
      if (isBlock) {
        final hasText = node.text.trim().isNotEmpty;
        final hasImageSource =
            node.attributes['alt']?.trim().isNotEmpty == true ||
            node.attributes['src']?.trim().isNotEmpty == true;
        if ((tag != 'hr' && tag != 'img' && !hasText) ||
            (tag == 'img' && !hasImageSource)) {
          return;
        }
        node.attributes['data-xq-block-id'] = _blockId(snapshotHash, index++);
        return;
      }
      for (final child in node.children) {
        visit(child);
      }
    }

    visit(root);
  }

  bool _isSafeLink(String value, {required bool allowData}) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return false;
    if (uri.scheme.isEmpty) return true;
    if (uri.scheme == 'http' || uri.scheme == 'https') return true;
    return allowData &&
        uri.scheme == 'data' &&
        value.trim().startsWith('data:image/');
  }

  String? _resolveSafeLink(String raw, String sourceUrl) {
    final base = Uri.tryParse(sourceUrl.split('#').first);
    final resolved = base?.resolve(raw.trim());
    if (resolved == null ||
        !_isSafeLink(resolved.toString(), allowData: false)) {
      return null;
    }
    return resolved.toString();
  }
}
