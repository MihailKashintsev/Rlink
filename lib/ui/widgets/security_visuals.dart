import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Hand-drawn security visuals (no emoji, no Material icons).
//
// 1. [SecurityStrengthMeter] — password strength as an escalating illustration:
//    a flimsy paperclip-latched door → a padlocked door → a bolted iron door →
//    a 3-lock vault, with a 4-segment status bar (red → orange → amber → green).
// 2. [SuccessSeal] — the PIN "unlocked" seal: four stars orbit inward and
//    coalesce into a stroke-drawn checkmark on a glowing disc.
// 3. [LockGlyph] — a small drawn padlock used as the lock-screen header mark.
// ─────────────────────────────────────────────────────────────────────────────

const _kLevelColors = <Color>[
  Color(0xFF9AA0A6), // 0 — none / idle grey
  Color(0xFFE5484D), // 1 — weak (red)
  Color(0xFFF76B15), // 2 — medium (orange)
  Color(0xFFFFB224), // 3 — good (amber)
  Color(0xFF30A46C), // 4 — strong (green)
];

const _kLevelLabels = <String>[
  '',
  'Слабый',
  'Средний',
  'Хороший',
  'Надёжный',
];

/// Levels 1‑4 map to the door→vault progression the user described.
class SecurityStrengthMeter extends StatefulWidget {
  /// 0 (empty) .. 4 (strongest).
  final int strength;

  /// Height reserved for the drawn illustration.
  final double illustrationHeight;

  const SecurityStrengthMeter({
    super.key,
    required this.strength,
    this.illustrationHeight = 92,
  });

  @override
  State<SecurityStrengthMeter> createState() => _SecurityStrengthMeterState();
}

class _SecurityStrengthMeterState extends State<SecurityStrengthMeter>
    with TickerProviderStateMixin {
  // Continuous, gentle idle motion (dial spin, paperclip wobble, bolt shine).
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  // A quick "pop" replayed every time the level changes — the illustration
  // scales in with a slight overshoot and flares its glow.
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
    value: 1,
  );

  @override
  void didUpdateWidget(covariant SecurityStrengthMeter old) {
    super.didUpdateWidget(old);
    if (old.strength != widget.strength && widget.strength > 0) {
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _idle.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = widget.strength.clamp(0, 4);
    final color = _kLevelColors[level];
    final label = _kLevelLabels[level];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: widget.illustrationHeight,
          child: AnimatedBuilder(
            animation: Listenable.merge([_idle, _pop]),
            builder: (_, __) {
              final pop = Curves.easeOutBack.transform(_pop.value);
              return CustomPaint(
                painter: _LockIllustrationPainter(
                  level: level,
                  color: color,
                  phase: _idle.value,
                  pop: pop,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        // 4-segment status bar — fills 25 / 50 / 75 / 100 %.
        Row(
          children: List.generate(4, (i) {
            final active = i < level;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i < 3 ? 5 : 0),
                child: AnimatedContainer(
                  duration: Duration(milliseconds: 260 + i * 70),
                  curve: Curves.easeOutCubic,
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: active
                        ? color
                        : Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.18),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: color.withValues(alpha: 0.45),
                              blurRadius: 7,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 8),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 220),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: level == 0
                ? Theme.of(context).colorScheme.onSurfaceVariant
                : color,
          ),
          child: Text(level == 0 ? 'Придумайте пароль' : label),
        ),
      ],
    );
  }
}

class _LockIllustrationPainter extends CustomPainter {
  final int level;
  final Color color;
  final double phase; // 0..1 idle loop
  final double pop; // 0..1 transition overshoot

