// Generates the vector-redesigned default mascot stickers from real traced
// artwork (see tool/vectorize_mascot.py) as .rls (raster + keyframed
// transform) stickers. Happy and Love get a body layer plus small
// independently animated overlay layers (blinking eyelids, floating hearts)
// drawn by hand in Python/PIL — these states don't exist in the source PNG,
// so there's nothing to trace for them. The other 10 are single-layer
// (buildSimple) with a shared bounce/pulse/wobble preset for liveliness.
//
// Ships as .rls, not .rlv: flutter_svg's web compile path renders a stray
// extra shape for traced SVG content — confirmed correct via librsvg,
// Chrome's native SVG engine, and flutter_test's native Skia backend, wrong
// only in the actual deployed web app. Raster sidesteps it entirely.
//
// Run:
//   python3 tool/vectorize_mascot.py <Name>.png /tmp/vectrace   # for each of the 12
//   rsvg-convert -w 1024 -h 1024 -o /tmp/vectrace/<Name>_raster.png /tmp/vectrace/<Name>_combined.svg
//   (eyelid/heart overlay PNGs already hand-drawn once, in /tmp/vectrace)
//   (LapTop_raster.png additionally gets the Rlink logo composited onto the
//    laptop-lid ring — brand green #558623 rasterized from
//    assets/branding/logo.svg, centered near (733,705) at ~21x30px — redo
//    this composite after any LapTop re-vectorization, it doesn't survive one)
//   dart run tool/gen_mascot_stickers.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:rlink/models/rls_sticker.dart';
import 'package:rlink/models/rlv_animation_presets.dart';
import 'package:rlink/models/rlv_sticker.dart' show RlvKeyframe, RlvPose;

const canvas = 512.0;
const bodyScale = canvas * 0.72 / 1024.0;
const bodyBase = (
  x: canvas / 2,
  y: canvas / 2,
  sx: bodyScale,
  sy: bodyScale,
  rotDeg: 0.0,
  alpha: 1.0,
);

RlsKeyframe _rls(RlvKeyframe k) => RlsKeyframe(
      tMs: k.tMs,
      x: k.x,
      y: k.y,
      sx: k.sx,
      sy: k.sy,
      rotDeg: k.rotDeg,
      alpha: k.alpha,
      ease: k.ease,
    );

/// Stretches a preset's timeline by [factor] without touching any pose
/// value — same motion, slower. bouncePreset/pulsePreset read as punchy at
/// their original durations; the mascot stickers want a calmer read.
List<RlvKeyframe> _scaleTime(List<RlvKeyframe> keys, double factor) => [
      for (final k in keys)
        RlvKeyframe(
          tMs: (k.tMs * factor).round(),
          x: k.x,
          y: k.y,
          sx: k.sx,
          sy: k.sy,
          rotDeg: k.rotDeg,
          alpha: k.alpha,
          ease: k.ease,
        ),
    ];

typedef _Pose = ({double x, double y, double sx, double sy, double rotDeg});

/// Linear-interpolates the body track's pose at an arbitrary time — lets an
/// overlay (eyelid, mouth state) insert its OWN alpha keyframes at times the
/// body track doesn't have, while still landing exactly on the body's moving
/// position. A short local gap makes plain linear interpolation
/// indistinguishable from re-running the body's own eased curve.
_Pose _poseAt(List<RlvKeyframe> track, int t) {
  if (t <= track.first.tMs) {
    final k = track.first;
    return (x: k.x, y: k.y, sx: k.sx, sy: k.sy, rotDeg: k.rotDeg);
  }
  if (t >= track.last.tMs) {
    final k = track.last;
    return (x: k.x, y: k.y, sx: k.sx, sy: k.sy, rotDeg: k.rotDeg);
  }
  for (var i = 0; i < track.length - 1; i++) {
    final a = track[i], b = track[i + 1];
    if (t < a.tMs || t > b.tMs) continue;
    final span = (b.tMs - a.tMs).clamp(1, 1 << 30);
    final p = (t - a.tMs) / span;
    double lerp(double x, double y) => x + (y - x) * p;
    return (
      x: lerp(a.x, b.x),
      y: lerp(a.y, b.y),
      sx: lerp(a.sx, b.sx),
      sy: lerp(a.sy, b.sy),
      rotDeg: lerp(a.rotDeg, b.rotDeg),
    );
  }
  final k = track.last;
  return (x: k.x, y: k.y, sx: k.sx, sy: k.sy, rotDeg: k.rotDeg);
}

