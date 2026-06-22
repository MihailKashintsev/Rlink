import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/motion_controller.dart';

/// A continuous, oscillating audio wave drawn as a single smooth line (like a
/// vibrating string). Its size can either be procedural (decorative) or follow
/// the *real* sound:
///   • [samples] — a fixed amplitude envelope (e.g. a decoded voice message);
///   • [level]   — a live amplitude (0..1), e.g. the call's audio level, kept
///                 as a scrolling history so the wave reacts to the live sound.
/// When neither is given it falls back to a per-[seed] procedural envelope.
class WaveLine extends StatefulWidget {
  final double progress; // 0..1 played portion
  final bool animating; // oscillate while true (e.g. during playback / call)
  final Color activeColor;
  final Color inactiveColor;
  final int seed; // stable per-source envelope (procedural fallback)
  final double strokeWidth;
  final List<double>? samples; // real amplitude envelope (0..1 each)
  final ValueListenable<double>? level; // live amplitude (0..1) for calls

  const WaveLine({
    super.key,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    this.animating = false,
    this.seed = 0,
    this.strokeWidth = 2.4,
    this.samples,
    this.level,
  });

  @override
  State<WaveLine> createState() => _WaveLineState();
}

class _WaveLineState extends State<WaveLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  // Scrolling history of live levels (call mode).
  static const _historyLen = 56;
  List<double>? _history;

  bool get _liveMode => widget.level != null;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (_liveMode) {
      _history = List<double>.filled(_historyLen, 0.0);
      widget.level!.addListener(_onLevel);
    }
    MotionController.instance.scale.addListener(_syncRunning);
    _syncRunning();
  }

  @override
  void didUpdateWidget(covariant WaveLine old) {
    super.didUpdateWidget(old);
    if (old.level != widget.level) {
      old.level?.removeListener(_onLevel);
      if (widget.level != null) {
        _history ??= List<double>.filled(_historyLen, 0.0);
        widget.level!.addListener(_onLevel);
      }
    }
    if (old.animating != widget.animating) _syncRunning();
  }

  void _onLevel() {
    final h = _history;
    if (h == null) return;
    // Shift left, append the newest level → scrolling live waveform.
    for (var i = 0; i < h.length - 1; i++) {
      h[i] = h[i + 1];
    }
    h[h.length - 1] = widget.level!.value.clamp(0.0, 1.0);
  }

  void _syncRunning() {
    final on =
        (widget.animating || _liveMode) && MotionController.instance.enabled;
    if (on) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      if (_ctrl.isAnimating) _ctrl.stop();
    }
  }

  @override
  void dispose() {
    widget.level?.removeListener(_onLevel);
    MotionController.instance.scale.removeListener(_syncRunning);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final samples = _liveMode ? _history : widget.samples;
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
          samples: samples,
          // Flatter when idle so a paused/unplayed wave reads as calm.
          liveliness: (widget.animating || _liveMode) ? 1.0 : 0.6,
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
  final List<double>? samples;

  const _WaveLinePainter({
    required this.progress,
    required this.phase,
    required this.activeColor,
    required this.inactiveColor,
    required this.seed,
    required this.strokeWidth,
    required this.liveliness,
    required this.samples,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final midY = size.height / 2;
    if (w <= 0) return;

    final real = samples != null && samples!.isNotEmpty;

    // Amplitude envelope. Real data when available, else an organic per-seed
    // envelope so the string isn't a flat sine.
    final List<double> env;
    if (real) {
      env = samples!;
    } else {
      final rng = math.Random(seed == 0 ? 1 : seed);
      env = List<double>.generate(9, (_) => 0.45 + rng.nextDouble() * 0.55);
    }
    double envAt(double t) {
      if (env.length == 1) return env[0];
      final f = (t.clamp(0.0, 1.0)) * (env.length - 1);
      final i = f.floor().clamp(0, env.length - 2);
      return lerpDouble(env[i], env[i + 1], f - i)!;
    }

    final steps = w.clamp(40, 240).toInt();
    final path = Path();
    final maxAmp = midY * 0.92 * liveliness;
    for (var s = 0; s <= steps; s++) {
      final t = s / steps;
      final x = t * w;
      final a = maxAmp * envAt(t);
      // Carrier oscillation modulated by the (real or procedural) envelope.
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
      old.seed != seed ||
      !identical(old.samples, samples);
}
