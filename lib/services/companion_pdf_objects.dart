part of 'companion_pdf_reflow.dart';

const _pdfWholePage = Rect.fromLTWH(0, 0, 1, 1);
final _tableCaption = RegExp(
  r'^(?:表\s*[0-9０-９一二三四五六七八九十]+|table\s*\d)',
  caseSensitive: false,
);
final _tableNote = RegExp(
  r'^(?:(?:注|说明|資料來源|资料来源|来源)\s*[:：]|(?:notes?|source)\s*:)',
  caseSensitive: false,
);
final _numberCell = RegExp(r'^\s*[-+−]?[\d０-９][\d０-９,.，．:%％\s−+-]*$');

class _PdfPictureRegion {
  const _PdfPictureRegion(this.bounds, {this.columns = 0});

  final Rect bounds;
  final int columns;
}

Future<List<Rect>> _embeddedPdfImages(PdfPage page) async {
  try {
    return await page.document.useNativeDocumentHandle((address) {
      final engine = pdfium.getPdfium(modulePath: Pdfrx.pdfiumModulePath);
      final document = pdfium.FPDF_DOCUMENT.fromAddress(address);
      final nativePage = engine.FPDF_LoadPage(document, page.pageNumber - 1);
      if (nativePage == ffi.nullptr) return const <Rect>[];
      try {
        return using((arena) {
          final left = arena<ffi.Float>();
          final bottom = arena<ffi.Float>();
          final right = arena<ffi.Float>();
          final top = arena<ffi.Float>();
          final deviceX = arena<ffi.Int>();
          final deviceY = arena<ffi.Int>();
          const units = 8192;

          Offset? devicePoint(double x, double y) {
            if (engine.FPDF_PageToDevice(
                  nativePage,
                  0,
                  0,
                  units,
                  units,
                  0,
                  x,
                  y,
                  deviceX,
                  deviceY,
                ) ==
                0) {
              return null;
            }
            return Offset(deviceX.value / units, deviceY.value / units);
          }

          final bounds = <Rect>[];
          final count = engine.FPDFPage_CountObjects(nativePage);
          for (var index = 0; index < count; index++) {
            final object = engine.FPDFPage_GetObject(nativePage, index);
            if (object == ffi.nullptr) continue;
            final type = engine.FPDFPageObj_GetType(object);
            if (type != pdfium.FPDF_PAGEOBJ_IMAGE &&
                (type != pdfium.FPDF_PAGEOBJ_FORM ||
                    _graphicFormHasImage(engine, object, 0) != true)) {
              continue;
            }
            // PDFium reports the containing form in page coordinates. Keep
            // its image parts together, including any space between them.
            if (engine.FPDFPageObj_GetBounds(
                  object,
                  left,
                  bottom,
                  right,
                  top,
                ) ==
                0) {
              continue;
            }
            final start = devicePoint(left.value, top.value);
            final end = devicePoint(right.value, bottom.value);
            if (start == null || end == null) continue;
            final box = Rect.fromPoints(start, end).intersect(_pdfWholePage);
            // A scan or a full-bleed background is not an independent figure.
            if (box.width < .04 ||
                box.height < .018 ||
                (box.width > .78 && box.height > .78)) {
              continue;
            }
            bounds.add(box.inflate(.002).intersect(_pdfWholePage));
          }
          return bounds;
        });
      } finally {
        engine.FPDF_ClosePage(nativePage);
      }
    });
  } on Object {
    // The original raster also covers paths, nested objects and other engines.
    return const [];
  }
}

// Null means this form may contain page content outside a standalone figure.
bool? _graphicFormHasImage(
  pdfium.PDFium engine,
  pdfium.FPDF_PAGEOBJECT form,
  int depth,
) {
  if (depth >= 8) return null;
  final count = engine.FPDFFormObj_CountObjects(form);
  if (count < 0) return null;
  var hasImage = false;
  for (var index = 0; index < count; index++) {
    final child = engine.FPDFFormObj_GetObject(form, index);
    if (child == ffi.nullptr) return null;
    switch (engine.FPDFPageObj_GetType(child)) {
      case pdfium.FPDF_PAGEOBJ_IMAGE:
        hasImage = true;
      case pdfium.FPDF_PAGEOBJ_FORM:
        final nested = _graphicFormHasImage(engine, child, depth + 1);
        if (nested == null) return null;
        hasImage = hasImage || nested;
      case pdfium.FPDF_PAGEOBJ_PATH:
      case pdfium.FPDF_PAGEOBJ_SHADING:
        break;
      default:
        return null;
    }
  }
  return hasImage;
}

