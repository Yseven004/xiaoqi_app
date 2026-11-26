part of 'epub_document_service.dart';

/// Only declared, local assets are passed to a Flutter renderer. XHTML stored
/// for derived revisions contains inert spans instead of live media elements.
class _EpubMedia {
  _EpubMedia(
    Map<String, _ManifestItem> manifest,
    this.entries, {
    this.inlinePrefix = 'epub-inline:',
  }) : byPath = {for (final item in manifest.values) item.href: item};
  final Map<String, _ManifestItem> byPath;
  final Map<String, ArchiveFile> entries;
  final String inlinePrefix;
  final assets = <String, XiaoqiDocumentAsset>{};
  final ratios = <String, double>{};
  int inlineCount = 0;

  String? load(String chapter, String? href, String alt) {
    final target = EpubDocumentService._navigationTarget(chapter, href);
    final item = byPath[target?.path];
    if (item == null ||
        !const {
          'image/png',
          'image/jpeg',
          'image/webp',
          'image/svg+xml',
        }.contains(item.mediaType)) {
      return null;
    }
    final id = item.properties.split(RegExp(r'\s+')).contains('cover-image')
        ? 'epub-cover'
        : 'epub-asset:${item.id}';
    if (assets.containsKey(id)) return id;
    final entry = entries[item.href];
    if (entry == null) return null;
    try {
      var bytes = entry.content;
      if (item.mediaType == 'image/svg+xml') {
        return svg(id, utf8.decode(bytes), alt, item.href);
      }
      final info = img.findDecoderForData(bytes)?.startDecode(bytes);
      if (info == null ||
          info.width < 1 ||
          info.height < 1 ||
          info.width * info.height > 16 * 1024 * 1024) {
        return null;
      }
      ratios[id] = info.width / info.height;
      assets[id] = XiaoqiDocumentAsset(
        id: id,
        mimeType: item.mediaType,
        bytes: bytes,
        sourceLocator: item.href,
        altText: alt,
      );
      return id;
    } on Object {
      return null;
    }
  }

