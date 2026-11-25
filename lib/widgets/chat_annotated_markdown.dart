import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../models/chat_annotation.dart';
import 'chat_annotation_controls.dart';

/// Context only for pending annotations on this source message. Unannotated and
/// streaming messages retain the application's existing GptMarkdown path.
class ChatInlineAnnotationScope extends InheritedWidget {
  const ChatInlineAnnotationScope({
    required this.annotations,
    required this.numbers,
    required this.onTap,
    required this.onRendered,
    required super.child,
    super.key,
  });
  final List<ChatAnnotation> annotations;
  final Map<String, int> numbers;
  final void Function(ChatAnnotation, Offset) onTap;
  final ValueChanged<Set<String>> onRendered;

  @override
  bool updateShouldNotify(ChatInlineAnnotationScope oldWidget) => true;
}

class ChatAnnotatedMarkdown extends StatelessWidget {
  const ChatAnnotatedMarkdown({required this.markdown, super.key});
  final GptMarkdown markdown;

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ChatInlineAnnotationScope>();
    if (scope == null || scope.annotations.isEmpty || markdown.isStreaming) {
      return markdown;
    }
    // These are the same config fields supplied by the home chat renderer.
    // Use the installed 1.3.0 renderer, including its link/code span tags and
    // RevealableSpan block rebuilding hook; never edit the Markdown source.
    final config = GptMarkdownConfig(
      style: markdown.style,
      styleSheet: markdown.styleSheet,
      textDirection: markdown.textDirection,
      textAlign: markdown.textAlign,
      textScaler: markdown.textScaler,
      inlineLinkBuilder: markdown.inlineLinkBuilder,
      onLinkTap: markdown.onLinkTap,
      onSourceTagTap: markdown.onSourceTagTap,
      inlineSourceTagBuilder: markdown.inlineSourceTagBuilder,
      inlinePatterns: markdown.inlinePatterns,
      followLinkColor: markdown.followLinkColor,
      autolink: markdown.autolink,
      autolinkSchemes: markdown.autolinkSchemes,
      blocksRenderDirectly: true,
    );
    final source = markdown.data.replaceAll('\r\n', '\n').trim();
    final segments = splitStreamSegments(source);
    List<InlineSpan> segmentSpans(String segment) {
      final rendered = PlusparseRenderer.render(context, segment, config);
      final content = rendered
          .where((span) => !_isBlockSeparator(span))
          .toList();
      // The official static path drops the separating newline spans when it
      // lifts a list's blocks into widgets. They are not selectable characters.
      return content.isNotEmpty &&
              content.every((span) => _blockWidget(span) != null)
          ? content
          : rendered;
    }

    final spans = <InlineSpan>[
      for (final segment in segments) TextSpan(children: segmentSpans(segment)),
    ];
    final pinned = <String>{};
    final transformed = insertChatAnnotationPins(spans, scope.annotations, (
      annotation,
    ) {
      pinned.add(annotation.id);
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _InlinePinLayout(
          child: SelectionContainer.disabled(
            child: ChatInlineAnnotationPin(
              key: ValueKey('inline-annotation:${annotation.id}'),
              number: scope.numbers[annotation.id] ?? 1,
              onTap: (anchor) => scope.onTap(annotation, anchor),
            ),
          ),
        ),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => scope.onRendered(pinned),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < transformed.length; i++) ...[
          if (i > 0) SizedBox(height: blockGap(context, config)),
          _renderGroup((transformed[i] as TextSpan).children!, config),
        ],
      ],
    );
  }

  // Match the installed renderer's static block path: block widgets keep their
  // own layout, while paragraphs keep the official bidi/link/code renderer.
  Widget _renderGroup(List<InlineSpan> spans, GptMarkdownConfig config) {
    final blocks = <Widget>[];
    for (final span in spans) {
      final child = _blockWidget(span);
      if (child != null) {
        blocks.add(child);
      } else if (!_isBlockSeparator(span)) {
        return config.getRich(
          TextSpan(style: markdown.style, children: spans),
          isRoot: true,
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
  }
}

bool _isBlockSeparator(InlineSpan span) =>
    span is TextSpan &&
    span.children == null &&
    (span.text ?? '').trim().isEmpty;

Widget? _blockWidget(InlineSpan span) {
  if (span is RevealableSpan && span.children?.length == 1) {
    span = span.children!.single;
  }
  if (span is TextSpan && span.text == null && span.children?.length == 1) {
    span = span.children!.single;
  }
  return span is BlockWidgetSpan ? span.bare ?? span.child : null;
}

class _InlinePinLayout extends SingleChildRenderObjectWidget {
  const _InlinePinLayout({required super.child});
  @override
  RenderChatInlineAnnotationPin createRenderObject(BuildContext context) =>
      RenderChatInlineAnnotationPin();
}

/// Excluded from the source-text projection used to locate annotation quotes.
class RenderChatInlineAnnotationPin extends RenderProxyBox {}

/// Reuses the frozen pin SVG at text size. Its layout box reserves real inline
/// space, so a full line wraps and two annotations cannot cover one another.
class ChatInlineAnnotationPin extends StatelessWidget {
  const ChatInlineAnnotationPin({
    required this.number,
    required this.onTap,
    super.key,
  });
  final int number;
  final ValueChanged<Offset> onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '注释 $number',
    child: Builder(
      builder: (pinContext) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final box = pinContext.findRenderObject() as RenderBox;
          onTap(box.localToGlobal(Offset(box.size.width / 2, box.size.height)));
        },
        child: SizedBox(
          width: 24,
          height: 27,
          child: FittedBox(
            fit: BoxFit.contain,
            child: IgnorePointer(
              child: ChatAnnotationPin(number: number, onTap: () {}),
            ),
          ),
        ),
      ),
    ),
  );
}

