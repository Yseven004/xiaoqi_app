import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';

const bookImportInProgressLabel = '正在导入';

class BookImportProgress extends StatelessWidget {
  const BookImportProgress({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(
      color: BookFlowTheme.inkSecondary,
      strokeWidth: 2,
    ),
  );
}