  String? svg(String id, String markup, String alt, String path) {
    if (markup.toLowerCase().contains('<!doctype') ||
        markup.toLowerCase().contains('<!entity')) {
      return null;
    }
    final doc = EpubDocumentService._parseOptionalXml(markup);
    final root = doc?.rootElement;
    if (root == null || root.localName != 'svg') return null;
    _inlineDiagramStyles(root);
    final allowed = {
      'svg',
      'g',
      'defs',
      'path',
      'rect',
      'circle',
      'ellipse',
      'line',
      'polyline',
      'polygon',
      'text',
      'tspan',
      'title',
      'desc',
      'clipPath',
      'mask',
      'linearGradient',
      'radialGradient',
      'stop',
      'pattern',
      'marker',
      'symbol',
      'use',
    };
    for (final e in [root, ...root.descendants.whereType<XmlElement>()]) {
      if (!allowed.contains(e.localName)) {
        e.parent?.children.remove(e);
        continue;
      }
      e.attributes.removeWhere((a) {
        final name = a.localName.toLowerCase();
        final value = a.value.trim().toLowerCase();
        if (name.startsWith('on') || name == 'src' || name == 'base') {
          return true;
        }
        if (name == 'href') return !RegExp(r'^#[^\s]+$').hasMatch(value);
        return value.contains('@import') ||
            value.contains('javascript:') ||
            value.contains('data:') ||
            value.contains(r'\') ||
            (value.contains('url(') &&
                RegExp(
                  r'url\(\s*[^#\s]',
                  caseSensitive: false,
                ).hasMatch(value));
      });
    }
    _expandDiagramMarkers(root);
    final view = root.getAttribute('viewBox')?.trim().split(RegExp(r'[\s,]+'));
    double? dimension(String? s) =>
        double.tryParse((s ?? '').replaceFirst(RegExp(r'px$'), ''));
    final width = view?.length == 4
        ? dimension(view![2])
        : dimension(root.getAttribute('width'));
    final height = view?.length == 4
        ? dimension(view![3])
        : dimension(root.getAttribute('height'));
    if (width != null &&
        height != null &&
        width > 0 &&
        height > 0 &&
        (width / height).isFinite) {
      ratios[id] = width / height;
    }
    assets[id] = XiaoqiDocumentAsset(
      id: id,
      mimeType: 'image/svg+xml',
      bytes: Uint8List.fromList(utf8.encode(root.toXmlString())),
      altText: alt,
      sourceLocator: path,
    );
    return id;
  }
}

void _prepareLocalMarkup(
  dom.Document document,
  String chapter,
  _EpubMedia media,
) {
  for (final e in document.querySelectorAll(
    '[hidden], script, style, noscript, iframe, object, embed, form',
  )) {
    e.remove();
  }
  for (final e in document.querySelectorAll('[data-xiaoqi-asset]')) {
    e.attributes.remove('data-xiaoqi-asset');
  }
  for (final e in document.querySelectorAll('img, svg')) {
    final alt =
        e.attributes['alt'] ??
        e.attributes['aria-label'] ??
        e.querySelector('title')?.text ??
        '';
    String? id;
    if (e.localName == 'svg') {
      final image =
          e.children.length == 1 && e.children.first.localName == 'image'
          ? e.children.first
          : null;
      if (image != null) {
        final href = image.attributes.entries
            .where((a) => a.key.toString().split(':').last == 'href')
            .firstOrNull
            ?.value;
        id = media.load(chapter, href, alt);
      } else {
        id = media.svg(
          '${media.inlinePrefix}${media.inlineCount++}',
          e.outerHtml,
          alt,
          chapter,
        );
      }
    } else {
      id = media.load(chapter, e.attributes['src'], alt);
    }
    final span = dom.Element.tag('span');
    if (e.id.isNotEmpty) span.id = e.id;
    if (id != null) {
      span.attributes['data-xiaoqi-asset'] = id;
      if (alt.isNotEmpty) span.attributes['aria-label'] = alt;
    } else {
      span.text = alt;
    }
    e.replaceWith(span);
  }
}

String? _readingTarget(String chapter, String? href) {
  if (href == null || href.isEmpty) return null;
  final uri = Uri.tryParse(href);
  if (uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty) {
    return uri.toString();
  }
  return EpubDocumentService._navigationTarget(chapter, href)?.href;
}

/// Normalizes prose while collecting ranges in its final UTF-16 coordinates.
class _InlineText {
  _InlineText(this.verbatim);
  final bool verbatim;
  final buffer = StringBuffer();
  final bold = <List<int>>[];
  final links = <List<Object>>[];
  bool pendingSpace = false;
  void append(String value, {String? link, bool strong = false}) {
    for (final token
        in verbatim
            ? [value]
            : RegExp(r'\s+|[^\s]+').allMatches(value).map((m) => m[0]!)) {
      if (!verbatim && token.trim().isEmpty) {
        pendingSpace = buffer.isNotEmpty;
        continue;
      }
      final lastEnd = buffer.length;
      if (pendingSpace) {
        buffer.write(' ');
        pendingSpace = false;
      }
      final start = buffer.length;
      buffer.write(token);
      final end = buffer.length;
      if (end == start) continue;
      if (strong) {
        if (bold.isNotEmpty && bold.last[1] == lastEnd) {
          bold.last[1] = end;
        } else {
          bold.add([start, end]);
        }
      }
      if (link != null) {
        if (links.isNotEmpty &&
            links.last[1] == lastEnd &&
            links.last[2] == link) {
          links.last[1] = end;
        } else {
          links.add([start, end, link]);
        }
      }
    }
  }

