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
/// reads the container, OPF manifest/spine, navigation, and XHTML chapters.
/// Navigation metadata keeps the authored outline independent of spine order.
class EpubDocumentService {
  const EpubDocumentService();

  // EPUB is an untrusted ZIP container. The central-directory preflight below
  // applies these limits before the decoder inflates any entry.
  static const int maxInputBytes = 256 * 1024 * 1024;
  static const int maxEntries = 10000;
  static const int maxEntryBytes = 32 * 1024 * 1024;
  static const int maxExpandedBytes = 512 * 1024 * 1024;

  Future<XiaoqiDocument> parseFile(
    String filePath, {
    bool includeCover = false,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) throw StateError('EPUB 文件不存在');
    if (await file.length() > maxInputBytes) {
      throw const FormatException('EPUB 文件过大，无法安全解析');
    }
    final bytes = await file.readAsBytes();
    return parseBytes(bytes, includeCover: includeCover);
  }

  XiaoqiDocument parseBytes(List<int> bytes, {bool includeCover = false}) {
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
    String? optionalText(_ManifestItem? item) {
      if (item == null || !entries.containsKey(item.href)) return null;
      try {
        return readText(item.href);
      } on Exception {
        return null;
      }
    }

    final navSource = optionalText(navItem);
    final nav = navSource == null ? null : html_parser.parse(navSource);
    final navPageList = nav == null || navItem == null
        ? const <_EpubPageReference>[]
        : _parsePageList(nav, navItem.href);
    final tocId = spine?.getAttribute('toc');
    final ncxItem = tocId == null ? null : manifest[tocId];
    final ncxSource = optionalText(ncxItem);
    final ncx = ncxSource == null ? null : _parseOptionalXml(ncxSource);
    final pageList = navPageList.isNotEmpty
        ? navPageList
        : ncx == null || ncxItem == null
        ? const <_EpubPageReference>[]
        : _parseNcxPageList(ncx, ncxItem.href);
    final pageLabels = <String, String>{
      for (final page in pageList) page.href: page.label,
    };
    final navOutline = nav == null || navItem == null
        ? const <_EpubOutlineReference>[]
        : _parseNavOutline(nav, navItem.href);
    final ncxOutline = ncx == null || ncxItem == null
        ? const <_EpubOutlineReference>[]
        : _parseNcxOutline(ncx, ncxItem.href);
    final fragmentsByPath = <String, Set<String>>{};
    for (final entry in [...navOutline, ...ncxOutline]) {
      final target = entry.target;
      final fragment = target?.fragment;
      if (target != null && fragment != null) {
        fragmentsByPath.putIfAbsent(target.path, () => {}).add(fragment);
      }
    }

    final chapters = <XiaoqiDocumentChapter>[];
    final fragmentBlocksByPath = <String, Map<String, String>>{};
    var inlinePageBreakCount = 0;
    var fallbackPageNumber = pageList.length + 1;
    for (var index = 0; index < orderedItems.length; index++) {
      final item = orderedItems[index];
      final html = readText(item.href);
      final document = html_parser.parse(html);
      _removeUnsafeNodes(document);
      final chapterTitle = _chapterTitle(document, item.href, index + 1);
      final chapterId = 'epub:${item.id}';
      final fragments = fragmentsByPath[item.href] ?? const <String>{};
      final fragmentBlocks = <String, String>{};
      final blocksResult = _contentBlocks(
        document,
        item.href,
        chapterId,
        pageLabels,
        fallbackPageNumber,
        fragments,
        fragmentBlocks,
      );
      inlinePageBreakCount += blocksResult.pageBreakCount;
      fallbackPageNumber += blocksResult.pageBreakCount;
      final plainText = _plainText(document);
      if (chapterTitle.isEmpty && plainText.isEmpty) continue;
      if (fragmentBlocks.isNotEmpty) {
        fragmentBlocksByPath.putIfAbsent(item.href, () => fragmentBlocks);
      }
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
    final chapterIdsByPath = <String, String>{};
    for (final chapter in chapters) {
      chapterIdsByPath.putIfAbsent(chapter.href, () => chapter.id);
    }
    final resolvedNav = _resolveOutline(
      navOutline,
      chapterIdsByPath,
      fragmentBlocksByPath,
    );
    final outline = resolvedNav.isNotEmpty
        ? resolvedNav
        : _resolveOutline(ncxOutline, chapterIdsByPath, fragmentBlocksByPath);
    final cover = includeCover ? _readCover(metadata, manifest, entries) : null;
    return XiaoqiDocument(
      format: 'epub',
      title: title,
      author: author,
      language: language,
      chapters: List.unmodifiable(chapters),
      outline: outline,
      assets: [if (cover != null) cover],
      originalPageCount: pageList.isNotEmpty
          ? pageList.length
          : inlinePageBreakCount == 0
          ? null
          : inlinePageBreakCount + 1,
    );
  }

  XiaoqiDocumentAsset? _readCover(
    XmlElement? metadata,
    Map<String, _ManifestItem> manifest,
    Map<String, ArchiveFile> entries,
  ) {
    final legacyCovers = metadata == null
        ? const <String?>[]
        : _allElements(metadata, 'meta')
              .where((element) => element.getAttribute('name') == 'cover')
              .map((element) => element.getAttribute('content'));
    for (final candidate in [
      ...manifest.values.where(
        (item) => item.properties.split(RegExp(r'\s+')).contains('cover-image'),
      ),
      ...legacyCovers.map((id) => manifest[id]).whereType<_ManifestItem>(),
    ]) {
      if (!const {
        'image/jpeg',
        'image/png',
        'image/webp',
      }.contains(candidate.mediaType)) {
        continue;
      }
      final entry = entries[candidate.href];
      if (entry == null || entry.size <= 0 || entry.size > 5 * 1024 * 1024) {
        continue;
      }
      try {
        final bytes = entry.content;
        if (bytes.length == entry.size) {
          return XiaoqiDocumentAsset(
            id: 'epub-cover',
            mimeType: candidate.mediaType,
            bytes: bytes,
            sourceLocator: candidate.href,
          );
        }
      } catch (_) {
        // A damaged optional cover does not invalidate a readable EPUB.
      }
    }
    return null;
  }

  static XmlDocument? _parseOptionalXml(String source) {
    try {
      return XmlDocument.parse(source);
    } on Exception {
      return null;
    }
  }

  static bool _navHasType(dom.Element nav, String type) =>
      (nav.attributes['epub:type'] ?? nav.attributes['type'] ?? '')
          .split(RegExp(r'\s+'))
          .contains(type);

  List<_EpubPageReference> _parsePageList(dom.Document document, String path) {
    for (final nav in document.querySelectorAll('nav')) {
      if (!_navHasType(nav, 'page-list')) continue;
      final result = <_EpubPageReference>[];
      for (final link in nav.querySelectorAll('a')) {
        final target = _navigationTarget(path, link.attributes['href']);
        final label = link.text.trim();
        if (target != null && label.isNotEmpty) {
          result.add(_EpubPageReference(href: target.href, label: label));
        }
      }
      if (result.isNotEmpty) return result;
    }
    return const [];
  }

  List<_EpubPageReference> _parseNcxPageList(
    XmlDocument document,
    String path,
  ) {
    final result = <_EpubPageReference>[];
    for (final pageList in _allElements(document, 'pageList')) {
      for (final item in _childElements(pageList, 'pageTarget')) {
        final target = _navigationTarget(path, _ncxSource(item));
        final label = _ncxLabel(item);
        if (target != null && label.isNotEmpty) {
          result.add(_EpubPageReference(href: target.href, label: label));
        }
      }
    }
    return result;
  }

  List<_EpubOutlineReference> _parseNavOutline(
    dom.Document document,
    String path,
  ) {
    final nav = document
        .querySelectorAll('nav')
        .where((element) => _navHasType(element, 'toc'))
        .firstOrNull;
    if (nav == null) return const [];
    final result = <_EpubOutlineReference>[];
    for (final label
        in nav.querySelectorAll('li > a, li > span').take(maxEntries)) {
      final title = label.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (title.isEmpty) continue;
      final target = _navigationTarget(path, label.attributes['href']);
      if (target == null && label.localName == 'a') continue;
      var depth = 0;
      for (
        var parent = label.parent?.parent;
        parent != null && parent != nav;
        parent = parent.parent
      ) {
        if (parent.localName == 'li') depth++;
      }
      result.add(_EpubOutlineReference(title, target, depth));
    }
    return result;
  }

  List<_EpubOutlineReference> _parseNcxOutline(
    XmlDocument document,
    String path,
  ) {
    final nav = _firstElement(document, 'navMap');
    if (nav == null) return const [];
    final result = <_EpubOutlineReference>[];
    for (final item in _allElements(nav, 'navPoint').take(maxEntries)) {
      final title = _ncxLabel(item);
      final target = _navigationTarget(path, _ncxSource(item));
      if (title.isEmpty || target == null) continue;
      var depth = 0;
      for (
        var parent = item.parent;
        parent != null && parent != nav;
        parent = parent.parent
      ) {
        if (parent is XmlElement && parent.localName == 'navPoint') depth++;
      }
      result.add(_EpubOutlineReference(title, target, depth));
    }
    return result;
  }

  static Iterable<XmlElement> _childElements(XmlElement node, String name) =>
      node.children.whereType<XmlElement>().where(
        (child) => child.localName == name,
      );

  static String _ncxLabel(XmlElement node) =>
      _firstElement(
        _childElements(node, 'navLabel').firstOrNull,
        'text',
      )?.innerText.replaceAll(RegExp(r'\s+'), ' ').trim() ??
      '';

  static String? _ncxSource(XmlElement node) =>
      _childElements(node, 'content').firstOrNull?.getAttribute('src');

  List<XiaoqiDocumentOutlineEntry> _resolveOutline(
    List<_EpubOutlineReference> entries,
    Map<String, String> chapterIds,
    Map<String, Map<String, String>> blocks,
  ) {
    final result = <XiaoqiDocumentOutlineEntry>[];
    for (final item in entries) {
      final target = item.target;
      final chapterId = target == null ? null : chapterIds[target.path];
      if (target != null && chapterId == null) continue;
      final fragment = target?.fragment;
      final blockId = fragment == null ? null : blocks[target?.path]?[fragment];
      if (fragment != null && blockId == null) continue;
      result.add(
        XiaoqiDocumentOutlineEntry(
          title: item.title,
          chapterId: chapterId,
          blockId: blockId,
          level: item.level,
        ),
      );
    }
    return result.any((item) => item.chapterId != null)
        ? List.unmodifiable(result)
        : const [];
  }

  _EpubBlocksResult _contentBlocks(
    dom.Document document,
    String chapterHref,
    String chapterId,
    Map<String, String> pageLabels,
    int fallbackPageNumber,
    Set<String> outlineFragments,
    Map<String, String> outlineBlocks,
  ) {
    final blocks = <XiaoqiDocumentBlock>[];
    var pageBreakCount = 0;
    final body = document.body ?? document.documentElement;
    if (body == null) return const _EpubBlocksResult([], 0);
    final pendingFragments = <String>{};

    void captureFragment(dom.Element element) {
      // Legacy XHTML sometimes uses <a name="…"> instead of an id.
      final fragment = element.id.isNotEmpty
          ? element.id
          : element.localName == 'a'
          ? element.attributes['name']
          : null;
      if (fragment != null && outlineFragments.contains(fragment)) {
        pendingFragments.add(fragment);
      }
    }

    void addBlock(XiaoqiDocumentBlock block) {
      for (final fragment in pendingFragments) {
        outlineBlocks.putIfAbsent(fragment, () => block.id);
      }
      pendingFragments.clear();
      blocks.add(block);
    }

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
      addBlock(
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
      captureFragment(node);
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
          final text = segment
              .toString()
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          segment = StringBuffer();
          if (text.isEmpty) return;
          final blockIndex = blocks.length;
          addBlock(
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
            captureFragment(child);
            addPageBreak(child, labelOverride: markerLabel);
            return;
          }
          captureFragment(child);
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

    final root = document.documentElement;
    if (root != null) captureFragment(root);
    captureFragment(body);
    for (final child in List<dom.Element>.from(body.children)) {
      visit(child);
    }
    if (blocks.where((block) => block.kind != 'page_break').isEmpty &&
        _plainText(document).trim().isNotEmpty) {
      addBlock(
        XiaoqiDocumentBlock(
          id: '$chapterId:block:plain',
          kind: 'paragraph',
          text: _plainText(document),
          sourceLocator: chapterHref,
        ),
      );
    }
    if (blocks.isNotEmpty) {
      for (final fragment in pendingFragments) {
        outlineBlocks.putIfAbsent(fragment, () => blocks.last.id);
      }
    }
    return _EpubBlocksResult(List.unmodifiable(blocks), pageBreakCount);
  }

  static bool _isPageBreak(dom.Element element) {
    final type = element.attributes['epub:type'] ?? '';
    final role = element.attributes['role'] ?? '';
    return type.split(RegExp(r'\s+')).contains('pagebreak') ||
        role == 'doc-pagebreak';
  }

  static _EpubNavigationTarget? _navigationTarget(
    String basePath,
    String? href,
  ) {
    final value = href?.trim();
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.path.startsWith('/')) {
      return null;
    }
    try {
      final path = uri.path.isEmpty
          ? basePath
          : _resolveArchivePath(p.posix.dirname(basePath), uri.path);
      final fragment = uri.fragment.isEmpty
          ? null
          : Uri.decodeComponent(uri.fragment);
      return _EpubNavigationTarget(path, fragment);
    } on FormatException {
      return null;
    }
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

class _EpubNavigationTarget {
  const _EpubNavigationTarget(this.path, this.fragment);

  final String path;
  final String? fragment;

  String get href => fragment == null ? path : '$path#$fragment';
}

class _EpubOutlineReference {
  const _EpubOutlineReference(this.title, this.target, this.level);

  final String title;
  final _EpubNavigationTarget? target;
  final int level;
}

class _EpubBlocksResult {
  const _EpubBlocksResult(this.blocks, this.pageBreakCount);

  final List<XiaoqiDocumentBlock> blocks;
  final int pageBreakCount;
}
