import 'package:flutter/widgets.dart';

/// Keeps surfaces that do not own keyboard input in their normal layout.
class BookKeyboardLayout extends StatelessWidget {
  const BookKeyboardLayout({
    super.key,
    required this.avoidKeyboard,
    required this.child,
  });

  final bool avoidKeyboard;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: avoidKeyboard
          ? media
          : media.copyWith(
              padding: media.viewPadding,
              viewInsets: EdgeInsets.zero,
            ),
      child: child,
    );
  }
}
