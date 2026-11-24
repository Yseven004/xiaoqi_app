part of 'epub_document_service.dart';

/// Flutter's SVG compiler renders use/g but not path markers or CSS rule sets.
/// Expand authored local definitions into equivalent presentation attributes
/// and referenced shapes. Both results still go through the media sanitizer.
void _inlineDiagramStyles(XmlElement root) {
  final rules = <String, Map<String, String>>{};
  const properties = {
    'fill',
    'stroke',
    'stroke-width',
    'stroke-dasharray',
    'opacity',
    'font-family',
    'font-weight',
    'font-style',
    'font-size',
    'text-anchor',
    'marker-start',
    'marker-end',
    'marker-mid',
  };
  Map<String, String> declarations(String css) {
    final result = <String, String>{};
    for (final item in css.split(';')) {
      final sep = item.indexOf(':');
      if (sep < 0) continue;
      final key = item.substring(0, sep).trim();
      if (properties.contains(key)) {
        result[key] = item.substring(sep + 1).trim();
      }
    }
    return result;
  }

  final all = root.descendants.whereType<XmlElement>().toList();
  for (final sheet in all.where((e) => e.localName == 'style')) {
    for (final match in RegExp(
      r'(?:^|})\s*\.([\w-]+)\s*\{([^{}]*)',
    ).allMatches(sheet.innerText)) {
      (rules[match[1]!] ??= {}).addAll(declarations(match[2]!));
    }
  }
  for (final e in all) {
    final classes = (e.getAttribute('class') ?? '')
        .split(RegExp(r'\s+'))
        .toSet();
    if (rules.isNotEmpty && classes.isNotEmpty) {
      for (final r in rules.entries.where((r) => classes.contains(r.key))) {
        r.value.forEach(e.setAttribute);
      }
    }
    declarations(e.getAttribute('style') ?? '').forEach(e.setAttribute);
    // The native renderer takes a single family, while authored SVG commonly
    // lists desktop/web fallbacks separated by commas. Select the matching
    // bundled CJK family to keep labels readable on every target platform.
    final families = e.getAttribute('font-family');
    if (families != null && families.contains(',')) {
      final candidates = families.toLowerCase().split(',').map((s) => s.trim());
      if (candidates.contains('sans-serif')) {
        e.setAttribute('font-family', 'NotoSansCJKSC');
      } else if (candidates.contains('serif')) {
        e.setAttribute('font-family', 'NotoSerifCJKSC');
      }
    }
  }
}

typedef _Point = math.Point<double>;

class _MarkerEndpoints extends PathProxy {
  _Point? origin, subpathOrigin, point, firstDirection, lastDirection;
  @override
  void moveTo(double x, double y) {
    origin ??= _Point(x, y);
    subpathOrigin = point = _Point(x, y);
  }

  @override
  void lineTo(double x, double y) {
    final next = _Point(x, y), here = point;
    if (here != null && next != here) {
      firstDirection ??= next - here;
      lastDirection = next - here;
    }
    point = next;
  }

  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x, double y) {
    final a = _Point(x1, y1),
        b = _Point(x2, y2),
        last = _Point(x, y),
        first = point;
    if (first != null) {
      for (final p in [a, b, last]) {
        if (p != first) {
          firstDirection ??= p - first;
          break;
        }
      }
      for (final p in [b, a, first]) {
        if (p != last) {
          lastDirection = last - p;
          break;
        }
      }
    }
    point = last;
  }

  @override
  void close() {
    if (subpathOrigin case final p?) lineTo(p.x, p.y);
  }
}

