import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Rlink's own animated-sticker container: **.rls**.
///
/// Format (mirrors the idea behind Telegram's `.tgs` — gzip a small JSON
/// description instead of shipping per-frame raster video — but animates
/// **raster layers via keyframed affine transforms**, not vector paths. That
/// trade-off is deliberate: a full vector path-morph engine (what Lottie
/// actually is) is a large undertaking to build and render ourselves; keyframed
/// transforms on a handful of PNG layers cover the vast majority of sticker
/// motion (bounce, spin, wobble, pulse, slide) using a renderer we can write
/// and audit ourselves, while still being tiny — the pixel data is PNG-encoded
/// once per unique layer image, and everything that varies per instant is a
/// few numbers.
///
/// On-disk bytes = gzip(utf8(jsonEncode(_schema))). `.rls` files are those
/// bytes; `RlsSticker.encode()`/`RlsSticker.decodeBytes()` are the only two
/// places that need to know that.
///
/// JSON schema (fmt "rls1"):
/// ```json
/// {
///   "fmt": "rls1",
///   "w": 512, "h": 512,       // canvas size, px
///   "durMs": 1600,             // one loop's duration. Playback is continuous
///                               // (time-driven interpolation), not frame-
///                               // quantized, so there is no "fps" field.
///   "loop": true,
///   "assets": { "a1": "<base64 png bytes>", ... },   // deduped raster layers
///   "layers": [
///     {
///       "id": "l1",
///       "asset": "a1",
///       "anchor": [0.5, 0.5],  // rotation/scale pivot, normalized to the image
///       "ease": "easeOut",     // default easing name for this layer's segments
///       "keys": [
///         {"t": 0,    "x":256,"y":256,"sx":1,"sy":1,"rot":0,"a":1},
///         {"t": 400,  "x":256,"y":220,"sx":1.15,"sy":1.15,"rot":6,"a":1, "ease":"outBack"},
///         {"t": 1600, "x":256,"y":256,"sx":1,"sy":1,"rot":0,"a":1}
///       ]
///     }
///   ]
/// }
/// ```
/// `x`/`y` are canvas pixel coordinates of the layer's anchor point; `sx`/`sy`
/// are scale factors; `rot` is degrees; `a` is opacity 0..1. Keyframes must be
/// sorted by `t` (ms, relative to loop start). A keyframe's own `ease`
/// overrides the layer default for the segment ending at that keyframe.
const String rlsFormatId = 'rls1';
const String rlsFileExtension = '.rls';

/// MIME used when an `.rls` travels as a `data:` URL (the web collection has no
/// real files, so the extension isn't available to identify it by).
const String rlsMimeType = 'application/x-rls';

/// Is this renderable ref an animated sticker? Covers both shapes a ref can
/// take: a path/URL ending in `.rls` (native files, OPFS entries) and a
/// `data:application/x-rls;base64,…` inline ref (web collection).
bool looksLikeRlsRef(String ref) {
  if (ref.startsWith('data:')) return ref.startsWith('data:$rlsMimeType');
  return ref.split('#').first.split('?').first.toLowerCase().endsWith(
        rlsFileExtension,
      );
}

/// Ceilings applied when decoding. `.rls` files arrive from other people over
/// the network, so a malformed or hostile one must be rejected rather than be
/// allowed to allocate unbounded work in the renderer.
const int rlsMaxLayers = 64;
const int rlsMaxKeysPerLayer = 512;
const int rlsMaxCanvasSide = 4096;
const int rlsMaxDurationMs = 60000;
const int rlsMaxTotalAssetBytes = 16 * 1024 * 1024;

class RlsKeyframe {
  final int tMs;
  final double x;
  final double y;
  final double sx;
  final double sy;
  final double rotDeg;
  final double alpha;
  final String? ease;

  const RlsKeyframe({
    required this.tMs,
    required this.x,
    required this.y,
    this.sx = 1,
    this.sy = 1,
    this.rotDeg = 0,
    this.alpha = 1,
    this.ease,
  });

