import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/material.dart';

/// Bundled Google **Noto Animated Emoji** codes (Apache-2.0 / OFL, free for
/// commercial use). Assets live in assets/animated_emoji/{code}.gif.
const Set<String> _kNotoAnimated = {
  '1f389', '1f440', '1f44b', '1f44c', '1f44d', '1f44e', '1f44f', '1f47b',
  '1f480', '1f4a9', '1f4aa', '1f4af', '1f525', '1f600', '1f601', '1f602',
  '1f603', '1f604', '1f605', '1f606', '1f607', '1f608', '1f609', '1f60a',
  '1f60b', '1f60d', '1f60e', '1f618', '1f61c', '1f61d', '1f621', '1f622',
  '1f624', '1f628', '1f62d', '1f631', '1f634', '1f642', '1f64f', '1f913',
  '1f914', '1f917', '1f918', '1f921', '1f923', '1f929', '1f92a', '1f92b',
  '1f92c', '1f92d', '1f970', '1f973', '1f97a', '2728', '2764_fe0f', '2b50',
};

/// Maps a single emoji grapheme to its bundled Noto code (handling the VS16
/// `fe0f` variation selector), or null if we don't have an animation for it.
String? notoAnimatedCodeFor(String grapheme) {
  final runes = grapheme.runes.toList();
  if (runes.isEmpty) return null;
  final exact = runes.map((r) => r.toRadixString(16)).join('_');
  if (_kNotoAnimated.contains(exact)) return exact;
  final noVs =
      runes.where((r) => r != 0xFE0F).map((r) => r.toRadixString(16)).join('_');
  if (noVs.isNotEmpty && _kNotoAnimated.contains(noVs)) return noVs;
  if (runes.length == 1) {
    final withVs = '${runes.first.toRadixString(16)}_fe0f';
    if (_kNotoAnimated.contains(withVs)) return withVs;
  }
  return null;
}

/// True when [text] is only standard unicode emoji (no letters/digits/commands),
/// up to 6 glyphs. Such messages render as large animated "live" emoji.
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

/// Renders emoji-only messages large. Known emoji play their real Google Noto
/// **animation** (bundled GIF); the rest get a lively bounce/pulse so every
/// emoji you send feels alive.
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
    final size = single ? widget.fontSize * 1.6 : widget.fontSize * 1.15;
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < glyphs.length; i++) _glyph(glyphs[i], i, size),
      ],
    );
  }

  Widget _glyph(String g, int i, double size) {
    final code = notoAnimatedCodeFor(g);
    if (code != null) {
      // Real Noto animation — the GIF plays itself.
      return Image.asset(
        'assets/animated_emoji/$code.gif',
        width: size,
        height: size,
        gaplessPlayback: true,
        cacheWidth: (size * 2).round(),
        errorBuilder: (_, __, ___) => _bounceGlyph(g, i, size),
      );
    }
    return _bounceGlyph(g, i, size);
  }

  Widget _bounceGlyph(String g, int i, double size) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final phase = (_c.value + i * 0.18) % 1.0;
        final b = math.sin(phase * 2 * math.pi);
        return Transform.translate(
          offset: Offset(0, -8.0 * (b > 0 ? b : 0.0)),
          child: Transform.rotate(
            angle: 0.08 * b,
            child: Transform.scale(
              scale: 1.0 + 0.14 * b,
              child: Text(g, style: TextStyle(fontSize: size, height: 1.15)),
            ),
          ),
        );
      },
    );
  }
}