  _LockIllustrationPainter({
    required this.level,
    required this.color,
    required this.phase,
    required this.pop,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final s = math.min(size.width, size.height) * 0.94;
    final k = s / 100; // design grid is 100×100
    Offset p(double x, double y) =>
        center + Offset((x - 50) * k, (y - 50) * k);

    // Soft ambient glow behind the illustration.
    final glow = Paint()
      ..color = color.withValues(alpha: 0.16 + 0.12 * (1 - pop).abs())
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 18 * k);
    canvas.drawCircle(center, 30 * k, glow);

    // The whole illustration scales in on level change.
    canvas.save();
    final scale = 0.86 + 0.14 * pop;
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    canvas.translate(-center.dx, -center.dy);

    switch (level) {
      case 1:
        _paintPaperclipDoor(canvas, p, k);
        break;
      case 2:
        _paintPadlockDoor(canvas, p, k);
        break;
      case 3:
        _paintBoltDoor(canvas, p, k);
        break;
      case 4:
        _paintVault(canvas, p, k, center);
        break;
      default:
        _paintGhostDoor(canvas, p, k);
    }
    canvas.restore();
  }

  // ── shared paints ──────────────────────────────────────────────────────────
  Paint _stroke(double k, {double w = 2.6, double alpha = 1}) => Paint()
    ..color = color.withValues(alpha: alpha)
    ..style = PaintingStyle.stroke
    ..strokeWidth = w * k
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;

  Paint _fill(double k, {double alpha = 0.10}) => Paint()
    ..color = color.withValues(alpha: alpha)
    ..style = PaintingStyle.fill;

  // ── level 0: faint placeholder door ─────────────────────────────────────────
  void _paintGhostDoor(Canvas c, Offset Function(double, double) p, double k) {
    final leaf = _rrect(p(34, 20), p(66, 84), 4 * k);
    c.drawRRect(leaf, _stroke(k, w: 2.4, alpha: 0.5));
    c.drawCircle(p(60, 52), 2.4 * k, _stroke(k, w: 2, alpha: 0.5)..style = PaintingStyle.fill);
  }

  // ── level 1: a door hanging open, "latched" by a bent paperclip ──────────────
  void _paintPaperclipDoor(
      Canvas c, Offset Function(double, double) p, double k) {
    // Fixed frame.
    c.drawRRect(_rrect(p(28, 14), p(72, 88), 4 * k), _stroke(k, w: 2.2, alpha: 0.4));
    // Door leaf, swung ajar on its left hinge with a slow wobble.
    final wobble = math.sin(phase * math.pi * 2) * 0.045 + 0.11; // radians
    final hinge = p(31, 86);
    c.save();
    c.translate(hinge.dx, hinge.dy);
    c.rotate(wobble);
    c.translate(-hinge.dx, -hinge.dy);
    final leaf = _rrect(p(31, 16), p(67, 86), 4 * k);
    c.drawRRect(leaf, _fill(k));
    c.drawRRect(leaf, _stroke(k, w: 2.6));
    // Handle.
    c.drawCircle(p(61, 52), 2.6 * k, _fill(k, alpha: 1));
    c.restore();

    // A classic paperclip standing in for the lock — the flimsy latch. Drawn as
    // two nested vertical loops over the door's latch edge.
    final clipPaint = _stroke(k, w: 1.7);
    final outer = RRect.fromRectAndRadius(
      Rect.fromPoints(p(60, 42), p(70, 66)),
      Radius.circular(5 * k),
    );
    final inner = RRect.fromRectAndRadius(
      Rect.fromPoints(p(62.5, 46), p(67.5, 62)),
      Radius.circular(2.5 * k),
    );
    // Outer loop, open at the top (leave a small gap so it reads as bent wire).
    final outerPath = Path()..addRRect(outer);
    c.drawPath(outerPath, clipPaint);
    c.drawRRect(inner, clipPaint);
    // The inner loop's tail overshoots past the top — the tell-tale paperclip end.
    c.drawLine(p(65, 46), p(65, 39), clipPaint);
  }

