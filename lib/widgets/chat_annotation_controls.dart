import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../models/chat_annotation.dart';

/// Keep source links selectable, with an explicit blue independent of theme.
InlineSpan chatAnnotationLinkSpan(LinkBuildDetails link) {
  if (Uri.tryParse(link.url)?.scheme != 'xiaoqi-annotation') {
    return link.defaultSpan();
  }
  return link.defaultSpan(
    children: [
      TextSpan(
        text: link.label,
        style: link.style.copyWith(
          color: const Color(0xFF3B82F6),
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.none,
        ),
      ),
    ],
  );
}

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

  // The SVG's anchor dot is at (20, 49), inside a 40 × 54 viewBox.
  static const textAnchor = Offset(24, 44.1);

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
    this.focusNode,
    this.requireText = false,
    super.key,
  });
  final TextEditingController controller;
  final VoidCallback onSubmit;
  final VoidCallback? onDelete;
  final bool optional;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool requireText;

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
              focusNode: focusNode,
              autofocus: autofocus,
              minLines: 1,
              maxLines: 4,
              maxLength: 4000,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (!requireText || controller.text.trim().isNotEmpty)
                  onSubmit();
              },
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
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final enabled = !requireText || value.text.trim().isNotEmpty;
              return IconButton(
                tooltip: '确认评论',
                onPressed: enabled ? onSubmit : null,
                icon: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: enabled
                        ? const Color(0xFF252525)
                        : const Color(0xFFB8B8B8),
                    shape: BoxShape.circle,
                  ),
                  child: chatAnnotationIcon('arrow-up', size: 21),
                ),
              );
            },
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
  Rect? Function()? resolveAnchor,
  ScrollPosition? scrollPosition,
  bool dockToKeyboard = false,
  bool requireText = true,
  ValueChanged<VoidCallback>? onDismissReady,
}) async {
  final result = Completer<String?>();
  void close(String? value) {
    if (!result.isCompleted) result.complete(value);
  }

  final overlay = Overlay.of(context, rootOverlay: true);
  final history = LocalHistoryEntry(
    impliesAppBarDismissal: false,
    onRemove: () => close(null),
  );
  ModalRoute.of(context)?.addLocalHistoryEntry(history);
  final entry = OverlayEntry(
    builder: (context) => Positioned.fill(
      child: _ChatAnnotationCommentPopover(
        initialText: initialText,
        anchor: anchor,
        resolveAnchor: resolveAnchor,
        scrollPosition: scrollPosition,
        dockToKeyboard: dockToKeyboard,
        requireText: requireText,
        onClose: close,
      ),
    ),
  );
  overlay.insert(entry);
  onDismissReady?.call(() => close(null));
  try {
    return await result.future;
  } finally {
    history.remove();
    entry.remove();
    entry.dispose();
  }
}

class _ChatAnnotationCommentPopover extends StatefulWidget {
  const _ChatAnnotationCommentPopover({
    required this.initialText,
    required this.anchor,
    required this.resolveAnchor,
    required this.scrollPosition,
    required this.dockToKeyboard,
    required this.requireText,
    required this.onClose,
  });

  final String initialText;
  final Offset anchor;
  final Rect? Function()? resolveAnchor;
  final ScrollPosition? scrollPosition;
  final bool dockToKeyboard;
  final bool requireText;
  final ValueChanged<String?> onClose;

  @override
  State<_ChatAnnotationCommentPopover> createState() =>
      _ChatAnnotationCommentPopoverState();
}

