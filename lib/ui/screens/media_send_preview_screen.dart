import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_l10n.dart';
import 'package:image/image.dart' as img;

/// A freehand pen stroke (local coords in the editing area).
class _PenStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  _PenStroke(this.points, this.color, this.width);
}

/// A text label placed on the photo (local coords in the editing area).
class _TextLabel {
  String text;
  Offset pos;
  final Color color;
  final double size;
  _TextLabel(this.text, this.pos, this.color, this.size);
}

class _StrokesPainter extends CustomPainter {
  final List<_PenStroke> strokes;
  final _PenStroke? active;
  _StrokesPainter(this.strokes, this.active);
  @override
  void paint(Canvas canvas, Size size) {
    for (final s in [...strokes, if (active != null) active!]) {
      if (s.points.length < 2) {
        if (s.points.length == 1) {
          canvas.drawCircle(s.points.first, s.width / 2,
              Paint()..color = s.color);
        }
        continue;
      }
      final p = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
      for (var i = 1; i < s.points.length; i++) {
        path.lineTo(s.points[i].dx, s.points[i].dy);
      }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_StrokesPainter old) => true;
}

/// Result returned by [MediaSendPreviewScreen]: the (possibly edited) image
/// bytes plus an optional caption typed by the user.
class MediaPreviewResult {
  final Uint8List bytes;
  final String caption;
  const MediaPreviewResult({required this.bytes, required this.caption});
}

/// Telegram-style "review before send" screen for a picked photo.
/// Lets the user rotate / crop the image and add a caption, then send.
/// Returns a [MediaPreviewResult] via `Navigator.pop`, or `null` if cancelled.
class MediaSendPreviewScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final String? peerName;

  const MediaSendPreviewScreen({
    super.key,
    required this.imageBytes,
    this.peerName,
  });

  @override
  State<MediaSendPreviewScreen> createState() => _MediaSendPreviewScreenState();
}

class _MediaSendPreviewScreenState extends State<MediaSendPreviewScreen> {
  late Uint8List _bytes;
  final _captionCtrl = TextEditingController();
  final _cropController = CropController();
  bool _cropMode = false;
  bool _busy = false;

  // Draw / text annotation.
  final GlobalKey _editKey = GlobalKey();
  bool _drawMode = false;
  bool _textMode = false;
  final List<_PenStroke> _strokes = [];
  _PenStroke? _activeStroke;
  final List<_TextLabel> _texts = [];
  Color _penColor = const Color(0xFFFF3B30);
  int _imgW = 0;
  int _imgH = 0;

  static const _palette = [
    Color(0xFFFF3B30), Color(0xFFFFFFFF), Color(0xFF000000),
    Color(0xFF34C759), Color(0xFF0A84FF), Color(0xFFFFD60A),
  ];

