import 'dart:ui' show Offset;

/// Author identity is deliberately separate from the visual tool. A red
/// stroke is not automatically an AI stroke, and changing its color must not
/// erase its provenance.
enum AnnotationAuthor { user, ai, collaborative }

/// Coordinate system used by the annotation canvas.
///
/// Older editor versions normalized points against the inset content column;
/// the current editor normalizes against the full content viewport so the
/// page margins remain drawable.
enum PageAnnotationCoordinateSpace { content, viewport }

/// The visual tool that produced a stored path. [StrokeTool.eraser] is kept
/// only for reading legacy annotation JSON; new free erases are materialized
/// as deleted/split normal strokes instead of persisting an eraser overlay.
enum StrokeTool { ballpoint, pencil, highlighter, eraser }

abstract final class PageTextFontFamily {
  static const song = 'NotoSerifCJKSC';
  static const kai = 'LXGWWenKai';
  static const black = 'NotoSansCJKSC';
  static const handwriting = 'MaShanZheng';
  static const rounded = 'ZCOOLQingKeHuangYou';
  static const fangSong = 'ZCOOLXiaoWei';
}

String _normalizePageTextFont(Object? raw) {
  final family = raw?.toString() ?? '';
  return switch (family) {
    '' || 'serif' || PageTextFontFamily.song => PageTextFontFamily.song,
    'KaiTi' || PageTextFontFamily.kai => PageTextFontFamily.kai,
    'sans-serif' || PageTextFontFamily.black => PageTextFontFamily.black,
    PageTextFontFamily.handwriting => PageTextFontFamily.handwriting,
    'sans-serif-rounded' ||
    PageTextFontFamily.rounded => PageTextFontFamily.rounded,
    'FangSong' || PageTextFontFamily.fangSong => PageTextFontFamily.fangSong,
    'LongCang' => 'LongCang',
    _ => PageTextFontFamily.song,
  };
}

class PageTextAnchor {
  const PageTextAnchor({
    required this.sourceBlockId,
    required this.start,
    required this.end,
    required this.quote,
  });

  final int sourceBlockId;
  final int start;
  final int end;
  final String quote;

  factory PageTextAnchor.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Invalid page text anchor');
    }
    return PageTextAnchor(
      sourceBlockId: (raw['source_block_id'] as num?)?.toInt() ?? 0,
      start: (raw['start'] as num?)?.toInt() ?? 0,
      end: (raw['end'] as num?)?.toInt() ?? 0,
      quote: raw['quote']?.toString() ?? '',
    );
  }

  Map<String, Object?> toJson() => {
    'source_block_id': sourceBlockId,
    'start': start,
    'end': end,
    'quote': quote,
  };

  @override
  bool operator ==(Object other) =>
      other is PageTextAnchor &&
      sourceBlockId == other.sourceBlockId &&
      start == other.start &&
      end == other.end &&
      quote == other.quote;

  @override
  int get hashCode => Object.hash(sourceBlockId, start, end, quote);
}

class PageStroke {
  PageStroke({
    required this.id,
    required this.tool,
    required this.colorValue,
    required this.width,
    required this.opacity,
    required List<Offset> points,
    this.author = AnnotationAuthor.user,
    this.createdAt,
  }) : points = List.unmodifiable(points);

  final String id;
  final StrokeTool tool;
  final int colorValue;
  final double width;
  final double opacity;
  final List<Offset> points;
  final AnnotationAuthor author;
  final String? createdAt;

  factory PageStroke.fromJson(Map raw) {
    final rawPoints = raw['points'];
    final points = rawPoints is List
        ? [
            for (final point in rawPoints)
              if (point is List && point.length >= 2)
                Offset(_unit(point[0]), _unit(point[1]))
              else if (point is Map)
                Offset(_unit(point['x']), _unit(point['y'])),
          ]
        : const <Offset>[];
    return PageStroke(
      id: raw['id']?.toString() ?? '',
      tool: StrokeTool.values.firstWhere(
        (value) => value.name == raw['tool'],
        orElse: () => StrokeTool.ballpoint,
      ),
      colorValue: (raw['color'] as num?)?.toInt() ?? 0xFF1A1A1A,
      // For an eraser stroke, width stores the radius. Keeping the same field
      // allows old normal strokes and new erase paths to share one format.
      width: ((raw['width'] as num?)?.toDouble() ?? 2).clamp(.5, 64),
      opacity: ((raw['opacity'] as num?)?.toDouble() ?? 1).clamp(0, 1),
      points: points,
      author: AnnotationAuthor.values.firstWhere(
        (value) => value.name == raw['author'],
        orElse: () => AnnotationAuthor.user,
      ),
      createdAt: raw['created_at']?.toString(),
    );
  }