void _expandDiagramMarkers(XmlElement root) {
  final all = root.descendants.whereType<XmlElement>().toList();
  final markers = {
    for (final e in all)
      if (e.localName == 'marker' && e.getAttribute('id') != null)
        e.getAttribute('id')!: e,
  };
  if (markers.isEmpty) return;
  double number(XmlElement e, String key, [double fallback = 0]) =>
      double.tryParse(e.getAttribute(key) ?? '') ?? fallback;
  final ref = RegExp(r'^url\(\s*#([^\s)]+)\s*\)$');
  for (final shape in all) {
    final start =
        markers[ref.firstMatch(shape.getAttribute('marker-start') ?? '')?[1]];
    final end =
        markers[ref.firstMatch(shape.getAttribute('marker-end') ?? '')?[1]];
    if (start == null && end == null) continue;
    final path = _MarkerEndpoints();
    switch (shape.localName) {
      case 'line':
        path.moveTo(number(shape, 'x1'), number(shape, 'y1'));
        path.lineTo(number(shape, 'x2'), number(shape, 'y2'));
      case 'polyline':
      case 'polygon':
        final points = (shape.getAttribute('points') ?? '')
            .trim()
            .split(RegExp(r'[\s,]+'))
            .map(double.tryParse)
            .toList();
        for (var i = 1; i < points.length; i += 2) {
          final x = points[i - 1], y = points[i];
          if (x == null || y == null) break;
          if (i == 1) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        if (shape.localName == 'polygon') path.close();
      case 'path':
        try {
          writeSvgPathDataToPath(shape.getAttribute('d'), path);
        } on Object {
          continue;
        }
      default:
        continue;
    }
    void place(
      XmlElement? marker,
      _Point? point,
      _Point? direction,
      bool atStart,
    ) {
      final parent = shape.parentElement;
      if (marker == null ||
          point == null ||
          direction == null ||
          parent == null) {
        return;
      }
      final orient = marker.getAttribute('orient') ?? '0';
      final angle = orient.startsWith('auto')
          ? math.atan2(direction.y, direction.x) * 180 / math.pi +
                (atStart && orient == 'auto-start-reverse' ? 180 : 0)
          : double.tryParse(orient.replaceFirst(RegExp(r'deg$'), '')) ?? 0;
      var scaleX = marker.getAttribute('markerUnits') == 'userSpaceOnUse'
              ? 1.0
              : number(shape, 'stroke-width', 1),
          scaleY = scaleX;
      final view = (marker.getAttribute('viewBox') ?? '')
          .trim()
          .split(RegExp(r'[\s,]+'))
          .map(double.tryParse)
          .toList();
      if (view.length == 4 && (view[2] ?? 0) > 0 && (view[3] ?? 0) > 0) {
        final sx = number(marker, 'markerWidth', 3) / view[2]!,
            sy = number(marker, 'markerHeight', 3) / view[3]!;
        final aspect =
            marker.getAttribute('preserveAspectRatio') ?? 'xMidYMid meet';
        scaleX *= aspect == 'none'
            ? sx
            : aspect.contains('slice')
            ? math.max(sx, sy)
            : math.min(sx, sy);
        scaleY *= aspect == 'none'
            ? sy
            : aspect.contains('slice')
            ? math.max(sx, sy)
            : math.min(sx, sy);
      }
      final transform = [
        ?shape.getAttribute('transform'),
        'translate(${point.x} ${point.y})',
        'rotate($angle)',
        'scale($scaleX $scaleY)',
        'translate(${-number(marker, 'refX')} ${-number(marker, 'refY')})',
      ].join(' ');
      final use = XmlElement(const XmlName.parts('use'))
        ..setAttribute('href', '#${marker.getAttribute('id')}')
        ..setAttribute('transform', transform);
      parent.children.insert(parent.children.indexOf(shape) + 1, use);
    }

    place(end, path.point, path.lastDirection, false);
    place(start, path.origin, path.firstDirection, true);
  }
  for (final marker in markers.values) {
    final parent = marker.parentElement;
    if (parent == null) continue;
    const presentation = {
      'color',
      'fill',
      'fill-opacity',
      'fill-rule',
      'opacity',
      'stroke',
      'stroke-dasharray',
      'stroke-dashoffset',
      'stroke-linecap',
      'stroke-linejoin',
      'stroke-miterlimit',
      'stroke-opacity',
      'stroke-width',
      'visibility',
    };
    final symbol = XmlElement(const XmlName.parts('g'), [
      XmlAttribute(const XmlName.parts('id'), marker.getAttribute('id')!),
      for (final attribute in marker.attributes)
        if (presentation.contains(attribute.localName)) attribute.copy(),
    ], marker.children.map((n) => n.copy()));
    parent.children[parent.children.indexOf(marker)] = symbol;
  }
}