  // ── level 2: closed door with a round padlock on the latch ───────────────────
  void _paintPadlockDoor(
      Canvas c, Offset Function(double, double) p, double k) {
    c.drawRRect(_rrect(p(28, 14), p(72, 88), 4 * k), _stroke(k, w: 2.2, alpha: 0.4));
    final leaf = _rrect(p(31, 16), p(69, 86), 4 * k);
    c.drawRRect(leaf, _fill(k));
    c.drawRRect(leaf, _stroke(k, w: 2.6));
    // Inset panels.
    c.drawRRect(_rrect(p(36, 22), p(64, 44), 2.5 * k), _stroke(k, w: 1.6, alpha: 0.55));
    c.drawRRect(_rrect(p(36, 50), p(64, 80), 2.5 * k), _stroke(k, w: 1.6, alpha: 0.55));
    // Padlock centred on the latch, gentle bob on the shackle.
    final bob = math.sin(phase * math.pi * 2) * 1.2;
    final body = _rrect(p(44, 58), p(60, 74), 2.5 * k);
    c.drawRRect(body, _fill(k, alpha: 0.9));
    c.drawRRect(body, _stroke(k, w: 2.2));
    // Shackle.
    final shackle = Path()
      ..moveTo(p(47, 58).dx, p(47, 58).dy)
      ..lineTo(p(47, 54 + bob).dx, p(47, 54 + bob).dy)
      ..arcToPoint(p(57, 54 + bob),
          radius: Radius.circular(5 * k), clockwise: true)
      ..lineTo(p(57, 58).dx, p(57, 58).dy);
    c.drawPath(shackle, _stroke(k, w: 2.2));
    // Keyhole.
    c.drawCircle(p(52, 65), 1.6 * k, _stroke(k, w: 1.6)..style = PaintingStyle.fill);
  }

  // ── level 3: riveted iron door with a horizontal sliding deadbolt ────────────
  void _paintBoltDoor(Canvas c, Offset Function(double, double) p, double k) {
    c.drawRRect(_rrect(p(26, 12), p(74, 90), 4 * k), _stroke(k, w: 2.4, alpha: 0.5));
    final leaf = _rrect(p(30, 15), p(70, 87), 3 * k);
    c.drawRRect(leaf, _fill(k, alpha: 0.13));
    c.drawRRect(leaf, _stroke(k, w: 2.8));
    // Vertical seam + rivets down both edges.
    for (final x in [34.0, 66.0]) {
      for (var y = 22.0; y <= 80.0; y += 11.5) {
        c.drawCircle(p(x, y), 1.3 * k, _fill(k, alpha: 0.85));
      }
    }
    // Cross panel line.
    c.drawLine(p(30, 51), p(70, 51), _stroke(k, w: 1.6, alpha: 0.5));
    // Heavy horizontal deadbolt sliding across the latch, with a travelling shine.
    final boltR = _rrect(p(40, 46), p(78, 56), 2.5 * k);
    c.drawRRect(boltR, _fill(k, alpha: 0.95));
    c.drawRRect(boltR, _stroke(k, w: 2.4));
    // Bolt knob.
    c.drawCircle(p(46, 51), 3 * k, _stroke(k, w: 2.2));
    // Shine sweep.
    final sx = 44 + (phase * 30) % 30;
    c.drawLine(
      p(sx, 47.5),
      p(sx, 54.5),
      _stroke(k, w: 1.6, alpha: 0.6)..color = Colors.white.withValues(alpha: 0.6),
    );
  }