  Map<String, Object?> toJson() => {
    'kind': 'stroke',
    'id': id,
    'tool': tool.name,
    'color': colorValue,
    'width': width,
    'opacity': opacity,
    'points': [
      for (final point in points) [point.dx, point.dy],
    ],
    'author': author.name,
    if (createdAt != null) 'created_at': createdAt,
  };

  PageStroke copyWith({
    String? id,
    StrokeTool? tool,
    int? colorValue,
    double? width,
    double? opacity,
    List<Offset>? points,
    AnnotationAuthor? author,
    String? createdAt,
  }) => PageStroke(
    id: id ?? this.id,
    tool: tool ?? this.tool,
    colorValue: colorValue ?? this.colorValue,
    width: width ?? this.width,
    opacity: opacity ?? this.opacity,
    points: points ?? this.points,
    author: author ?? this.author,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is PageStroke &&
      id == other.id &&
      tool == other.tool &&
      colorValue == other.colorValue &&
      width == other.width &&
      opacity == other.opacity &&
      author == other.author &&
      createdAt == other.createdAt &&
      _pointsEqual(points, other.points);

  @override
  int get hashCode => Object.hash(
    id,
    tool,
    colorValue,
    width,
    opacity,
    author,
    createdAt,
    Object.hashAll(points.map((point) => Object.hash(point.dx, point.dy))),
  );
}

class PageTextObject {
  PageTextObject({
    required this.id,
    required this.text,
    required this.center,
    required this.width,
    required this.height,
    this.rotation = 0,
    this.scale = 1,
    this.colorValue = 0xFF1A1A1A,
    this.fontFamily = PageTextFontFamily.song,
    this.fontSize = 18,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.outline = false,
    this.shadow = false,
    this.alignment = 'left',
    this.letterSpacing = 0,
    this.lineSpacing = 1.2,
    this.anchor,
    this.author = AnnotationAuthor.user,
  });

  final String id;
  final String text;
  final Offset center;
  final double width;
  final double height;
  final double rotation;
  final double scale;
  final int colorValue;
  final String fontFamily;
  final double fontSize;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool outline;
  final bool shadow;
  final String alignment;
  final double letterSpacing;
  final double lineSpacing;
  final PageTextAnchor? anchor;
  final AnnotationAuthor author;

  factory PageTextObject.fromJson(Map raw) => PageTextObject(
    id: raw['id']?.toString() ?? '',
    text: raw['text']?.toString() ?? '',
    center: Offset(_unit(raw['center_x']), _unit(raw['center_y'])),
    width: _unit(raw['width']),
    height: _unit(raw['height']),
    rotation: (raw['rotation'] as num?)?.toDouble() ?? 0,
    scale: ((raw['scale'] as num?)?.toDouble() ?? 1).clamp(.05, 20),
    colorValue: (raw['color'] as num?)?.toInt() ?? 0xFF1A1A1A,
    fontFamily: _normalizePageTextFont(raw['font_family']),
    fontSize: ((raw['font_size'] as num?)?.toDouble() ?? 18).clamp(6, 120),
    bold: raw['bold'] == true,
    italic: raw['italic'] == true,
    underline: raw['underline'] == true,
    outline: raw['outline'] == true,
    shadow: raw['shadow'] == true,
    alignment: raw['alignment']?.toString() ?? 'left',
    letterSpacing: (raw['letter_spacing'] as num?)?.toDouble() ?? 0,
    lineSpacing: ((raw['line_spacing'] as num?)?.toDouble() ?? 1.2).clamp(
      .8,
      3,
    ),
    anchor: raw['anchor'] == null
        ? null
        : PageTextAnchor.fromJson(raw['anchor']),
    author: AnnotationAuthor.values.firstWhere(
      (value) => value.name == raw['author'],
      orElse: () => AnnotationAuthor.user,
    ),
  );