Future<({List<Rect> bands, List<_PdfPictureRegion> objects})> _scanPageObjects(
  TransferableTypedData payload,
  int width,
  int height,
  List<CompanionReflowLine> lines,
  List<Rect> embedded,
) => Isolate.run(() {
  final pixels = payload.materialize().asUint8List();
  final tables = _ruledPdfTables(pixels, width, height);
  for (final candidate in _alignedPdfTables(lines)) {
    if (!tables.any((table) => table.bounds.overlaps(candidate.bounds))) {
      tables.add(candidate);
    }
  }
  final tableRegions = [
    for (final table in tables)
      if (!embedded.any((picture) {
        final overlap = picture.inflate(.004).intersect(table.bounds);
        // The raster detector can mistake lines inside an illustration for
        // a table. Its smaller crop cannot stand in for the native object.
        return !overlap.isEmpty &&
            overlap.width * overlap.height >=
                .9 * table.bounds.width * table.bounds.height;
      }))
        _withTableLabels(table, lines),
  ];
  final objects = <_PdfPictureRegion>[
    ...tableRegions,
    for (final picture in embedded)
      if (!tableRegions.any(
        (table) => table.bounds.intersect(picture) == picture,
      ))
        _PdfPictureRegion(picture),
  ];
  return (
    bands: CompanionPdfReflow._scanBands(pixels, width, height, [
      for (final line in lines) line.bounds.inflate(.004),
      for (final object in objects) object.bounds.inflate(.004),
    ]),
    objects: objects,
  );
});

bool _isBesideCaption(Rect bounds, CompanionReflowLine caption) {
  final text = caption.bounds;
  return bounds.contains(text.center) ||
      (bounds.left < text.right &&
          bounds.right > text.left &&
          ((text.top - bounds.bottom).abs() < .06 ||
              (bounds.top - text.bottom).abs() < .04));
}

bool _needsOriginalLayout(Rect picture, CompanionReflowLine line) {
  final text = line.bounds;
  if (picture.contains(text.center)) return false;
  final alongside =
      text.center.dy >= picture.top && text.center.dy <= picture.bottom;
  return alongside &&
      (text.right <= picture.left + .009 || text.left >= picture.right - .009);
}

_PdfPictureRegion _withTableLabels(
  _PdfPictureRegion table,
  List<CompanionReflowLine> lines,
) {
  var bounds = table.bounds;
  final above = lines.where((line) => line.bounds.bottom <= bounds.top);
  final caption = above.lastOrNull;
  if (caption != null &&
      _tableCaption.hasMatch(caption.text) &&
      _isBesideCaption(bounds, caption)) {
    bounds = bounds.expandToInclude(caption.bounds);
  }
  for (final line in lines) {
    if (line.bounds.center.dy < table.bounds.bottom) continue;
    if (!_tableNote.hasMatch(line.text) ||
        line.bounds.top - bounds.bottom > .035 ||
        line.bounds.left > bounds.right ||
        line.bounds.right < bounds.left) {
      break;
    }
    bounds = bounds.expandToInclude(line.bounds);
  }
  return _PdfPictureRegion(
    bounds.inflate(.004).intersect(_pdfWholePage),
    columns: table.columns,
  );
}

typedef _RasterRule = ({int left, int right, int y});