  void newline() {
    pendingSpace = false;
    buffer.write('\n');
  }
}

// Keeps pre-upgrade IDs on the original text elements. Resources newly brought
// back into the body receive a separate ID space so they cannot steal a note.
Map<dom.Element, List<int>> _legacyBlockIds(
  dom.Document document,
  String chapterHref,
  String chapterId,
  Map<String, String> pageLabels,
  Map<String, String>? baseline,
) {
  final ids = <dom.Element, List<int>>{};
  var next = 0, page = 0;
  const ignored = {
    'script',
    'style',
    'noscript',
    'svg',
    'img',
    'iframe',
    'object',
    'embed',
    'form',
    'base',
    'link',
    'meta',
    'video',
    'audio',
    'source',
    'track',
  };
  bool marked(dom.Element e) =>
      EpubDocumentService._isPageBreak(e) ||
      pageLabels.containsKey('$chapterHref#${e.id}');
  void marker() {
    next++;
    page++;
    baseline?['$chapterId:page-break:$page'] = '';
  }

  void visit(dom.Element node) {
    if (ignored.contains(node.localName)) return;
    final hasMarker = marked(node);
    if (hasMarker) marker();
    if (EpubDocumentService._isPageBreak(node)) return;
    if (!const {
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
    }.contains(node.localName)) {
      if (!hasMarker) {
        for (final c in node.children) {
          visit(c);
        }
      }
      return;
    }
    var text = StringBuffer();
    void flush() {
      final value = text.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      text = StringBuffer();
      if (value.isEmpty) return;
      (ids[node] ??= []).add(next);
      baseline?['$chapterId:block:$next'] = value;
      next++;
    }

    void scan(dom.Node child) {
      if (child is dom.Text) {
        text.write(child.data);
        return;
      }
      if (child is! dom.Element || ignored.contains(child.localName)) return;
      if (marked(child)) {
        flush();
        marker();
        return;
      }
      for (final n in child.nodes) {
        scan(n);
      }
    }

    for (final n in node.nodes) {
      scan(n);
    }
    flush();
  }

  for (final n in document.body?.children ?? <dom.Element>[]) {
    visit(n);
  }
  return ids;
}

Future<XiaoqiDocument> upgradeStoredEpub((String, XiaoqiDocument) input) async {
  final (path, stored) = input;
  if (stored.format != 'epub' ||
      stored.structureVersion >= EpubDocumentService.structureVersion) {
    return stored;
  }
  const parser = EpubDocumentService();
  final original = <String, String>{};
  final fresh = parser.parseBytes(
    await parser._readFile(path),
    legacyText: original,
  );
  return _mergeLegacyDocument(stored, fresh, original);
}

/// Upgrade an active revision only when original text / chapter ownership can
/// be verified. The saved version is never mutated; uncertain anchors stay on
/// the exact content the user edited.
XiaoqiDocument _mergeLegacyDocument(
  XiaoqiDocument stored,
  XiaoqiDocument fresh,
  Map<String, String> original,
) {
  if (stored.chapters.length != fresh.chapters.length) return stored;
  final chapters = <XiaoqiDocumentChapter>[];
  final remaining = original.keys.toSet();
  for (var i = 0; i < stored.chapters.length; i++) {
    final old = stored.chapters[i], current = fresh.chapters[i];
    if (old.id != current.id || old.href != current.href) return stored;
    final blocks = {for (final b in current.blocks) b.id: b};
    final edits = <String, XiaoqiDocumentBlock>{};
    for (final b in old.blocks) {
      final src = original[b.id];
      if (src == null || !remaining.remove(b.id)) return stored;
      final next = blocks[b.id];
      if (stored.annotations.isNotEmpty &&
          (next == null || next.text != b.text)) {
        return stored;
      }
      if (b.text == src) continue;
      // A changed passage which was split, merged or removed cannot safely be
      // overlaid on an unrelated shorter block by merely reusing its ordinal.
      if (next == null || next.kind != b.kind || next.text != src) {
        return stored;
      }
      edits[b.id] = b;
    }
    final merged = [for (final b in current.blocks) edits[b.id] ?? b];
    chapters.add(
      XiaoqiDocumentChapter(
        id: old.id,
        title: old.title,
        href: old.href,
        html: current.html,
        order: old.order,
        sourceLocator: old.sourceLocator,
        plainText: merged
            .map((b) => b.text)
            .where((t) => t.isNotEmpty)
            .join('\n\n'),
        fragmentBlocks: current.fragmentBlocks,
        blocks: merged,
      ),
    );
  }
  if (remaining.isNotEmpty) return stored;
  return XiaoqiDocument(
    format: stored.format,
    structureVersion: fresh.structureVersion,
    title: stored.title,
    author: stored.author,
    language: stored.language,
    originalPageCount: fresh.originalPageCount,
    chapters: chapters,
    assets: {
      for (final a in fresh.assets) a.id: a,
      for (final a in stored.assets) a.id: a,
    }.values.toList(),
    annotations: stored.annotations,
    outline: fresh.outline,
  );
}
