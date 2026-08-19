import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Rlink's vector-sticker container: **.rlv**.
///
/// Sibling of `.rls` (`rls_sticker.dart`), not an extension of it — same
/// container technique (gzip(utf8(json))), same keyframe/easing shape and
/// semantics, but layers are vector (shape primitives, a freehand path, or an
/// imported SVG) instead of raster PNG. Kept as a fully separate model on
/// purpose: the only genuinely shareable code between the two formats is the
/// ~35-line easing/lerp switch, and copying that is cheaper and safer than
/// reaching into the shipped, tested `.rls` model to extract it.
///
/// JSON schema (fmt "rlv1"):
/// ```json
/// {
///   "fmt": "rlv1",
///   "w": 512, "h": 512, "durMs": 1500, "loop": true,
///   "layers": [
///     {"id":"l1","kind":"shape","shapeType":"rect","sides":0,"cornerRadius":8,
///      "fill":"#FF3B30FF","stroke":null,"strokeWidth":0,"size":[160,160],
///      "anchor":[0.5,0.5],"ease":"easeOut","keys":[...]},
///     {"id":"l2","kind":"path","points":[0.1,0.2,0.15,0.3],
///      "color":"#000000FF","strokeWidth":0.04,"filled":false,"closed":false,
///      "size":[512,512],"anchor":[0.5,0.5],"ease":"linear","keys":[...]},
///     {"id":"l3","kind":"svg","svg":"<svg ...>...</svg>",
///      "anchor":[0.5,0.5],"ease":"easeInOut","keys":[...]}
///   ]
/// }
/// ```
/// `kind:"shape"` — `shapeType` one of rect/circle/star/polygon/line; `sides`
/// only matters for star/polygon; `size` is the layer's local unscaled
/// bounding box, anchor-centered. `kind:"path"` — freehand stroke, `points`
/// are a flat x,y,x,y,... list normalized 0..1 against the layer's own
/// `size` (captured at editor canvas resolution), `strokeWidth` is also a
/// fraction of `size`, not raw px, so the stroke renders correctly at any
/// playback scale. `kind:"svg"` — `svg` is raw inline SVG source text; no
/// `size` is stored for it, the decoded picture's own intrinsic size is used
/// (storing it redundantly risks drifting from what actually renders).
const String rlvFormatId = 'rlv1';
const String rlvFileExtension = '.rlv';

/// MIME used when an `.rlv` travels as a `data:` URL (web collection has no
/// real files, mirrors `rlsMimeType`'s role).
const String rlvMimeType = 'application/x-rlv';

/// Is this renderable ref a vector sticker? Same two shapes as
/// [looksLikeRlsRef]: extension on a path/URL, or MIME on a `data:` ref.
bool looksLikeRlvRef(String ref) {
  if (ref.startsWith('data:')) return ref.startsWith('data:$rlvMimeType');
  return ref.split('#').first.split('?').first.toLowerCase().endsWith(
        rlvFileExtension,
      );
}

/// Ceilings applied when decoding. Vector data is inherently tiny compared to
/// raster — these are deliberately far below `.rls`'s byte ceilings, not
/// scaled proportionally, since a legitimate sticker never needs to approach
/// them; they exist purely to reject hostile/corrupt input cheaply.
const int rlvMaxLayers = 64;
const int rlvMaxKeysPerLayer = 512;
const int rlvMaxCanvasSide = 4096;
const int rlvMaxDurationMs = 60000;
const int rlvMaxPointsPerPath = 2000; // decode-time backstop, not a capture target
const int rlvMaxSvgBytesPerLayer = 256 * 1024;
const int rlvMaxTotalInlineBytes = 1 * 1024 * 1024;

class RlvKeyframe {
  final int tMs;
  final double x;
  final double y;
  final double sx;
  final double sy;
  final double rotDeg;
  final double alpha;
  final String? ease;

