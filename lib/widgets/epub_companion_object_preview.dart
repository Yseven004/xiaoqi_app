import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/xiaoqi_document.dart';
import 'companion_pdf_object_view.dart';
import 'xiaoqi_document_block_view.dart';

Future<void> showEpubCompanionObjectPreview({
  required BuildContext context,
  required XiaoqiDocumentBlock block,
  required XiaoqiDocumentAsset? asset,
}) {
  final stamp = DateTime.now().millisecondsSinceEpoch;
  if (block.kind == 'table') {
    final direction = Directionality.of(context);
    // Use the original block. A page can contain only a slice of its rows.
    return showCompanionObjectPreview(
      context: context,
      filename: 'xiaoqi-epub-table-$stamp.png',
      loadPreview: () async {
        final (size, picture) = await _recordTable(block, direction);
        return CompanionObjectPreviewContent(
          size.aspectRatio,
          Semantics(
            image: true,
            label: '表格',
            child: CustomPaint(painter: _TablePreviewPainter(size, picture)),
          ),
          naturalSize: size,
          release: picture.dispose,
        );
      },
      loadExport: () async {
        final (size, picture) = await _recordTable(block, direction);
        try {
          return await _encodePicture(
            size,
            (canvas) => canvas.drawPicture(picture),
          );
        } finally {
          picture.dispose();
        }
      },
    );
  }
  if (asset == null || asset.bytes.isEmpty) return Future<void>.value();
  final bytes = asset.bytes is Uint8List
      ? asset.bytes as Uint8List
      : Uint8List.fromList(asset.bytes);
  final label = asset.altText.trim().isEmpty ? '图片' : asset.altText.trim();
  if (asset.mimeType == 'image/svg+xml') {
    final loader = SvgBytesLoader(bytes);
    return showCompanionObjectPreview(
      context: context,
      filename: 'xiaoqi-epub-image-$stamp.png',
      loadPreview: () async {
        final vector = await vg.loadPicture(loader, null);
        try {
          final size = vector.size;
          if (size.isEmpty || !size.isFinite) {
            throw const FormatException('Invalid EPUB SVG size.');
          }
          return CompanionObjectPreviewContent(
            size.aspectRatio,
            ColoredBox(
              color: Colors.white,
              child: SvgPicture(
                loader,
                fit: BoxFit.contain,
                semanticsLabel: label,
              ),
            ),
          );
        } finally {
          vector.picture.dispose();
        }
      },
      loadExport: () async {
        final vector = await vg.loadPicture(loader, null);
        try {
          return await _encodePicture(vector.size, (canvas) {
            canvas.drawColor(Colors.white, BlendMode.src);
            canvas.drawPicture(vector.picture);
          });
        } finally {
          vector.picture.dispose();
        }
      },
    );
  }
  final extension = switch (asset.mimeType.toLowerCase()) {
    'image/jpeg' || 'image/jpg' => 'jpg',
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => null,
  };
  return showCompanionObjectPreview(
    context: context,
    filename: 'xiaoqi-epub-image-$stamp.${extension ?? 'png'}',
    loadPreview: () async {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          return CompanionObjectPreviewContent(
            descriptor.width / descriptor.height,
            _previewImage(bytes, label),
          );
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    },
    loadExport: () async {
      if (extension != null) return bytes;
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        try {
          final png = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    },
  );
}

Widget _previewImage(Uint8List bytes, String label) => Image.memory(
  bytes,
  fit: BoxFit.contain,
  semanticLabel: label,
  errorBuilder: (_, _, _) => const Center(
    child: Text('图片暂时无法显示', style: TextStyle(color: Colors.white)),
  ),
);

Future<(Size, ui.Picture)> _recordTable(
  XiaoqiDocumentBlock block,
  TextDirection direction,
) async {
  await Future<void>.delayed(Duration.zero);
  final rows =
      documentTableRows(block) ??
      [
        [block.text],
      ];
  final columns = rows.fold<int>(
    1,
    (count, row) => math.max(count, row.length),
  );
  final headerRows = int.tryParse(block.attributes['headerRows'] ?? '') ?? 0;
  final cellWidth = (780.0 / columns).clamp(120.0, 260.0);
  const padding = 10.0;
  final width = columns * cellWidth;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final line = Paint()
    ..color = const Color(0xFFBCB9B2)
    ..strokeWidth = 1;
  final background = Paint();
  var y = .5;
  try {
    for (final (rowIndex, row) in rows.indexed) {
      if (rowIndex > 0 && rowIndex % 64 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final header = rowIndex < headerRows;
      final style = TextStyle(
        color: const Color(0xFF242424),
        fontFamily: 'NotoSerifCJKSC',
        fontSize: 17,
        height: 1.35,
        fontWeight: header ? FontWeight.w700 : FontWeight.w400,
      );
      final cells = <TextPainter>[];
      var rowHeight = 38.0;
      try {
        for (final text in row) {
          final cell = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: direction,
          );
          cells.add(cell);
          cell.layout(maxWidth: cellWidth - padding * 2);
          rowHeight = math.max(rowHeight, cell.height + padding * 2);
        }
        background.color = header ? const Color(0xFFF0EFEB) : Colors.white;
        canvas.drawRect(Rect.fromLTWH(.5, y, width, rowHeight), background);
        for (final (column, cell) in cells.indexed) {
          cell.paint(
            canvas,
            Offset(column * cellWidth + padding + .5, y + padding),
          );
        }
        canvas.drawLine(Offset(.5, y), Offset(width + .5, y), line);
        y += rowHeight;
      } finally {
        for (final cell in cells) {
          cell.dispose();
        }
      }
    }
    canvas.drawLine(Offset(.5, y), Offset(width + .5, y), line);
    for (var c = 0; c <= columns; c++) {
      final x = c * cellWidth + .5;
      canvas.drawLine(Offset(x, .5), Offset(x, y), line);
    }
    final size = Size(width + 1, y + .5);
    return (size, recorder.endRecording());
  } finally {
    if (recorder.isRecording) recorder.endRecording().dispose();
  }
}

class _TablePreviewPainter extends CustomPainter {
  const _TablePreviewPainter(this.sourceSize, this.picture);

  final Size sourceSize;
  final ui.Picture picture;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(
      size.width / sourceSize.width,
      size.height / sourceSize.height,
    );
    canvas.drawPicture(picture);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TablePreviewPainter oldDelegate) =>
      oldDelegate.picture != picture || oldDelegate.sourceSize != sourceSize;
}

Future<Uint8List> _encodePicture(Size size, void Function(Canvas) paint) async {
  if (size.isEmpty || !size.isFinite) {
    throw const FormatException('Invalid EPUB object size.');
  }
  // Bound both the GPU texture edge and working memory on mobile. All rows
  // and columns are still included, even when a large object needs scaling.
  final scale = math.min(
    2.0,
    math.min(
      4096 / size.longestSide,
      math.sqrt(8000000 / (size.width * size.height)),
    ),
  );
  final width = math.max(1, (size.width * scale).ceil());
  final height = math.max(1, (size.height * scale).ceil());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..scale(width / size.width, height / size.height);
  ui.Picture? picture;
  try {
    paint(canvas);
    picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Cannot encode EPUB preview.');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture?.dispose();
    if (recorder.isRecording) recorder.endRecording().dispose();
  }
}
