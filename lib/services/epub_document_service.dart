import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:image/image.dart' as img;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:path_parsing/path_parsing.dart';
import 'package:xml/xml.dart';

import '../models/xiaoqi_document.dart';

part 'epub_reading_content.dart';
part 'epub_svg_markers.dart';

class EpubBookMetadata {
  const EpubBookMetadata({
    required this.title,
    required this.authors,
    required this.publisher,
    required this.edition,
    required this.publishedDate,
    required this.cover,
  });

  final String title;
  final List<String> authors;
  String get author => authors.join('、');
  final String publisher;
  final String edition;
  final String publishedDate;
  final XiaoqiDocumentAsset? cover;
}

typedef _EpubPackage = ({
  XmlDocument opf,
  XmlElement? metadata,
  Map<String, _ManifestItem> manifest,
  Map<String, ArchiveFile> entries,
});

typedef _EpubReadingPackage = ({
  _EpubPackage package,
  String title,
  String author,
  String language,
  List<_ManifestItem> items,
  List<_EpubPageReference> pageList,
  Map<String, String> pageLabels,
  List<_EpubOutlineReference> nav,
  List<_EpubOutlineReference> ncx,
});

typedef EpubReaderSpineItem = ({String chapterId, String href});
typedef EpubReaderOutlineItem = ({
  String title,
  String? chapterId,
  String? fragment,
  int level,
});

class EpubReaderPreview {
  const EpubReaderPreview(this.document, this.spine, this.outline);

  final XiaoqiDocument document;
  final List<EpubReaderSpineItem> spine;
  final List<EpubReaderOutlineItem> outline;
}

/// Parses an EPUB package into the app's format-neutral document model.
///
/// This deliberately keeps the source package intact on disk. The parser only
/// reads the container, OPF manifest/spine, navigation, and XHTML chapters.
/// Navigation metadata keeps the authored outline independent of spine order.
class EpubDocumentService {
  const EpubDocumentService();
  static const structureVersion = 2;

  // EPUB is an untrusted ZIP container. The central-directory preflight below
  // applies these limits before the decoder inflates any entry.
  static const int maxInputBytes = 256 * 1024 * 1024;
  static const int maxEntries = 10000;
  static const int maxEntryBytes = 32 * 1024 * 1024;
  static const int maxExpandedBytes = 512 * 1024 * 1024;

