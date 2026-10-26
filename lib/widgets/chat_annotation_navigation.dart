import 'package:flutter/material.dart';

/// Seek an unbuilt row without making the entire conversation resident.
/// Heights are estimates only; mounted row identities bound every correction.
Future<bool> revealChatMessage({
  required String messageId,
  required List<String> messageIds,
  required Map<String, GlobalKey> anchors,
  required Map<String, double> heights,
  required ScrollController controller,
  required bool Function() cancelled,
}) async {
  final target = messageIds.indexOf(messageId);
  if (target < 0 || !controller.hasClients) return false;
  final indices = {
    for (var i = 0; i < messageIds.length; i++) messageIds[i]: i,
  };
  var lower = 0.0;
  var upper = controller.position.maxScrollExtent;
  var lastExtent = upper;
  for (var pass = 0; pass < 48; pass++) {
    if (cancelled() || !controller.hasClients) return false;
    final context = anchors[messageId]?.currentContext;
    final box = context?.findRenderObject();
    if (context != null && box is RenderBox && box.attached && box.hasSize) {
      if (!context.mounted) return false;
      await Scrollable.ensureVisible(context, alignment: .2);
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      if (cancelled()) return false;
      final settled = anchors[messageId]?.currentContext?.findRenderObject();
      if (settled is RenderBox && settled.attached && settled.hasSize) {
        return true;
      }
      // A lazy sliver can correct its estimated extent on this frame and
      // unmount the row again. Seek against its corrected layout, not stale keys.
    }
    int? first;
    int? last;
    for (final entry in anchors.entries) {
      final row = entry.value.currentContext?.findRenderObject();
      final index = indices[entry.key];
      if (index == null || row is! RenderBox || !row.attached || !row.hasSize) {
        continue;
      }
      heights[entry.key] = row.size.height;
      if (first == null || index < first) first = index;
      if (last == null || index > last) last = index;
    }
    final position = controller.position;
    final extent = position.maxScrollExtent;
    if ((extent - lastExtent).abs() > 1) {
      // Lazy sliver estimates change as previously unseen long rows mount.
      upper = extent;
      if (lower > upper) lower = 0;
      lastExtent = extent;
    }
    if (first != null && target < first) {
      upper = position.pixels.clamp(lower, extent).toDouble();
    } else if (last != null && target > last) {
      lower = position.pixels.clamp(0, upper).toDouble();
    }
    final average = heights.isEmpty
        ? 160.0
        : heights.values.reduce((a, b) => a + b) / heights.length;
    final estimate =
        64.0 +
        messageIds
            .take(target)
            .fold<double>(0, (height, id) => height + (heights[id] ?? average));
    var next = (pass == 0 ? estimate : (lower + upper) / 2)
        .clamp(0, extent)
        .toDouble();
    if ((next - position.pixels).abs() < .5) {
      final direction = first != null && target < first ? -1 : 1;
      next = (position.pixels + direction * position.viewportDimension * .8)
          .clamp(0, extent)
          .toDouble();
      if ((next - position.pixels).abs() < .5) return false;
    }
    controller.jumpTo(next);
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
  }
  return false;
}