/// An overlay that rides the body's motion but flashes its own alpha at
/// [alphaKeys] times — a fast rise/fall (a few tens of ms) reads as a clean
/// state swap; a slow one (the original bug) shows both states blended
/// together mid-fade, which looks like a smear, not a shape change.
List<RlsKeyframe> _overlayPulse(List<RlvKeyframe> track, List<(int, double)> alphaKeys) {
  return [
    for (final (t, a) in alphaKeys)
      RlsKeyframe(
        tMs: t,
        x: _poseAt(track, t).x,
        y: _poseAt(track, t).y,
        sx: _poseAt(track, t).sx,
        sy: _poseAt(track, t).sy,
        rotDeg: _poseAt(track, t).rotDeg,
        alpha: a,
      ),
  ];
}

RlsSticker buildHappy() {
  final bodyKeys = _scaleTime(bouncePreset(bodyBase, canvasSide: canvas), 1.6);
  final body = RlsLayer(id: 'body', assetId: 'body', keys: bodyKeys.map(_rls).toList());
  final duration = bodyKeys.last.tMs;

  // One quick, snappy blink during the landing/settle part of the hop.
  final eyelids = RlsLayer(
    id: 'eyelids',
    assetId: 'eyelids',
    keys: _overlayPulse(bodyKeys, [
      (0, 0), (870, 0), (896, 1), (930, 1), (955, 0), (duration, 0),
    ]),
  );

  return RlsSticker(
    width: canvas.toInt(),
    height: canvas.toInt(),
    durationMs: duration,
    loop: true,
    assets: {
      'body': File('/tmp/vectrace/Happy_raster.png').readAsBytesSync(),
      'eyelids': File('/tmp/vectrace/Happy_eyelids.png').readAsBytesSync(),
    },
    layers: [body, eyelids],
  );
}

RlsSticker buildLove() {
  final bodyKeys = _scaleTime(pulsePreset(bodyBase), 1.5);
  final body = RlsLayer(id: 'body', assetId: 'body', keys: bodyKeys.map(_rls).toList());
  final duration = bodyKeys.last.tMs;

  RlsLayer heart(String id, String asset, List<(int, double, double, double, double)> pts) {
    return RlsLayer(
      id: id,
      assetId: asset,
      keys: [
        for (final (t, x, y, s, a) in pts)
          RlsKeyframe(tMs: t, x: x, y: y, sx: s, sy: s, alpha: a, ease: 'easeInOut'),
      ],
    );
  }

  // Same drift shapes as before, timeline stretched 1.5x to match the
  // slower body pulse so nothing races ahead of the loop it lives in.
  final heart1 = heart('h1', 'heart0', [
    (0, 90, 400, 0.16, 0),
    (210, 78, 330, 0.20, 1),
    (600, 60, 190, 0.24, 0.9),
    (975, 48, 130, 0.26, 0),
  ]);
  final heart2 = heart('h2', 'heart1', [
    (0, 420, 380, 0, 0),
    (90, 420, 380, 0, 0),
    (375, 434, 300, 0.18, 1),
    (750, 448, 170, 0.22, 0.8),
    (975, 452, 130, 0.23, 0),
  ]);
  final heart3 = heart('h3', 'heart2', [
    (0, 250, 60, 0.13, 0.7),
    (330, 240, 15, 0.17, 0.9),
    (675, 232, -30, 0.10, 0),
    (676, 250, 60, 0.13, 0), // instant reset while invisible, before re-fading in
    (975, 250, 60, 0.13, 0.7),
  ]);

  return RlsSticker(
    width: canvas.toInt(),
    height: canvas.toInt(),
    durationMs: duration,
    loop: true,
    assets: {
      'body': File('/tmp/vectrace/Love_raster.png').readAsBytesSync(),
      'heart0': File('/tmp/vectrace/float_heart_0.png').readAsBytesSync(),
      'heart1': File('/tmp/vectrace/float_heart_1.png').readAsBytesSync(),
      'heart2': File('/tmp/vectrace/float_heart_2.png').readAsBytesSync(),
    },
    layers: [body, heart1, heart2, heart3],
  );
}

