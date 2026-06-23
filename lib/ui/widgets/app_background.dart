import 'package:flutter/material.dart';

/// Full-screen themed wallpaper shown behind all app content. The universal
/// background image is cropped to fill the screen (any size / orientation);
/// dark theme → black.png, light theme → light.png. A subtle scrim keeps text
/// legible over the artwork.
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asset = isDark
        ? 'assets/backgrounds/black.png'
        : 'assets/backgrounds/light.png';
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: AssetImage(asset),
              fit: BoxFit.cover,
            ),
          ),
        ),
        // Scrim toward the base colour for readability over the doodles.
        ColoredBox(
          color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.14),
        ),
        child,
      ],
    );
  }
}
