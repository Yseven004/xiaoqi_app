import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A capability stored at one object-replacement character in the composer.
class CapabilityTextTag {
  CapabilityTextTag({required this.offset, required Map<String, Object?> data})
    : data = Map<String, Object?>.unmodifiable(data);

  /// UTF-16 offset in the controller value, including preceding tag markers.
  final int offset;
  final Map<String, Object?> data;

  CapabilityTextTag copyAt(int nextOffset) =>
      CapabilityTextTag(offset: nextOffset, data: data);
}

/// In-memory composer draft, including the metadata hidden behind inline tags.
class CapabilityTextSnapshot {
  const CapabilityTextSnapshot({required this.value, this.tag});

  final TextEditingValue value;
  final CapabilityTextTag? tag;
}

/// Keeps each capability as one editable inline unit in a standard TextField.
class CapabilityTagTextController extends TextEditingController {
  static const objectMarker = '\uFFFC';

  CapabilityTextTag? _tag;
  bool _settingTaggedValue = false;

  String get messageText => text.replaceAll(objectMarker, '');

  CapabilityTextSnapshot snapshot() =>
      CapabilityTextSnapshot(value: value, tag: _tag);

  void restore(CapabilityTextSnapshot snapshot) {
    _tag = snapshot.tag;
    _setTaggedValue(snapshot.value);
  }

  /// Removes selected capabilities while keeping any message text and caret.
  void clearCapabilities() {
    final tag = _tag;
    if (tag == null) return;
    final nextText = text.replaceAll(objectMarker, '');
    final oldCaret = value.selection.extentOffset;
    _tag = null;
    _setTaggedValue(
      TextEditingValue(
        text: nextText,
        selection: TextSelection.collapsed(
          offset: (oldCaret - (tag.offset < oldCaret ? 1 : 0))
              .clamp(0, nextText.length)
              .toInt(),
        ),
      ),
    );
  }

  /// Inserts at the selection and replaces any selected text or whole tags.
  void insertCapability(Map<String, Object?> metadata) {
    // Keep the existing inline unit, but let its selection contain multiple
    // extensions. Selecting the same extension twice does not duplicate it.
    if (metadata['type'] != 'action' &&
        _tag != null &&
        _tag!.data['type'] != 'action') {
      final existing = _tag!.data;
      final selections = (existing['selected_capabilities'] is List
          ? (existing['selected_capabilities'] as List)
                .whereType<Map>()
                .map((v) => Map<String, Object?>.from(v))
                .toList()
          : [Map<String, Object?>.from(existing)]);
      selections.removeWhere((v) => v['id'] == metadata['id']);
      selections.add(Map<String, Object?>.from(metadata));
      if (selections.length > 16) return;
      metadata = {
        ...metadata,
        'name': selections.map((v) => v['name']).join('、'),
        'selected_capabilities': selections,
      };
    }
    final selectionStart = value.selection.isValid
        ? value.selection.start
        : value.text.length;
    final selectionEnd = value.selection.isValid
        ? value.selection.end
        : selectionStart;
    final existingTag = _tag;
    final cleanText = text.replaceAll(objectMarker, '');
    final start =
        (selectionStart -
                (existingTag != null && existingTag.offset < selectionStart
                    ? 1
                    : 0))
            .clamp(0, cleanText.length)
            .toInt();
    final end =
        (selectionEnd -
                (existingTag != null && existingTag.offset < selectionEnd
                    ? 1
                    : 0))
            .clamp(start, cleanText.length)
            .toInt();
    final before = cleanText.substring(0, start);
    final after = cleanText.substring(end);
    _tag = CapabilityTextTag(offset: start, data: metadata);
    _setTaggedValue(
      TextEditingValue(
        text: '$before$objectMarker$after',
        selection: TextSelection.collapsed(offset: start + 1),
      ),
    );
  }

  /// Recreates a sent message while keeping its tag at the original text offset.
  void setMessage(String message, Map<String, Object?>? metadata) {
    final offset = metadata?['composer_text_offset'] is int
        ? (metadata!['composer_text_offset'] as int)
              .clamp(0, message.length)
              .toInt()
        : 0;
    if (metadata == null) {
      _tag = null;
      _setTaggedValue(
        TextEditingValue(
          text: message,
          selection: TextSelection.collapsed(offset: message.length),
        ),
      );
      return;
    }
    final tagData = Map<String, Object?>.from(metadata)
      ..['composer_text_offset'] = offset;
    _tag = CapabilityTextTag(offset: offset, data: tagData);
    _setTaggedValue(
      TextEditingValue(
        text:
            '${message.substring(0, offset)}$objectMarker${message.substring(offset)}',
        selection: TextSelection.collapsed(offset: offset + 1),
      ),
    );
  }

  Map<String, Object?>? messageMetadata() {
    final tag = _tag;
    if (tag == null) return null;
    return Map<String, Object?>.from(tag.data)
      ..['composer_text_offset'] = tag.offset;
  }

