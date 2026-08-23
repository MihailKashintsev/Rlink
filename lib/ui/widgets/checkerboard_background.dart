import 'package:flutter/material.dart';

/// Transparency checkerboard, shared by any preview that needs to show
/// where an image has (or doesn't have) alpha — background removal and
/// photo-to-vector both render onto this.
class CheckerboardBackground extends StatelessWidget {
  const CheckerboardBackground({super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _CheckerPainter());
}

class _CheckerPainter extends CustomPainter {
  static const _cell = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final light = Paint()..color = const Color(0xFFDDDDDD);
    final dark = Paint()..color = const Color(0xFFBBBBBB);
    canvas.drawRect(Offset.zero & size, light);
    for (var y = 0.0; y < size.height; y += _cell) {
      for (var x = 0.0; x < size.width; x += _cell) {
        final col = (x / _cell).floor();
        final row = (y / _cell).floor();
        if ((col + row).isOdd) {
          canvas.drawRect(Rect.fromLTWH(x, y, _cell, _cell), dark);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
