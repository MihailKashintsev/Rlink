import 'rlv_sticker.dart';

/// Named one-tap animation presets for the vector sticker studio. Each
/// generator takes the layer's *current* interpolated pose (whatever
/// `RlvLayer.transformAt(playheadMs)` returns right now, not a hardcoded
/// canvas-center value — the user may have placed the layer anywhere) and
/// returns a full keyframe sequence that REPLACES the layer's `keys`. All
/// eases used are among the 6 already defined in `rlv_sticker.dart` — no new
/// curves needed.

/// Подпрыгивание — anticipation crouch, launch with lean, apex hang, fall,
/// hard land, small secondary rebound, settle. ~750ms. Bigger squash/stretch
/// and a rotation lean through the arc (vs. a previous pure-vertical version
/// that read as mechanical) is what actually sells "alive" here.
List<RlvKeyframe> bouncePreset(RlvPose base, {double canvasSide = 512}) {
  final apexY = base.y - canvasSide * 0.10;
  return [
    RlvKeyframe(
      tMs: 0,
      x: base.x,
      y: base.y,
      sx: base.sx * 1.16,
      sy: base.sy * 0.84,
      rotDeg: base.rotDeg - 4,
      alpha: base.alpha,
    ),
    RlvKeyframe(
      tMs: 110,
      x: base.x,
      y: base.y + 6,
      sx: base.sx * 0.92,
      sy: base.sy * 1.10,
      rotDeg: base.rotDeg + 3,
      alpha: base.alpha,
      ease: 'easeOut',
    ),
    RlvKeyframe(
      tMs: 300,
      x: base.x,
      y: apexY,
      sx: base.sx * 0.92,
      sy: base.sy * 1.08,
      rotDeg: base.rotDeg - 3,
      alpha: base.alpha,
      ease: 'easeOut',
    ),
    RlvKeyframe(
      tMs: 460,
      x: base.x,
      y: base.y + 8,
      sx: base.sx * 0.94,
      sy: base.sy * 1.06,
      rotDeg: base.rotDeg + 2,
      alpha: base.alpha,
      ease: 'easeIn',
    ),
    RlvKeyframe(
      tMs: 560,
      x: base.x,
      y: base.y + 10,
      sx: base.sx * 1.20,
      sy: base.sy * 0.80,
      rotDeg: base.rotDeg - 2,
      alpha: base.alpha,
      ease: 'outBounce',
    ),
    RlvKeyframe(
      tMs: 650,
      x: base.x,
      y: base.y + 3,
      sx: base.sx * 1.04,
      sy: base.sy * 0.97,
      rotDeg: base.rotDeg + 1,
      alpha: base.alpha,
      ease: 'easeOut',
    ),
    RlvKeyframe(
      tMs: 750,
      x: base.x,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
      ease: 'easeOut',
    ),
  ];
}

/// Пульсация — a heartbeat "lub-dub" (quick punchy attack, dip, smaller
/// second beat) instead of one smooth symmetric scale, plus a hair of
/// rotation so it doesn't read as a static breathing loop. ~650ms.
List<RlvKeyframe> pulsePreset(RlvPose base) => [
      RlvKeyframe(
        tMs: 0,
        x: base.x,
        y: base.y,
        sx: base.sx,
        sy: base.sy,
        rotDeg: base.rotDeg,
        alpha: base.alpha,
      ),
      RlvKeyframe(
        tMs: 150,
        x: base.x,
        y: base.y,
        sx: base.sx * 1.15,
        sy: base.sy * 1.15,
        rotDeg: base.rotDeg,
        alpha: base.alpha,
        ease: 'easeOut',
      ),
      RlvKeyframe(
        tMs: 300,
        x: base.x,
        y: base.y,
        sx: base.sx * 1.24,
        sy: base.sy * 1.24,
        rotDeg: base.rotDeg + 2,
        alpha: base.alpha,
        ease: 'easeOut',
      ),
      RlvKeyframe(
        tMs: 400,
        x: base.x,
        y: base.y,
        sx: base.sx * 1.04,
        sy: base.sy * 1.04,
        rotDeg: base.rotDeg - 1,
        alpha: base.alpha,
        ease: 'easeInOut',
      ),
      RlvKeyframe(
        tMs: 480,
        x: base.x,
        y: base.y,
        sx: base.sx * 1.10,
        sy: base.sy * 1.10,
        rotDeg: base.rotDeg + 1,
        alpha: base.alpha,
        ease: 'easeOut',
      ),
      RlvKeyframe(
        tMs: 650,
        x: base.x,
        y: base.y,
        sx: base.sx,
        sy: base.sy,
        rotDeg: base.rotDeg,
        alpha: base.alpha,
        ease: 'easeInOut',
      ),
    ];