List<_PdfPictureRegion> _ruledPdfTables(
  Uint8List pixels,
  int width,
  int height,
) {
  bool dark(int x, int y) {
    final offset = (y * width + x) * 4;
    return pixels[offset] + pixels[offset + 1] + pixels[offset + 2] < 600;
  }

  final rules = <_RasterRule>[];
  final minLength = (width * .14).ceil();
  for (var y = 0; y < height; y++) {
    var x = 0;
    while (x < width) {
      if (!dark(x, y)) {
        x++;
        continue;
      }
      final left = x;
      while (x < width && dark(x, y)) {
        x++;
      }
      if (x - left >= minLength) {
        rules.add((left: left, right: x - 1, y: y));
      }
    }
  }

  int columnRules(int left, int right, int top, int bottom) {
    var count = 0;
    var previousColumn = left - 5;
    for (var x = left; x <= right; x++) {
      var filled = 0;
      for (var y = top + 2; y <= bottom - 2; y++) {
        if (dark(x, y)) filled++;
      }
      if (filled >= (bottom - top - 3) * .73) {
        if (x - previousColumn >= 3) count++;
        previousColumn = x;
      }
    }
    return count;
  }

  final cells = <({Rect bounds, int columns})>[];
  for (var index = 1; index < rules.length; index++) {
    final lower = rules[index];
    for (var i = index - 1; i >= 0; i--) {
      final upper = rules[i];
      final gap = lower.y - upper.y;
      if (gap < 5) continue;
      if (gap > height * .13) break;
      final left = math.max(upper.left, lower.left);
      final right = math.min(upper.right, lower.right);
      final overlap = right - left + 1;
      if (overlap < minLength ||
          overlap <
              math.max(upper.right - upper.left, lower.right - lower.left) *
                  .79) {
        continue;
      }
      final columns = columnRules(left, right, upper.y, lower.y) - 1;
      if (columns < 1) break;
      cells.add((
        bounds: Rect.fromLTRB(
          math.min(upper.left, lower.left) / width,
          upper.y / height,
          (math.max(upper.right, lower.right) + 1) / width,
          (lower.y + 1) / height,
        ),
        columns: columns,
      ));
      break;
    }
  }

  final groups = <({Rect bounds, int columns, int rows})>[];
  for (final cell in cells) {
    final index = groups.lastIndexWhere((group) {
      final overlap = group.bounds.intersect(cell.bounds.inflate(.006));
      return !overlap.isEmpty &&
          overlap.width >=
              math.max(group.bounds.width, cell.bounds.width) * .79;
    });
    if (index < 0) {
      groups.add((bounds: cell.bounds, columns: cell.columns, rows: 1));
    } else {
      final previous = groups[index];
      groups[index] = (
        bounds: previous.bounds.expandToInclude(cell.bounds),
        columns: math.max(previous.columns, cell.columns),
        rows: previous.rows + 1,
      );
    }
  }
  return [
    for (final group in groups)
      if (group.columns >= 2 && (group.rows >= 2 || group.columns >= 3))
        _PdfPictureRegion(group.bounds, columns: group.columns),
  ];
}

List<_PdfPictureRegion> _alignedPdfTables(List<CompanionReflowLine> lines) {
  final rows = <List<CompanionReflowLine>>[];
  for (final line in lines) {
    if (rows.isNotEmpty) {
      final first = rows.last.first.bounds;
      if ((line.bounds.center.dy - first.center.dy).abs() <=
          first.height * .55) {
        rows.last.add(line);
        continue;
      }
    }
    rows.add([line]);
  }

  bool aligned(Rect a, Rect b) =>
      (a.left - b.left).abs() < .02 ||
      (a.center.dx - b.center.dx).abs() < .017 ||
      (a.right - b.right).abs() < .02;

  bool hasCells(List<CompanionReflowLine> row) =>
      row.length >= 2 && row.every((cell) => cell.bounds.width < .46);

  final tables = <_PdfPictureRegion>[];
  for (var start = 0; start < rows.length; start++) {
    final first = rows[start];
    if (!hasCells(first)) continue;
    var last = start;
    while (last + 1 < rows.length) {
      final next = rows[last + 1];
      final previous = rows[last].first.bounds;
      if (!hasCells(next) ||
          next.first.bounds.top - previous.bottom > previous.height * 2 ||
          next
                  .where(
                    (cell) => first.any((f) => aligned(f.bounds, cell.bounds)),
                  )
                  .length <
              2) {
        break;
      }
      last++;
    }
    if (last == start) continue;
    final cells = rows.sublist(start, last + 1).expand((row) => row).toList();
    final bounds = cells
        .map((cell) => cell.bounds)
        .reduce((a, b) => a.expandToInclude(b));
    final hasCaption = lines.any(
      (line) =>
          _tableCaption.hasMatch(line.text) && _isBesideCaption(bounds, line),
    );
    final hasNumbers =
        cells.where((cell) => _numberCell.hasMatch(cell.text)).length >= 2;
    final compactLabels =
        rows.sublist(start, last + 1).every((row) => row.length >= 3) &&
        cells.every(
          (cell) =>
              cell.text.length <= 24 &&
              !CompanionReflowPage._sentenceEnd.hasMatch(cell.text),
        );
    if (hasCaption || (last - start >= 2 && (hasNumbers || compactLabels))) {
      tables.add(
        _PdfPictureRegion(
          bounds,
          columns: rows
              .sublist(start, last + 1)
              .fold<int>(0, (count, row) => math.max(count, row.length)),
        ),
      );
    }
    start = last;
  }
  return tables;
}