  Map<String, Object?> toJson() => {
    'kind': 'text',
    'id': id,
    'text': text,
    'center_x': center.dx,
    'center_y': center.dy,
    'width': width,
    'height': height,
    'rotation': rotation,
    'scale': scale,
    'color': colorValue,
    'font_family': fontFamily,
    'font_size': fontSize,
    'bold': bold,
    'italic': italic,
    'underline': underline,
    'outline': outline,
    'shadow': shadow,
    'alignment': alignment,
    'letter_spacing': letterSpacing,
    'line_spacing': lineSpacing,
    if (anchor != null) 'anchor': anchor!.toJson(),
    'author': author.name,
  };

  PageTextObject copyWith({
    String? id,
    String? text,
    Offset? center,
    double? width,
    double? height,
    double? rotation,
    double? scale,
    int? colorValue,
    String? fontFamily,
    double? fontSize,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? outline,
    bool? shadow,
    String? alignment,
    double? letterSpacing,
    double? lineSpacing,
    PageTextAnchor? anchor,
    AnnotationAuthor? author,
  }) => PageTextObject(
    id: id ?? this.id,
    text: text ?? this.text,
    center: center ?? this.center,
    width: width ?? this.width,
    height: height ?? this.height,
    rotation: rotation ?? this.rotation,
    scale: scale ?? this.scale,
    colorValue: colorValue ?? this.colorValue,
    fontFamily: fontFamily ?? this.fontFamily,
    fontSize: fontSize ?? this.fontSize,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    outline: outline ?? this.outline,
    shadow: shadow ?? this.shadow,
    alignment: alignment ?? this.alignment,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    lineSpacing: lineSpacing ?? this.lineSpacing,
    anchor: anchor ?? this.anchor,
    author: author ?? this.author,
  );

  @override
  bool operator ==(Object other) =>
      other is PageTextObject &&
      id == other.id &&
      text == other.text &&
      center == other.center &&
      width == other.width &&
      height == other.height &&
      rotation == other.rotation &&
      scale == other.scale &&
      colorValue == other.colorValue &&
      fontFamily == other.fontFamily &&
      fontSize == other.fontSize &&
      bold == other.bold &&
      italic == other.italic &&
      underline == other.underline &&
      outline == other.outline &&
      shadow == other.shadow &&
      alignment == other.alignment &&
      letterSpacing == other.letterSpacing &&
      lineSpacing == other.lineSpacing &&
      anchor == other.anchor &&
      author == other.author;

  @override
  int get hashCode => Object.hash(
    id,
    text,
    center,
    width,
    height,
    rotation,
    scale,
    colorValue,
    fontFamily,
    fontSize,
    bold,
    italic,
    underline,
    outline,
    shadow,
    alignment,
    letterSpacing,
    lineSpacing,
    anchor,
    author,
  );
}

/// An image layer anchored to the page annotation canvas.
///
/// Coordinates are normalized to the canvas (0..1) so a page can be rendered
/// at any device size without losing the user's chosen placement. The source
/// image is kept outside the database; [assetPath] is a relative path managed
/// by the page image asset store.
class PageImageObject {
  PageImageObject({
    required this.id,
    required this.assetPath,
    required this.originalName,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.center,
    required this.width,
    required this.createdAt,
    this.author = AnnotationAuthor.user,
    this.sourceDocumentHash,
    this.pageKey,
    this.modelVersion,
    this.promptVersion,
    this.purposeKey,
    this.layoutFingerprint,
    this.reviewStatus,
    this.reviewReason,
    this.userInstruction,
  }) : assert(pixelWidth > 0),
       assert(pixelHeight > 0),
       assert(width > 0),
       assert(center.dx >= 0 && center.dx <= 1),
       assert(center.dy >= 0 && center.dy <= 1);

  final String id;
  final String assetPath;
  final String originalName;
  final int pixelWidth;
  final int pixelHeight;
  final Offset center;
  final double width;
  final String createdAt;
  final AnnotationAuthor author;
  final String? sourceDocumentHash;
  final String? pageKey;
  final String? modelVersion;
  final String? promptVersion;
  final String? purposeKey;
  final String? layoutFingerprint;
  final String? reviewStatus;
  final String? reviewReason;
  final String? userInstruction;