  bool get _hasAnnotations => _strokes.isNotEmpty || _texts.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _bytes = widget.imageBytes;
    _prepare();
  }

  /// Decode once to record dimensions (needed to composite annotations) and
  /// downscale huge photos so pure-Dart edits don't freeze the main thread.
  Future<void> _prepare() async {
    setState(() => _busy = true);
    try {
      var decoded = img.decodeImage(_bytes);
      if (decoded != null) {
        if (decoded.width > 2000 || decoded.height > 2000) {
          decoded = img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? 2000 : null,
            height: decoded.height > decoded.width ? 2000 : null,
            interpolation: img.Interpolation.average,
          );
          _bytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 88));
        }
        _imgW = decoded.width;
        _imgH = decoded.height;
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    super.dispose();
  }

  Future<void> _rotate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final decoded = img.decodeImage(_bytes);
      if (decoded != null) {
        final rotated = img.copyRotate(decoded, angle: 90);
        final out = Uint8List.fromList(img.encodeJpg(rotated, quality: 90));
        if (mounted) {
          setState(() {
            _bytes = out;
            _imgW = rotated.width;
            _imgH = rotated.height;
            _strokes.clear();
            _texts.clear();
          });
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось обработать изображение')),
        );
      }
    } catch (_) {
      // Non-decodable image — leave as-is.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (_busy) return;
    var out = _bytes;
    if (_hasAnnotations) {
      setState(() => _busy = true);
      try {
        out = await _compositeAnnotations();
      } catch (_) {
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    if (!mounted) return;
    Navigator.pop(
      context,
      MediaPreviewResult(bytes: out, caption: _captionCtrl.text.trim()),
    );
  }

  /// Bake strokes + text labels onto the image via dart:ui (CanvasKit-safe,
  /// unlike RenderRepaintBoundary.toImage which hangs on web).
  Future<Uint8List> _compositeAnnotations() async {
    if (!_hasAnnotations || _imgW == 0 || _imgH == 0) return _bytes;
    final box = _editKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || box.size.width <= 0) return _bytes;
    final sx = _imgW / box.size.width;
    final sy = _imgH / box.size.height;
    final codec = await ui.instantiateImageCodec(_bytes);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      src,
      Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      Rect.fromLTWH(0, 0, _imgW.toDouble(), _imgH.toDouble()),
      Paint(),
    );
    for (final s in _strokes) {
      if (s.points.isEmpty) continue;
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width * sx
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (s.points.length == 1) {
        canvas.drawCircle(Offset(s.points.first.dx * sx, s.points.first.dy * sy),
            s.width * sx / 2, Paint()..color = s.color);
        continue;
      }
      final path = Path()
        ..moveTo(s.points.first.dx * sx, s.points.first.dy * sy);
      for (var i = 1; i < s.points.length; i++) {
        path.lineTo(s.points[i].dx * sx, s.points[i].dy * sy);
      }
      canvas.drawPath(path, paint);
    }
    for (final t in _texts) {
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            color: t.color,
            fontSize: t.size * sx,
            fontWeight: FontWeight.w700,
            shadows: const [Shadow(blurRadius: 6, color: Colors.black54)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: _imgW.toDouble());
      tp.paint(canvas, Offset(t.pos.dx * sx, t.pos.dy * sy));
    }
    final pic = recorder.endRecording();
    final outImg = await pic.toImage(_imgW, _imgH);
    final bd = await outImg.toByteData(format: ui.ImageByteFormat.png);
    src.dispose();
    outImg.dispose();
    pic.dispose();
    return bd?.buffer.asUint8List() ?? _bytes;
  }

  Future<void> _addTextAt(Offset pos) async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Текст на фото'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(hintText: 'Введите текст…'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(AppL10n.t('common_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(AppL10n.t('common_add'))),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _texts.add(_TextLabel(text, pos, _penColor, 26));
    });
  }

  Widget _buildEditArea() {
    final aspect = (_imgW > 0 && _imgH > 0) ? _imgW / _imgH : 1.0;
    final annotating = _drawMode || _textMode;
    final stack = Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: Stack(
          key: _editKey,
          fit: StackFit.expand,
          children: [
            Image.memory(_bytes, fit: BoxFit.fill, gaplessPlayback: true),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _StrokesPainter(_strokes, _activeStroke),
                ),
              ),
            ),
            for (final t in _texts)
              Positioned(
                left: t.pos.dx,
                top: t.pos.dy,
                child: GestureDetector(
                  onPanUpdate: (d) => setState(() => t.pos += d.delta),
                  child: Text(
                    t.text,
                    style: TextStyle(
                      color: t.color,
                      fontSize: t.size,
                      fontWeight: FontWeight.w700,
                      shadows: const [
                        Shadow(blurRadius: 6, color: Colors.black54),
                      ],
                    ),
                  ),
                ),
              ),
            if (_drawMode)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => setState(() =>
                      _activeStroke = _PenStroke([d.localPosition], _penColor, 5)),
                  onPanUpdate: (d) =>
                      setState(() => _activeStroke?.points.add(d.localPosition)),
                  onPanEnd: (_) => setState(() {
                    if (_activeStroke != null &&
                        _activeStroke!.points.isNotEmpty) {
                      _strokes.add(_activeStroke!);
                    }
                    _activeStroke = null;
                  }),
                ),
              ),
            if (_textMode)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _addTextAt(d.localPosition),
                ),
              ),
          ],
        ),
      ),
    );
    // No zoom while annotating (gestures are for drawing/placing text).
    return annotating
        ? stack
        : InteractiveViewer(minScale: 1, maxScale: 4, child: stack);
  }

  Widget _buildColorBar(ColorScheme cs) {
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_textMode)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Text('Нажмите на фото',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            for (final c in _palette)
              GestureDetector(
                onTap: () => setState(() => _penColor = c),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  margin: const EdgeInsets.symmetric(horizontal: 5),
                  width: _penColor == c ? 32 : 26,
                  height: _penColor == c ? 32 : 26,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _penColor == c ? Colors.white : Colors.white24,
                      width: _penColor == c ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
        title: Text(
          widget.peerName != null && widget.peerName!.isNotEmpty
              ? 'Отправить → ${widget.peerName}'
              : 'Отправить фото',
          style: const TextStyle(fontSize: 16),
        ),
        actions: _cropMode
            ? [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _busy = true);
                          _cropController.crop();
                        },
                  child: Text(AppL10n.t('common_done'),
                      style: TextStyle(
                          color: cs.primary, fontWeight: FontWeight.w600)),
                ),
              ]
            : (_drawMode || _textMode)
                ? [
                    if (_hasAnnotations)
                      IconButton(
                        tooltip: 'Отменить',
                        onPressed: () => setState(() {
                          if (_texts.isNotEmpty &&
                              (_textMode || _strokes.isEmpty)) {
                            _texts.removeLast();
                          } else if (_strokes.isNotEmpty) {
                            _strokes.removeLast();
                          }
                        }),
                        icon: const Icon(Icons.undo_rounded),
                      ),
                    TextButton(
                      onPressed: () => setState(() {
                        _drawMode = false;
                        _textMode = false;
                      }),
                      child: Text(AppL10n.t('common_done'),
                          style: TextStyle(
                              color: cs.primary, fontWeight: FontWeight.w600)),
                    ),
                  ]
                : [
                    IconButton(
                      tooltip: 'Рисовать',
                      onPressed: _busy
                          ? null
                          : () => setState(() => _drawMode = true),
                      icon: const Icon(Icons.brush_rounded),
                    ),
                    IconButton(
                      tooltip: 'Текст',
                      onPressed: _busy
                          ? null
                          : () => setState(() => _textMode = true),
                      icon: const Icon(Icons.title_rounded),
                    ),
                    IconButton(
                      tooltip: 'Повернуть',
                      onPressed: _busy ? null : _rotate,
                      icon: const Icon(Icons.rotate_right_rounded),
                    ),
                    IconButton(
                      tooltip: 'Обрезать',
                      onPressed: _busy
                          ? null
                          : () => setState(() => _cropMode = true),
                      icon: const Icon(Icons.crop_rounded),
                    ),
                  ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _cropMode
                ? Crop(
                    controller: _cropController,
                    image: _bytes,
                    onCropped: (result) {
                      setState(() {
                        _busy = false;
                        _cropMode = false;
                      });
                      switch (result) {
                        case CropSuccess(:final croppedImage):
                          setState(() {
                            _bytes = croppedImage;
                            _strokes.clear();
                            _texts.clear();
                          });
                          unawaited(_prepare());
                        case CropFailure(:final cause):
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('$cause'),
                                backgroundColor: Colors.red),
                          );
                      }
                    },
                    onStatusChanged: (s) {
                      if (s == CropStatus.cropping && !_busy) {
                        setState(() => _busy = true);
                      }
                    },
                    baseColor: Colors.black,
                    maskColor: Colors.black.withValues(alpha: 0.55),
                  )
                : _buildEditArea(),
          ),
          if ((_drawMode || _textMode) && !_cropMode) _buildColorBar(cs),
          if (!_cropMode)
            SafeArea(
              top: false,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                color: Colors.black,
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: TextField(
                          controller: _captionCtrl,
                          minLines: 1,
                          maxLines: 4,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: 'Подпись...',
                            hintStyle: TextStyle(color: Colors.white54),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _busy ? null : _send,
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.send_rounded,
                            color: cs.onPrimary, size: 22),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
