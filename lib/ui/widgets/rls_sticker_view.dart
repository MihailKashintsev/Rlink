import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/rls_sticker.dart';

/// Plays a [RlsSticker] on loop: decodes its raster layers once, then paints
/// each frame by applying the layer's keyframed transform (see rls_sticker.dart
/// for the format). Static and network/asset fallbacks are the caller's job —
/// this widget only knows how to play a sticker it already has bytes for.
class RlsStickerView extends StatefulWidget {
  final RlsSticker sticker;
  final double? width;
  final double? height;

  const RlsStickerView({super.key, required this.sticker, this.width, this.height});

  @override
  State<RlsStickerView> createState() => _RlsStickerViewState();
}

class _RlsStickerViewState extends State<RlsStickerView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final Map<String, ui.Image> _images = {};
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.sticker.durationMs.clamp(1, 1 << 30)),
    );
    unawaited(_decodeAssets());
  }

  Future<void> _decodeAssets() async {
    for (final e in widget.sticker.assets.entries) {
      try {
        final codec = await ui.instantiateImageCodec(e.value);
        final frame = await codec.getNextFrame();
        _images[e.key] = frame.image;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _ready = true);
    if (widget.sticker.loop) {
      // Plays 3 full cycles then settles rather than looping forever — each
      // time the message scrolls into view or the chat reopens, this widget
      // is recreated (initState runs again), so the count naturally resets.
      _ctrl.repeat(count: 3);
    } else {
      _ctrl.forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    for (final im in _images.values) {
      im.dispose();
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
                  painter: _RlsPainter(
                    sticker: s,
                    images: _images,
                    tMs: (_ctrl.value * s.durationMs).round(),
                  ),
                ),
              ),
            ),
    );
  }
}

class _RlsPainter extends CustomPainter {
  final RlsSticker sticker;
  final Map<String, ui.Image> images;
  final int tMs;

  _RlsPainter({required this.sticker, required this.images, required this.tMs});

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / sticker.width;
    final scaleY = size.height / sticker.height;
    canvas.save();
    canvas.scale(scaleX, scaleY);
    for (final layer in sticker.layers) {
      final image = images[layer.assetId];
      if (image == null) continue;
      final tr = layer.transformAt(tMs);
      if (tr.alpha <= 0.003) continue;
      final iw = image.width.toDouble();
      final ih = image.height.toDouble();
      canvas.save();
      canvas.translate(tr.x, tr.y);
      canvas.rotate(tr.rotDeg * math.pi / 180);
      canvas.scale(tr.sx, tr.sy);
      canvas.translate(-layer.anchorX * iw, -layer.anchorY * ih);
      final paint = Paint()
        ..color = Color.fromRGBO(255, 255, 255, tr.alpha.clamp(0.0, 1.0))
        ..filterQuality = FilterQuality.high;
      canvas.drawImage(image, Offset.zero, paint);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RlsPainter old) =>
      old.tMs != tMs || !identical(old.sticker, sticker);
}
