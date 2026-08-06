import 'package:flutter/material.dart';

/// Displays a display name, honouring the sender's Premium nickname colour.
///
/// One widget for every place a name is shown (chat list, chat header, peer
/// profile), so the colour can't be applied inconsistently — and so a peer who
/// hasn't set one keeps the normal theme colour.
class NickText extends StatelessWidget {
  final String name;

  /// ARGB value received with the peer's profile; null = default theme colour.
  final int? nickColor;

  final TextStyle? style;
  final int maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;

  const NickText(
    this.name, {
    super.key,
    this.nickColor,
    this.style,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
    this.textAlign,
  });

  /// Keeps a custom colour readable on the current background: very dark
  /// colours on a dark theme (and vice versa) are nudged toward the surface's
  /// contrast instead of disappearing.
  static Color? resolve(BuildContext context, int? value) {
    if (value == null) return null;
    final c = Color(value);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l = c.computeLuminance();
    if (isDark && l < 0.18) {
      return Color.lerp(c, Colors.white, 0.55);
    }
    if (!isDark && l > 0.82) {
      return Color.lerp(c, Colors.black, 0.45);
    }
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final c = resolve(context, nickColor);
    return Text(
      name,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
      style: (style ?? const TextStyle()).copyWith(color: c ?? style?.color),
    );
  }
}

/// The palette offered in the profile editor.
const kNickColors = <int>[
  0xFF1DB954, // green
  0xFF2196F3, // blue
  0xFF7C3AED, // violet
  0xFFE91E63, // pink
  0xFFFF7043, // orange
  0xFFFFC107, // amber
  0xFF00BCD4, // cyan
  0xFF8BC34A, // lime
  0xFFF44336, // red
  0xFF9C27B0, // purple
];
