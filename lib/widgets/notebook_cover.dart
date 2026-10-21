import 'package:flutter/material.dart';

import '../config/notebook_theme.dart';
import '../models/notebook.dart';
import '../utils/book_cover_palette.dart';
import 'book_spine_shading.dart';

/// The existing book's physical shape, with the notebook's own single color.
class NotebookCover extends StatelessWidget {
  const NotebookCover({
    super.key,
    required this.notebook,
    this.showTitle = true,
  });

  final Notebook notebook;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final color = NotebookTheme
        .covers[notebook.coverIndex.abs() % NotebookTheme.covers.length]
        .first;
    return Semantics(
      image: true,
      label: '${notebook.name}封面',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final spineWidth = (constraints.maxWidth * .075).clamp(8.0, 11.0);
          return ClipRRect(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(8),
              bottomLeft: Radius.circular(8),
              topRight: Radius.circular(5),
              bottomRight: Radius.circular(5),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: color),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: spineWidth + 2,
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: BookSpineShadingPainter(
                        palette: BookCoverPalette.fromColors([color], color),
                        foldX: spineWidth,
                      ),
                    ),
                  ),
                ),
                if (showTitle)
                  Padding(
                    padding: EdgeInsets.fromLTRB(spineWidth + 8, 18, 8, 12),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        notebook.name,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF202124),
                          fontSize: 14,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
