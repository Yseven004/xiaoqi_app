import 'package:flutter/material.dart';

import '../config/book_flow_theme.dart';

enum BookLearningDestination { books, notes, discover, profile }

class BookLearningBottomBar extends StatelessWidget {
  const BookLearningBottomBar({
    super.key,
    required this.selected,
    required this.onDestinationSelected,
  });

  final BookLearningDestination selected;
  final ValueChanged<BookLearningDestination> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final barHeight = 68.0 + bottomInset;
    return Container(
      height: barHeight,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: BookFlowTheme.line)),
      ),
      child: Row(
        children: [
          _DestinationItem(
            label: '阅读空间',
            icon: Icons.auto_stories_outlined,
            selectedIcon: Icons.auto_stories_rounded,
            selected: selected == BookLearningDestination.books,
            onTap: () => onDestinationSelected(BookLearningDestination.books),
          ),
          _DestinationItem(
            label: '笔记',
            icon: Icons.note_alt_outlined,
            selectedIcon: Icons.note_alt_rounded,
            selected: selected == BookLearningDestination.notes,
            onTap: () => onDestinationSelected(BookLearningDestination.notes),
          ),
          _DestinationItem(
            label: '发现',
            icon: Icons.explore_outlined,
            selectedIcon: Icons.explore_rounded,
            selected: selected == BookLearningDestination.discover,
            onTap: () =>
                onDestinationSelected(BookLearningDestination.discover),
          ),
          _DestinationItem(
            label: '我的',
            icon: Icons.person_outline_rounded,
            selectedIcon: Icons.person_rounded,
            selected: selected == BookLearningDestination.profile,
            onTap: () => onDestinationSelected(BookLearningDestination.profile),
          ),
        ],
      ),
    );
  }
}

class _DestinationItem extends StatelessWidget {
  const _DestinationItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? BookFlowTheme.primaryStrong : BookFlowTheme.muted;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: SizedBox.expand(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(selected ? selectedIcon : icon, color: color, size: 27),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
