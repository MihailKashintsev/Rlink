import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../../services/motion_controller.dart';
import '../app_palettes.dart';

/// A gently flowing multi-colour gradient wash that sits behind app content.
/// Active only when the user enables it (AppSettings.animatedGradient); the
/// flow animation is gated by the global motion intensity (battery-aware).
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
      duration: const Duration(seconds: 9),
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

  @override
  Widget build(BuildContext context) {
    if (!AppSettings.instance.animatedGradient) return widget.child;
    final base = Theme.of(context).scaffoldBackgroundColor;
    final pal = paletteFor(AppSettings.instance.appPalette).gradient;
    // Tint the palette toward the base so content stays readable.
    final colors = pal
        .map((c) => Color.alphaBlend(c.withValues(alpha: 0.42), base))
        .toList();
    final solidBase = base == Colors.transparent
        ? (Theme.of(context).colorScheme.surface)
        : base;

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) {
        final a = _ctrl.value * 2 * math.pi;
        final begin = Alignment(math.cos(a), math.sin(a));
        final end = Alignment(-math.cos(a), -math.sin(a));
        return DecoratedBox(
          decoration: BoxDecoration(color: solidBase),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: begin,
                end: end,
                colors: colors,
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