class _ChatAnnotationCommentPopoverState
    extends State<_ChatAnnotationCommentPopover> {
  late final _controller = TextEditingController(text: widget.initialText);
  final _focus = FocusNode();
  final _fieldKey = GlobalKey();
  double _fieldHeight = 56;
  late Rect _anchor = Rect.fromLTWH(widget.anchor.dx, widget.anchor.dy, 0, 0);
  bool _scheduled = false;
  bool _keyboardWasVisible = false;

  @override
  void initState() {
    super.initState();
    widget.scrollPosition?.addListener(_onScroll);
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  void _revealAnchor(double safeTop, double bottom) {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final height = _fieldKey.currentContext?.size?.height;
      if (height != null && (height - _fieldHeight).abs() > .5) {
        setState(() => _fieldHeight = height);
      }
      if (widget.dockToKeyboard) return;
      final anchor = widget.resolveAnchor?.call();
      if (widget.resolveAnchor != null && anchor == null) {
        widget.onClose(null);
        return;
      }
      if (anchor != null && anchor != _anchor) {
        setState(() => _anchor = anchor);
      }
      final position = widget.scrollPosition;
      if (anchor == null ||
          position == null ||
          !position.hasContentDimensions) {
        return;
      }
      final needed = anchor.bottom + 16 + (height ?? _fieldHeight) - bottom;
      final delta = needed > 0 ? needed : math.min(0.0, anchor.top - safeTop);
      final target = (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((target - position.pixels).abs() > .5) position.jumpTo(target);
    });
  }

  @override
  void dispose() {
    widget.scrollPosition?.removeListener(_onScroll);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      if (media.viewInsets.bottom > 0) _keyboardWasVisible = true;
      if (widget.dockToKeyboard &&
          _keyboardWasVisible &&
          media.viewInsets.bottom == 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onClose(null);
        });
      }
      final safeTop = media.padding.top + 8;
      final bottom =
          constraints.maxHeight -
          math.max(media.viewInsets.bottom, media.padding.bottom);
      final width = math.max(0.0, constraints.maxWidth - 24);
      final fieldWidth = widget.dockToKeyboard ? width : math.min(width, 360.0);
      final origin =
          (Overlay.of(context, rootOverlay: true).context.findRenderObject()
                  as RenderBox)
              .localToGlobal(Offset.zero);
      final anchor = _anchor.bottomRight - origin;
      final left = (anchor.dx - fieldWidth / 2).clamp(
        12.0,
        math.max(12.0, constraints.maxWidth - fieldWidth - 12),
      );
      final preferredTop = math.max(safeTop, anchor.dy + 8);
      final latestTop = math.max(safeTop, bottom - _fieldHeight - 8);
      final anchorTop = math.min(preferredTop, latestTop);
      _revealAnchor(safeTop + origin.dy, bottom + origin.dy);
      return Stack(
        children: [
          Positioned(
            left: widget.dockToKeyboard ? 12 : left.toDouble(),
            top: widget.dockToKeyboard ? null : anchorTop,
            bottom: widget.dockToKeyboard
                ? math.max(media.viewInsets.bottom, media.padding.bottom) + 8
                : null,
            width: fieldWidth,
            child: TapRegion(
              onTapOutside: (_) => widget.onClose(null),
              child: ChatAnnotationInput(
                key: _fieldKey,
                controller: _controller,
                focusNode: _focus,
                autofocus: widget.dockToKeyboard,
                requireText: widget.requireText,
                optional: !widget.requireText,
                onSubmit: () {
                  final value = _controller.text.trim();
                  if (widget.requireText && value.isEmpty) return;
                  widget.onClose(value);
                },
              ),
            ),
          ),
        ],
      );
    },
  );
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
      padding: const EdgeInsets.fromLTRB(6, 4, 0, 4),
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFFD5D8DE)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(
                  height: 48,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      chatAnnotationIcon(
                        'comment',
                        color: const Color(0xFF555B62),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${annotations.length} 条注释',
                        style: const TextStyle(
                          color: Color(0xFF303134),
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(width: 1, height: 24, color: const Color(0xFFD5D8DE)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '删除所有注释',
              onPressed: onRemove,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              icon: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFFF2F2F2),
                  shape: BoxShape.circle,
                ),
                child: SvgPicture.asset(
                  'assets/icons/chat_note_editor/x.svg',
                  width: 16,
                  height: 16,
                  colorFilter: const ColorFilter.mode(
                    Color(0xFF303134),
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showChatAnnotationReview(
  BuildContext context, {
  required List<ChatAnnotation> annotations,
  ValueChanged<List<ChatAnnotation>>? onChanged,
  Future<String?> Function(BuildContext context, ChatAnnotation annotation)?
  onEditComment,
  ValueChanged<ChatAnnotation>? onLocate,
}) async {
  var current = List<ChatAnnotation>.of(annotations);
  FocusManager.instance.primaryFocus?.unfocus();
  final editable = onChanged != null && onEditComment != null;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => Dialog(
        alignment: const Alignment(0, .35),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(480, MediaQuery.sizeOf(context).width * .82),
            maxHeight: MediaQuery.sizeOf(context).height * .7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        editable ? '待发送注释' : '已发送注释',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: SvgPicture.asset(
                        'assets/icons/chat_note_editor/x.svg',
                        width: 20,
                        height: 20,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: current.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('暂无注释'),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                        itemCount: current.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 25, color: Color(0xFFE0E0E0)),
                        itemBuilder: (context, index) {
                          final a = current[index];
                          Future<void> edit() async {
                            final value = await onEditComment!(
                              dialogContext,
                              a,
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
                            onChanged!(current);
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: InkWell(
                                      onTap: onLocate == null
                                          ? null
                                          : () {
                                              Navigator.pop(dialogContext);
                                              onLocate(a);
                                            },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                        child: Text(
                                          '注释 ${index + 1}',
                                          style: const TextStyle(
                                            color: Color(0xFF3B82F6),
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (editable)
                                    IconButton(
                                      tooltip: '编辑评论',
                                      onPressed: edit,
                                      icon: SvgPicture.asset(
                                        'assets/images/home_message_edit.svg',
                                        width: 20,
                                        height: 20,
                                      ),
                                    ),
                                  if (editable)
                                    IconButton(
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
                                ],
                              ),
                              Text(
                                a.isImage ? '所选图片：' : '所选文本：',
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                a.isImage
                                    ? '图片点位 · ${(a.x * 100).round()}%，${(a.y * 100).round()}%'
                                    : a.quote,
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 14),
                              const Text(
                                '评论：',
                                style: TextStyle(
                                  fontSize: 15,
                                  height: 1.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              InkWell(
                                onTap: editable ? edit : null,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  child: Text(
                                    a.comment.isEmpty
                                        ? (editable ? '添加可选评论…' : '未填写评论')
                                        : a.comment,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ],
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

/// A sent annotation-only message is this chip, without a parent text bubble.
class ChatAnnotationCountChip extends StatelessWidget {
  const ChatAnnotationCountChip({
    required this.count,
    required this.onTap,
    super.key,
  });
  final int count;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '查看 $count 条注释',
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0xFFD5D8DE)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                chatAnnotationIcon(
                  'comment',
                  color: const Color(0xFF555B62),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  '$count 条注释',
                  style: const TextStyle(
                    fontSize: 15,
                    color: Color(0xFF303134),
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

/// Measures the quote against the rendered paragraphs, in the root's coordinates.
List<Rect> chatTextQuoteBoxes(RenderBox root, ChatAnnotation annotation) {
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
  final range = locateChatQuote(
    plain,
    annotation.quote,
    annotation.startOffset,
  );
  if (range == null) return const [];
  final boxes = <Rect>[];
  for (final p in paragraphs) {
    final start = (range.start - p.start).clamp(0, p.text.length);
    final end = (range.end - p.start).clamp(0, p.text.length);
    if (end <= start) continue;
    for (final box in p.box.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    )) {
      boxes.add(
        box.toRect().shift(p.box.localToGlobal(Offset.zero, ancestor: root)),
      );
    }
  }
  return boxes;
}

class ChatTextAnnotationLayer extends StatefulWidget {
  const ChatTextAnnotationLayer({
    required this.child,
    required this.annotations,
    this.annotationNumbers = const {},
    this.draft,
    this.highlight,
    required this.onTapAnnotation,
    super.key,
  });
  final Widget child;
  final List<ChatAnnotation> annotations;
  final Map<String, int> annotationNumbers;
  final ChatAnnotation? draft;
  final ChatAnnotation? highlight;
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
      final marks = <({ChatAnnotation annotation, List<Rect> boxes})>[];
      for (final a in [
        ...widget.annotations,
        if (widget.draft != null) widget.draft!,
        if (widget.highlight != null &&
            !widget.annotations.any((a) => a.id == widget.highlight!.id))
          widget.highlight!,
      ]) {
        final boxes = chatTextQuoteBoxes(root, a);
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
            if (mark.annotation.id != widget.draft?.id &&
                mark.annotation.id != widget.highlight?.id)
              Positioned(
                left: mark.boxes.last.right - ChatAnnotationPin.textAnchor.dx,
                top: mark.boxes.last.bottom - ChatAnnotationPin.textAnchor.dy,
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
                        box.localToGlobal(ChatAnnotationPin.textAnchor),
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