  double get aspectRatio => pixelWidth / pixelHeight;

  factory PageImageObject.fromJson(Map raw) {
    final width = ((raw['width'] as num?)?.toDouble() ?? .5)
        .clamp(.01, 1.0)
        .toDouble();
    final pixelWidth = (raw['pixel_width'] as num?)?.toInt() ?? 1;
    final pixelHeight = (raw['pixel_height'] as num?)?.toInt() ?? 1;
    return PageImageObject(
      id: raw['id']?.toString() ?? '',
      assetPath: raw['asset_path']?.toString() ?? '',
      originalName: raw['original_name']?.toString() ?? '',
      pixelWidth: pixelWidth.clamp(1, 100000000).toInt(),
      pixelHeight: pixelHeight.clamp(1, 100000000).toInt(),
      center: Offset(_unit(raw['center_x']), _unit(raw['center_y'])),
      width: width,
      createdAt: raw['created_at']?.toString() ?? '',
      author: AnnotationAuthor.values.firstWhere(
        (value) => value.name == raw['author'],
        orElse: () => AnnotationAuthor.user,
      ),
      sourceDocumentHash: raw['source_document_hash']?.toString(),
      pageKey: raw['page_key']?.toString(),
      modelVersion: raw['model_version']?.toString(),
      promptVersion: raw['prompt_version']?.toString(),
      purposeKey: raw['purpose_key']?.toString(),
      layoutFingerprint: raw['layout_fingerprint']?.toString(),
      reviewStatus: raw['review_status']?.toString(),
      reviewReason: raw['review_reason']?.toString(),
      userInstruction: raw['user_instruction']?.toString(),
    );
  }

  Map<String, Object?> toJson() => {
    'kind': 'image',
    'id': id,
    'asset_path': assetPath,
    'original_name': originalName,
    'pixel_width': pixelWidth,
    'pixel_height': pixelHeight,
    'center_x': center.dx,
    'center_y': center.dy,
    'width': width,
    'created_at': createdAt,
    'author': author.name,
    if (sourceDocumentHash != null)
      'source_document_hash': sourceDocumentHash,
    if (pageKey != null) 'page_key': pageKey,
    if (modelVersion != null) 'model_version': modelVersion,
    if (promptVersion != null) 'prompt_version': promptVersion,
    if (purposeKey != null) 'purpose_key': purposeKey,
    if (layoutFingerprint != null) 'layout_fingerprint': layoutFingerprint,
    if (reviewStatus != null) 'review_status': reviewStatus,
    if (reviewReason != null) 'review_reason': reviewReason,
    if (userInstruction != null) 'user_instruction': userInstruction,
  };

  PageImageObject copyWith({
    String? id,
    String? assetPath,
    String? originalName,
    int? pixelWidth,
    int? pixelHeight,
    Offset? center,
    double? width,
    String? createdAt,
    AnnotationAuthor? author,
    String? sourceDocumentHash,
    String? pageKey,
    String? modelVersion,
    String? promptVersion,
    String? purposeKey,
    String? layoutFingerprint,
    String? reviewStatus,
    String? reviewReason,
    String? userInstruction,
  }) => PageImageObject(
    id: id ?? this.id,
    assetPath: assetPath ?? this.assetPath,
    originalName: originalName ?? this.originalName,
    pixelWidth: pixelWidth ?? this.pixelWidth,
    pixelHeight: pixelHeight ?? this.pixelHeight,
    center: center ?? this.center,
    width: width ?? this.width,
    createdAt: createdAt ?? this.createdAt,
    author: author ?? this.author,
    sourceDocumentHash: sourceDocumentHash ?? this.sourceDocumentHash,
    pageKey: pageKey ?? this.pageKey,
    modelVersion: modelVersion ?? this.modelVersion,
    promptVersion: promptVersion ?? this.promptVersion,
    purposeKey: purposeKey ?? this.purposeKey,
    layoutFingerprint: layoutFingerprint ?? this.layoutFingerprint,
    reviewStatus: reviewStatus ?? this.reviewStatus,
    reviewReason: reviewReason ?? this.reviewReason,
    userInstruction: userInstruction ?? this.userInstruction,
  );

