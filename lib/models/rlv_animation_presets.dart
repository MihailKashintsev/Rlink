import 'rlv_sticker.dart';

/// Named one-tap animation presets for the vector sticker studio. Each
/// generator takes the layer's *current* interpolated pose (whatever
/// `RlvLayer.transformAt(playheadMs)` returns right now, not a hardcoded
/// canvas-center value — the user may have placed the layer anywhere) and
/// returns a full keyframe sequence that REPLACES the layer's `keys`. All
/// eases used are among the 6 already defined in `rlv_sticker.dart` — no new
/// curves needed.

/// Подпрыгивание — crouch, launch, apex hang, bounce-land, settle. ~700ms.
List<RlvKeyframe> bouncePreset(RlvPose base, {double canvasSide = 512}) {
  final crouchSx = base.sx * 1.12;
  final crouchSy = base.sy * 0.88;
  final apexY = base.y - canvasSide * 0.16;
  return [
    RlvKeyframe(
      tMs: 0,
      x: base.x,
      y: base.y,
      sx: crouchSx,
      sy: crouchSy,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
    ),
    RlvKeyframe(
      tMs: 90,
      x: base.x,
      y: base.y + 10,
      sx: crouchSx,
      sy: crouchSy,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
      ease: 'easeOut',
    ),
    RlvKeyframe(
      tMs: 300,
      x: base.x,
      y: apexY,
      sx: base.sx * 0.95,
      sy: base.sy * 1.05,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
      ease: 'easeOut',
    ),
    RlvKeyframe(
      tMs: 520,
      x: base.x,
      y: base.y + 10,
      sx: crouchSx,
      sy: crouchSy,
      rotDeg: base.rotDeg,
      alpha: base.alpha,
      ease: 'outBounce',
    ),
    RlvKeyframe(
      tMs: 700,
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

/// Пульсация — scale up and back. ~600ms.
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
        tMs: 300,
        x: base.x,
        y: base.y,
        sx: base.sx * 1.18,
        sy: base.sy * 1.18,
        rotDeg: base.rotDeg,
        alpha: base.alpha,
        ease: 'easeInOut',
      ),
      RlvKeyframe(
        tMs: 600,
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
