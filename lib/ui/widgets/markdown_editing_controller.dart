import 'package:flutter/material.dart';

/// A [TextEditingController] that renders inline markdown **live while typing** —
/// `**bold**`, `__underline__`, `~~strike~~`, `` `mono` ``, `_italic_`,
/// `||spoiler||` — so the user sees formatting instead of raw symbols.
///
/// The marker characters are kept (removing them would break cursor/selection
/// math) but dimmed so they fade into the background; the wrapped text is styled.
/// Mirrors the markers that [RichMessageText] renders for sent messages.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  // Order matters: longer/more specific markers first (** before _, __ before _).
  static final _fmtRegex = RegExp(
    r'\*\*([\s\S]*?)\*\*|__([\s\S]*?)__|~~([\s\S]*?)~~|`([\s\S]*?)`|_([\s\S]*?)_|\|\|([\s\S]*?)\|\|',
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final src = text;
    // Don't restyle mid-IME-composition — keeps Android/iOS typing smooth.
    if (src.isEmpty ||
        (withComposing &&
            value.composing.isValid &&
            !value.composing.isCollapsed)) {
      return super
          .buildTextSpan(context: context, style: style, withComposing: withComposing);
    }

    final markerColor = (base.color ?? const Color(0xFF888888)).withValues(
      alpha: 0.30,
    );
    final markerStyle = base.copyWith(color: markerColor);
    final spoilerBg = (base.color ?? const Color(0xFF888888)).withValues(
      alpha: 0.18,
    );

    final spans = <InlineSpan>[];
    var pos = 0;
    for (final m in _fmtRegex.allMatches(src)) {
      if (m.start > pos) {
        spans.add(TextSpan(text: src.substring(pos, m.start), style: base));
      }
      final full = m.group(0)!;
      TextStyle inner = base;
      int markerLen = 0;
      String? content;
      if (m.group(1) != null) {
        inner = base.copyWith(fontWeight: FontWeight.bold);
        markerLen = 2;
        content = m.group(1);
      } else if (m.group(2) != null) {
        inner = base.copyWith(decoration: TextDecoration.underline);
        markerLen = 2;
        content = m.group(2);
      } else if (m.group(3) != null) {
        inner = base.copyWith(decoration: TextDecoration.lineThrough);
        markerLen = 2;
        content = m.group(3);
      } else if (m.group(4) != null) {
        inner = base.copyWith(fontFamily: 'monospace');
        markerLen = 1;
        content = m.group(4);
      } else if (m.group(5) != null) {
        inner = base.copyWith(fontStyle: FontStyle.italic);
        markerLen = 1;
        content = m.group(5);
      } else if (m.group(6) != null) {
        inner = base.copyWith(backgroundColor: spoilerBg);
        markerLen = 2;
        content = m.group(6);
      }
      if (content != null && markerLen > 0 && full.length >= markerLen * 2) {
        spans.add(
            TextSpan(text: full.substring(0, markerLen), style: markerStyle));
        spans.add(TextSpan(text: content, style: inner));
        spans.add(TextSpan(
            text: full.substring(full.length - markerLen), style: markerStyle));
      } else {
        spans.add(TextSpan(text: full, style: base));
      }
      pos = m.end;
    }
    if (pos < src.length) {
      spans.add(TextSpan(text: src.substring(pos), style: base));
    }
    return TextSpan(style: base, children: spans);
  }
}