  @override
  bool operator ==(Object other) =>
      other is PageImageObject &&
      id == other.id &&
      assetPath == other.assetPath &&
      originalName == other.originalName &&
      pixelWidth == other.pixelWidth &&
      pixelHeight == other.pixelHeight &&
      center == other.center &&
      width == other.width &&
      createdAt == other.createdAt &&
      author == other.author &&
      sourceDocumentHash == other.sourceDocumentHash &&
      pageKey == other.pageKey &&
      modelVersion == other.modelVersion &&
      promptVersion == other.promptVersion &&
      purposeKey == other.purposeKey &&
      layoutFingerprint == other.layoutFingerprint &&
      reviewStatus == other.reviewStatus &&
      reviewReason == other.reviewReason &&
      userInstruction == other.userInstruction;

  @override
  int get hashCode => Object.hash(
    id,
    assetPath,
    originalName,
    pixelWidth,
    pixelHeight,
    center,
    width,
    createdAt,
    author,
    sourceDocumentHash,
    pageKey,
    modelVersion,
    promptVersion,
    purposeKey,
    layoutFingerprint,
    reviewStatus,
    reviewReason,
    userInstruction,
  );
}

class PageAnnotationDocument {
  PageAnnotationDocument({
    List<PageStroke> strokes = const [],
    List<PageTextObject> texts = const [],
    List<PageImageObject> images = const [],
    this.coordinateSpace = PageAnnotationCoordinateSpace.viewport,
  }) : strokes = List.unmodifiable(strokes),
       texts = List.unmodifiable(texts),
       images = List.unmodifiable(images);

  final List<PageStroke> strokes;
  final List<PageTextObject> texts;
  final List<PageImageObject> images;
  final PageAnnotationCoordinateSpace coordinateSpace;

  bool get isEmpty => strokes.isEmpty && texts.isEmpty && images.isEmpty;

  factory PageAnnotationDocument.fromJson(Object? raw) {
    if (raw is! Map) return PageAnnotationDocument();
    final rawItems = raw['annotations'];
    if (rawItems is! List) return PageAnnotationDocument();
    final coordinateSpace = switch (raw['annotation_coordinate_space'] ??
        raw['coordinate_space']) {
      'viewport' => PageAnnotationCoordinateSpace.viewport,
      _ => PageAnnotationCoordinateSpace.content,
    };
    final strokes = <PageStroke>[];
    final texts = <PageTextObject>[];
    final images = <PageImageObject>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final kind = item['kind']?.toString();
      if (kind == 'text') {
        texts.add(PageTextObject.fromJson(item));
      } else if (kind == 'stroke') {
        strokes.add(PageStroke.fromJson(item));
      } else if (kind == 'image') {
        final image = PageImageObject.fromJson(item);
        if (image.id.isNotEmpty && image.assetPath.isNotEmpty) {
          images.add(image);
        }
      }
    }
    return PageAnnotationDocument(
      strokes: strokes,
      texts: texts,
      images: images,
      coordinateSpace: coordinateSpace,
    );
  }

  Map<String, Object?> toJson() => {
    'schema_version': 2,
    'annotation_coordinate_space': coordinateSpace.name,
    'annotations': [
      for (final stroke in strokes) stroke.toJson(),
      for (final text in texts) text.toJson(),
      for (final image in images) image.toJson(),
    ],
  };

  PageAnnotationDocument copyWith({
    List<PageStroke>? strokes,
    List<PageTextObject>? texts,
    List<PageImageObject>? images,
    PageAnnotationCoordinateSpace? coordinateSpace,
  }) => PageAnnotationDocument(
    strokes: strokes ?? this.strokes,
    texts: texts ?? this.texts,
    images: images ?? this.images,
    coordinateSpace: coordinateSpace ?? this.coordinateSpace,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PageAnnotationDocument &&
          _listEquals(strokes, other.strokes) &&
          _listEquals(texts, other.texts) &&
          _listEquals(images, other.images) &&
          coordinateSpace == other.coordinateSpace;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(strokes),
    Object.hashAll(texts),
    Object.hashAll(images),
    coordinateSpace,
  );
}

double _unit(Object? value) =>
    ((value as num?)?.toDouble() ?? 0).clamp(0, 1).toDouble();

bool _pointsEqual(List<Offset> a, List<Offset> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