  const RlvKeyframe({
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

  factory RlvKeyframe.fromJson(Map<String, dynamic> m) => RlvKeyframe(
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

typedef RlvPose = ({double x, double y, double sx, double sy, double rotDeg, double alpha});

class RlvLayer {
  final String id;
  final String kind; // 'shape' | 'path' | 'svg'

  // kind == 'shape'
  final String? shapeType; // rect|circle|star|polygon|line
  final int sides;
  final double cornerRadius;
  final String? fill; // "#RRGGBBAA"
  final String? stroke; // "#RRGGBBAA", nullable
  final double strokeWidth; // shape: local px. path: fraction of size.

  // kind == 'path' (freehand)
  final List<double>? points; // flat [x0,y0,x1,y1,...] normalized 0..1
  final String? color;
  final bool filled;
  final bool closed;

  // shape + path share a local bounding box; svg uses its own intrinsic size
  final List<double>? size; // [w, h]

  // kind == 'svg'
  final String? svg;

  final double anchorX; // 0..1
  final double anchorY;
  final String defaultEase;
  final List<RlvKeyframe> keys; // sorted by tMs

  const RlvLayer({
    required this.id,
    required this.kind,
    this.shapeType,
    this.sides = 0,
    this.cornerRadius = 0,
    this.fill,
    this.stroke,
    this.strokeWidth = 0,
    this.points,
    this.color,
    this.filled = false,
    this.closed = false,
    this.size,
    this.svg,
    this.anchorX = 0.5,
    this.anchorY = 0.5,
    this.defaultEase = 'linear',
    required this.keys,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        if (shapeType != null) 'shapeType': shapeType,
        if (sides != 0) 'sides': sides,
        if (cornerRadius != 0) 'cornerRadius': cornerRadius,
        if (fill != null) 'fill': fill,
        if (stroke != null) 'stroke': stroke,
        if (strokeWidth != 0) 'strokeWidth': strokeWidth,
        if (points != null) 'points': points,
        if (color != null) 'color': color,
        if (filled) 'filled': filled,
        if (closed) 'closed': closed,
        if (size != null) 'size': size,
        if (svg != null) 'svg': svg,
        'anchor': [anchorX, anchorY],
        if (defaultEase != 'linear') 'ease': defaultEase,
        'keys': keys.map((k) => k.toJson()).toList(),
      };

  factory RlvLayer.fromJson(Map<String, dynamic> m) {
    final anchor = (m['anchor'] as List?)?.cast<num>();
    final rawPoints = (m['points'] as List?)?.cast<num>();
    final rawSize = (m['size'] as List?)?.cast<num>();
    return RlvLayer(
      id: m['id'] as String,
      kind: m['kind'] as String,
      shapeType: m['shapeType'] as String?,
      sides: (m['sides'] as num?)?.toInt() ?? 0,
      cornerRadius: (m['cornerRadius'] as num?)?.toDouble() ?? 0,
      fill: m['fill'] as String?,
      stroke: m['stroke'] as String?,
      strokeWidth: (m['strokeWidth'] as num?)?.toDouble() ?? 0,
      points: rawPoints?.map((e) => e.toDouble()).toList(),
      color: m['color'] as String?,
      filled: m['filled'] as bool? ?? false,
      closed: m['closed'] as bool? ?? false,
      size: rawSize?.map((e) => e.toDouble()).toList(),
      svg: m['svg'] as String?,
      anchorX: anchor != null && anchor.length > 0 ? anchor[0].toDouble() : 0.5,
      anchorY: anchor != null && anchor.length > 1 ? anchor[1].toDouble() : 0.5,
      defaultEase: (m['ease'] as String?) ?? 'linear',
      keys: ((m['keys'] as List?) ?? const [])
          .map((e) => RlvKeyframe.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList()
        ..sort((a, b) => a.tMs.compareTo(b.tMs)),
    );
  }

  /// Interpolated transform at [tMs]. Identical semantics to
  /// `RlsLayer.transformAt`: holds first/last keyframe outside range, affine
  /// lerp between keys after remapping through the eased `t`.
  RlvPose transformAt(int tMs) {
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

/// Named easing curves — same 6 as `.rls`, evaluated by hand so this file has
/// no Flutter dependency. Deliberately not shared with `rls_sticker.dart`'s
/// copy (see file doc-comment).
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

class RlvSticker {
  final int width;
  final int height;
  final int durationMs;
  final bool loop;
  final List<RlvLayer> layers;

  const RlvSticker({
    required this.width,
    required this.height,
    required this.durationMs,
    this.loop = true,
    required this.layers,
  });

  Map<String, dynamic> _toSchema() => {
        'fmt': rlvFormatId,
        'w': width,
        'h': height,
        'durMs': durationMs,
        'loop': loop,
        'layers': layers.map((l) => l.toJson()).toList(),
      };

  static RlvSticker _fromSchema(Map<String, dynamic> m) => RlvSticker(
        width: (m['w'] as num).toInt(),
        height: (m['h'] as num).toInt(),
        durationMs: (m['durMs'] as num).toInt(),
        loop: m['loop'] as bool? ?? true,
        layers: ((m['layers'] as List?) ?? const [])
            .map((e) => RlvLayer.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );

  /// Encodes to the on-disk `.rlv` byte format: gzip(utf8(json)).
  Uint8List encode() {
    final jsonBytes = utf8.encode(jsonEncode(_toSchema()));
    return Uint8List.fromList(GZipEncoder().encode(jsonBytes));
  }

  /// Decodes `.rlv` bytes. Returns null on any malformed, foreign or
  /// out-of-bounds input rather than throwing — an unreadable sticker reads
  /// as "missing", never a crash.
  static RlvSticker? decodeBytes(Uint8List bytes) {
    try {
      final jsonBytes = GZipDecoder().decodeBytes(bytes);
      final decoded = jsonDecode(utf8.decode(jsonBytes));
      if (decoded is! Map || decoded['fmt'] != rlvFormatId) return null;
      final s = _fromSchema(Map<String, dynamic>.from(decoded));
      return s._withinLimits() ? s : null;
    } catch (_) {
      return null;
    }
  }

  bool _withinLimits() {
    if (width < 1 || width > rlvMaxCanvasSide) return false;
    if (height < 1 || height > rlvMaxCanvasSide) return false;
    if (durationMs < 1 || durationMs > rlvMaxDurationMs) return false;
    if (layers.length > rlvMaxLayers) return false;
    var totalInlineBytes = 0;
    for (final l in layers) {
      if (l.keys.length > rlvMaxKeysPerLayer) return false;
      if (l.kind == 'path') {
        final pts = l.points ?? const [];
        if (pts.length ~/ 2 > rlvMaxPointsPerPath) return false;
        totalInlineBytes += pts.length * 8;
      } else if (l.kind == 'svg') {
        final svgBytes = utf8.encode(l.svg ?? '').length;
        if (svgBytes > rlvMaxSvgBytesPerLayer) return false;
        totalInlineBytes += svgBytes;
      } else if (l.kind != 'shape') {
        return false; // unknown layer kind — reject rather than render garbage
      }
      if (totalInlineBytes > rlvMaxTotalInlineBytes) return false;
    }
    return true;
  }
}