  Future<Uint8List> _readFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw StateError('EPUB 文件不存在');
    if (await file.length() > maxInputBytes) {
      throw const FormatException('EPUB 文件过大，无法安全解析');
    }
    return file.readAsBytes();
  }

  Future<XiaoqiDocument> parseFile(
    String filePath, {
    bool includeCover = false,
  }) async => parseBytes(await _readFile(filePath), includeCover: includeCover);

  Future<EpubBookMetadata> readMetadata(String filePath) async {
    final package = _openPackage(await _readFile(filePath));
    final metadata = package.metadata;
    String field(String tag) =>
        _firstElement(metadata, tag)?.innerText.trim() ?? '';
    final edition = metadata == null
        ? ''
        : _allElements(metadata, 'meta')
                  .where(
                    (e) => const {
                      'schema:bookEdition',
                      'bookEdition',
                    }.contains(e.getAttribute('property')),
                  )
                  .map((e) => e.innerText.trim())
                  .where((v) => v.isNotEmpty)
                  .firstOrNull ??
              '';
    return EpubBookMetadata(
      title: field('title'),
      authors: _authors(metadata),
      publisher: field('publisher'),
      edition: edition,
      publishedDate: field('date'),
      cover: _readCover(
        metadata,
        package.manifest,
        package.entries,
        package.opf,
      ),
    );
  }

  List<String> _authors(XmlElement? metadata) {
    if (metadata == null) return const [];
    final roles = {
      for (final item in _allElements(metadata, 'meta'))
        if (item.getAttribute('property') == 'role')
          item.getAttribute('refines'): item.innerText.trim(),
    };
    final authors = <String>[];
    for (final item in _allElements(metadata, 'creator')) {
      final role =
          roles['#${item.getAttribute('id')}'] ??
          item.attributes
              .where((a) => a.localName == 'role')
              .firstOrNull
              ?.value;
      if (role != null &&
          role.isNotEmpty &&
          role != 'aut' &&
          role != 'author') {
        continue;
      }
      final name = item.innerText.trim();
      if (name.isNotEmpty && !authors.contains(name)) authors.add(name);
    }
    return List.unmodifiable(authors);
  }

  _EpubPackage _openPackage(List<int> bytes) {
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
    final manifest = <String, _ManifestItem>{};
    for (final item in _allElements(opf, 'item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null || id.isEmpty || href.isEmpty) continue;
      final uri = Uri.tryParse(href);
      if (uri == null || uri.hasScheme || uri.hasAuthority) continue;
      manifest[id] = _ManifestItem(
        originalHref: href,
        id: id,
        href: _resolveArchivePath(opfDirectory, href),
        mediaType: item.getAttribute('media-type') ?? '',
        properties: item.getAttribute('properties') ?? '',
      );
    }

    return (opf: opf, metadata: metadata, entries: entries, manifest: manifest);
  }

  XiaoqiDocument parseBytes(
    List<int> bytes, {
    bool includeCover = false,
    Map<String, String>? legacyText,
  }) {
    final prepared = _openReadingPackage(bytes);
    final media = _EpubMedia(
      prepared.package.manifest,
      prepared.package.entries,
    );
    final chapters = <XiaoqiDocumentChapter>[];
    var pageBreaks = 0;
    for (var index = 0; index < prepared.items.length; index++) {
      final chapter = _readChapter(
        prepared,
        index,
        media,
        fallbackPageNumber: prepared.pageList.length + 1 + pageBreaks,
        legacyText: legacyText,
      );
      chapters.add(chapter.document);
      pageBreaks += chapter.pageBreakCount;
    }
    return _finishReading(
      prepared,
      chapters,
      media,
      pageBreaks,
      includeCover: includeCover,
    );
  }

  /// Opens the archive once. The requested chapter is delivered before the
  /// canonical spine pass so stored page labels and inline assets stay stable.
  Future<XiaoqiDocument> parseForReader(
    String filePath, {
    required String? Function() takeTarget,
    required void Function(EpubReaderPreview preview) publish,
  }) async {
    final prepared = _openReadingPackage(await _readFile(filePath));
    if (prepared.items.isEmpty) {
      throw const FormatException('EPUB 没有可读取的章节');
    }
    final spine = List<EpubReaderSpineItem>.unmodifiable([
      for (final item in prepared.items)
        (chapterId: 'epub:${item.id}', href: item.href),
    ]);
    final byHref = <String, String>{};
    final indices = <String, int>{};
    for (final (index, item) in spine.indexed) {
      byHref.putIfAbsent(item.href, () => item.chapterId);
      indices.putIfAbsent(item.chapterId, () => index);
    }
    List<EpubReaderOutlineItem> resolve(
      List<_EpubOutlineReference> references,
    ) => [
      for (final item in references)
        if (item.target == null || byHref.containsKey(item.target!.path))
          (
            title: item.title,
            chapterId: byHref[item.target?.path],
            fragment: item.target?.fragment,
            level: item.level,
          ),
    ];
    final nav = resolve(prepared.nav);
    final outline = List<EpubReaderOutlineItem>.unmodifiable(
      nav.any((entry) => entry.chapterId != null) ? nav : resolve(prepared.ncx),
    );
    final media = _EpubMedia(
      prepared.package.manifest,
      prepared.package.entries,
    );
    final chapters = <XiaoqiDocumentChapter>[];

    ({XiaoqiDocumentChapter document, int pageBreakCount})? firstChapter;
    void show(int target) {
      final parsed = target < chapters.length;
      final previewMedia = parsed || target == 0
          ? media
          : _EpubMedia(
              prepared.package.manifest,
              prepared.package.entries,
              // Avoid collisions while the old preview is still visible.
              inlinePrefix: 'epub-preview-inline:$target:',
            );
      XiaoqiDocumentChapter chapter;
      if (parsed) {
        chapter = chapters[target];
      } else if (target == 0 && firstChapter != null) {
        chapter = firstChapter!.document;
      } else {
        final read = _readChapter(
          prepared,
          target,
          previewMedia,
          // Preceding chapters determine generated page labels. Authored
          // labels and stable block IDs remain available in the preview.
          fallbackPageNumber: target == 0 ? prepared.pageList.length + 1 : null,
        );
        if (target == 0) firstChapter = read;
        chapter = read.document;
      }
      final usedAssets = {for (final block in chapter.blocks) block.assetId};
      publish(
        EpubReaderPreview(
          XiaoqiDocument(
            format: 'epub',
            structureVersion: EpubDocumentService.structureVersion,
            title: prepared.title,
            author: prepared.author,
            language: prepared.language,
            chapters: [chapter],
            assets: [for (final id in usedAssets) ?previewMedia.assets[id]],
            originalPageCount: prepared.pageList.isEmpty
                ? null
                : prepared.pageList.length,
          ),
          spine,
          outline,
        ),
      );
    }

    await Future<void>.delayed(Duration.zero);
    show(indices[takeTarget()] ?? 0);
    var pageBreaks = 0;
    for (var index = 0; index < prepared.items.length; index++) {
      // Let the isolate receive a newer navigation request between chapters.
      await Future<void>.delayed(Duration.zero);
      final requested = indices[takeTarget()];
      if (requested != null) show(requested);
      final chapter = index == 0 && firstChapter != null
          ? firstChapter!
          : _readChapter(
              prepared,
              index,
              media,
              fallbackPageNumber: prepared.pageList.length + 1 + pageBreaks,
            );
      chapters.add(chapter.document);
      pageBreaks += chapter.pageBreakCount;
    }
    return _finishReading(prepared, chapters, media, pageBreaks);
  }

  _EpubReadingPackage _openReadingPackage(List<int> bytes) {
    final package = _openPackage(bytes);
    final (:opf, :metadata, :entries, :manifest) = package;
    String readText(String path) =>
        utf8.decode(entries[path]!.content, allowMalformed: true);
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
    return (
      package: package,
      title: _firstElement(metadata, 'title')?.innerText.trim() ?? '',
      author: _authors(metadata).join('、'),
      language: _firstElement(metadata, 'language')?.innerText.trim() ?? '',
      items: orderedItems,
      pageList: pageList,
      pageLabels: pageLabels,
      nav: navOutline,
      ncx: ncxOutline,
    );
  }

  ({XiaoqiDocumentChapter document, int pageBreakCount}) _readChapter(
    _EpubReadingPackage prepared,
    int index,
    _EpubMedia media, {
    required int? fallbackPageNumber,
    Map<String, String>? legacyText,
  }) {
    final item = prepared.items[index];
    final entry = prepared.package.entries[item.href];
    if (entry == null) throw const FormatException('EPUB 缺少章节文件');
    final html = utf8.decode(entry.content, allowMalformed: true);
    final document = html_parser.parse(html);
    final chapterId = 'epub:${item.id}';
    final priorIds = _legacyBlockIds(
      document,
      item.href,
      chapterId,
      prepared.pageLabels,
      legacyText,
    );
    _prepareLocalMarkup(document, item.href, media);
    _removeUnsafeNodes(document);
    final fragmentBlocks = <String, String>{};
    final blocksResult = _contentBlocks(
      document,
      item.href,
      chapterId,
      prepared.pageLabels,
      fallbackPageNumber,
      media,
      priorIds,
      fragmentBlocks,
    );
    return (
      document: XiaoqiDocumentChapter(
        id: chapterId,
        title: _chapterTitle(document, item.href, index + 1),
        href: item.href,
        // Persist inert derived markup, keeping the original package intact.
        html: document.outerHtml,
        plainText: blocksResult.blocks
            .map((block) => block.text)
            .where((text) => text.isNotEmpty)
            .join('\n\n'),
        order: index,
        blocks: blocksResult.blocks,
        fragmentBlocks: fragmentBlocks,
      ),
      pageBreakCount: blocksResult.pageBreakCount,
    );
  }

  XiaoqiDocument _finishReading(
    _EpubReadingPackage prepared,
    List<XiaoqiDocumentChapter> chapters,
    _EpubMedia media,
    int pageBreaks, {
    bool includeCover = false,
  }) {
    if (chapters.isEmpty) throw const FormatException('EPUB 没有可读取的章节');
    final chapterIds = <String, String>{};
    final fragments = <String, Map<String, String>>{};
    for (final chapter in chapters) {
      chapterIds.putIfAbsent(chapter.href, () => chapter.id);
      if (chapter.fragmentBlocks.isNotEmpty) {
        fragments.putIfAbsent(chapter.href, () => chapter.fragmentBlocks);
      }
    }
    final nav = _resolveOutline(prepared.nav, chapterIds, fragments);
    final (:metadata, :manifest, :entries, :opf) = prepared.package;
    final cover = includeCover
        ? _readCover(metadata, manifest, entries, opf)
        : null;
    return XiaoqiDocument(
      format: 'epub',
      structureVersion: EpubDocumentService.structureVersion,
      title: prepared.title,
      author: prepared.author,
      language: prepared.language,
      chapters: List.unmodifiable(chapters),
      outline: nav.isNotEmpty
          ? nav
          : _resolveOutline(prepared.ncx, chapterIds, fragments),
      assets: [
        ?cover,
        ...media.assets.values.where((asset) => asset.id != cover?.id),
      ],
      originalPageCount: prepared.pageList.isNotEmpty
          ? prepared.pageList.length
          : pageBreaks == 0
          ? null
          : pageBreaks + 1,
    );
  }

  XiaoqiDocumentAsset? _readCover(
    XmlElement? metadata,
    Map<String, _ManifestItem> manifest,
    Map<String, ArchiveFile> entries,
    XmlDocument opf,
  ) {
    final legacyCovers = metadata == null
        ? const <String?>[]
        : _allElements(metadata, 'meta')
              .where((element) => element.getAttribute('name') == 'cover')
              .map((element) => element.getAttribute('content'));
    final guide = _firstElement(opf, 'guide');
    final coverPage = guide == null
        ? null
        : _allElements(guide, 'reference')
              .where((r) => r.getAttribute('type') == 'cover')
              .firstOrNull
              ?.getAttribute('href');
    _ManifestItem? guideImage;
    if (coverPage != null) {
      final candidate = manifest.values
          .where((m) => m.originalHref == coverPage.split('#').first)
          .firstOrNull;
      if (candidate != null && candidate.mediaType.startsWith('image/')) {
        guideImage = candidate;
      } else if (candidate != null && entries.containsKey(candidate.href)) {
        final chapter = entries[candidate.href]!;
        final wrapper = html_parser.parse(
          utf8.decode(chapter.content, allowMalformed: true),
        );
        final image = wrapper.querySelector('img, image');
        final reference = image?.attributes.entries
            .where(
              (entry) =>
                  entry.key.toString() == 'src' ||
                  entry.key.toString().split(':').last == 'href',
            )
            .firstOrNull
            ?.value;
        final path = _navigationTarget(candidate.href, reference)?.path;
        guideImage = manifest.values.where((m) => m.href == path).firstOrNull;
      }
    }
    for (final candidate in [
      ...manifest.values.where(
        (item) => item.properties.split(RegExp(r'\s+')).contains('cover-image'),
      ),
      ...legacyCovers.map((id) => manifest[id]).whereType<_ManifestItem>(),
      ?guideImage,
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
    int? fallbackPageNumber,
    _EpubMedia media,
    Map<dom.Element, List<int>> legacyIds,
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
      if (fragment != null && fragment.isNotEmpty) {
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
      'figcaption': (kind: 'caption', level: 0),
      'caption': (kind: 'caption', level: 0),
      'blockquote': (kind: 'quote', level: 0),
      'pre': (kind: 'code', level: 0),
      'code': (kind: 'code', level: 0),
    };

    String? pageLabel(dom.Element marker) {
      final id = marker.id.trim();
      final mapped = id.isEmpty ? null : pageLabels['$chapterHref#$id'];
      if (mapped != null && mapped.isNotEmpty) return mapped;
      for (final key in const ['aria-label', 'title', 'data-page']) {
        final value = marker.attributes[key]?.trim();
        if (value != null && value.isNotEmpty) return value;
      }
      final text = marker.text.trim();
      if (text.isNotEmpty) return text;
      return fallbackPageNumber == null
          ? null
          : '${fallbackPageNumber + pageBreakCount}';
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

    var newIndex = 0;
    String nextId(dom.Element node) {
      final ids = legacyIds[node];
      return ids != null && ids.isNotEmpty
          ? '$chapterId:block:${ids.removeAt(0)}'
          : '$chapterId:rich:${newIndex++}';
    }

    void visit(dom.Node node) {
      if (node is! dom.Element) return;
      captureFragment(node);
      final pageListLabel = pageLabels['$chapterHref#${node.id}'];
      if (_isPageBreak(node)) {
        addPageBreak(node, labelOverride: pageListLabel);
        return;
      }
      if (pageListLabel != null) {
        addPageBreak(node, labelOverride: pageListLabel);
      }
      final assetId = node.attributes['data-xiaoqi-asset'];
      if (assetId != null && media.assets.containsKey(assetId)) {
        final asset = media.assets[assetId]!;
        var ancestor = node.parent;
        while (ancestor != null && ancestor.localName != 'a') {
          ancestor = ancestor.parent;
        }
        final link = _readingTarget(chapterHref, ancestor?.attributes['href']);
        addBlock(
          XiaoqiDocumentBlock(
            id: nextId(node),
            kind: 'image',
            text: node.attributes['aria-label'] ?? asset.altText,
            assetId: assetId,
            sourceLocator: asset.sourceLocator,
            attributes: {
              'imageLink': ?link,
              if (media.ratios[assetId] case final r?)
                'aspectRatio': r.toString(),
            },
          ),
        );
        return;
      }
      if (node.localName == 'table') {
        for (final caption in node.children.where(
          (e) => e.localName == 'caption',
        )) {
          visit(caption);
        }
        final rows = <List<String>>[];
        var headerRows = 0;
        final cellLinks = <String, List<List<Object>>>{};
        final occupied = <int, int>{};
        for (final tr in node.querySelectorAll('tr')) {
          var owner = tr.parent;
          while (owner != null && owner.localName != 'table') {
            owner = owner.parent;
          }
          if (owner != node) continue;
          final cells = tr.children.where(
            (c) => c.localName == 'td' || c.localName == 'th',
          );
          if (cells.isEmpty) continue;
          if (rows.length == headerRows &&
              cells.every((c) => c.localName == 'th')) {
            headerRows++;
          }
          final row = <String>[];
          for (final c in cells) {
            while ((occupied[row.length] ?? 0) > rows.length) {
              row.add('');
            }
            final content = _InlineText(false);
            void readCell(dom.Node node, String? link) {
              if (node is dom.Text) {
                content.append(node.data, link: link);
                return;
              }
              if (node is! dom.Element) return;
              if (node.localName == 'br') {
                content.newline();
                return;
              }
              final target = node.localName == 'a'
                  ? _readingTarget(chapterHref, node.attributes['href'])
                  : link;
              for (final nested in node.nodes) {
                readCell(nested, target);
              }
            }

            readCell(c, null);
            if (content.links.isNotEmpty) {
              cellLinks['${rows.length}:${row.length}'] = content.links;
            }
            final columns = (int.tryParse(c.attributes['colspan'] ?? '') ?? 1)
                .clamp(1, 256);
            final span = (int.tryParse(c.attributes['rowspan'] ?? '') ?? 1)
                .clamp(1, 65534);
            for (var col = 0; col < columns; col++) {
              if (span > 1) occupied[row.length] = rows.length + span;
              row.add(col == 0 ? content.buffer.toString() : '');
            }
          }
          rows.add(row);
        }
        if (rows.isNotEmpty) {
          addBlock(
            XiaoqiDocumentBlock(
              id: nextId(node),
              kind: 'table',
              text: rows.map((r) => r.join('\t')).join('\n'),
              sourceLocator: chapterHref,
              attributes: {
                'rows': jsonEncode(rows),
                if (cellLinks.isNotEmpty) 'cellLinks': jsonEncode(cellLinks),
                if (headerRows > 0) 'headerRows': '$headerRows',
              },
            ),
          );
        }
        return;
      }
      final descriptor = blockTags[node.localName];
      if (descriptor == null) {
        for (final child in node.children) {
          visit(child);
        }
        return;
      }
      final verbatim = descriptor.kind == 'code';
      var segment = _InlineText(verbatim);
      var listDepth = 0;
      if (descriptor.kind == 'list_item') {
        for (var parent = node.parent; parent != null; parent = parent.parent) {
          if (parent.localName == 'li') listDepth++;
        }
      }
      void flush() {
        final text = segment.buffer.toString();
        if (text.trim().isEmpty) {
          segment = _InlineText(verbatim);
          return;
        }
        final id = nextId(node);
        addBlock(
          XiaoqiDocumentBlock(
            id: id,
            kind: descriptor.kind,
            text: text,
            level: descriptor.level,
            sourceLocator: id.startsWith('$chapterId:block:')
                ? '$chapterHref#block-${id.split(':').last}'
                : '$chapterHref#${node.id.isNotEmpty ? node.id : id}',
            attributes: {
              if (segment.links.isNotEmpty)
                'linkRanges': jsonEncode(segment.links),
              if (segment.bold.isNotEmpty)
                'boldRanges': jsonEncode(segment.bold),
              if (descriptor.kind == 'list_item') 'listDepth': '$listDepth',
              if (descriptor.kind == 'list_item' &&
                  node.parent?.localName == 'ol')
                'listMarker':
                    '${(int.tryParse(node.parent!.attributes['start'] ?? '') ?? 1) + node.parent!.children.where((e) => e.localName == 'li').toList().indexOf(node)}.',
            },
          ),
        );
        segment = _InlineText(verbatim);
      }

      void collect(dom.Node child, {String? link, bool bold = false}) {
        if (child is dom.Text) {
          segment.append(child.data, link: link, strong: bold);
          return;
        }
        if (child is! dom.Element) return;
        if (_isPageBreak(child) ||
            pageLabels.containsKey('$chapterHref#${child.id}') ||
            child.attributes.containsKey('data-xiaoqi-asset') ||
            const {
              'ol',
              'ul',
              'table',
              'figure',
              'pre',
            }.contains(child.localName)) {
          flush();
          visit(child);
          return;
        }
        captureFragment(child);
        if (child.localName == 'br') {
          segment.newline();
          return;
        }
        final target = child.localName == 'a'
            ? _readingTarget(chapterHref, child.attributes['href'])
            : link;
        final strong =
            bold || child.localName == 'b' || child.localName == 'strong';
        for (final n in child.nodes) {
          collect(n, link: target, bold: strong);
        }
        if (child.localName == 'p' && descriptor.kind == 'quote') flush();
      }

      for (final child in node.nodes) {
        collect(child);
      }
      flush();
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
            normalizedName == 'style' ||
            normalizedName == 'srcset' ||
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
    required this.originalHref,
    required this.id,
    required this.href,
    required this.mediaType,
    this.properties = '',
  });

  final String id;
  final String href;
  final String originalHref;
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