/// A single-layer whole-body sticker: trace the source art once, animate the
/// entire raster with one of the shared presets. No per-part rigging (that's
/// only worth the extra work for the two hero stickers) — just a real vector
/// trace instead of primitives, a clean transparent edge, and a calm,
/// stretched-out timeline instead of the presets' punchy defaults.
RlsSticker buildSimple(
  String stem,
  List<RlvKeyframe> Function(({double x, double y, double sx, double sy, double rotDeg, double alpha}) base) preset,
  double timeScale,
) {
  final bodyKeys = _scaleTime(preset(bodyBase), timeScale);
  final body = RlsLayer(id: 'body', assetId: 'body', keys: bodyKeys.map(_rls).toList());
  return RlsSticker(
    width: canvas.toInt(),
    height: canvas.toInt(),
    durationMs: bodyKeys.last.tMs,
    loop: true,
    assets: {'body': File('/tmp/vectrace/${stem}_raster.png').readAsBytesSync()},
    layers: [body],
  );
}

/// Converts a raw 1024px raster coordinate (the space colors/positions were
/// eyeballed in against the source PNGs) to this canvas's 512px space, given
/// the body layer sits centered and scaled by [bodyScale].
double _rx(double raster1024) => canvas / 2 + (raster1024 - 512) * bodyScale;

RlsLayer _floatLayer(
  String id,
  String assetId,
  List<(int, double, double, double, double)> pts,
) {
  final keys = pts
      .map((p) => RlsKeyframe(
            tMs: p.$1,
            x: p.$2,
            y: p.$3,
            sx: p.$4,
            sy: p.$4,
            rotDeg: 0,
            alpha: p.$5,
            ease: 'easeInOut',
          ))
      .toList();
  return RlsLayer(id: id, assetId: assetId, keys: keys);
}

/// Like [buildSimple] but with extra independently-animated overlay layers
/// (floating smoke, sparkles, rain, etc.) drawn by hand in Python/PIL — see
/// tool/vectorize_mascot.py's sibling overlay-generation block.
RlsSticker _buildWithOverlays(
  String stem,
  List<RlvKeyframe> Function(RlvPose base) preset,
  double timeScale,
  Map<String, String> extraAssetFiles,
  List<RlsLayer> Function(int durationMs) overlays,
) {
  final bodyKeys = _scaleTime(preset(bodyBase), timeScale);
  final duration = bodyKeys.last.tMs;
  final body = RlsLayer(id: 'body', assetId: 'body', keys: bodyKeys.map(_rls).toList());
  final assets = <String, List<int>>{
    'body': File('/tmp/vectrace/${stem}_raster.png').readAsBytesSync(),
  };
  extraAssetFiles.forEach((assetId, filename) {
    assets[assetId] = File('/tmp/vectrace/$filename').readAsBytesSync();
  });
  return RlsSticker(
    width: canvas.toInt(),
    height: canvas.toInt(),
    durationMs: duration,
    loop: true,
    assets: assets.map((k, v) => MapEntry(k, Uint8List.fromList(v))),
    layers: [body, ...overlays(duration)],
  );
}

