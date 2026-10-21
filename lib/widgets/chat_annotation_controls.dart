import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/chat_annotation.dart';

Widget chatAnnotationIcon(
  String name, {
  Color color = Colors.white,
  double size = 22,
}) => SvgPicture.asset(
  'assets/icons/chat_annotations/$name.svg',
  width: size,
  height: size,
  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
  excludeFromSemantics: true,
);

class ChatAnnotationPin extends StatelessWidget {
  const ChatAnnotationPin({
    required this.number,
    required this.onTap,
    super.key,
  });
  final int number;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '注释 $number',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 48,
        height: 54,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            SvgPicture.asset(
              'assets/icons/chat_annotations/pin.svg',
              width: 36,
              height: 48.6,
            ),
            Positioned(
              top: 9,
              child: Text(
                '$number',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class ChatAnnotationInput extends StatelessWidget {
  const ChatAnnotationInput({
    required this.controller,
    required this.onSubmit,
    this.onDelete,
    this.optional = false,
    this.autofocus = false,
    super.key,
  });
  final TextEditingController controller;
  final VoidCallback onSubmit;
  final VoidCallback? onDelete;
  final bool optional;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    elevation: 3,
    shadowColor: const Color(0x22000000),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(28),
      side: const BorderSide(color: Color(0xFFE1E2E5)),
    ),
    child: Padding(
      padding: const EdgeInsets.only(left: 18, right: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: autofocus,
              minLines: 1,
              maxLines: 4,
              maxLength: 4000,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onSubmit(),
              style: const TextStyle(color: Color(0xFF282828), fontSize: 15),
              decoration: InputDecoration(
                border: InputBorder.none,
                counterText: '',
                hintText: optional ? '添加可选评论…' : '添加评论…',
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: '删除这条注释',
              onPressed: onDelete,
              icon: SvgPicture.asset(
                'assets/icons/chat_note_editor/trash.svg',
                width: 19,
                height: 19,
              ),
            ),
          IconButton(
            tooltip: '确认评论',
            onPressed: onSubmit,
            icon: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0xFF252525),
                shape: BoxShape.circle,
              ),
              child: chatAnnotationIcon('arrow-up', size: 21),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<String?> showChatAnnotationComment(
  BuildContext context, {
  required String initialText,
  required Offset anchor,
}) async {
  final controller = TextEditingController(text: initialText);
  try {
    final route = DialogRoute<String>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (dialogContext) => LayoutBuilder(
        builder: (context, constraints) {
          final mq = MediaQuery.of(context);
          final width = (constraints.maxWidth - 24).clamp(0.0, 360.0);
          final safeTop = mq.padding.top + 8;
          final keyboardTop = constraints.maxHeight - mq.viewInsets.bottom;
          const fieldHeight = 160.0;
          final bottom = math.min(
            constraints.maxHeight - mq.padding.bottom,
            keyboardTop,
          );
          final left = (anchor.dx - width / 2).clamp(
            12.0,
            constraints.maxWidth - width - 12,
          );
          final top = (anchor.dy - 90)
              .clamp(
                safeTop,
                (bottom - fieldHeight - 8).clamp(safeTop, double.infinity),
              )
              .toDouble();
          return Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                width: width,
                child: ChatAnnotationInput(
                  controller: controller,
                  optional: true,
                  onSubmit: () =>
                      Navigator.of(dialogContext).pop(controller.text.trim()),
                ),
              ),
            ],
          );
        },
      ),
    );
    final result = await Navigator.of(context, rootNavigator: true).push(route);
    final value = result ?? controller.text.trim();
    await route.completed;
    return value;
  } finally {
    controller.dispose();
  }
}

