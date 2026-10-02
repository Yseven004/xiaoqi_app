import 'dart:io';

import 'package:flutter/material.dart';

import '../config/notebook_theme.dart';
import '../models/notebook.dart';

class NotebookCover extends StatelessWidget {
  const NotebookCover({
    super.key,
    required this.notebook,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.child,
    this.boxShadow = const [],
  });

  final Notebook notebook;
  final BorderRadius borderRadius;
  final Widget? child;
  final List<BoxShadow> boxShadow;

  @override
  Widget build(BuildContext context) {
    final path = notebook.coverPath.trim();
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: NotebookTheme.coverGradient(notebook.coverIndex),
        borderRadius: borderRadius,
        boxShadow: boxShadow,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (path.isNotEmpty)
            Image.file(
              File(path),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ?child,
        ],
      ),
    );
  }
}
