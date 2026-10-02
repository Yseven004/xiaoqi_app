import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models/xiaoqi_document.dart';

/// Parses an EPUB package into the app's format-neutral document model.
///
/// This deliberately keeps the source package intact on disk. The parser only
/// reads the container, OPF manifest/spine, and XHTML chapter content; it does
/// not rewrite the author's source or silently merge chapters.
class EpubDocumentService {
  const EpubDocumentService();

  // EPUB is an untrusted ZIP container. The central-directory preflight below
  // applies these limits before the decoder inflates any entry.
  static const int maxInputBytes = 256 * 1024 * 1024;
  static const int maxEntries = 10000;
  static const int maxEntryBytes = 32 * 1024 * 1024;
  static const int maxExpandedBytes = 512 * 1024 * 1024;

  Future<XiaoqiDocument> parseFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw StateError('EPUB 文件不存在');
    if (await file.length() > maxInputBytes) {
      throw const FormatException('EPUB 文件过大，无法安全解析');
    }
    final bytes = await file.readAsBytes();
    return parseBytes(bytes);
  }

  XiaoqiDocument parseBytes(List<int> bytes) {
    if (bytes.length > maxInputBytes) {
      throw const FormatException('EPUB 文件过大，无法安全解析');
    }
    _preflightZip(bytes);
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.length > maxEntries) {
      throw const FormatException('EPUB 条目过多，无法安全解析');
    }
    final entries = <String, ArchiveFile>{};
    var expandedBytes = 0;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final normalized = _checkedArchivePath(entry.name);
      final size = entry.size;
      if (size > maxEntryBytes) {
        throw const FormatException('EPUB 单个资源过大，无法安全解析');
      }
      expandedBytes += size;
      if (expandedBytes > maxExpandedBytes) {
        throw const FormatException('EPUB 解压后内容过大，无法安全解析');
      }
      if (entries.containsKey(normalized)) {
        throw const FormatException('EPUB 包含重复路径，无法安全解析');
      }
      entries[normalized] = entry;
    }

    String readText(String path) {
      final entry = entries[_normalizePath(path)];
      if (entry == null) throw const FormatException('EPUB 缺少必要文件');
      return utf8.decode(entry.content, allowMalformed: true);
    }

    final container = XmlDocument.parse(readText('META-INF/container.xml'));
    final rootfile = _firstElement(container, 'rootfile');
    final rawOpfPath = rootfile?.getAttribute('full-path');
    final opfPath = rawOpfPath == null
        ? null
        : _checkedArchivePath(Uri.decodeFull(rawOpfPath));
    if (opfPath == null || opfPath.trim().isEmpty) {
      throw const FormatException('EPUB 缺少 OPF 入口');
    }

    final opf = XmlDocument.parse(readText(opfPath));
    final opfDirectory = p.posix.dirname(_normalizePath(opfPath));
    final metadata = _firstElement(opf, 'metadata');
    final title = _firstElement(metadata, 'title')?.innerText.trim() ?? '';
    final author = _firstElement(metadata, 'creator')?.innerText.trim() ?? '';
    final language =
        _firstElement(metadata, 'language')?.innerText.trim() ?? '';

    final manifest = <String, _ManifestItem>{};
    for (final item in _allElements(opf, 'item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null || id.isEmpty || href.isEmpty) continue;
      manifest[id] = _ManifestItem(
        id: id,
        href: _resolveArchivePath(opfDirectory, href),
        mediaType: item.getAttribute('media-type') ?? '',
        properties: item.getAttribute('properties') ?? '',
      );
    }

    final spine = _firstElement(opf, 'spine');
    final spineRefs = spine == null
        ? const <String>[]
        : _allElements(spine, 'itemref')
              .map((item) => item.getAttribute('idref'))
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toList(growable: false);
    final orderedItems = spineRefs.isEmpty
        ? manifest.values
              .where(
                (item) =>
                    item.mediaType.contains('xhtml') ||
                    item.mediaType.contains('html'),
              )
              .toList(growable: false)
        : spineRefs
              .map((id) => manifest[id])
              .whereType<_ManifestItem>()
              .toList();

    _ManifestItem? navItem;
    for (final item in manifest.values) {
      if (item.properties.split(RegExp(r'\s+')).contains('nav')) {
        navItem = item;
        break;
      }
    }
    final navPageList = navItem == null
        ? const <_EpubPageReference>[]
        : _parsePageList(readText(navItem.href), navItem.href);
    final tocId = spine?.getAttribute('toc');
    final ncxItem = tocId == null ? null : manifest[tocId];
    final pageList = navPageList.isNotEmpty
        ? navPageList
        : ncxItem == null
        ? const <_EpubPageReference>[]
        : _parseNcxPageList(readText(ncxItem.href), ncxItem.href);
    final pageLabels = <String, String>{
      for (final page in pageList) page.href: page.label,
    };

    final chapters = <XiaoqiDocumentChapter>[];
    var inlinePageBreakCount = 0;
    var fallbackPageNumber = pageList.length + 1;
    for (var index = 0; index < orderedItems.length; index++) {
      final item = orderedItems[index];
      final html = readText(item.href);
      final document = html_parser.parse(html);
      _removeUnsafeNodes(document);
      final chapterTitle = _chapterTitle(document, item.href, index + 1);
      final chapterId = 'epub:${item.id}';
      final blocksResult = _contentBlocks(
        document,
        item.href,
        chapterId,
        pageLabels,
        fallbackPageNumber,
      );
      inlinePageBreakCount += blocksResult.pageBreakCount;
      fallbackPageNumber += blocksResult.pageBreakCount;
      final plainText = _plainText(document);
      if (chapterTitle.isEmpty && plainText.isEmpty) continue;
      chapters.add(
        XiaoqiDocumentChapter(
          id: chapterId,
          title: chapterTitle,
          href: item.href,
          // Keep the source package unchanged on disk, but never carry
          // executable or remotely-loaded markup into derived data.
          html: document.outerHtml,
          plainText: plainText,
          order: chapters.length,
          blocks: blocksResult.blocks,
        ),
      );
    }

    if (chapters.isEmpty) throw const FormatException('EPUB 没有可读取的章节');
    return XiaoqiDocument(
      format: 'epub',
      title: title,
      author: author,
      language: language,
      chapters: List.unmodifiable(chapters),
      originalPageCount: pageList.isNotEmpty
          ? pageList.length
          : inlinePageBreakCount == 0
          ? null
          : inlinePageBreakCount + 1,
    );
  }

  List<_EpubPageReference> _parsePageList(String source, String navPath) {
    final document = html_parser.parse(source);
    for (final nav in document.querySelectorAll('nav')) {
      final type = nav.attributes['epub:type'] ?? nav.attributes['type'] ?? '';
      if (!type.split(RegExp(r'\s+')).contains('page-list')) continue;
      final result = <_EpubPageReference>[];
      for (final link in nav.querySelectorAll('a')) {
        final href = link.attributes['href']?.trim();
        final label = link.text.trim();
        if (href == null || href.isEmpty || label.isEmpty) continue;
        result.add(
          _EpubPageReference(
            href: _resolveHrefKey(navPath, href),
            label: label,
          ),
        );
      }
      if (result.isNotEmpty) return List.unmodifiable(result);
    }
    return const [];
  }

  List<_EpubPageReference> _parseNcxPageList(String source, String ncxPath) {
    try {
      final document = XmlDocument.parse(source);
      final pageList = document.descendants.whereType<XmlElement>().where(
        (element) => element.localName == 'pageList',
      );
      final result = <_EpubPageReference>[];
      for (final list in pageList) {
        for (final target in list.children.whereType<XmlElement>().where(
          (element) => element.localName == 'pageTarget',
        )) {
          final label = target.descendants
              .whereType<XmlElement>()
              .where((element) => element.localName == 'text')
              .map((element) => element.innerText.trim())
              .firstWhere((value) => value.isNotEmpty, orElse: () => '');
          final src = target.descendants
              .whereType<XmlElement>()
              .where((element) => element.localName == 'content')
              .map((element) => element.getAttribute('src')?.trim() ?? '')
              .firstWhere((value) => value.isNotEmpty, orElse: () => '');
          if (label.isEmpty || src.isEmpty) continue;
          result.add(
            _EpubPageReference(
              href: _resolveHrefKey(ncxPath, src),
              label: label,
            ),
          );
        }
      }
      return List.unmodifiable(result);
    } catch (_) {
      return const [];
    }
  }

  _EpubBlocksResult _contentBlocks(
    dom.Document document,
    String chapterHref,
    String chapterId,
    Map<String, String> pageLabels,
    int fallbackPageNumber,
  ) {
    final blocks = <XiaoqiDocumentBlock>[];
    var pageBreakCount = 0;
    final body = document.body ?? document.documentElement;
    if (body == null) return const _EpubBlocksResult([], 0);

    final blockTags = <String, ({String kind, int level})>{
      'h1': (kind: 'heading', level: 1),
      'h2': (kind: 'heading', level: 2),
      'h3': (kind: 'heading', level: 3),
      'h4': (kind: 'heading', level: 4),
      'h5': (kind: 'heading', level: 5),
      'h6': (kind: 'heading', level: 6),
      'p': (kind: 'paragraph', level: 0),
      'li': (kind: 'list_item', level: 0),
      'blockquote': (kind: 'quote', level: 0),
      'pre': (kind: 'code', level: 0),
      'code': (kind: 'code', level: 0),
    };

    String pageLabel(dom.Element marker) {
      final id = marker.id.trim();
      final mapped = id.isEmpty ? null : pageLabels['$chapterHref#$id'];
      if (mapped != null && mapped.isNotEmpty) return mapped;
      for (final key in const ['aria-label', 'title', 'data-page']) {
        final value = marker.attributes[key]?.trim();
        if (value != null && value.isNotEmpty) return value;
      }
      final text = marker.text.trim();
      if (text.isNotEmpty) return text;
      return '${fallbackPageNumber + pageBreakCount}';
    }

    void addPageBreak(dom.Element marker, {String? labelOverride}) {
      pageBreakCount++;
      blocks.add(
        XiaoqiDocumentBlock(
          id: '$chapterId:page-break:$pageBreakCount',
          kind: 'page_break',
          text: '',
          originalPageLabel: labelOverride ?? pageLabel(marker),
          sourceLocator: '$chapterHref#${marker.id}',
        ),
      );
    }

    void visit(dom.Node node) {
      if (node is! dom.Element) return;
      final pageListLabel = pageLabels['$chapterHref#${node.id}'];
      if (_isPageBreak(node)) {
        addPageBreak(node, labelOverride: pageListLabel);
        node.remove();
        return;
      }
      if (pageListLabel != null && !blockTags.containsKey(node.localName)) {
        addPageBreak(node, labelOverride: pageListLabel);
        return;
      }
      final descriptor = blockTags[node.localName];
      if (descriptor != null) {
        if (pageListLabel != null) {
          addPageBreak(node, labelOverride: pageListLabel);
        }
        // A page marker may occur inside a paragraph. Emitting all nested
        // markers before the paragraph shifts the original-page mapping.
        var segment = StringBuffer();
        void flushSegment() {
          final text = segment.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
          segment = StringBuffer();
          if (text.isEmpty) return;
          final blockIndex = blocks.length;
          blocks.add(
            XiaoqiDocumentBlock(
              id: '$chapterId:block:$blockIndex',
              kind: descriptor.kind,
              text: text,
              level: descriptor.level,
              sourceLocator: '$chapterHref#block-$blockIndex',
            ),
          );
        }
        void collect(dom.Node child) {
          if (child is dom.Text) {
            segment.write(child.data);
            return;
          }
          if (child is! dom.Element) return;
          final markerLabel = pageLabels['$chapterHref#${child.id}'];
          if (_isPageBreak(child) || markerLabel != null) {
            flushSegment();
            addPageBreak(child, labelOverride: markerLabel);
            return;
          }
          for (final nested in child.nodes) {
            collect(nested);
          }
        }
        for (final child in node.nodes) {
          collect(child);
        }
        flushSegment();
        return;
      }
      for (final child in List<dom.Element>.from(node.children)) {
        visit(child);
      }
    }

    for (final child in List<dom.Element>.from(body.children)) {
      visit(child);
    }
    if (blocks.where((block) => block.kind != 'page_break').isEmpty &&
        _plainText(document).trim().isNotEmpty) {
      blocks.add(
        XiaoqiDocumentBlock(
          id: '$chapterId:block:plain',
          kind: 'paragraph',
          text: _plainText(document),
          sourceLocator: chapterHref,
        ),
      );
    }
    return _EpubBlocksResult(List.unmodifiable(blocks), pageBreakCount);
  }

  static bool _isPageBreak(dom.Element element) {
    final type = element.attributes['epub:type'] ?? '';
    final role = element.attributes['role'] ?? '';
    return type.split(RegExp(r'\s+')).contains('pagebreak') ||
        role == 'doc-pagebreak';
  }

  static String _resolveHrefKey(String basePath, String href) {
    final parts = href.split('#');
    final path = _resolveArchivePath(p.posix.dirname(basePath), parts.first);
    return parts.length > 1 && parts[1].isNotEmpty ? '$path#${parts[1]}' : path;
  }

  static XmlElement? _firstElement(XmlNode? root, String localName) {
    if (root == null) return null;
    for (final element in root.descendants.whereType<XmlElement>()) {
      if (element.localName == localName) return element;
    }
    return null;
  }

  static Iterable<XmlElement> _allElements(XmlNode root, String localName) =>
      root.descendants.whereType<XmlElement>().where(
        (element) => element.localName == localName,
      );

  static String _normalizePath(String value) {
    var normalized = value.replaceAll('\\', '/');
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    return p.posix.normalize(normalized);
  }

  static void _preflightZip(List<int> bytes) {
    final directory = ZipDirectory();
    try {
      // ZipDirectory reads only the central directory and compressed entry
      // slices. It does not inflate content, so declared uncompressed sizes
      // can be rejected before ZipDecoder allocates decompressed buffers.
      directory.read(InputMemoryStream(bytes));
    } on Object {
      throw const FormatException('EPUB ZIP 目录损坏，无法安全解析');
    }
    if (directory.totalCentralDirectoryEntries > maxEntries ||
        directory.fileHeaders.length > maxEntries) {
      throw const FormatException('EPUB 条目过多，无法安全解析');
    }
    var expandedBytes = 0;
    final paths = <String>{};
    for (final header in directory.fileHeaders) {
      final normalized = _checkedArchivePath(header.filename);
      final size = header.uncompressedSize;
      if (size > maxEntryBytes) {
        throw const FormatException('EPUB 单个资源过大，无法安全解析');
      }
      if (expandedBytes > maxExpandedBytes - size) {
        throw const FormatException('EPUB 解压后内容过大，无法安全解析');
      }
      expandedBytes += size;
      if (!paths.add(normalized)) {
        throw const FormatException('EPUB 包含重复路径，无法安全解析');
      }
    }
  }

  static String _checkedArchivePath(String value) {
    final normalized = _normalizePath(value);
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        normalized.contains(':')) {
      throw const FormatException('EPUB 包含非法资源路径');
    }
    return normalized;
  }

  static String _resolveArchivePath(String base, String href) {
    final withoutFragment = href.split('#').first;
    final decoded = Uri.decodeFull(withoutFragment);
    return _checkedArchivePath(p.posix.join(base, decoded));
  }

  static void _removeUnsafeNodes(dom.Document document) {
    for (final element in document.querySelectorAll(
      'script,style,noscript,svg,iframe,object,embed,form,base,link,meta,'
      'img,video,audio,source,track',
    )) {
      element.remove();
    }
    for (final element in document.querySelectorAll('*')) {
      for (final name in element.attributes.keys.toList(growable: false)) {
        final attributeName = name.toString();
        final normalizedName = attributeName.toLowerCase();
        final value =
            element.attributes[attributeName]?.trim().toLowerCase() ?? '';
        final dangerousUrl =
            (normalizedName == 'href' ||
                normalizedName == 'src' ||
                normalizedName == 'xlink:href') &&
            (value.startsWith('javascript:') ||
                value.startsWith('vbscript:') ||
                value.startsWith('data:text/html'));
        if (normalizedName.startsWith('on') ||
          normalizedName == 'srcdoc' ||
            dangerousUrl) {
          element.attributes.remove(attributeName);
        }
      }
    }
  }

  static String _chapterTitle(dom.Document document, String href, int number) {
    for (final selector in const ['h1', 'h2', 'h3', 'title']) {
      final text = document.querySelector(selector)?.text.trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    final filename = p.posix.basenameWithoutExtension(href);
    return filename.isEmpty ? '第 $number 章' : filename;
  }

  static String _plainText(dom.Document document) {
    for (final element in document.querySelectorAll(
      'script,style,noscript,svg',
    )) {
      element.remove();
    }
    final body = document.body ?? document.documentElement;
    if (body == null) return '';

    final buffer = StringBuffer();
    const blockTags = {
      'address',
      'article',
      'aside',
      'blockquote',
      'br',
      'dd',
      'div',
      'dl',
      'dt',
      'figcaption',
      'figure',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'li',
      'p',
      'pre',
      'section',
      'table',
      'tr',
    };

    void visit(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.data.replaceAll(RegExp(r'\s+'), ' '));
        return;
      }
      if (node is! dom.Element) return;
      final tag = node.localName;
      final isBlock = blockTags.contains(tag);
      if (tag == 'br') {
        buffer.write('\n');
        return;
      }
      if (isBlock && buffer.isNotEmpty && !buffer.toString().endsWith('\n')) {
        buffer.write('\n');
      }
      for (final child in node.nodes) {
        visit(child);
      }
      if (isBlock && !buffer.toString().endsWith('\n')) buffer.write('\n');
    }

    visit(body);
    return buffer
        .toString()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n\n');
  }
}

class _ManifestItem {
  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    this.properties = '',
  });

  final String id;
  final String href;
  final String mediaType;
  final String properties;
}

class _EpubPageReference {
  const _EpubPageReference({required this.href, required this.label});

  final String href;
  final String label;
}

class _EpubBlocksResult {
  const _EpubBlocksResult(this.blocks, this.pageBreakCount);

  final List<XiaoqiDocumentBlock> blocks;
  final int pageBreakCount;
}
