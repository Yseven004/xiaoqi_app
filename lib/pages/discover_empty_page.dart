import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';

class DiscoverEmptyPage extends StatelessWidget {
  const DiscoverEmptyPage({super.key, required this.onBackToBooks});

  final VoidCallback onBackToBooks;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: BookFlowTheme.primarySoft,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.explore_outlined,
                size: 34,
                color: BookFlowTheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            const Text('发现', style: BookFlowTheme.pageTitle),
            const SizedBox(height: 8),
            const Text(
              '发现更多书籍与学习内容的功能正在准备中。\n现在先把你的书和笔记整理好吧。',
              textAlign: TextAlign.center,
              style: BookFlowTheme.body,
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: onBackToBooks,
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('返回阅读空间'),
            ),
          ],
        ),
      ),
    ),
  );
}
