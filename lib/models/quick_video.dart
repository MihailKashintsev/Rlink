import 'dart:math' as math;

import 'package:camera/camera.dart' show ResolutionPreset;
import 'package:flutter/material.dart';
import 'package:video_compress/video_compress.dart' show VideoQuality;

import '../l10n/app_l10n.dart';

/// Форма «быстрого видео» (аналог кружка Telegram). Файл всегда квадратный
/// (`*_sq.mp4`), форма — маска при показе. Она едет к получателю в самом имени:
/// id сообщения = `<uuid>_sh<форма>` (для квадрата суффикса нет), поэтому старые
/// клиенты просто видят обычный квадратик, а протокол не менялся.
enum QuickVideoShape { square, circle, star, heart, hexagon, flower }

final _shapeInPath =
    RegExp(r'_sh(circle|star|heart|hexagon|flower)(?=[_.#/:]|$)');

extension QuickVideoShapeX on QuickVideoShape {
  String get label => switch (this) {
        QuickVideoShape.square => AppL10n.t('Квадрат'),
        QuickVideoShape.circle => AppL10n.t('Круг'),
        QuickVideoShape.star => AppL10n.t('Звезда'),
        QuickVideoShape.heart => AppL10n.t('Сердце'),
        QuickVideoShape.hexagon => AppL10n.t('Шестиугольник'),
        QuickVideoShape.flower => AppL10n.t('Цветок'),
      };

  /// `<id>` для квадрата, иначе `<id>_sh<форма>`.
  String tagId(String id) => this == QuickVideoShape.square ? id : '${id}_sh$name';

  /// Имя файла/путь → форма (квадрат, если метки нет).
  static QuickVideoShape fromPath(String path) {
    final m = _shapeInPath.firstMatch(path);
    return m == null ? QuickVideoShape.square : QuickVideoShape.values.byName(m.group(1)!);
  }

  static QuickVideoShape fromName(String? n) => QuickVideoShape.values
      .firstWhere((s) => s.name == n, orElse: () => QuickVideoShape.circle);

  /// Контур формы, вписанный в [r].
  Path pathIn(Rect r) {
    final side = r.shortestSide;
    final c = r.center;
    final rad = side / 2;
    switch (this) {
      case QuickVideoShape.square:
        return Path()
          ..addRRect(RRect.fromRectAndRadius(r, Radius.circular(side * 0.1)));
      case QuickVideoShape.circle:
        return Path()..addOval(r);
      case QuickVideoShape.star:
        final pts = <Offset>[
          for (var i = 0; i < 10; i++)
            c +
                Offset.fromDirection(
                    -math.pi / 2 + i * math.pi / 5, i.isEven ? rad : rad * 0.64)
        ];
        return _roundedPolygon(pts, side * 0.07);
      case QuickVideoShape.hexagon:
        final pts = <Offset>[
          for (var i = 0; i < 6; i++)
            c + Offset.fromDirection(-math.pi / 2 + i * math.pi / 3, rad)
        ];
        return _roundedPolygon(pts, side * 0.08);
      case QuickVideoShape.heart:
        double x(double u) => r.left + u * side + (r.width - side) / 2;
        double y(double v) => r.top + (v + 0.04) * side + (r.height - side) / 2;
        final path = Path()..moveTo(x(0.5), y(0.26));
        void cubic(double x1, double y1, double x2, double y2, double x3,
                double y3) =>
            path.cubicTo(x(x1), y(y1), x(x2), y(y2), x(x3), y(y3));
        cubic(0.5, 0.10, 0.66, 0.0, 0.80, 0.14);
        cubic(1.0, 0.34, 0.92, 0.62, 0.5, 0.92);
        cubic(0.08, 0.62, 0.0, 0.34, 0.20, 0.14);
        cubic(0.34, 0.0, 0.5, 0.10, 0.5, 0.26);
        return path..close();
      case QuickVideoShape.flower:
        final path = Path();
        const n = 160;
        for (var i = 0; i <= n; i++) {
          final t = -math.pi / 2 + i * 2 * math.pi / n;
          final rr = rad * (0.9 + 0.1 * math.cos(8 * (t + math.pi / 2)));
          final p = c + Offset.fromDirection(t, rr);
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        return path..close();
    }
  }
}

Path _roundedPolygon(List<Offset> p, double radius) {
  final path = Path();
  final n = p.length;
  for (var i = 0; i < n; i++) {
    final prev = p[(i - 1 + n) % n], cur = p[i], next = p[(i + 1) % n];
    final v1 = prev - cur, v2 = next - cur;
    final cut = math.min(radius, math.min(v1.distance, v2.distance) / 2);
    final a = cur + v1 / v1.distance * cut;
    final b = cur + v2 / v2.distance * cut;
    i == 0 ? path.moveTo(a.dx, a.dy) : path.lineTo(a.dx, a.dy);
    path.quadraticBezierTo(cur.dx, cur.dy, b.dx, b.dy);
  }
  return path..close();
}

class QuickVideoShapeClipper extends CustomClipper<Path> {
  final QuickVideoShape shape;
  const QuickVideoShapeClipper(this.shape);

