import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../app_palettes.dart';

/// Flowing, glowing gradient backdrop in the spirit of the animated intro
/// (Brand gradient + soft accent blobs). Painted behind screen content when the
/// "new design" mode is on; otherwise it just shows the flat themed background.
///
/// Cheap: two animated radial gradients over the base colour, ~20s loop.
class AuroraBackground extends StatefulWidget {
  final Widget child;
  final double intensity; // 0..1 opacity multiplier for the glow
  const AuroraBackground({super.key, required this.child, this.intensity = 1});

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 22),
  );

  @override
  void initState() {
    super.initState();
    _maybeAnimate();
    AppSettings.instance.addListener(_maybeAnimate);
  }

  void _maybeAnimate() {
    final s = AppSettings.instance;
    final on = s.newDesign && s.animationLevel > 0.05;
    if (on && !_c.isAnimating) {
      _c.repeat();
    } else if (!on && _c.isAnimating) {
      _c.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_maybeAnimate);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    final theme = Theme.of(context);

    // Old design: true no-op (screens keep their own backgrounds).
    if (!s.newDesign) return widget.child;

    final palette = paletteFor(s.appPalette);
    final isDark = palette.dark ?? (theme.brightness == Brightness.dark);
    // Solid base from the palette so transparent scaffolds sit on it.
    final base = palette.background ?? (isDark ? Colors.black : Colors.white);
    final g = palette.gradient;
    final c1 = g.isNotEmpty ? g[0] : theme.colorScheme.primary;
    final c2 = g.length > 1 ? g[1] : theme.colorScheme.primary;
    final glow = widget.intensity * (isDark ? 1.0 : 0.7);

    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value * 2 * math.pi;
        final a1 = Alignment(0.55 * math.cos(t), -0.4 + 0.35 * math.sin(t * 0.8));
        final a2 =
            Alignment(-0.6 * math.cos(t * 0.7), 0.45 - 0.3 * math.sin(t));
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: base),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: a1,
                  radius: 1.15,
                  colors: [
                    c1.withValues(alpha: 0.30 * glow),
                    c1.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.62],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: a2,
                  radius: 1.25,
                  colors: [
                    c2.withValues(alpha: 0.24 * glow),
                    c2.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.64],
                ),
              ),
            ),
            // Vignette toward the base colour keeps content legible.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    base.withValues(alpha: 0.35),
                    base.withValues(alpha: 0.0),
                    base.withValues(alpha: 0.45),
                  ],
                  stops: const [0.0, 0.4, 1.0],
                ),
              ),
            ),
            widget.child,
          ],
        );
      },
    );
  }
}

/// A gradient + glow circular button in the intro's badge style — for FABs and
/// prominent actions when the new design is on.
class GlowGradientCircle extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onTap;
  final String? tooltip;
  const GlowGradientCircle({
    super.key,
    required this.icon,
    this.size = 56,
    this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final palette = paletteFor(AppSettings.instance.appPalette);
    final a = palette.accentColor;
    final b = Color.lerp(a, cs.tertiary, 0.5) ?? a;
    final onAccent =
        a.computeLuminance() > 0.55 ? const Color(0xFF0A0A0A) : Colors.white;
    final btn = GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [a, b],
          ),
          boxShadow: [
            BoxShadow(
              color: a.withValues(alpha: 0.5),
              blurRadius: 22,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Icon(icon, color: onAccent, size: size * 0.46),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}
