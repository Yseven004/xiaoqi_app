import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Reverse, lazy chat viewport with short-content alignment resolved in layout.
class ChatMessageScrollView extends CustomScrollView {
  const ChatMessageScrollView({
    super.key,
    required super.controller,
    required super.slivers,
  }) : super(reverse: true);

  @override
  Widget buildViewport(
    BuildContext context,
    ViewportOffset offset,
    AxisDirection axisDirection,
    List<Widget> slivers,
  ) {
    return _ChatViewport(
      offset: offset,
      axisDirection: axisDirection,
      slivers: slivers,
    );
  }
}

class _ChatViewport extends Viewport {
  _ChatViewport({
    required super.offset,
    required super.axisDirection,
    required super.slivers,
  });

  @override
  RenderViewport createRenderObject(BuildContext context) =>
      _ChatRenderViewport(
        offset: offset,
        axisDirection: axisDirection,
        crossAxisDirection: Viewport.getDefaultCrossAxisDirection(
          context,
          axisDirection,
        ),
      );
}

class _ChatRenderViewport extends RenderViewport {
  _ChatRenderViewport({
    required super.offset,
    required super.axisDirection,
    required super.crossAxisDirection,
  });

  RenderBox? _readingAnchor;
  double _readingTop = 0;
  double _previousPixels = 0;
  Size? _previousSize;
  double _layoutAnchor = 0;

  @override
  double get anchor => _layoutAnchor;

  double _top(RenderBox box) =>
      box.localToGlobal(Offset.zero, ancestor: this).dy;

  @override
  void performLayout() {
    final pixelsBeforeLayout = offset.pixels;
    super.performLayout();
    var contentExtent = 0.0;
    for (var sliver = firstChild; sliver != null; sliver = childAfter(sliver)) {
      contentExtent += sliver.geometry?.scrollExtent ?? 0;
    }
    final nextAnchor = size.height == 0
        ? 0.0
        : (1 - contentExtent / size.height).clamp(0.0, 1.0).toDouble();
    if ((anchor - nextAnchor).abs() > .0001) {
      _layoutAnchor = nextAnchor;
      super.performLayout();
    }
    // Preserve the visible row, not an estimated total list height. Account for
    // actual scrolling so a drag or a navigation animation is never cancelled.
    var correction = 0.0;
    invokeLayoutCallback<BoxConstraints>((_) {
      final reading = _readingAnchor;
      if (pixelsBeforeLayout > 72 &&
          _previousPixels > 72 &&
          _previousSize == size &&
          reading != null &&
          reading.attached &&
          reading.hasSize) {
        final expectedTop = _readingTop + pixelsBeforeLayout - _previousPixels;
        correction = expectedTop - _top(reading);
      }
    });
    if (correction.abs() > .5) {
      offset.correctBy(correction);
      super.performLayout();
    }
    invokeLayoutCallback<BoxConstraints>((_) {
      _readingAnchor = null;
      var firstTop = double.infinity;
      void visitSliver(RenderSliver sliver) {
        if (sliver is RenderSliverPadding) {
          final child = sliver.child;
          if (child != null) visitSliver(child);
        } else if (sliver is RenderSliverMultiBoxAdaptor) {
          var box = sliver.firstChild;
          while (box != null) {
            final next = sliver.childAfter(box);
            final top = _top(box);
            if (top < size.height &&
                top + box.size.height > 0 &&
                top < firstTop) {
              firstTop = top;
              _readingAnchor = box;
              _readingTop = top;
            }
            box = next;
          }
        }
      }

      for (
        var sliver = firstChild;
        sliver != null;
        sliver = childAfter(sliver)
      ) {
        visitSliver(sliver);
      }
      _previousPixels = offset.pixels;
      _previousSize = size;
    });
  }
}
