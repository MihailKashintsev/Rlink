import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../services/motion_controller.dart';

/// A continuous, organically-oscillating audio wave drawn as a single smooth
/// line (like a vibrating string) — replaces the row-of-bars look. Animates
/// while [animating] is true, gated by the global motion intensity.
class WaveLine extends StatefulWidget {
  final double progress; // 0..1 played portion
  final bool animating; // oscillate while true (e.g. during playback / call)
  final Color activeColor;
  final Color inactiveColor;
  final int seed; // stable per-source envelope
  final double strokeWidth;

  const WaveLine({
    super.key,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    this.animating = false,
    this.seed = 0,
    this.strokeWidth = 2.4,
  });

  @override
  State<WaveLine> createState() => _WaveLineState();
}

class _WaveLineState extends State<WaveLine> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    MotionController.instance.scale.addListener(_syncRunning);
    _syncRunning();
  }

  @override
  void didUpdateWidget(covariant WaveLine old) {
    super.didUpdateWidget(old);
    if (old.animating != widget.animating) _syncRunning();
  }

  void _syncRunning() {
    final on = widget.animating && MotionController.instance.enabled;
    if (on) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      if (_ctrl.isAnimating) _ctrl.stop();
    }
  }

  @override
  void dispose() {
    MotionController.instance.scale.removeListener(_syncRunning);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _WaveLinePainter(
          progress: widget.progress,
          phase: _ctrl.value * 2 * math.pi,
          activeColor: widget.activeColor,
          inactiveColor: widget.inactiveColor,
          seed: widget.seed,
          strokeWidth: widget.strokeWidth,
          // Flatter when idle so a paused/unplayed wave reads as calm.
          liveliness: widget.animating ? 1.0 : 0.55,
        ),
      ),
    );
  }
}

class _WaveLinePainter extends CustomPainter {
  final double progress;
  final double phase;
  final Color activeColor;
  final Color inactiveColor;
  final int seed;
  final double strokeWidth;
  final double liveliness;

  const _WaveLinePainter({
    required this.progress,
    required this.phase,
    required this.activeColor,
    required this.inactiveColor,
    required this.seed,
    required this.strokeWidth,
    required this.liveliness,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final midY = size.height / 2;
    if (w <= 0) return;

    // Organic amplitude envelope (stable per seed) so the string isn't a flat sine.
    final rng = math.Random(seed == 0 ? 1 : seed);
    final env = List<double>.generate(9, (_) => 0.45 + rng.nextDouble() * 0.55);
    double envAt(double t) {
      final f = (t.clamp(0.0, 1.0)) * (env.length - 1);
      final i = f.floor().clamp(0, env.length - 2);
      return lerpDouble(env[i], env[i + 1], f - i)!;
    }

    final steps = w.clamp(40, 220).toInt();
    final path = Path();
    final maxAmp = midY * 0.92 * liveliness;
    for (var s = 0; s <= steps; s++) {
      final t = s / steps;
      final x = t * w;
      final a = maxAmp * envAt(t);
      // Two travelling components → a lively, string-like wave.
      final y = midY +
          a *
              (math.sin(t * math.pi * 7 + phase) * 0.72 +
                  math.sin(t * math.pi * 15 - phase * 1.4) * 0.28);
      if (s == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // Inactive (full) line first…
    stroke.color = inactiveColor;
    canvas.drawPath(path, stroke);
    // …then the played portion in the active colour, clipped to progress.
    final splitX = progress.clamp(0.0, 1.0) * w;
    if (splitX > 0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, splitX, size.height));
      stroke.color = activeColor;
      canvas.drawPath(path, stroke);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_WaveLinePainter old) =>
      old.progress != progress ||
      old.phase != phase ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      old.liveliness != liveliness ||
      old.seed != seed;
}