class ChatAnnotationTray extends StatelessWidget {
  const ChatAnnotationTray({
    required this.annotations,
    required this.onTap,
    required this.onRemove,
    super.key,
  });
  final List<ChatAnnotation> annotations;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(left: 6, right: 10, top: 10, bottom: 6),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          OutlinedButton.icon(
            onPressed: onTap,
            icon: chatAnnotationIcon(
              'comment',
              color: const Color(0xFF555555),
              size: 17,
            ),
            label: Text('${annotations.length} 条注释'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF333333),
              minimumSize: const Size(48, 42),
              side: const BorderSide(color: Color(0xFFE3E3E3)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          Positioned(
            right: -7,
            top: -7,
            child: Material(
              color: Colors.white,
              shape: const CircleBorder(),
              elevation: 2,
              child: IconButton(
                tooltip: '删除所有注释',
                onPressed: onRemove,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                icon: const Icon(
                  Icons.close,
                  size: 17,
                  color: Color(0xFF666666),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> showChatAnnotationReview(
  BuildContext context, {
  required List<ChatAnnotation> annotations,
  required ValueChanged<List<ChatAnnotation>> onChanged,
  required Future<String?> Function(String initialText, Offset anchor)
  onEditComment,
}) async {
  var current = List<ChatAnnotation>.of(annotations);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    showDragHandle: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, update) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '待发送注释',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: current.isEmpty
                    ? const Center(child: Text('暂无注释'))
                    : ListView.separated(
                        itemCount: current.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final a = current[index];
                          return ListTile(
                            leading: Text(
                              '${index + 1}',
                              style: const TextStyle(color: Color(0xFF3B82F6)),
                            ),
                            title: Text(
                              a.isImage
                                  ? '图片点位 · ${(a.x * 100).round()}%，${(a.y * 100).round()}%'
                                  : a.quote,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14),
                            ),
                            subtitle: Text(
                              a.comment.isEmpty ? '添加可选评论…' : a.comment,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () async {
                              final value = await onEditComment(
                                a.comment,
                                Offset(
                                  MediaQuery.sizeOf(context).width / 2,
                                  180,
                                ),
                              );
                              if (value == null || !context.mounted) return;
                              update(
                                () => current = current
                                    .map(
                                      (v) => v.id == a.id
                                          ? v.copyWith(comment: value)
                                          : v,
                                    )
                                    .toList(),
                              );
                              onChanged(current);
                            },
                            trailing: IconButton(
                              tooltip: '移除注释',
                              icon: SvgPicture.asset(
                                'assets/icons/chat_note_editor/trash.svg',
                                width: 20,
                                height: 20,
                              ),
                              onPressed: () {
                                update(
                                  () => current = current
                                      .where((v) => v.id != a.id)
                                      .toList(),
                                );
                                onChanged(current);
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Finds a quote in displayed text, using the actual selection range to resolve
/// repeated phrases. Whitespace is normalized without losing box offsets.
({int start, int end})? locateChatQuote(
  String text,
  String quote,
  int? preferredStart,
) {
  ({String text, List<int> offsets}) normalize(String value) {
    final b = StringBuffer();
    final offsets = <int>[];
    var wasSpace = false;
    for (var i = 0; i < value.length; i++) {
      final c = value.substring(i, i + 1);
      final space = RegExp(r'\s').hasMatch(c);
      if (!space || !wasSpace) {
        b.write(space ? ' ' : c);
        offsets.add(i);
      }
      wasSpace = space;
    }
    return (text: b.toString(), offsets: offsets);
  }

  final haystack = normalize(text);
  final needle = normalize(quote).text.trim();
  if (needle.isEmpty) return null;
  var at = haystack.text.indexOf(needle);
  int? best;
  while (at >= 0) {
    if (best == null ||
        (haystack.offsets[at] - (preferredStart ?? 0)).abs() <
            (haystack.offsets[best] - (preferredStart ?? 0)).abs()) {
      best = at;
    }
    at = haystack.text.indexOf(needle, at + 1);
  }
  return best == null
      ? null
      : (
          start: haystack.offsets[best],
          end: haystack.offsets[best + needle.length - 1] + 1,
        );
}

class ChatTextAnnotationLayer extends StatefulWidget {
  const ChatTextAnnotationLayer({
    required this.child,
    required this.annotations,
    this.annotationNumbers = const {},
    required this.onTapAnnotation,
    super.key,
  });
  final Widget child;
  final List<ChatAnnotation> annotations;
  final Map<String, int> annotationNumbers;
  final void Function(ChatAnnotation, Offset) onTapAnnotation;
  @override
  State<ChatTextAnnotationLayer> createState() =>
      _ChatTextAnnotationLayerState();
}

class _ChatTextAnnotationLayerState extends State<ChatTextAnnotationLayer> {
  final _contentKey = GlobalKey();
  List<({ChatAnnotation annotation, List<Rect> boxes})> _marks = [];
  Size _contentSize = Size.zero;
  bool _scheduled = false;

  void _measure() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final root = _contentKey.currentContext?.findRenderObject();
      if (root is! RenderBox || !root.hasSize) return;
      final paragraphs = <({RenderParagraph box, String text, int start})>[];
      var plain = '';
      void visit(RenderObject object) {
        if (object is RenderParagraph) {
          final text = object.text.toPlainText(includePlaceholders: false);
          paragraphs.add((box: object, text: text, start: plain.length));
          plain += '$text\n';
        } else {
          object.visitChildren(visit);
        }
      }

      visit(root);
      final marks = <({ChatAnnotation annotation, List<Rect> boxes})>[];
      for (final a in widget.annotations) {
        final range = locateChatQuote(plain, a.quote, a.startOffset);
        if (range == null) continue;
        final boxes = <Rect>[];
        for (final p in paragraphs) {
          final start = (range.start - p.start).clamp(0, p.text.length);
          final end = (range.end - p.start).clamp(0, p.text.length);
          if (end <= start) continue;
          for (final b in p.box.getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: end),
          )) {
            final offset = p.box.localToGlobal(Offset.zero, ancestor: root);
            boxes.add(b.toRect().shift(offset));
          }
        }
        if (boxes.isNotEmpty) marks.add((annotation: a, boxes: boxes));
      }
      String signature(
        List<({ChatAnnotation annotation, List<Rect> boxes})> values,
      ) => values
          .map((m) => '${m.annotation.id}:${m.annotation.comment}:${m.boxes}')
          .join('|');
      if (root.size != _contentSize || signature(marks) != signature(_marks)) {
        setState(() {
          _contentSize = root.size;
          _marks = marks;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, _) {
      _measure();
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Container(key: _contentKey, child: widget.child),
          for (final mark in _marks) ...[
            for (final box in mark.boxes)
              Positioned.fromRect(
                rect: box,
                child: const IgnorePointer(
                  child: ColoredBox(color: Color(0x263B82F6)),
                ),
              ),
            Positioned(
              left: (mark.boxes.last.right - 18)
                  .clamp(
                    0.0,
                    (_contentSize.width - 48).clamp(0.0, double.infinity),
                  )
                  .toDouble(),
              top: (mark.boxes.last.bottom - 5)
                  .clamp(
                    0.0,
                    (_contentSize.height - 54).clamp(0.0, double.infinity),
                  )
                  .toDouble(),
              child: Builder(
                builder: (pinContext) => ChatAnnotationPin(
                  number:
                      widget.annotationNumbers[mark.annotation.id] ??
                      widget.annotations.indexWhere(
                            (a) => a.id == mark.annotation.id,
                          ) +
                          1,
                  onTap: () {
                    final box = pinContext.findRenderObject() as RenderBox;
                    widget.onTapAnnotation(
                      mark.annotation,
                      box.localToGlobal(Offset.zero),
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}
