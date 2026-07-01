import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/material.dart';

/// True when [text] is only standard unicode emoji (no letters/digits/commands),
/// up to 6 glyphs. Such messages render as large, gently animated "live" emoji.
bool isEmojiOnlyMessage(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (RegExp(r'[A-Za-z0-9А-Яа-яЁё@#/:]').hasMatch(t)) return false;
  final noSpace = t.replaceAll(RegExp(r'\s'), '');
  if (noSpace.isEmpty) return false;
  final graphemes = noSpace.characters.toList();
  if (graphemes.length > 6) return false;
  return t.runes.any((r) =>
      r >= 0x1F000 ||
      (r >= 0x2600 && r <= 0x27BF) ||
      (r >= 0x2190 && r <= 0x21FF) ||
      (r >= 0x2B00 && r <= 0x2BFF) ||
      r == 0x2764 ||
      r == 0x203C ||
      r == 0x2049);
}

/// Renders emoji-only messages large with a looping bounce/pulse/wiggle so any
/// emoji you send feels alive — a built-in animated-emoji effect for everyone.
class AnimatedEmojiText extends StatefulWidget {
  final String text;
  final double fontSize;
  const AnimatedEmojiText({super.key, required this.text, this.fontSize = 40});

  @override
  State<AnimatedEmojiText> createState() => _AnimatedEmojiTextState();
}

class _AnimatedEmojiTextState extends State<AnimatedEmojiText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glyphs =
        widget.text.trim().replaceAll(RegExp(r'\s'), '').characters.toList();
    final single = glyphs.length == 1;
    final size = single ? widget.fontSize * 1.45 : widget.fontSize;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            for (var i = 0; i < glyphs.length; i++)
              _glyph(glyphs[i], i, size),
          ],
        );
      },
    );
  }

  Widget _glyph(String g, int i, double size) {
    final phase = (_c.value + i * 0.18) % 1.0;
    final b = math.sin(phase * 2 * math.pi);
    final scale = 1.0 + 0.14 * b;
    final dy = -8.0 * (b > 0 ? b : 0.0);
    final rot = 0.08 * b;
    return Transform.translate(
      offset: Offset(0, dy),
      child: Transform.rotate(
        angle: rot,
        child: Transform.scale(
          scale: scale,
          child: Text(g, style: TextStyle(fontSize: size, height: 1.15)),
        ),
      ),
    );
  }
}