/// Вращение — one full linear rotation. ~1000ms.
List<RlvKeyframe> spinPreset(RlvPose base) => [
      RlvKeyframe(
        tMs: 0,
        x: base.x,
        y: base.y,
        sx: base.sx,
        sy: base.sy,
        rotDeg: base.rotDeg,
        alpha: base.alpha,
      ),
      RlvKeyframe(
        tMs: 1000,
        x: base.x,
        y: base.y,
        sx: base.sx,
        sy: base.sy,
        rotDeg: base.rotDeg + 360,
        alpha: base.alpha,
        ease: 'linear',
      ),
    ];

/// Тряска — side-to-side shake with a little rotation. ~500ms.
List<RlvKeyframe> wobblePreset(RlvPose base, {double canvasSide = 512}) {
  final amp = canvasSide * 0.03;
  return [
    RlvKeyframe(
      tMs: 0,
      x: base.x,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
    ),
    RlvKeyframe(
      tMs: 100,
      x: base.x - amp,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg - 4,
      alpha: base.alpha,
      ease: 'easeInOut',
    ),
    RlvKeyframe(
      tMs: 200,
      x: base.x + amp,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg + 4,
      alpha: base.alpha,
      ease: 'easeInOut',
    ),
    RlvKeyframe(
      tMs: 300,
      x: base.x - amp * 0.6,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg - 2,
      alpha: base.alpha,
      ease: 'easeInOut',
    ),
    RlvKeyframe(
      tMs: 400,
      x: base.x + amp * 0.6,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg + 2,
      alpha: base.alpha,
      ease: 'easeInOut',
    ),
    RlvKeyframe(
      tMs: 500,
      x: base.x,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
      ease: 'easeInOut',
    ),
  ];
}

/// Появление — alpha 0 to base over 250ms, optionally held until [holdMs].
List<RlvKeyframe> fadeInPreset(RlvPose base, {int holdMs = 1000}) {
  final safeHold = holdMs < 250 ? 250 : holdMs;
  final keys = <RlvKeyframe>[
    RlvKeyframe(
      tMs: 0,
      x: base.x,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg,
      alpha: 0,
    ),
    RlvKeyframe(
      tMs: 250,
      x: base.x,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
      ease: 'easeOut',
    ),
  ];
  if (safeHold > 250) {
    keys.add(RlvKeyframe(
      tMs: safeHold,
      x: base.x,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
    ));
  }
  return keys;
}

/// Исчезновение — held at base alpha, then fades to 0 over the final 250ms.
List<RlvKeyframe> fadeOutPreset(RlvPose base, {int holdMs = 1000}) {
  final safeHold = holdMs < 250 ? 250 : holdMs;
  final dropStart = safeHold - 250;
  final keys = <RlvKeyframe>[
    RlvKeyframe(
      tMs: 0,
      x: base.x,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
    ),
  ];
  if (dropStart > 0) {
    keys.add(RlvKeyframe(
      tMs: dropStart,
      x: base.x,
      y: base.y,
      sx: base.sx,
      sy: base.sy,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
    ));
  }
  keys.add(RlvKeyframe(
    tMs: safeHold,
    x: base.x,
    y: base.y,
    sx: base.sx,
    sy: base.sy,
    rotDeg: base.rotDeg,
    alpha: 0,
    ease: 'easeIn',
  ));
  return keys;
}

/// Появление сдвигом — slides in from off-canvas left with an overshoot
/// settle. ~400ms.
List<RlvKeyframe> slideInPreset(RlvPose base, {double canvasSide = 512}) => [
      RlvKeyframe(
        tMs: 0,
        x: base.x - canvasSide * 0.6,
        y: base.y,
        sx: base.sx,
        sy: base.sy,
        rotDeg: base.rotDeg,
        alpha: base.alpha,
      ),
      RlvKeyframe(
        tMs: 400,
        x: base.x,
        y: base.y,
        sx: base.sx,
        sy: base.sy,
        rotDeg: base.rotDeg,
        alpha: base.alpha,
        ease: 'outBack',
      ),
    ];
