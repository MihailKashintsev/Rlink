import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Custom-drawn bottom-nav glyphs. Each icon is a stroke path on a 24 grid and
/// carries its own motion, driven by ONE selection spring (0 = idle, 1 =
/// selected). The spring starts from the live value + velocity, so rapid tab
/// switches interrupt and re-target cleanly (apple-design), and it collapses to
/// an instant jump under reduce-motion. Two icons morph to a stable selected
/// state (chats grows its dots, settings slides its knobs); two fire a transient
/// emission during the switch (nearby pings, ether broadcasts).
enum NavGlyph { chats, nearby, ether, settings, search }

class AnimatedNavGlyph extends StatefulWidget {
  final NavGlyph glyph;
  final bool selected;
  final Color color;
  final double size;

  const AnimatedNavGlyph({
    super.key,
    required this.glyph,
    required this.selected,
    required this.color,
    this.size = 24,
  });

  @override
  State<AnimatedNavGlyph> createState() => _AnimatedNavGlyphState();
}

class _AnimatedNavGlyphState extends State<AnimatedNavGlyph>
    with SingleTickerProviderStateMixin {
  // Unbounded so the spring can overshoot past 1 — that overshoot is the life
  // in the dots popping and the knobs settling.
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: widget.selected ? 1 : 0,
  );

  // Critically-damped-ish with a hair of bounce; response ~0.36s. A tab tap has
  // a little snap, so a small overshoot (ratio 0.82) reads right, not fidgety.
  static final SpringDescription _spring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 0.82);

  void _to(double target) {
    if (!mounted) return;
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = target;
      return;
    }
    _c.animateWith(SpringSimulation(_spring, _c.value, target, _c.velocity));
  }

  @override
  void didUpdateWidget(covariant AnimatedNavGlyph old) {
    super.didUpdateWidget(old);
    if (widget.selected != old.selected) _to(widget.selected ? 1 : 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _GlyphPainter(widget.glyph, _c, widget.color),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  final NavGlyph glyph;
  final Animation<double> anim;
  final Color color;

  _GlyphPainter(this.glyph, this.anim, this.color) : super(repaint: anim);

  @override
  void paint(Canvas canvas, Size size) {
    final t = anim.value;
    switch (glyph) {
      case NavGlyph.chats:
        _chats(canvas, size, t);
      case NavGlyph.nearby:
        _nearby(canvas, size, t);
      case NavGlyph.ether:
        _ether(canvas, size, t);
      case NavGlyph.settings:
        _settings(canvas, size, t);
      case NavGlyph.search:
        _search(canvas, size);
    }
  }

  // 24-unit grid → pixels.
  double _u(Size s, double v) => v / 24.0 * s.width;

  Paint _stroke(Size s, {double? width, double? alpha}) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = _u(s, width ?? 2.1)
    ..color = alpha == null ? color : color.withValues(alpha: alpha);

  Paint _fill({double? alpha}) => Paint()
    ..style = PaintingStyle.fill
    ..color = alpha == null ? color : color.withValues(alpha: alpha);

  // ── Чаты: speech bubble with a tail; three dots pop in when selected ──
  void _chats(Canvas canvas, Size s, double t) {
    double u(double v) => _u(s, v);
    final body = RRect.fromRectAndRadius(
      Rect.fromLTRB(u(3.5), u(4), u(20.5), u(15)),
      Radius.circular(u(5)),
    );
    final path = Path()..addRRect(body);
    // Tail hanging off the bottom-left.
    path.moveTo(u(8.5), u(14.6));
    path.lineTo(u(6.4), u(19.2));
    path.lineTo(u(12.4), u(14.6));
    canvas.drawPath(path, _stroke(s));

    // Dots grow in, staggered — selected chat = an active bubble.
    const xs = [8.2, 12.0, 15.8];
    final cy = u(9.5);
    final maxR = u(1.45);
    for (var i = 0; i < 3; i++) {
      final st = (t * 1.34 - i * 0.17).clamp(0.0, 1.15);
      if (st <= 0.02) continue;
      canvas.drawCircle(Offset(u(xs[i]), cy), maxR * st, _fill());
    }
  }

  // ── Рядом: a radar scope — the sweep line makes one turn per selection and
  // lights the blip as it passes it. Round silhouette, unlike the ether waves.
  void _nearby(Canvas canvas, Size s, double t) {
    double u(double v) => _u(s, v);
    final c = Offset(u(12), u(12));
    final rOuter = u(8.6);
    canvas.drawCircle(c, rOuter, _stroke(s, width: 2.0, alpha: 0.9));
    canvas.drawCircle(c, u(4.7), _stroke(s, width: 1.5, alpha: 0.4));
    canvas.drawCircle(c, u(1.3), _fill());

    // Sweep rests on a diagonal (a straight-up line + circle reads as a power
    // button); one full turn per selection, spring-eased.
    final ang = -math.pi / 4 + t * 2 * math.pi;
    final trail = Path()
      ..moveTo(c.dx, c.dy)
      ..arcTo(
          Rect.fromCircle(center: c, radius: rOuter), ang - 0.85, 0.85, false)
      ..close();
    canvas.drawPath(trail, _fill(alpha: 0.16));
    canvas.drawLine(c, c + Offset(math.cos(ang), math.sin(ang)) * rOuter,
        _stroke(s, width: 1.8, alpha: 0.95));

    // Blip: brightest just after the sweep passes, fading until the next pass.
    const blipAng = math.pi * 0.32; // lower-right, clear of the resting sweep
    final blip = c + Offset(math.cos(blipAng), math.sin(blipAng)) * u(5.2);
    final past = (ang - blipAng) % (2 * math.pi);
    final glow = (1 - past / (2 * math.pi)).clamp(0.0, 1.0);
    canvas.drawCircle(blip, u(1.6), _fill(alpha: 0.3 + 0.7 * glow));
  }

  // ── Эфир: broadcast — a source dot with symmetric ripples that emit outward
  // on the switch. Open horizontal waves, unlike the radar's closed ring.
  void _ether(Canvas canvas, Size s, double t) {
    double u(double v) => _u(s, v);
    final c = Offset(u(12), u(12));
    canvas.drawCircle(c, u(2.1), _fill());

    const sweep = math.pi * 0.5;
    // Allow the spring overshoot to bulge the waves out before they settle.
    final tc = t.clamp(0.0, 1.15);
    final e = math.sin(math.pi * t.clamp(0.0, 1.0));
    for (final side in const [-1, 1]) {
      final centre = side == 1 ? 0.0 : math.pi; // east / west
      // The two arcs sit tight when idle and EXTEND outward when selected — the
      // visible difference is what makes "on air" read at a glance.
      for (var i = 1; i <= 2; i++) {
        final r0 = 3.2 + (i - 1) * 2.4; // idle radius
        final r1 = 5.4 + (i - 1) * 3.4; // selected radius
        final r = u(r0 + (r1 - r0) * tc);
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          centre - sweep / 2,
          sweep,
          false,
          _stroke(s, width: 1.9, alpha: 0.9 - (i - 1) * 0.14),
        );
      }
      // A further ripple shoots past on the switch, for a clear broadcast pulse.
      if (e > 0.02) {
        final r = u(8.8 + 2.4 * e);
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          centre - sweep / 2,
          sweep,
          false,
          _stroke(s, width: 1.7, alpha: (1 - e) * 0.8),
        );
      }
    }
  }

  // ── Настройки: three sliders; knobs spring across when selected ──
  void _settings(Canvas canvas, Size s, double t) {
    double u(double v) => _u(s, v);
    final track = _stroke(s, width: 2.0, alpha: 0.9);
    const ys = [7.0, 12.0, 17.0];
    // knob x travels A→B with t (overshoot from the spring adds the settle)
    const a = [9.0, 15.5, 11.0];
    const b = [15.5, 9.5, 16.0];
    final x0 = u(4.5), x1 = u(19.5);
    for (var i = 0; i < 3; i++) {
      final y = u(ys[i]);
      canvas.drawLine(Offset(x0, y), Offset(x1, y), track);
      final kx = u(a[i] + (b[i] - a[i]) * t);
      // knob: filled core + ring so it reads on top of the track
      canvas.drawCircle(Offset(kx, y), u(2.5), _fill(alpha: 1));
    }
  }

  // ── Search: magnifier (static; the button handles press feedback) ──
  void _search(Canvas canvas, Size s) {
    double u(double v) => _u(s, v);
    canvas.drawCircle(Offset(u(10.5), u(10.5)), u(6), _stroke(s));
    canvas.drawLine(Offset(u(15), u(15)), Offset(u(20), u(20)), _stroke(s));
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