RlsSticker buildAngry() => _buildWithOverlays(
      'Angry',
      (b) => wobblePreset(b, canvasSide: canvas),
      1.4,
      {'smoke': 'ov_smoke.png'},
      (d) => [
        _floatLayer('smoke1', 'smoke', [
          (0, _rx(230), _rx(190), 0.30, 0),
          (100, _rx(212), _rx(140), 0.42, 0.85),
          (400, _rx(150), _rx(50), 0.55, 0.5),
          (700, _rx(110), _rx(0), 0.65, 0),
        ]),
        _floatLayer('smoke2', 'smoke', [
          (0, _rx(283), _rx(363), 0.28, 0),
          (150, _rx(250), _rx(320), 0.38, 0.85),
          (450, _rx(190), _rx(230), 0.5, 0.45),
          (700, _rx(150), _rx(170), 0.6, 0),
        ]),
        _floatLayer('smoke3', 'smoke', [
          (0, _rx(926), _rx(367), 0.28, 0),
          (150, _rx(958), _rx(320), 0.38, 0.85),
          (450, _rx(1015), _rx(230), 0.5, 0.45),
          (700, _rx(1055), _rx(170), 0.6, 0),
        ]),
      ],
    );

RlsSticker buildBest() => _buildWithOverlays(
      'Best',
      pulsePreset,
      1.6,
      {'sparkle': 'ov_sparkle.png'},
      (d) => [
        _floatLayer('sparkle', 'sparkle', [
          (0, _rx(872), _rx(338), 0.4, 0),
          (150, _rx(872), _rx(330), 0.75, 1),
          (350, _rx(872), _rx(338), 0.5, 0.6),
          (600, _rx(872), _rx(330), 0.8, 1),
          (850, _rx(872), _rx(338), 0.45, 0.3),
          (d, _rx(872), _rx(338), 0.4, 0),
        ]),
      ],
    );

RlsSticker buildLapTop() => _buildWithOverlays(
      'LapTop',
      (b) => wobblePreset(b, canvasSide: canvas),
      2.0,
      {'code1': 'ov_code1.png', 'code2': 'ov_code2.png'},
      (d) => [
        _floatLayer('code1', 'code1', [
          (0, _rx(660), _rx(590), 0.5, 0),
          (200, _rx(645), _rx(480), 0.6, 0.9),
          (600, _rx(620), _rx(320), 0.65, 0.5),
          (1000, _rx(595), _rx(180), 0.7, 0),
        ]),
        _floatLayer('code2', 'code2', [
          (0, _rx(770), _rx(610), 0.5, 0),
          (300, _rx(788), _rx(480), 0.6, 0.9),
          (700, _rx(808), _rx(340), 0.65, 0.5),
          (1000, _rx(825), _rx(230), 0.7, 0),
        ]),
      ],
    );

RlsSticker buildMAX() => _buildWithOverlays(
      'MAX',
      pulsePreset,
      2.2,
      {'bubble': 'ov_bubble.png'},
      (d) => [
        _floatLayer('bubble1', 'bubble', [
          (0, _rx(915), _rx(370), 0.35, 0),
          (300, _rx(905), _rx(300), 0.45, 0.8),
          (800, _rx(890), _rx(190), 0.5, 0.5),
          (1430, _rx(875), _rx(90), 0.55, 0),
        ]),
        _floatLayer('bubble2', 'bubble', [
          (0, _rx(945), _rx(410), 0.3, 0),
          (450, _rx(960), _rx(320), 0.4, 0.75),
          (950, _rx(975), _rx(210), 0.45, 0.4),
          (1430, _rx(990), _rx(110), 0.5, 0),
        ]),
      ],
    );

RlsSticker buildSad() => _buildWithOverlays(
      'Sad',
      pulsePreset,
      2.2,
      {'rain': 'ov_raindrop.png'},
      (d) => [
        _floatLayer('rain1', 'rain', [
          (0, _rx(400), _rx(-40), 0.6, 0),
          (150, _rx(400), _rx(40), 0.6, 0.9),
          (600, _rx(400), _rx(240), 0.6, 0.9),
          (750, _rx(400), _rx(320), 0.6, 0),
          (1430, _rx(400), _rx(-40), 0.6, 0),
        ]),
        _floatLayer('rain2', 'rain', [
          (0, _rx(512), _rx(-40), 0.6, 0),
          (300, _rx(512), _rx(-40), 0.6, 0),
          (450, _rx(512), _rx(40), 0.6, 0.9),
          (900, _rx(512), _rx(240), 0.6, 0.9),
          (1050, _rx(512), _rx(320), 0.6, 0),
          (1430, _rx(512), _rx(-40), 0.6, 0),
        ]),
        _floatLayer('rain3', 'rain', [
          (0, _rx(624), _rx(-40), 0.6, 0),
          (600, _rx(624), _rx(-40), 0.6, 0),
          (750, _rx(624), _rx(40), 0.6, 0.9),
          (1200, _rx(624), _rx(240), 0.6, 0.9),
          (1430, _rx(624), _rx(300), 0.6, 0),
        ]),
      ],
    );

