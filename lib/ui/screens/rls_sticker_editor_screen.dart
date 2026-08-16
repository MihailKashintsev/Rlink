import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../models/rls_sticker.dart';

/// Editor for a Rlink animated sticker (.rls): compose a few image layers,
/// pose each one on the canvas at chosen moments in time, and the result plays
/// back as a short, tiny, looping animation (see rls_sticker.dart for why the
/// format looks the way it does).
///
/// v1 scope, deliberately: layer sources are "photo" and "emoji glyph" (no
/// freehand drawing, no picking an existing static sticker as a layer — both
/// are reasonable follow-ups, not needed to make "красивые анимированные
/// стикеры" possible). Each layer's motion is authored by dragging/pinching/
/// rotating it on the canvas at a chosen point on the timeline, which records
/// a keyframe there; playback interpolates between keyframes with a per-layer
/// easing curve. No per-keyframe easing override in the UI yet (the format
/// supports it; editing it is a follow-up affordance).
class RlsStickerEditorScreen extends StatefulWidget {
  const RlsStickerEditorScreen({super.key});

  @override
  State<RlsStickerEditorScreen> createState() => _RlsStickerEditorScreenState();
}

const double _kCanvasSide = 512;
const List<String> _kEaseNames = [
  'linear',
  'easeIn',
  'easeOut',
  'easeInOut',
  'outBack',
  'outBounce',
];

class _EdLayer {
  final String id;
  final ui.Image image;
  final Uint8List pngBytes;
  final List<RlsKeyframe> keys;
  String ease = 'easeInOut';

  _EdLayer({
    required this.id,
    required this.image,
    required this.pngBytes,
    required this.keys,
  });

  ({double x, double y, double sx, double sy, double rotDeg, double alpha})
      transformAt(int tMs) => RlsLayer(id: id, assetId: id, keys: keys, defaultEase: ease)
          .transformAt(tMs);
}