  @override
  set value(TextEditingValue newValue) {
    if (!_settingTaggedValue) _reconcileTags(text, newValue.text);
    super.value = newValue;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final tag = _tag;
    if (tag == null) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    if (tag.offset > cursor) {
      _appendText(spans, cursor, tag.offset, style, withComposing);
    }
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: CapabilityInlineTag(
          data: tag.data,
          textStyle: style,
          emphasize: true,
        ),
      ),
    );
    cursor = tag.offset + 1;
    if (cursor < text.length) {
      _appendText(spans, cursor, text.length, style, withComposing);
    }
    return TextSpan(style: style, children: spans);
  }

  void _appendText(
    List<InlineSpan> spans,
    int start,
    int end,
    TextStyle? style,
    bool withComposing,
  ) {
    final composing = value.composing;
    final hasComposing =
        withComposing && composing.isValid && !composing.isCollapsed;
    final cuts = <int>{start, end};
    if (hasComposing) {
      if (composing.start > start && composing.start < end) {
        cuts.add(composing.start);
      }
      if (composing.end > start && composing.end < end) cuts.add(composing.end);
    }
    final points = cuts.toList()..sort();
    for (var index = 0; index < points.length - 1; index++) {
      final from = points[index];
      final to = points[index + 1];
      final composingPart =
          hasComposing && from >= composing.start && to <= composing.end;
      spans.add(
        TextSpan(
          text: text.substring(from, to),
          style: composingPart
              ? (style ?? const TextStyle()).copyWith(
                  decoration: TextDecoration.underline,
                )
              : style,
        ),
      );
    }
  }

  void _reconcileTags(String oldText, String newText) {
    final tag = _tag;
    if (tag == null || oldText == newText) return;
    var prefix = 0;
    final sharedLength = oldText.length < newText.length
        ? oldText.length
        : newText.length;
    while (prefix < sharedLength &&
        oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix++;
    }
    var oldEnd = oldText.length;
    var newEnd = newText.length;
    while (oldEnd > prefix &&
        newEnd > prefix &&
        oldText.codeUnitAt(oldEnd - 1) == newText.codeUnitAt(newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }
    if (tag.offset < prefix) return;
    if (tag.offset >= oldEnd) {
      _tag = tag.copyAt(tag.offset + newEnd - oldEnd);
    } else {
      _tag = null;
    }
  }

  void _setTaggedValue(TextEditingValue nextValue) {
    _settingTaggedValue = true;
    try {
      super.value = nextValue;
    } finally {
      _settingTaggedValue = false;
    }
  }
}

class CapabilityMessageText extends StatelessWidget {
  const CapabilityMessageText({
    required this.message,
    required this.metadata,
    required this.textStyle,
    super.key,
  });

  final String message;
  final Map<String, Object?>? metadata;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final capability = metadata;
    if (capability == null) {
      return Text(message, style: textStyle);
    }
    final rawOffset = capability['composer_text_offset'];
    final offset = rawOffset is int
        ? rawOffset.clamp(0, message.length).toInt()
        : 0;
    return Text.rich(
      TextSpan(
        style: textStyle,
        children: [
          if (offset > 0) TextSpan(text: message.substring(0, offset)),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: CapabilityInlineTag(data: capability, textStyle: textStyle),
          ),
          if (offset < message.length)
            TextSpan(text: message.substring(offset)),
        ],
      ),
    );
  }
}

class CapabilityInlineTag extends StatelessWidget {
  const CapabilityInlineTag({
    required this.data,
    this.textStyle,
    this.emphasize = false,
    this.onTap,
    super.key,
  });

  final Map<String, Object?> data;
  final TextStyle? textStyle;
  final bool emphasize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final name = data['name']?.toString() ?? '能力';
    final inheritedStyle = textStyle ?? DefaultTextStyle.of(context).style;
    final tagContent = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SvgPicture.asset(
          'assets/images/reading_sidebar_wrench.svg',
          width: 18,
          height: 18,
        ),
        const SizedBox(width: 5),
        Text(
          name,
          style: inheritedStyle.copyWith(
            color: const Color(0xFFB54D76),
            fontSize: emphasize
                ? (inheritedStyle.fontSize ?? 16)
                : (inheritedStyle.fontSize ?? 16) - 1,
            fontWeight: emphasize ? FontWeight.w600 : inheritedStyle.fontWeight,
            height: 1.2,
          ),
        ),
        const SizedBox(width: 6),
      ],
    );
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xEFFFFFFF), Color(0xBFFFFFFF)],
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Color(0xB3FFFFFF), width: 0.8),
        boxShadow: [
          BoxShadow(
            color: const Color(0x1F202A44),
            blurRadius: emphasize ? 8 : 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: tagContent,
    );
    return Semantics(
      label: '$name，能力标签',
      button: onTap != null,
      onTap: onTap,
      child: onTap == null
          ? tag
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: tag,
            ),
    );
  }
}
