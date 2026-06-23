import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../../services/motion_controller.dart';
import '../app_palettes.dart';

/// A flowing multi-shade gradient wash behind app content. Builds several
/// *nearby shades* of the palette colours (so it reads as a living gradient, not
/// a flat colour) and sweeps + shimmers them. Active only when the user enables
/// it; motion is gated by the global intensity (battery-aware).
class AnimatedGradientBackground extends StatefulWidget {
  final Widget child;
  const AnimatedGradientBackground({super.key, required this.child});

  @override
  State<AnimatedGradientBackground> createState() =>
      _AnimatedGradientBackgroundState();
}

class _AnimatedGradientBackgroundState extends State<AnimatedGradientBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    );
    AppSettings.instance.addListener(_sync);
    MotionController.instance.scale.addListener(_sync);
    _sync();
  }

  void _sync() {
    final on = AppSettings.instance.animatedGradient;
    final animate = on && MotionController.instance.enabled;
    if (animate) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      if (_ctrl.isAnimating) _ctrl.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_sync);
    MotionController.instance.scale.removeListener(_sync);
    _ctrl.dispose();
    super.dispose();
  }

  /// Nearby shades of [base] colours: a darker, the colour itself, and a
  /// lighter + slightly hue-shifted variant — the "ближайшие оттенки".
  List<Color> _shades(List<Color> palette, Color bg, bool isDark) {
    final raw = <Color>[];
    for (final c in palette) {
      final h = HSLColor.fromColor(c);
      raw.add(h
          .withLightness((h.lightness * 0.72).clamp(0.0, 1.0))
          .withSaturation((h.saturation * 1.1).clamp(0.0, 1.0))
          .toColor());
      raw.add(c);
      raw.add(h
          .withHue((h.hue + 14) % 360)
          .withLightness((h.lightness * 1.22).clamp(0.0, 1.0))
          .toColor());
    }
    // Blend toward the background so content stays readable, but keep enough
    // colour that the sweep between shades is clearly visible.
    final a = isDark ? 0.5 : 0.32;
    return raw
        .map((c) => Color.alphaBlend(c.withValues(alpha: a), bg))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppSettings.instance.animatedGradient) return widget.child;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final base = theme.scaffoldBackgroundColor == Colors.transparent
        ? (isDark ? Colors.black : Colors.white)
        : theme.scaffoldBackgroundColor;
    final pal = paletteFor(AppSettings.instance.appPalette).gradient;
    final shades = _shades(pal, base, isDark);
    // Repeat the shade ring so the sweep always has colour off-screen to pull in.
    final colors = [...shades, ...shades, shades.first];

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) {
        final t = _ctrl.value;
        final a = t * 2 * math.pi;
        // Rotate the gradient axis…
        final begin = Alignment(math.cos(a), math.sin(a));
        final end = Alignment(-math.cos(a), -math.sin(a));
        // …and slide the stops so the bands flow across (the shimmer/перелив).
        final n = colors.length;
        final stops = List<double>.generate(n, (i) {
          final s = (i / (n - 1)) + t;
          return (s - s.floorToDouble()); // wrap into 0..1
        });
        // stops must be ascending for LinearGradient — sort colour/stop pairs.
        final pairs = List.generate(n, (i) => MapEntry(stops[i], colors[i]))
          ..sort((x, y) => x.key.compareTo(y.key));
        return DecoratedBox(
          decoration: BoxDecoration(color: base),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: begin,
                end: end,
                colors: [for (final p in pairs) p.value],
                stops: [for (final p in pairs) p.key],
              ),
            ),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