  // ── level 4: a vault with a rotating combination dial and 3 lock bolts ───────
  void _paintVault(
      Canvas c, Offset Function(double, double) p, double k, Offset center) {
    // Outer safe body.
    c.drawRRect(_rrect(p(20, 16), p(80, 84), 7 * k), _fill(k, alpha: 0.12));
    c.drawRRect(_rrect(p(20, 16), p(80, 84), 7 * k), _stroke(k, w: 3));
    // Inner door circle.
    final dialC = p(50, 50);
    c.drawCircle(dialC, 20 * k, _stroke(k, w: 2.2, alpha: 0.7));
    c.drawCircle(dialC, 20 * k, _fill(k, alpha: 0.08));
    // Tick marks around the dial.
    final tick = _stroke(k, w: 1.4, alpha: 0.6);
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6;
      final o1 = dialC + Offset(math.cos(a), math.sin(a)) * 20 * k;
      final o2 = dialC + Offset(math.cos(a), math.sin(a)) * 16.5 * k;
      c.drawLine(o1, o2, tick);
    }
    // Rotating dial hub with spokes.
    c.save();
    c.translate(dialC.dx, dialC.dy);
    c.rotate(phase * math.pi * 2);
    c.drawCircle(Offset.zero, 9 * k, _fill(k, alpha: 0.95));
    c.drawCircle(Offset.zero, 9 * k, _stroke(k, w: 2));
    for (var i = 0; i < 3; i++) {
      final a = i * 2 * math.pi / 3;
      c.drawLine(
        Offset.zero,
        Offset(math.cos(a), math.sin(a)) * 9 * k,
        _stroke(k, w: 2),
      );
    }
    c.restore();
    // Three engaged lock bolts (left, right, bottom).
    for (final o in [p(23, 50), p(77, 50), p(50, 81)]) {
      c.drawCircle(o, 2.6 * k, _fill(k, alpha: 1));
    }
  }

  RRect _rrect(Offset a, Offset b, double r) =>
      RRect.fromRectAndRadius(Rect.fromPoints(a, b), Radius.circular(r));

  @override
  bool shouldRepaint(_LockIllustrationPainter old) =>
      old.level != level ||
      old.color != color ||
      old.phase != phase ||
      old.pop != pop;
}

// ─────────────────────────────────────────────────────────────────────────────
// SuccessSeal — orbiting stars coalescing into a stroke-drawn checkmark.
// ─────────────────────────────────────────────────────────────────────────────

class SuccessSeal extends StatelessWidget {
  final double rotation; // radians, star orbit
  final double checkT; // 0..1 checkmark draw + star coalescence
  final double scale;
  final Color color;

