part of 'companion_pdf_reflow.dart';

typedef _PdfTextTag = ({int id, int heading});
typedef _PdfGlyphStyle = ({double size, bool bold, _PdfTextTag? tag});

final _pdfGlyphWhitespace = RegExp(r'[\s\u00a0\u3000]');
final _pdfBoldFontName = RegExp(
  r'(?:[-+_ ,]|^)(?:(?:Extra|Ultra|Semi|Demi)?Bold|Heavy|Black)(?:Italic|Oblique|[-_ ,]|$)',
  caseSensitive: false,
);

Future<List<_PdfGlyphStyle?>?> _loadPdfGlyphStyles(
  PdfPage page,
  String formattedText,
) async {
  if (formattedText.trim().isEmpty) return null;
  try {
    return await page.document.useNativeDocumentHandle<List<_PdfGlyphStyle?>?>((
      address,
    ) {
      final engine = pdfium.getPdfium(modulePath: Pdfrx.pdfiumModulePath);
      final document = pdfium.FPDF_DOCUMENT.fromAddress(address);
      final nativePage = engine.FPDF_LoadPage(document, page.pageNumber - 1);
      if (nativePage == ffi.nullptr) return null;
      try {
        final text = engine.FPDFText_LoadPage(nativePage);
        if (text == ffi.nullptr) return null;
        try {
          return _readPdfGlyphStyles(
            engine,
            text,
            _readPdfTextTags(engine, nativePage),
            formattedText,
            page.height,
          );
        } finally {
          engine.FPDFText_ClosePage(text);
        }
      } finally {
        engine.FPDF_ClosePage(nativePage);
      }
    });
  } on Object {
    // Optional metadata on unsupported backends or damaged PDFs. Geometry and
    // original-page fallback remain available.
    return null;
  }
}

List<_PdfGlyphStyle?>? _readPdfGlyphStyles(
  pdfium.PDFium engine,
  pdfium.FPDF_TEXTPAGE text,
  Map<int, _PdfTextTag> tags,
  String formattedText,
  double pageHeight,
) {
  final count = engine.FPDFText_CountChars(text);
  if (count > 20000 || pageHeight <= 0) return null;
  final glyphs = List<_PdfGlyphStyle?>.filled(formattedText.length, null);
  final stylesByObject = <int, _PdfGlyphStyle>{};
  return using((arena) {
    const capacity = 512;
    final fontName = arena<ffi.Uint8>(capacity);
    final fontFlags = arena<ffi.Int>();
    var offset = 0;
    for (var i = 0; i < count; i++) {
      final code = engine.FPDFText_GetUnicode(text, i);
      if (code < 1 || code > 0x10ffff) return null;
      final glyph = String.fromCharCode(code);
      if (_pdfGlyphWhitespace.hasMatch(glyph)) continue;
      while (offset < formattedText.length &&
          _pdfGlyphWhitespace.hasMatch(formattedText[offset])) {
        offset++;
      }
      // pdfrx normalizes whitespace. If another backend or malformed text
      // layer changes actual glyphs, do not attach ambiguous styles.
      if (!formattedText.startsWith(glyph, offset)) return null;
      final object = engine.FPDFText_GetTextObject(text, i);
      final style = object == ffi.nullptr
          ? null
          : stylesByObject.putIfAbsent(object.address, () {
              final size = engine.FPDFText_GetFontSize(text, i);
              final weight = engine.FPDFText_GetFontWeight(text, i);
              // Some embedded CJK fonts report nonsensical weights (e.g. 2092 for regular SimSun).
              var bold = weight >= 600 && weight <= 1000;
              if (!bold) {
                final length = engine.FPDFText_GetFontInfo(
                  text,
                  i,
                  fontName.cast(),
                  capacity,
                  fontFlags,
                );
                if (length > 1 && length <= capacity) {
                  final name = utf8.decode(
                    fontName.asTypedList(length - 1),
                    allowMalformed: true,
                  );
                  bold =
                      (fontFlags.value & (1 << 18)) != 0 ||
                      _pdfBoldFontName.hasMatch(name);
                }
              }
              return (
                size: size.isFinite && size > 0 ? size / pageHeight : 0.0,
                bold: bold,
                tag: tags.isEmpty
                    ? null
                    : tags[engine.FPDFPageObj_GetMarkedContentID(object)],
              );
            });
      for (var unit = 0; unit < glyph.length; unit++) {
        glyphs[offset++] = style;
      }
    }
    return formattedText.substring(offset).trim().isEmpty ? glyphs : null;
  });
}

Map<int, _PdfTextTag> _readPdfTextTags(
  pdfium.PDFium engine,
  pdfium.FPDF_PAGE page,
) {
  final tags = <int, _PdfTextTag>{};
  final tree = engine.FPDF_StructTree_GetForPage(page);
  if (tree == ffi.nullptr) return tags;
  try {
    return using((arena) {
      // P, H, and H1–H6 fit in three UTF-16 code units, including NUL.
      final type = arena<ffi.Uint16>(3);
      final visited = <int>{};
      final conflicting = <int>{};
      var paragraph = 0;

      void associate(int content, _PdfTextTag tag) {
        if (content < 0 || conflicting.contains(content)) return;
        final existing = tags[content];
        if (existing != null && existing != tag) {
          tags.remove(content);
          conflicting.add(content);
        } else {
          tags[content] = tag;
        }
      }

      void read(
        pdfium.FPDF_STRUCTELEMENT entry,
        _PdfTextTag? parent,
        int depth,
      ) {
        if (entry == ffi.nullptr ||
            depth > 32 ||
            visited.length >= 16384 ||
            !visited.add(entry.address)) {
          return;
        }
        final bytes = engine.FPDF_StructElement_GetType(entry, type.cast(), 6);
        final tag = switch ((bytes, type[0], type[1])) {
          (4, 0x50, _) => (id: ++paragraph, heading: 0), // P
          (4, 0x48, _) => (id: ++paragraph, heading: 1), // H
          (6, 0x48, >= 0x31 && <= 0x36) => (
            id: ++paragraph,
            heading: type[1] - 0x30,
          ),
          _ => parent,
        };
        if (tag != null) {
          associate(engine.FPDF_StructElement_GetMarkedContentID(entry), tag);
        }
        final children = engine.FPDF_StructElement_CountChildren(entry);
        for (var i = 0; i < children && i < 16384; i++) {
          final child = engine.FPDF_StructElement_GetChildAtIndex(entry, i);
          if (child != ffi.nullptr) {
            read(child, tag, depth + 1);
          } else if (tag != null) {
            associate(
              engine.FPDF_StructElement_GetChildMarkedContentID(entry, i),
              tag,
            );
          }
        }
      }

      final children = engine.FPDF_StructTree_CountChildren(tree);
      for (var i = 0; i < children && i < 16384; i++) {
        read(engine.FPDF_StructTree_GetChildAtIndex(tree, i), null, 0);
      }
      return tags;
    });
  } on Object {
    // Keep font metadata when a backend cannot inspect the structure tree.
    return const {};
  } finally {
    engine.FPDF_StructTree_Close(tree);
  }
}