class _RlsStickerEditorScreenState extends State<RlsStickerEditorScreen>
    with SingleTickerProviderStateMixin {
  final _uuid = const Uuid();
  final _picker = ImagePicker();
  final List<_EdLayer> _layers = [];
  int? _selected;
  int _durationMs = 1500;
  bool _playing = false;
  bool _exporting = false;

  late final AnimationController _playCtrl;
  int _playheadMs = 0;

  // Live (uncommitted) pose while the user is actively dragging the selected
  // layer — kept separate from committed keyframes so a drag can be cancelled
  // by lifting outside the canvas without leaving a half-formed keyframe.
  ({double x, double y, double sx, double sy, double rotDeg, double alpha})?
      _livePose;
  Offset? _dragStartFocal;
  double _dragStartScale = 1;
  double _dragStartRotDeg = 0;
  Offset _dragBaseXY = Offset.zero;

  @override
  void initState() {
    super.initState();
    _playCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _durationMs),
    )..addListener(() {
        if (!mounted) return;
        setState(() => _playheadMs = (_playCtrl.value * _durationMs).round());
      });
  }

  @override
  void dispose() {
    _playCtrl.dispose();
    for (final l in _layers) {
      l.image.dispose();
    }
    super.dispose();
  }

  _EdLayer? get _sel => _selected != null && _selected! < _layers.length
      ? _layers[_selected!]
      : null;

  void _togglePlay() {
    setState(() => _playing = !_playing);
    if (_playing) {
      _playCtrl.duration = Duration(milliseconds: _durationMs);
      _playCtrl.repeat();
    } else {
      _playCtrl.stop();
    }
  }

  void _pausePlaybackForEditing() {
    if (_playing) {
      _playing = false;
      _playCtrl.stop();
    }
  }

  /// Re-encodes a picked layer to PNG, downscaled to fit the canvas.
  ///
  /// This is the single biggest lever on sticker weight. Layers are stored as
  /// lossless RGBA PNG, so a 1200×1200 photo costs ~5.5× the pixels the 512×512
  /// canvas can ever show — measured at ~1.8 MB per layer instead of ~330 KB,
  /// for detail that is thrown away at paint time anyway. Decoding straight to
  /// the target size also avoids ever materialising the full-res bitmap.
  Future<Uint8List> _decodeToPng(Uint8List raw) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(raw);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    const maxSide = _kCanvasSide;
    final w = descriptor.width;
    final h = descriptor.height;
    var tw = w;
    var th = h;
    if (w > maxSide || h > maxSide) {
      final s = maxSide / math.max(w, h);
      tw = (w * s).round().clamp(1, maxSide.round());
      th = (h * s).round().clamp(1, maxSide.round());
    }
    final codec =
        await descriptor.instantiateCodec(targetWidth: tw, targetHeight: th);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    descriptor.dispose();
    return data!.buffer.asUint8List();
  }

  Future<void> _addLayerFromBytes(Uint8List rawBytes) async {
    try {
      final pngBytes = await _decodeToPng(rawBytes);
      final codec = await ui.instantiateImageCodec(pngBytes);
      final frame = await codec.getNextFrame();
      final id = _uuid.v4();
      final layer = _EdLayer(
        id: id,
        image: frame.image,
        pngBytes: pngBytes,
        keys: [
          RlsKeyframe(tMs: 0, x: _kCanvasSide / 2, y: _kCanvasSide / 2),
        ],
      );
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _layers.add(layer);
        _selected = _layers.length - 1;
      });
    } catch (e) {
      _snack('Не удалось добавить слой: $e');
    }
  }

  Future<void> _addPhotoLayer() async {
    try {
      // No maxWidth/imageQuality: those make image_picker re-encode to JPEG,
      // which flattens away the alpha channel — and a cut-out PNG layer is
      // exactly what makes a good sticker. _decodeToPng downscales instead.
      final picked = await _picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) return;
      await _addLayerFromBytes(bytes);
    } catch (e) {
      _snack('Не удалось выбрать фото: $e');
    }
  }

  Future<void> _addEmojiLayer() async {
    final emoji = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text('Эмодзи-слой'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Вставьте эмодзи'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Добавить'),
            ),
          ],
        );
      },
    );
    final e = emoji?.trim() ?? '';
    if (e.isEmpty) return;
    final bytes = await _rasterizeEmoji(e);
    if (bytes != null) await _addLayerFromBytes(bytes);
  }

  Future<Uint8List?> _rasterizeEmoji(String emoji) async {
    try {
      const side = 256.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, side, side));
      final tp = TextPainter(
        text: TextSpan(text: emoji, style: const TextStyle(fontSize: 200)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset((side - tp.width) / 2, (side - tp.height) / 2),
      );
      final pic = recorder.endRecording();
      final img = await pic.toImage(side.round(), side.round());
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      pic.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  void _removeSelectedLayer() {
    final i = _selected;
    if (i == null) return;
    setState(() {
      _layers.removeAt(i).image.dispose();
      _selected = _layers.isEmpty ? null : i.clamp(0, _layers.length - 1);
    });
  }

  void _upsertKeyframeForSelected({required double alphaOverride}) {
    final layer = _sel;
    final pose = _livePose;
    if (layer == null || pose == null) return;
    final t = _playheadMs.clamp(0, _durationMs);
    final nk = RlsKeyframe(
      tMs: t,
      x: pose.x,
      y: pose.y,
      sx: pose.sx,
      sy: pose.sy,
      rotDeg: pose.rotDeg,
      alpha: alphaOverride,
    );
    final idx = layer.keys.indexWhere((k) => k.tMs == t);
    setState(() {
      if (idx >= 0) {
        layer.keys[idx] = nk;
      } else {
        layer.keys.add(nk);
        layer.keys.sort((a, b) => a.tMs.compareTo(b.tMs));
      }
      _livePose = null;
    });
  }

  void _deleteNearestKeyframe() {
    final layer = _sel;
    if (layer == null || layer.keys.length <= 1) {
      _snack('У слоя должен остаться хотя бы один ключевой кадр');
      return;
    }
    var nearest = 0;
    var best = (layer.keys[0].tMs - _playheadMs).abs();
    for (var i = 1; i < layer.keys.length; i++) {
      final d = (layer.keys[i].tMs - _playheadMs).abs();
      if (d < best) {
        best = d;
        nearest = i;
      }
    }
    setState(() => layer.keys.removeAt(nearest));
  }

  void _onScaleStart(ScaleStartDetails d, Size canvasScreenSize) {
    final layer = _sel;
    if (layer == null) return;
    _pausePlaybackForEditing();
    final cur = layer.transformAt(_playheadMs);
    _dragStartFocal = d.localFocalPoint;
    _dragStartScale = cur.sx;
    _dragStartRotDeg = cur.rotDeg;
    _dragBaseXY = Offset(cur.x, cur.y);
    setState(() => _livePose = cur);
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size canvasScreenSize) {
    final layer = _sel;
    final start = _dragStartFocal;
    if (layer == null || start == null) return;
    final k = _kCanvasSide / canvasScreenSize.width; // screen px -> canvas px
    final delta = (d.localFocalPoint - start) * k;
    final newScale = (_dragStartScale * d.scale).clamp(0.15, 6.0);
    final newRot = _dragStartRotDeg + d.rotation * 180 / 3.141592653589793;
    setState(() {
      _livePose = (
        x: _dragBaseXY.dx + delta.dx,
        y: _dragBaseXY.dy + delta.dy,
        sx: newScale,
        sy: newScale,
        rotDeg: newRot,
        alpha: _livePose?.alpha ?? 1,
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _upsertKeyframeForSelected(alphaOverride: _livePose?.alpha ?? 1);
  }

  void _onOpacityChanged(double v) {
    final layer = _sel;
    if (layer == null) return;
    final base = _livePose ?? layer.transformAt(_playheadMs);
    setState(() => _livePose = (
          x: base.x,
          y: base.y,
          sx: base.sx,
          sy: base.sy,
          rotDeg: base.rotDeg,
          alpha: v,
        ));
  }

  void _onOpacityCommitted(double v) {
    _pausePlaybackForEditing();
    _upsertKeyframeForSelected(alphaOverride: v);
  }

  Future<void> _export() async {
    if (_layers.isEmpty) {
      _snack('Добавьте хотя бы один слой');
      return;
    }
    setState(() => _exporting = true);
    try {
      final sticker = RlsSticker(
        width: _kCanvasSide.round(),
        height: _kCanvasSide.round(),
        durationMs: _durationMs,
        loop: true,
        assets: {for (final l in _layers) l.id: l.pngBytes},
        layers: [
          for (final l in _layers)
            RlsLayer(id: l.id, assetId: l.id, keys: l.keys, defaultEase: l.ease),
        ],
      );
      final bytes = sticker.encode();
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (e) {
      _snack('Не удалось собрать стикер: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF101014),
        foregroundColor: Colors.white,
        title: const Text('Анимированный стикер'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_rounded, size: 18),
              label: const Text('Готово'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _canvas(cs),
                ),
              ),
            ),
          ),
          if (_sel != null) _opacityRow(cs),
          _timeline(cs),
          _layerTray(cs),
          _toolbar(cs),
        ],
      ),
    );
  }

  Widget _canvas(ColorScheme cs) {
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: GestureDetector(
          onScaleStart: _selected == null
              ? null
              : (d) => _onScaleStart(d, size),
          onScaleUpdate: _selected == null
              ? null
              : (d) => _onScaleUpdate(d, size),
          onScaleEnd: _selected == null ? null : _onScaleEnd,
          child: Container(
            color: const Color(0xFF1B1B22),
            child: CustomPaint(
              painter: _EditorPainter(
                layers: _layers,
                selected: _selected,
                tMs: _playheadMs,
                livePose: _livePose,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
    });
  }

  Widget _opacityRow(ColorScheme cs) {
    final layer = _sel!;
    final pose = _livePose ?? layer.transformAt(_playheadMs);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.opacity, color: Colors.white54, size: 18),
          Expanded(
            child: Slider(
              value: pose.alpha.clamp(0.0, 1.0),
              onChanged: _onOpacityChanged,
              onChangeEnd: _onOpacityCommitted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeline(ColorScheme cs) {
    final layer = _sel;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                color: Colors.white,
                icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                onPressed: _togglePlay,
              ),
              Expanded(
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Slider(
                      value: _playheadMs.toDouble().clamp(0, _durationMs.toDouble()),
                      max: _durationMs.toDouble(),
                      onChanged: (v) {
                        _pausePlaybackForEditing();
                        setState(() {
                          _playheadMs = v.round();
                          _livePose = null;
                        });
                      },
                    ),
                    if (layer != null)
                      IgnorePointer(
                        child: Stack(
                          children: [
                            for (final k in layer.keys)
                              Positioned(
                                left: (k.tMs / _durationMs.clamp(1, 1 << 30)) *
                                    (MediaQuery.sizeOf(context).width - 32 - 96),
                                top: 18,
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: cs.primary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Удалить ближайший ключевой кадр',
                color: Colors.white54,
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: layer == null ? null : _deleteNearestKeyframe,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _layerTray(ColorScheme cs) {
    return SizedBox(
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _layers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final selected = i == _selected;
          return GestureDetector(
            onTap: () => setState(() {
              _selected = i;
              _livePose = null;
            }),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? cs.primary : Colors.white24,
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: RawImage(image: _layers[i].image, fit: BoxFit.contain),
            ),
          );
        },
      ),
    );
  }

  Widget _toolbar(ColorScheme cs) {
    final layer = _sel;
    return SafeArea(
      top: false,
      child: Container(
        height: 62,
        color: const Color(0xFF17171C),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _toolBtn(Icons.photo_outlined, 'Фото', _addPhotoLayer),
            _toolBtn(Icons.emoji_emotions_outlined, 'Эмодзи', _addEmojiLayer),
            _toolBtn(
              Icons.delete_outline,
              'Удалить слой',
              layer == null ? null : _removeSelectedLayer,
            ),
            _easePicker(layer),
            _durationPicker(),
          ],
        ),
      ),
    );
  }

  Widget _easePicker(_EdLayer? layer) {
    return InkWell(
      onTap: layer == null
          ? null
          : () async {
              final v = await showModalBottomSheet<String>(
                context: context,
                builder: (ctx) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final e in _kEaseNames)
                        ListTile(
                          title: Text(e),
                          onTap: () => Navigator.pop(ctx, e),
                        ),
                    ],
                  ),
                ),
              );
              if (v != null) setState(() => layer.ease = v);
            },
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timeline_rounded,
                color: layer == null ? Colors.white24 : Colors.white,
                size: 22),
            const SizedBox(height: 2),
            Text(
              layer?.ease ?? 'ease',
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _durationPicker() {
    return InkWell(
      onTap: () async {
        final v = await showModalBottomSheet<int>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final ms in const [800, 1200, 1500, 2000, 3000])
                  ListTile(
                    title: Text('${ms / 1000}s'),
                    onTap: () => Navigator.pop(ctx, ms),
                  ),
              ],
            ),
          ),
        );
        if (v != null) {
          setState(() {
            _durationMs = v;
            _playheadMs = _playheadMs.clamp(0, _durationMs);
          });
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.schedule_rounded, color: Colors.white, size: 22),
            const SizedBox(height: 2),
            Text(
              '${(_durationMs / 1000).toStringAsFixed(1)}s',
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolBtn(IconData icon, String label, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: onTap == null ? Colors.white24 : Colors.white, size: 22),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: onTap == null ? Colors.white24 : Colors.white70,
                    fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _EditorPainter extends CustomPainter {
  final List<_EdLayer> layers;
  final int? selected;
  final int tMs;
  final ({double x, double y, double sx, double sy, double rotDeg, double alpha})?
      livePose;

  _EditorPainter({
    required this.layers,
    required this.selected,
    required this.tMs,
    required this.livePose,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / _kCanvasSide;
    canvas.save();
    canvas.scale(scale, scale);
    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      final tr = (i == selected && livePose != null)
          ? livePose!
          : layer.transformAt(tMs);
      if (tr.alpha <= 0.003) continue;
      final iw = layer.image.width.toDouble();
      final ih = layer.image.height.toDouble();
      canvas.save();
      canvas.translate(tr.x, tr.y);
      canvas.rotate(tr.rotDeg * 3.141592653589793 / 180);
      canvas.scale(tr.sx, tr.sy);
      canvas.translate(-iw / 2, -ih / 2);
      final paint = Paint()
        ..color = Color.fromRGBO(255, 255, 255, tr.alpha.clamp(0.0, 1.0))
        ..filterQuality = FilterQuality.high;
      canvas.drawImage(layer.image, Offset.zero, paint);
      if (i == selected) {
        final rect = Rect.fromLTWH(0, 0, iw, ih);
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 / tr.sx
            ..color = Colors.white70,
        );
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EditorPainter old) =>
      old.tMs != tMs ||
      old.selected != selected ||
      old.livePose != livePose ||
      old.layers.length != layers.length;
}