  const SuccessSeal({
    super.key,
    required this.rotation,
    required this.checkT,
    required this.scale,
    this.color = const Color(0xFF30A46C),
  });

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: scale,
      child: SizedBox(
        width: 150,
        height: 150,
        child: CustomPaint(
          painter: _SuccessSealPainter(
            rotation: rotation,
            checkT: checkT,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _SuccessSealPainter extends CustomPainter {
  final double rotation;
  final double checkT;
  final Color color;

  _SuccessSealPainter({
    required this.rotation,
    required this.checkT,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ct = Curves.easeOutCubic.transform(checkT.clamp(0, 1));

    // Glow that swells as the checkmark forms.
    canvas.drawCircle(
      center,
      36 + 10 * ct,
      Paint()
        ..color = color.withValues(alpha: 0.35 * ct)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 20),
    );

    // Solid disc.
    canvas.drawCircle(
      center,
      36 * ct,
      Paint()..color = color.withValues(alpha: ct),
    );

    // Four stars orbiting inward, fading as the check appears.
    final orbitR = 52 * (1 - ct);
    final starAlpha = (1 - ct).clamp(0.0, 1.0);
    if (starAlpha > 0.01) {
      for (var i = 0; i < 4; i++) {
        final a = rotation + i * math.pi / 2;
        final pos = center + Offset(math.cos(a), math.sin(a)) * orbitR;
        _drawStar(
          canvas,
          pos,
          6.5 * (0.6 + 0.4 * starAlpha),
          color.withValues(alpha: starAlpha),
        );
      }
    }

    // Stroke-drawn checkmark, revealed by path length.
    if (ct > 0.02) {
      final path = Path()
        ..moveTo(center.dx - 15, center.dy + 1)
        ..lineTo(center.dx - 4, center.dy + 12)
        ..lineTo(center.dx + 16, center.dy - 12);
      final drawn = Path();
      for (final m in path.computeMetrics()) {
        drawn.addPath(m.extractPath(0, m.length * ct), Offset.zero);
      }
      canvas.drawPath(
        drawn,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  void _drawStar(Canvas c, Offset o, double r, Color col) {
    final path = Path();
    for (var i = 0; i < 5; i++) {
      final outer = -math.pi / 2 + i * 2 * math.pi / 5;
      final inner = outer + math.pi / 5;
      final po = o + Offset(math.cos(outer), math.sin(outer)) * r;
      final pi_ = o + Offset(math.cos(inner), math.sin(inner)) * r * 0.45;
      if (i == 0) {
        path.moveTo(po.dx, po.dy);
      } else {
        path.lineTo(po.dx, po.dy);
      }
      path.lineTo(pi_.dx, pi_.dy);
    }
    path.close();
    c.drawPath(path, Paint()..color = col);
  }

  @override
  bool shouldRepaint(_SuccessSealPainter old) =>
      old.rotation != rotation ||
      old.checkT != checkT ||
      old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// LockSuccessOverlay — full-screen unlock celebration: the keypad/field blurs
// away while four stars orbit inward and resolve into a drawn checkmark, then
// [onCompleted] fires (the caller unlocks the app there, so the animation is
// fully seen before the overlay disappears).
// ─────────────────────────────────────────────────────────────────────────────

class LockSuccessOverlay extends StatefulWidget {
  final VoidCallback onCompleted;
  final Color color;

  const LockSuccessOverlay({
    super.key,
    required this.onCompleted,
    this.color = const Color(0xFF30A46C),
  });

  @override
  State<LockSuccessOverlay> createState() => _LockSuccessOverlayState();
}

class _LockSuccessOverlayState extends State<LockSuccessOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );

  late final Animation<double> _scale =
      Tween<double>(begin: 0.55, end: 1.0).animate(CurvedAnimation(
          parent: _ctrl,
          curve: const Interval(0, 0.45, curve: Curves.easeOutBack)));
  late final Animation<double> _rotation =
      Tween<double>(begin: 0, end: 4 * math.pi)
          .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  late final Animation<double> _checkT = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.4, 0.82)));
  late final Animation<double> _blur = Tween<double>(begin: 0, end: 22).animate(
      CurvedAnimation(
          parent: _ctrl,
          curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic)));

  @override
  void initState() {
    super.initState();
    _ctrl.forward().whenComplete(widget.onCompleted);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Stack(
        fit: StackFit.expand,
        children: [
          if (_blur.value > 0.1)
            BackdropFilter(
              filter: ui.ImageFilter.blur(
                  sigmaX: _blur.value, sigmaY: _blur.value),
              child: ColoredBox(
                color: widget.color
                    .withValues(alpha: 0.06 * (_blur.value / 22)),
              ),
            ),
          Center(
            child: SuccessSeal(
              rotation: _rotation.value,
              checkT: _checkT.value,
              scale: _scale.value,
              color: widget.color,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LockGlyph — a small drawn padlock for the lock-screen header.
// ─────────────────────────────────────────────────────────────────────────────

class LockGlyph extends StatelessWidget {
  final double size;
  final Color color;
  const LockGlyph({super.key, this.size = 46, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _LockGlyphPainter(color)),
    );
  }
}

class _LockGlyphPainter extends CustomPainter {
  final Color color;
  _LockGlyphPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 100;
    Offset p(double x, double y) => Offset(x * k, y * k);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7 * k
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    // Body.
    final body = RRect.fromRectAndRadius(
      Rect.fromPoints(p(26, 48), p(74, 86)),
      Radius.circular(9 * k),
    );
    canvas.drawRRect(body, Paint()..color = color.withValues(alpha: 0.12));
    canvas.drawRRect(body, stroke);
    // Shackle.
    final shackle = Path()
      ..moveTo(p(34, 48).dx, p(34, 48).dy)
      ..lineTo(p(34, 40).dx, p(34, 40).dy)
      ..arcToPoint(p(66, 40), radius: Radius.circular(16 * k), clockwise: true)
      ..lineTo(p(66, 48).dx, p(66, 48).dy);
    canvas.drawPath(shackle, stroke);
    // Keyhole.
    canvas.drawCircle(p(50, 63), 4 * k, Paint()..color = color);
    canvas.drawLine(p(50, 63), p(50, 74), stroke);
  }

  @override
  bool shouldRepaint(_LockGlyphPainter old) => old.color != color;
}
