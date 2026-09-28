import 'package:flutter/material.dart';

import '../../services/chat_storage_service.dart';

/// A [TextEditingController] that renders inline markdown **live while typing** —
/// `**bold**`, `__underline__`, `~~strike~~`, `` `mono` ``, `_italic_`,
/// `||spoiler||` — so the user sees formatting instead of raw symbols.
///
/// The marker characters are kept (removing them would break cursor/selection
/// math) but dimmed so they fade into the background; the wrapped text is styled.
/// Mirrors the markers that [RichMessageText] renders for sent messages.
///
/// Also styles `&<64-hex-char-id>` mention tokens (inserted by the @-picker
/// in composer_input_bar.dart) as "@Name" in the composer's accent color —
/// TextField can't host a real rounded chip/avatar inline (no WidgetSpan
/// support in EditableText), so this is the closest a plain TextField gets;
/// the sent message renders the same token as a proper styled span via
/// RichMessageText's own mentionLabelFor.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  // Order matters: longer/more specific markers first (** before _, __ before _).
  static final _fmtRegex = RegExp(
    r'\*\*([\s\S]*?)\*\*|__([\s\S]*?)__|~~([\s\S]*?)~~|`([\s\S]*?)`|_([\s\S]*?)_|\|\|([\s\S]*?)\|\|',
  );
  static final _mentionRegex = RegExp(r'&([0-9a-f]{64})');

  static String? _mentionLabel(String id) {
    for (final c in ChatStorageService.instance.contactsNotifier.value) {
      if (c.publicKeyHex == id) {
        return c.nickname.isNotEmpty ? c.nickname : c.username;
      }
    }
    return null;
  }

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

    final accent = Theme.of(context).colorScheme.primary;
    return TextSpan(style: base, children: _spans(src, base, accent));
  }

  /// Recursively builds styled spans for [src], hiding every marker (at any
  /// nesting level) and merging styles — so `**_bold italic_**` shows with no
  /// `**`/`_` symbols, not just the outer pair.
  ///
  /// Mentions get the same "keep every character, style what should be
  /// hidden into near-invisibility" treatment: a `&<64-hex-id>` token (65
  /// chars) renders as one accent "@" glyph followed by the contact's name
  /// (each name character standing in for one hex character, same
  /// length-preserving substitution `obscureText` uses for password dots),
  /// then whatever hex characters are left over collapsed like a marker.
  /// TextField has no WidgetSpan/rich-chip support, and shortening the
  /// rendered run would desync it from the real text's character offsets —
  /// this is the closest a plain TextField gets to showing a name instead
  /// of a raw id while composing.
  List<InlineSpan> _spans(String src, TextStyle base, Color accent) {
    // Markers hidden: transparent + collapsed width. Kept in text for cursor math.
    final markerStyle = base.copyWith(
      color: const Color(0x00000000),
      fontSize: 0.01,
      letterSpacing: -0.5,
    );
    final spoilerBg =
        (base.color ?? const Color(0xFF888888)).withValues(alpha: 0.18);
    final mentionStyle = base.copyWith(
      color: accent,
      fontWeight: FontWeight.w700,
      backgroundColor: accent.withValues(alpha: 0.12),
    );

    final matches = <RegExpMatch>[
      ..._fmtRegex.allMatches(src),
      ..._mentionRegex.allMatches(src),
    ]..sort((a, b) => a.start.compareTo(b.start));

    final spans = <InlineSpan>[];
    var pos = 0;
    for (final m in matches) {
      if (m.start < pos) continue; // inside an already-consumed outer match
      if (m.start > pos) {
        spans.add(TextSpan(text: src.substring(pos, m.start), style: base));
      }

      if (m.pattern == _mentionRegex) {
        final id = m.group(1)!;
        final label = _mentionLabel(id) ?? '';
        final visible = label.length > 64 ? label.substring(0, 64) : label;
        final hiddenLen = 64 - visible.length;
        spans.add(TextSpan(text: '@', style: mentionStyle));
        if (visible.isNotEmpty) {
          spans.add(TextSpan(text: visible, style: mentionStyle));
        }
        if (hiddenLen > 0) {
          spans.add(TextSpan(
              text: m.group(1)!.substring(0, hiddenLen), style: markerStyle));
        }
        pos = m.end;
        continue;
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
        // Monospace + a code-chip background so `code` reads as formatted.
        inner = base.copyWith(
          fontFamily: 'monospace',
          backgroundColor:
              (base.color ?? const Color(0xFF888888)).withValues(alpha: 0.14),
        );
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
        spans.addAll(
            _spans(content, inner, accent)); // recurse for nested markers
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
    return spans;
  }
}
