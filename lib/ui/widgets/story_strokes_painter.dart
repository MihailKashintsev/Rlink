import 'package:flutter/material.dart';

import '../../services/story_service.dart';

/// Paints freehand story drawing strokes. Points are normalised (0..1 of the
/// canvas) so the same data renders identically in the creator and the viewer
/// at any size. [active] is the in-progress stroke (creator only).
class StoryStrokesPainter extends CustomPainter {
  final List<StoryStroke> strokes;
  final List<double>? active;
  final int activeColor;
  final double activeWidth;

  StoryStrokesPainter({
    required this.strokes,
    this.active,
    this.activeColor = 0xFFFF3B30,
    this.activeWidth = 0.012,
  });

  void _drawStroke(
      Canvas canvas, Size size, List<double> pts, int color, double width) {
    if (pts.length < 4) {
      if (pts.length >= 2) {
        canvas.drawCircle(
          Offset(pts[0] * size.width, pts[1] * size.height),
          width * size.width / 2,
          Paint()..color = Color(color),
        );
      }
      return;
    }
    final paint = Paint()
      ..color = Color(color)
      ..strokeWidth = width * size.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final path = Path()..moveTo(pts[0] * size.width, pts[1] * size.height);
    for (var i = 2; i + 1 < pts.length; i += 2) {
      path.lineTo(pts[i] * size.width, pts[i + 1] * size.height);
    }
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      _drawStroke(canvas, size, s.points, s.color, s.width);
    }
    final a = active;
    if (a != null) _drawStroke(canvas, size, a, activeColor, activeWidth);
  }

  @override
  bool shouldRepaint(StoryStrokesPainter old) => true;
}