  @override
  Path getClip(Size size) => shape.pathIn(Offset.zero & size);

  @override
  bool shouldReclip(covariant QuickVideoShapeClipper old) => old.shape != shape;
}

/// Маска формы для видео в пузыре.
class QuickVideoClip extends StatelessWidget {
  final QuickVideoShape shape;
  final Widget child;
  const QuickVideoClip({super.key, required this.shape, required this.child});

  @override
  Widget build(BuildContext context) => ClipPath(
        clipper: QuickVideoShapeClipper(shape),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
}

/// Контур формы; [progress] (0..1) рисуется поверх него по периметру.
class QuickVideoOutlinePainter extends CustomPainter {
  final QuickVideoShape shape;
  final Color color;
  final Color trackColor;
  final double width;
  final double? progress;

  const QuickVideoOutlinePainter({
    required this.shape,
    required this.color,
    this.trackColor = Colors.white24,
    this.width = 3,
    this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = shape.pathIn((Offset.zero & size).deflate(width / 2));
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeJoin = StrokeJoin.round
      ..color = trackColor;
    canvas.drawPath(path, track);
    final p = progress;
    if (p == null || p <= 0) return;
    final fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    canvas.save();
    if (shape == QuickVideoShape.circle) {
      // Oval path starts at 3 o'clock; make progress start at 12.
      canvas.translate(size.width / 2, size.height / 2);
      canvas.rotate(-math.pi / 2);
      canvas.translate(-size.width / 2, -size.height / 2);
    }
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * p.clamp(0.0, 1.0)), fill);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant QuickVideoOutlinePainter o) =>
      o.shape != shape ||
      o.color != color ||
      o.progress != progress ||
      o.width != width ||
      o.trackColor != trackColor;
}

/// Качество записи быстрого видео.
enum QuickVideoQuality { low, standard, high }

extension QuickVideoQualityX on QuickVideoQuality {
  String get label => switch (this) {
        QuickVideoQuality.low => AppL10n.t('Низкое'),
        QuickVideoQuality.standard => AppL10n.t('Стандартное'),
        QuickVideoQuality.high => AppL10n.t('Высокое'),
      };

  /// Разрешение камеры при записи.
  ResolutionPreset get preset => switch (this) {
        QuickVideoQuality.low => ResolutionPreset.low,
        QuickVideoQuality.standard => ResolutionPreset.medium,
        QuickVideoQuality.high => ResolutionPreset.high,
      };

  /// Сжатие перед отправкой.
  VideoQuality get compress => switch (this) {
        QuickVideoQuality.low => VideoQuality.LowQuality,
        QuickVideoQuality.standard => VideoQuality.MediumQuality,
        QuickVideoQuality.high => VideoQuality.Res1280x720Quality,
      };

  static QuickVideoQuality fromName(String? n) => QuickVideoQuality.values
      .firstWhere((q) => q.name == n, orElse: () => QuickVideoQuality.standard);
}
