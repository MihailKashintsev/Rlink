import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/rlv_sticker.dart';

/// Plays an [RlvSticker] on loop: builds each layer's vector content once
/// (shape/path `Path`s synchronously, SVG layers decoded once into a cached
/// `ui.Picture`), then paints each frame by applying the layer's keyframed
/// transform — same interpolation as `RlsStickerView`, vector content instead
/// of raster `drawImage`.
class RlvStickerView extends StatefulWidget {
  final RlvSticker sticker;
  final double? width;
  final double? height;

  const RlvStickerView({super.key, required this.sticker, this.width, this.height});

  @override
  State<RlvStickerView> createState() => _RlvStickerViewState();
}

class _RlvStickerViewState extends State<RlvStickerView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final Map<String, ui.Path> _shapePaths = {};
  final Map<String, Size> _shapeSizes = {};
  final Map<String, PictureInfo> _svgPictures = {};
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.sticker.durationMs.clamp(1, 1 << 30)),
    );
    unawaited(_decodeLayers());
  }

  Future<void> _decodeLayers() async {
    for (final layer in widget.sticker.layers) {
      try {
        switch (layer.kind) {
          case 'shape':
            final size = layer.size;
            if (size == null || size.length < 2) continue;
            _shapePaths[layer.id] = buildShapePath(
              layer.shapeType ?? 'rect',
              size[0],
              size[1],
              sides: layer.sides,
              cornerRadius: layer.cornerRadius,
            );
            _shapeSizes[layer.id] = Size(size[0], size[1]);
          case 'path':
            final size = layer.size;
            if (size == null || size.length < 2 || layer.points == null) continue;
            _shapePaths[layer.id] = buildFreehandPath(
              layer.points!,
              size[0],
              size[1],
              closed: layer.closed,
            );
            _shapeSizes[layer.id] = Size(size[0], size[1]);
          case 'svg':
            final svg = layer.svg;
            if (svg == null) continue;
            final info = await vg.loadPicture(SvgStringLoader(svg), null);
            _svgPictures[layer.id] = info;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _ready = true);
    if (widget.sticker.loop) {
      _ctrl.repeat();
    } else {
      _ctrl.forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    for (final info in _svgPictures.values) {
      info.picture.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sticker;
    final aspect = s.width / s.height;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: !_ready
          ? const SizedBox.shrink()
          : AspectRatio(
              aspectRatio: aspect,
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (_, __) => CustomPaint(
                  painter: _RlvPainter(
                    sticker: s,
                    shapePaths: _shapePaths,
                    shapeSizes: _shapeSizes,
                    svgPictures: _svgPictures,
                    tMs: (_ctrl.value * s.durationMs).round(),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Builds a shape primitive's outline in local space, origin at the
/// bounding box's top-left corner — same convention `RlsStickerView` uses
/// for raster images, so the anchor-offset math in the painter is identical.
ui.Path buildShapePath(
  String shapeType,
  double w,
  double h, {
  int sides = 5,
  double cornerRadius = 0,
}) {
  switch (shapeType) {
    case 'circle':
      return ui.Path()..addOval(Rect.fromLTWH(0, 0, w, h));
    case 'star':
      return _polygonPath(w, h, sides < 3 ? 5 : sides, starred: true);
    case 'polygon':
      return _polygonPath(w, h, sides < 3 ? 5 : sides, starred: false);
    case 'line':
      return ui.Path()
        ..moveTo(0, h / 2)
        ..lineTo(w, h / 2);
    case 'rect':
    default:
      if (cornerRadius > 0) {
        return ui.Path()
          ..addRRect(RRect.fromLTRBR(0, 0, w, h, Radius.circular(cornerRadius)));
      }
      return ui.Path()..addRect(Rect.fromLTWH(0, 0, w, h));
  }
}

ui.Path _polygonPath(double w, double h, int sides, {required bool starred}) {
  final cx = w / 2, cy = h / 2;
  final outerR = math.min(w, h) / 2;
  final innerR = outerR * 0.5;
  final points = starred ? sides * 2 : sides;
  final path = ui.Path();
  for (var i = 0; i < points; i++) {
    final angle = (math.pi * 2 * i / points) - math.pi / 2;
    final r = starred && i.isOdd ? innerR : outerR;
    final x = cx + r * math.cos(angle);
    final y = cy + r * math.sin(angle);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  path.close();
  return path;
}

/// Builds a freehand stroke's `Path` from normalized flat `[x0,y0,x1,y1,...]`
/// points, scaled against the layer's local bounding box.
ui.Path buildFreehandPath(List<double> points, double w, double h, {bool closed = false}) {
  final path = ui.Path();
  if (points.length < 2) return path;
  path.moveTo(points[0] * w, points[1] * h);
  for (var i = 2; i + 1 < points.length; i += 2) {
    path.lineTo(points[i] * w, points[i + 1] * h);
  }
  if (closed) path.close();
  return path;
}

/// Parses `#RRGGBBAA` (or `#RRGGBB`, alpha defaults to opaque) into a
/// [Color]. Returns null on anything malformed.
Color? parseRlvHexColor(String? hex) {
  if (hex == null) return null;
  var h = hex.startsWith('#') ? hex.substring(1) : hex;
  if (h.length == 6) h = '${h}FF';
  if (h.length != 8) return null;
  final v = int.tryParse(h, radix: 16);
  if (v == null) return null;
  return Color.fromARGB(v & 0xFF, (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF);
}

class _RlvPainter extends CustomPainter {
  final RlvSticker sticker;
  final Map<String, ui.Path> shapePaths;
  final Map<String, Size> shapeSizes;
  final Map<String, PictureInfo> svgPictures;
  final int tMs;

  _RlvPainter({
    required this.sticker,
    required this.shapePaths,
    required this.shapeSizes,
    required this.svgPictures,
    required this.tMs,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / sticker.width;
    final scaleY = size.height / sticker.height;
    canvas.save();
    canvas.scale(scaleX, scaleY);
    for (final layer in sticker.layers) {
      final tr = layer.transformAt(tMs);
      if (tr.alpha <= 0.003) continue;
      final alpha = tr.alpha.clamp(0.0, 1.0);
      canvas.save();
      canvas.translate(tr.x, tr.y);
      canvas.rotate(tr.rotDeg * math.pi / 180);
      canvas.scale(tr.sx, tr.sy);

      if (layer.kind == 'svg') {
        final info = svgPictures[layer.id];
        if (info != null) {
          canvas.translate(-layer.anchorX * info.size.width, -layer.anchorY * info.size.height);
          canvas.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, alpha));
          canvas.drawPicture(info.picture);
          canvas.restore();
        }
      } else {
        final path = shapePaths[layer.id];
        final localSize = shapeSizes[layer.id];
        if (path != null && localSize != null) {
          canvas.translate(-layer.anchorX * localSize.width, -layer.anchorY * localSize.height);
          if (layer.kind == 'shape') {
            final fill = parseRlvHexColor(layer.fill);
            if (fill != null) {
              canvas.drawPath(
                path,
                Paint()
                  ..style = PaintingStyle.fill
                  ..color = fill.withValues(alpha: (fill.a * alpha).clamp(0.0, 1.0)),
              );
            }
            final stroke = parseRlvHexColor(layer.stroke);
            if (stroke != null && layer.strokeWidth > 0) {
              canvas.drawPath(
                path,
                Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = layer.strokeWidth
                  ..strokeCap = StrokeCap.round
                  ..strokeJoin = StrokeJoin.round
                  ..color = stroke.withValues(alpha: (stroke.a * alpha).clamp(0.0, 1.0)),
              );
            }
          } else {
            // freehand path
            final color = parseRlvHexColor(layer.color) ?? const Color(0xFF000000);
            final strokeWidthPx = layer.strokeWidth * localSize.width;
            final paint = Paint()
              ..color = color.withValues(alpha: (color.a * alpha).clamp(0.0, 1.0))
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round;
            if (layer.filled) {
              paint.style = PaintingStyle.fill;
            } else {
              paint.style = PaintingStyle.stroke;
              paint.strokeWidth = strokeWidthPx <= 0 ? 1 : strokeWidthPx;
            }
            canvas.drawPath(path, paint);
          }
        }
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RlvPainter old) =>
      old.tMs != tMs || !identical(old.sticker, sticker);
}