String _spanText(InlineSpan span) {
  if (span is RevealableSpan) return span.content.map(_spanText).join();
  if (span is TextSpan) {
    return '${span.text ?? ''}${span.children?.map(_spanText).join() ?? ''}';
  }
  return '\uFFFC';
}

/// Offsets belong to rendered text, not raw Markdown. Matching uses the existing
/// whitespace-normalized quote locator and preferred offset for repeated text.
List<InlineSpan> insertChatAnnotationPins(
  List<InlineSpan> spans,
  List<ChatAnnotation> annotations,
  InlineSpan Function(ChatAnnotation) pin,
) {
  final plain = spans.map(_spanText).join();
  final endings = <int, List<ChatAnnotation>>{};
  for (final annotation in annotations) {
    final range = locateChatQuote(
      plain,
      annotation.quote,
      annotation.startOffset,
    );
    // An opaque block does not publish its selectable character count. Do not
    // guess which repeated quote after it was selected; keep the list entry.
    if (range != null && plain.substring(0, range.end).contains('\uFFFC')) {
      final first = locateChatQuote(plain, annotation.quote, 0);
      final last = locateChatQuote(plain, annotation.quote, plain.length);
      if (first?.start != last?.start) continue;
    }
    if (range != null) (endings[range.end] ??= []).add(annotation);
  }
  var cursor = 0;
  List<InlineSpan> walk(List<InlineSpan> input) {
    final out = <InlineSpan>[];
    for (final span in input) {
      final size = _spanText(span).length;
      final containsPin = endings.keys.any(
        (end) => end > cursor && end <= cursor + size,
      );
      if (!containsPin) {
        out.add(span);
        cursor += size;
        continue;
      }
      if (span is RevealableSpan) {
        final base = cursor;
        out.add(
          span.rebuild((inner) {
            cursor = base;
            return walk(inner);
          }),
        );
        cursor = base + size;
        continue;
      }
      if (span is! TextSpan) {
        out.add(span);
        cursor += size;
        continue;
      }
      final pieces = <InlineSpan>[];
      final text = span.text ?? '';
      final base = cursor;
      var consumed = 0;
      final positions =
          endings.keys
              .where((end) => end > base && end <= base + text.length)
              .toList()
            ..sort();
      for (final end in positions) {
        final local = end - base;
        pieces.add(
          TextSpan(
            text: text.substring(consumed, local),
            recognizer: span.recognizer,
          ),
        );
        pieces.addAll(endings[end]!.map(pin));
        consumed = local;
      }
      if (consumed < text.length) {
        pieces.add(
          TextSpan(text: text.substring(consumed), recognizer: span.recognizer),
        );
      }
      cursor += text.length;
      if (span.children != null) pieces.addAll(walk(span.children!));
      out.add(switch (span) {
        CodeTextSpan() => CodeTextSpan.revealing(
          children: pieces,
          codeStyle: span.codeStyle,
          style: span.style,
          recognizer: span.recognizer,
          mouseCursor: span.mouseCursor,
        ),
        LinkTextSpan() => LinkTextSpan.wrapping(
          children: pieces,
          url: span.url,
          linkStyle: span.linkStyle,
          onTap: span.onTap,
          hoverStyle: span.hoverStyle,
          style: span.style,
          mouseCursor: span.mouseCursor,
        ),
        TappableTextSpan() => TappableTextSpan.wrapping(
          children: pieces,
          onTap: span.onTap,
          hoverStyle: span.hoverStyle,
          style: span.style,
          mouseCursor: span.mouseCursor,
        ),
        _ => TextSpan(
          children: pieces,
          style: span.style,
          recognizer: span.recognizer,
          mouseCursor: span.mouseCursor,
          onEnter: span.onEnter,
          onExit: span.onExit,
          locale: span.locale,
          spellOut: span.spellOut,
        ),
      });
    }
    return out;
  }

  return walk(spans);
}