RlsSticker buildWoah() => _buildWithOverlays(
      'Woah!',
      pulsePreset,
      1.4,
      {'excl': 'ov_excl.png'},
      (d) => [
        _floatLayer('excl1', 'excl', [
          (0, _rx(620), _rx(124), 0.3, 0),
          (80, _rx(620), _rx(60), 0.9, 1),
          (200, _rx(620), _rx(80), 0.7, 1),
          (700, _rx(620), _rx(80), 0.7, 1),
          (d, _rx(620), _rx(124), 0.3, 0),
        ]),
        _floatLayer('excl2', 'excl', [
          (0, _rx(700), _rx(180), 0.25, 0),
          (150, _rx(700), _rx(120), 0.25, 0),
          (230, _rx(700), _rx(100), 0.75, 1),
          (350, _rx(700), _rx(110), 0.6, 1),
          (700, _rx(700), _rx(110), 0.6, 1),
          (d, _rx(700), _rx(180), 0.25, 0),
        ]),
      ],
    );

/// Jump's own bounce — same anticipation/launch/apex/fall as the shared
/// bouncePreset, but skips its secondary rebound (which read as a second,
/// smaller jump right after landing — redundant with Happy's cheer-bounce)
/// and settles on a slightly compressed, leaning-forward "caught my breath"
/// pose instead of resetting to the exact neutral base.
List<RlvKeyframe> _jumpBounce(RlvPose base, {double canvasSide = 512}) {
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
      tMs: 750,
      x: base.x,
      y: base.y + 4,
      sx: base.sx * 1.05,
      sy: base.sy * 0.97,
      rotDeg: base.rotDeg + 1.5,
      alpha: base.alpha,
      ease: 'easeOut',
    ),
  ];
}

void main() {
  final outDir = Directory('assets/sticker_packs/default');
  if (!outDir.existsSync()) {
    stderr.writeln('Run from the repo root — ${outDir.path} not found.');
    exit(1);
  }

  for (final (sticker, name) in [
    (buildHappy(), 'Happy.rls'),
    (buildLove(), 'Love.rls'),
    (buildAngry(), 'Angry.rls'),
    (buildBest(), 'Best.rls'),
    (buildSimple('Jump', (b) => _jumpBounce(b, canvasSide: canvas), 1.6), 'Jump.rls'),
    (buildLapTop(), 'LapTop.rls'),
    (buildSimple('Like', (b) => bouncePreset(b, canvasSide: canvas), 1.8), 'Like.rls'),
    (buildMAX(), 'MAX.rls'),
    (buildSad(), 'Sad.rls'),
    (buildSimple('Scary', (b) => wobblePreset(b, canvasSide: canvas), 1.6), 'Scary.rls'),
    (buildSimple('Wery scary', (b) => wobblePreset(b, canvasSide: canvas), 1.4), 'Wery scary.rls'),
    (buildWoah(), 'Woah!.rls'),
  ]) {
    final bytes = sticker.encode();
    File('${outDir.path}/$name').writeAsBytesSync(bytes);
    stdout.writeln('Wrote $name (${bytes.length} bytes, ${sticker.layers.length} layers)');
    final decoded = RlsSticker.decodeBytes(File('${outDir.path}/$name').readAsBytesSync());
    if (decoded == null) {
      stderr.writeln('FAIL: $name did not round-trip decode!');
      exit(1);
    }
    stdout.writeln('OK: $name decodes (${decoded.layers.length} layers, ${decoded.durationMs}ms)');
  }
}