  Map<String, dynamic> toJson() => {
        't': tMs,
        'x': x,
        'y': y,
        if (sx != 1) 'sx': sx,
        if (sy != 1) 'sy': sy,
        if (rotDeg != 0) 'rot': rotDeg,
        if (alpha != 1) 'a': alpha,
        if (ease != null) 'ease': ease,
      };

  factory RlsKeyframe.fromJson(Map<String, dynamic> m) => RlsKeyframe(
        tMs: (m['t'] as num).toInt(),
        x: (m['x'] as num).toDouble(),
        y: (m['y'] as num).toDouble(),
        sx: (m['sx'] as num?)?.toDouble() ?? 1,
        sy: (m['sy'] as num?)?.toDouble() ?? 1,
        rotDeg: (m['rot'] as num?)?.toDouble() ?? 0,
        alpha: (m['a'] as num?)?.toDouble() ?? 1,
        ease: m['ease'] as String?,
      );
}

class RlsLayer {
  final String id;
  final String assetId;
  final double anchorX; // 0..1, normalized within the source image
  final double anchorY;
  final String defaultEase;
  final List<RlsKeyframe> keys; // sorted by tMs

  const RlsLayer({
    required this.id,
    required this.assetId,
    this.anchorX = 0.5,
    this.anchorY = 0.5,
    this.defaultEase = 'linear',
    required this.keys,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'asset': assetId,
        'anchor': [anchorX, anchorY],
        if (defaultEase != 'linear') 'ease': defaultEase,
        'keys': keys.map((k) => k.toJson()).toList(),
      };

  factory RlsLayer.fromJson(Map<String, dynamic> m) {
    final anchor = (m['anchor'] as List?)?.cast<num>();
    return RlsLayer(
      id: m['id'] as String,
      assetId: m['asset'] as String,
      anchorX: anchor != null && anchor.length > 0 ? anchor[0].toDouble() : 0.5,
      anchorY: anchor != null && anchor.length > 1 ? anchor[1].toDouble() : 0.5,
      defaultEase: (m['ease'] as String?) ?? 'linear',
      keys: ((m['keys'] as List?) ?? const [])
          .map((e) => RlsKeyframe.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList()
        ..sort((a, b) => a.tMs.compareTo(b.tMs)),
    );
  }

  /// Interpolated transform at [tMs] (already wrapped into [0, duration)).
  /// Holds the first/last keyframe's value outside their range.
  ({double x, double y, double sx, double sy, double rotDeg, double alpha})
      transformAt(int tMs) {
    if (keys.isEmpty) {
      return (x: 0, y: 0, sx: 1, sy: 1, rotDeg: 0, alpha: 1);
    }
    if (tMs <= keys.first.tMs) {
      final k = keys.first;
      return (x: k.x, y: k.y, sx: k.sx, sy: k.sy, rotDeg: k.rotDeg, alpha: k.alpha);
    }
    if (tMs >= keys.last.tMs) {
      final k = keys.last;
      return (x: k.x, y: k.y, sx: k.sx, sy: k.sy, rotDeg: k.rotDeg, alpha: k.alpha);
    }
    for (var i = 0; i < keys.length - 1; i++) {
      final a = keys[i];
      final b = keys[i + 1];
      if (tMs < a.tMs || tMs > b.tMs) continue;
      final span = (b.tMs - a.tMs).clamp(1, 1 << 30);
      final rawP = (tMs - a.tMs) / span;
      final p = _ease(b.ease ?? defaultEase, rawP.clamp(0.0, 1.0));
      return (
        x: _lerp(a.x, b.x, p),
        y: _lerp(a.y, b.y, p),
        sx: _lerp(a.sx, b.sx, p),
        sy: _lerp(a.sy, b.sy, p),
        rotDeg: _lerp(a.rotDeg, b.rotDeg, p),
        alpha: _lerp(a.alpha, b.alpha, p),
      );
    }
    final k = keys.last;
    return (x: k.x, y: k.y, sx: k.sx, sy: k.sy, rotDeg: k.rotDeg, alpha: k.alpha);
  }
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Named easing curves, evaluated by hand so this file has no Flutter
/// dependency (the model stays usable from pure-Dart tooling/tests).
double _ease(String name, double t) {
  switch (name) {
    case 'linear':
      return t;
    case 'easeIn':
      return t * t;
    case 'easeOut':
      return 1 - (1 - t) * (1 - t);
    case 'easeInOut':
      return t < 0.5 ? 2 * t * t : 1 - ((-2 * t + 2) * (-2 * t + 2)) / 2;
    case 'outBack':
      const c1 = 1.70158, c3 = c1 + 1;
      final u = t - 1;
      return 1 + c3 * u * u * u + c1 * u * u;
    case 'outBounce':
      const n1 = 7.5625, d1 = 2.75;
      var x = t;
      if (x < 1 / d1) return n1 * x * x;
      if (x < 2 / d1) {
        x -= 1.5 / d1;
        return n1 * x * x + 0.75;
      }
      if (x < 2.5 / d1) {
        x -= 2.25 / d1;
        return n1 * x * x + 0.9375;
      }
      x -= 2.625 / d1;
      return n1 * x * x + 0.984375;
    default:
      return t;
  }
}

class RlsSticker {
  final int width;
  final int height;
  final int durationMs;
  final bool loop;
  final Map<String, Uint8List> assets; // assetId -> PNG bytes
  final List<RlsLayer> layers;

  const RlsSticker({
    required this.width,
    required this.height,
    required this.durationMs,
    this.loop = true,
    required this.assets,
    required this.layers,
  });

  Map<String, dynamic> _toSchema() => {
        'fmt': rlsFormatId,
        'w': width,
        'h': height,
        'durMs': durationMs,
        'loop': loop,
        'assets': assets.map((k, v) => MapEntry(k, base64Encode(v))),
        'layers': layers.map((l) => l.toJson()).toList(),
      };

  static RlsSticker _fromSchema(Map<String, dynamic> m) {
    final rawAssets = (m['assets'] as Map?) ?? const {};
    return RlsSticker(
      width: (m['w'] as num).toInt(),
      height: (m['h'] as num).toInt(),
      durationMs: (m['durMs'] as num).toInt(),
      loop: m['loop'] as bool? ?? true,
      assets: rawAssets.map(
        (k, v) => MapEntry(k as String, base64Decode(v as String)),
      ),
      layers: ((m['layers'] as List?) ?? const [])
          .map((e) => RlsLayer.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  /// Encodes to the on-disk `.rls` byte format: gzip(utf8(json)).
  Uint8List encode() {
    final jsonBytes = utf8.encode(jsonEncode(_toSchema()));
    return Uint8List.fromList(GZipEncoder().encode(jsonBytes));
  }

  /// Decodes `.rls` bytes. Returns null on any malformed, foreign or
  /// out-of-bounds input rather than throwing — callers treat an unreadable
  /// sticker as "missing", never a crash.
  static RlsSticker? decodeBytes(Uint8List bytes) {
    try {
      final jsonBytes = GZipDecoder().decodeBytes(bytes);
      final decoded = jsonDecode(utf8.decode(jsonBytes));
      if (decoded is! Map || decoded['fmt'] != rlsFormatId) return null;
      final s = _fromSchema(Map<String, dynamic>.from(decoded));
      return s._withinLimits() ? s : null;
    } catch (_) {
      return null;
    }
  }

  /// A sticker from the network must not be able to make the renderer do
  /// unbounded work — reject anything past the ceilings instead of clamping,
  /// so a bad file reads as "missing" rather than as a mangled sticker.
  bool _withinLimits() {
    if (width < 1 || width > rlsMaxCanvasSide) return false;
    if (height < 1 || height > rlsMaxCanvasSide) return false;
    if (durationMs < 1 || durationMs > rlsMaxDurationMs) return false;
    if (layers.length > rlsMaxLayers) return false;
    if (assets.length > rlsMaxLayers) return false;
    var total = 0;
    for (final a in assets.values) {
      total += a.length;
      if (total > rlsMaxTotalAssetBytes) return false;
    }
    for (final l in layers) {
      if (l.keys.length > rlsMaxKeysPerLayer) return false;
    }
    return true;
  }
}
