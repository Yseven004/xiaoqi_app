import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

Future<T?> showAnnotationSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool editing = false,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    isDismissible: !editing,
    enableDrag: !editing,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x38000000),
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) {
      final media = MediaQuery.of(context);
      final keyboard = media.viewInsets.bottom;
      final maxHeight = math.max(
        0.0,
        media.size.height - media.padding.top - keyboard,
      );
      return Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: Material(
          color: Colors.white,
          clipBehavior: Clip.antiAlias,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            side: BorderSide(color: Color(0xFFE6E7E9)),
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: builder(context),
            ),
          ),
        ),
      );
    },
  );
}

class AnnotationQuoteLine extends StatelessWidget {
  const AnnotationQuoteLine(this.quote, {this.guardContent, super.key});

  final String quote;
  final Widget Function(Widget)? guardContent;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () {
      FocusManager.instance.primaryFocus?.unfocus();
      showDialog<void>(
        context: context,
        builder: (context) {
          final dialog = AlertDialog(
            title: const Text('引文'),
            content: SingleChildScrollView(child: SelectableText(quote)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          );
          return guardContent?.call(dialog) ?? dialog;
        },
      );
    },
    child: Semantics(
      button: true,
      label: '查看完整引文',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Text(
          '引文  ${quote.replaceAll(RegExp(r"\s+"), " ")}',
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          style: const TextStyle(fontSize: 13, color: Color(0xFF5D626A)),
        ),
      ),
    ),
  );
}

Widget annotationAsset(String path, {double size = 20, Color? color}) =>
    SvgPicture.asset(
      path,
      width: size,
      height: size,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color, BlendMode.srcIn),
      excludeFromSemantics: true,
    );

class AnnotationThumbnails extends StatelessWidget {
  const AnnotationThumbnails({
    required this.paths,
    this.onRemove,
    this.guardContent,
    this.mediaChanges,
    this.onMissing,
    super.key,
  });

  final List<String> paths;
  final ValueChanged<int>? onRemove;
  final Widget Function(Widget)? guardContent;
  final Listenable? mediaChanges;
  final ValueChanged<String>? onMissing;

  @override
  Widget build(BuildContext context) {
    final changes = mediaChanges;
    return changes == null
        ? _gallery(context)
        : ListenableBuilder(
            listenable: changes,
            builder: (context, _) => _gallery(context),
          );
  }

  Widget _gallery(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (var index = 0; index < paths.length; index++)
        Stack(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                if (onMissing != null && !File(paths[index]).existsSync()) {
                  onMissing!(paths[index]);
                  return;
                }
                showDialog<void>(
                  context: context,
                  builder: (context) {
                    final dialog = Dialog(
                      clipBehavior: Clip.antiAlias,
                      child: InteractiveViewer(
                        child: Image.file(
                          File(paths[index]),
                          fit: BoxFit.contain,
                        ),
                      ),
                    );
                    return guardContent?.call(dialog) ?? dialog;
                  },
                );
              },
              child: Semantics(
                label: '查看图片 ${index + 1}',
                button: true,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: onMissing != null && !File(paths[index]).existsSync()
                      ? const ColoredBox(
                          color: Color(0xFFF1F2F4),
                          child: SizedBox(
                            width: 58,
                            height: 58,
                            child: Center(child: Text('待下载')),
                          ),
                        )
                      : Image.file(
                          File(paths[index]),
                          width: 58,
                          height: 58,
                          cacheWidth: 192,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const ColoredBox(
                            color: Color(0xFFF1F2F4),
                            child: SizedBox(
                              width: 58,
                              height: 58,
                              child: Center(child: Text('图片失效')),
                            ),
                          ),
                        ),
                ),
              ),
            ),
            if (onRemove != null)
              Positioned(
                top: 0,
                right: 0,
                child: SizedBox.square(
                  dimension: 36,
                  child: IconButton(
                    tooltip: '移除图片 ${index + 1}',
                    onPressed: () => onRemove!(index),
                    icon: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: Color(0xB3343740),
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: annotationAsset(
                          'assets/icons/chat_note_editor/x.svg',
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
    ],
  );
}

/// Releases an empty editor when Android hides the keyboard via system Back.
class AnnotationTextField extends StatefulWidget {
  const AnnotationTextField({required this.controller, super.key});

  final TextEditingController controller;

  @override
  State<AnnotationTextField> createState() => _AnnotationTextFieldState();
}

class _AnnotationTextFieldState extends State<AnnotationTextField>
    with WidgetsBindingObserver {
  final _focus = FocusNode();
  double _lastInset = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final inset = View.of(context).viewInsets.bottom;
    if (_lastInset > 0 && inset == 0 && widget.controller.text.isEmpty) {
      _focus.unfocus();
    }
    _lastInset = inset;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    focusNode: _focus,
    autofocus: true,
    minLines: 1,
    maxLines: 5,
    maxLength: 4000,
    onTapOutside: (_) => _focus.unfocus(),
    style: const TextStyle(
      color: Color(0xFF202124),
      fontSize: 15,
      height: 1.45,
    ),
    decoration: const InputDecoration(
      border: InputBorder.none,
      counterText: '',
      hintText: '写下注释…',
      hintStyle: TextStyle(color: Color(0xFF60646A)),
      contentPadding: EdgeInsets.symmetric(vertical: 8),
      isDense: true,
    ),
  );
}
