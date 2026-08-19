import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:uuid/uuid.dart';

import '../../models/rlv_animation_presets.dart';
import '../../models/rlv_sticker.dart';
import '../widgets/rlv_sticker_view.dart' show buildShapePath, buildFreehandPath, parseRlvHexColor;

/// The vector sticker "mini studio": compose shape/freehand/SVG layers, pose
/// each one on the canvas at chosen moments in time (same keyframe/timeline
/// model as the raster `.rls` editor), and apply a one-tap animation preset.
/// See rlv_sticker.dart for the format and rls_sticker_editor_screen.dart for
/// the sibling raster editor this one deliberately mirrors the skeleton of —
/// canvas/timeline/layer-tray/toolbar layout and the manipulate-then-commit-
/// keyframe gesture are copied rather than shared, same reasoning as the
/// format itself: small, safer to keep the two editors decoupled.
class RlvStickerEditorScreen extends StatefulWidget {
  const RlvStickerEditorScreen({super.key});

  @override
  State<RlvStickerEditorScreen> createState() => _RlvStickerEditorScreenState();
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
const List<Color> _kPalette = [
  Color(0xFFFF3B30),
  Color(0xFFFFFFFF),
  Color(0xFF000000),
  Color(0xFF34C759),
  Color(0xFF0A84FF),
  Color(0xFFFFD60A),
];
const List<(String, IconData)> _kShapeTypes = [
  ('rect', Icons.crop_square_rounded),
  ('circle', Icons.circle_outlined),
  ('star', Icons.star_border_rounded),
  ('polygon', Icons.change_history_rounded),
  ('line', Icons.horizontal_rule_rounded),
];
const Map<String, String> _kPresetLabels = {
  'bounce': 'Подпрыгивание',
  'pulse': 'Пульсация',
  'spin': 'Вращение',
  'wobble': 'Тряска',
  'fadeIn': 'Появление',
  'fadeOut': 'Исчезновение',
  'slideIn': 'Слайд',
};

String _colorToHex(Color c) {
  int ch(double v) => (v * 255).round().clamp(0, 255);
  String hx(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${hx(ch(c.r))}${hx(ch(c.g))}${hx(ch(c.b))}${hx(ch(c.a))}'.toUpperCase();
}

class _RlvEdLayer {
  final String id;
  final String kind; // shape | path | svg

  // shape
  String? shapeType;
  int sides;
  double cornerRadius;
  String? fill;
  String? stroke;
  double strokeWidth;

  // path (freehand)
  List<double>? points;
  String? color;
  bool filled;
  bool closed;

  // svg
  String? svgSource;
  ui.Picture? svgPicture;

  // shared: local bounding box (anchor-centered) + precomputed shape/path
  final Size localSize;
  final ui.Path? path;

  final List<RlvKeyframe> keys;
  String ease = 'easeInOut';

  _RlvEdLayer({
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
    this.svgSource,
    this.svgPicture,
    required this.localSize,
    this.path,
    required this.keys,
  });

  RlvPose transformAt(int tMs) =>
      RlvLayer(id: id, kind: kind, keys: keys, defaultEase: ease).transformAt(tMs);

  RlvLayer toRlvLayer() => RlvLayer(
        id: id,
        kind: kind,
        shapeType: shapeType,
        sides: sides,
        cornerRadius: cornerRadius,
        fill: fill,
        stroke: stroke,
        strokeWidth: strokeWidth,
        points: points,
        color: color,
        filled: filled,
        closed: closed,
        size: kind == 'svg' ? null : [localSize.width, localSize.height],
        svg: svgSource,
        keys: keys,
        defaultEase: ease,
      );
}

class _RlvStickerEditorScreenState extends State<RlvStickerEditorScreen>
    with SingleTickerProviderStateMixin {
  final _uuid = const Uuid();
  final List<_RlvEdLayer> _layers = [];
  int? _selected;
  int _durationMs = 1500;
  bool _playing = false;
  bool _exporting = false;
  bool _drawMode = false;
  Color _penColor = _kPalette[2]; // black

  late final AnimationController _playCtrl;
  int _playheadMs = 0;

  RlvPose? _livePose;
  Offset? _dragStartFocal;
  double _dragStartScale = 1;
  double _dragStartRotDeg = 0;
  Offset _dragBaseXY = Offset.zero;

  List<Offset>? _activeStrokePoints;

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
      l.svgPicture?.dispose();
    }
    super.dispose();
  }

  _RlvEdLayer? get _sel =>
      _selected != null && _selected! < _layers.length ? _layers[_selected!] : null;

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

  void _removeSelectedLayer() {
    final i = _selected;
    if (i == null) return;
    setState(() {
      _layers.removeAt(i).svgPicture?.dispose();
      _selected = _layers.isEmpty ? null : i.clamp(0, _layers.length - 1);
    });
  }

  void _upsertKeyframeForSelected({required double alphaOverride}) {
    final layer = _sel;
    final pose = _livePose;
    if (layer == null || pose == null) return;
    final t = _playheadMs.clamp(0, _durationMs);
    final nk = RlvKeyframe(
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

  // ---- manipulate (move/scale/rotate) selected layer ----

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
    final k = _kCanvasSide / canvasScreenSize.width;
    final delta = (d.localFocalPoint - start) * k;
    final newScale = (_dragStartScale * d.scale).clamp(0.15, 6.0);
    final newRot = _dragStartRotDeg + d.rotation * 180 / math.pi;
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

  // ---- freehand draw mode ----

  void _onDrawStart(DragStartDetails d, Size canvasScreenSize) {
    _pausePlaybackForEditing();
    final k = _kCanvasSide / canvasScreenSize.width;
    setState(() => _activeStrokePoints = [d.localPosition * k]);
  }

  void _onDrawUpdate(DragUpdateDetails d, Size canvasScreenSize) {
    final pts = _activeStrokePoints;
    if (pts == null) return;
    final k = _kCanvasSide / canvasScreenSize.width;
    final p = d.localPosition * k;
    // Distance-gate in canvas space — cuts a typical drag's point density
    // 5-10x without any real loss of shape (freehand input only, never an
    // imported dense path, so this is enough on its own).
    if ((p - pts.last).distanceSquared < 9) return;
    setState(() => _activeStrokePoints = [...pts, p]);
  }

  void _onDrawEnd(DragEndDetails d) {
    final pts = _activeStrokePoints;
    _activeStrokePoints = null;
    if (pts == null || pts.length < 2) {
      setState(() => _drawMode = false);
      return;
    }
    var minX = pts.first.dx, maxX = pts.first.dx;
    var minY = pts.first.dy, maxY = pts.first.dy;
    for (final p in pts) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final w = (maxX - minX).clamp(1.0, _kCanvasSide);
    final h = (maxY - minY).clamp(1.0, _kCanvasSide);
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
    final normPts = <double>[];
    for (final p in pts) {
      normPts.add(((p.dx - minX) / w).clamp(0.0, 1.0));
      normPts.add(((p.dy - minY) / h).clamp(0.0, 1.0));
    }
    final id = _uuid.v4();
    final layer = _RlvEdLayer(
      id: id,
      kind: 'path',
      points: normPts,
      color: _colorToHex(_penColor),
      strokeWidth: 0.06,
      localSize: Size(w, h),
      path: buildFreehandPath(normPts, w, h),
      keys: [RlvKeyframe(tMs: _playheadMs.clamp(0, _durationMs), x: cx, y: cy)],
    );
    setState(() {
      _layers.add(layer);
      _selected = _layers.length - 1;
      _drawMode = false;
    });
  }

  // ---- add layers ----

  void _addShapeLayer(String shapeType, Color color) {
    const side = 160.0;
    final cornerRadius = shapeType == 'rect' ? 12.0 : 0.0;
    final id = _uuid.v4();
    final layer = _RlvEdLayer(
      id: id,
      kind: 'shape',
      shapeType: shapeType,
      cornerRadius: cornerRadius,
      fill: _colorToHex(color),
      localSize: const Size(side, side),
      path: buildShapePath(shapeType, side, side, cornerRadius: cornerRadius),
      keys: [
        RlvKeyframe(
          tMs: _playheadMs.clamp(0, _durationMs),
          x: _kCanvasSide / 2,
          y: _kCanvasSide / 2,
        ),
      ],
    );
    setState(() {
      _layers.add(layer);
      _selected = _layers.length - 1;
    });
  }

  Future<void> _pickShape() async {
    final result = await showModalBottomSheet<(String, Color)>(
      context: context,
      builder: (ctx) {
        String? chosenShape;
        var chosenColor = _kPalette.first;
        return StatefulBuilder(builder: (ctx, setSheetState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Фигура', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    children: [
                      for (final s in _kShapeTypes)
                        GestureDetector(
                          onTap: () => setSheetState(() => chosenShape = s.$1),
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: chosenShape == s.$1
                                    ? Theme.of(ctx).colorScheme.primary
                                    : Colors.white24,
                                width: chosenShape == s.$1 ? 2 : 1,
                              ),
                            ),
                            child: Icon(s.$2, color: Colors.white70),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    children: [
                      for (final c in _kPalette)
                        GestureDetector(
                          onTap: () => setSheetState(() => chosenColor = c),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: c,
                              border: Border.all(
                                color: c == chosenColor ? Colors.white : Colors.white24,
                                width: c == chosenColor ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: chosenShape == null
                        ? null
                        : () => Navigator.pop(ctx, (chosenShape!, chosenColor)),
                    child: const Text('Добавить'),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
    if (result != null) _addShapeLayer(result.$1, result.$2);
  }

  Future<void> _addSvgLayer() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['svg'],
        withData: true,
      );
      final bytes = result?.files.single.bytes;
      if (bytes == null) return;
      if (bytes.length > rlvMaxSvgBytesPerLayer) {
        _snack('SVG слишком большой');
        return;
      }
      final svgText = utf8.decode(bytes);
      final info = await vg.loadPicture(SvgStringLoader(svgText), null);
      var w = info.size.width;
      var h = info.size.height;
      if (w <= 0 || h <= 0) {
        w = 200;
        h = 200;
      }
      // Start scaled to fit within ~200px so a large imported SVG doesn't
      // land on the canvas oversized — the same instinct as the raster
      // editor downscaling a picked photo, just via the scale keyframe
      // instead of re-encoding pixels (there are none to re-encode).
      final fitScale = math.min(1.0, 200 / math.max(w, h));
      final id = _uuid.v4();
      final layer = _RlvEdLayer(
        id: id,
        kind: 'svg',
        svgSource: svgText,
        svgPicture: info.picture,
        localSize: Size(w, h),
        keys: [
          RlvKeyframe(
            tMs: _playheadMs.clamp(0, _durationMs),
            x: _kCanvasSide / 2,
            y: _kCanvasSide / 2,
            sx: fitScale,
            sy: fitScale,
          ),
        ],
      );
      if (!mounted) {
        info.picture.dispose();
        return;
      }
      setState(() {
        _layers.add(layer);
        _selected = _layers.length - 1;
      });
    } catch (e) {
      _snack('Не удалось импортировать SVG: $e');
    }
  }

  Future<void> _pickPreset(_RlvEdLayer layer) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in _kPresetLabels.entries)
              ListTile(
                title: Text(e.value),
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    _pausePlaybackForEditing();
    final base = layer.transformAt(_playheadMs);
    List<RlvKeyframe> newKeys;
    switch (choice) {
      case 'bounce':
        newKeys = bouncePreset(base, canvasSide: _kCanvasSide);
      case 'pulse':
        newKeys = pulsePreset(base);
      case 'spin':
        newKeys = spinPreset(base);
      case 'wobble':
        newKeys = wobblePreset(base, canvasSide: _kCanvasSide);
      case 'fadeIn':
        newKeys = fadeInPreset(base, holdMs: _durationMs);
      case 'fadeOut':
        newKeys = fadeOutPreset(base, holdMs: _durationMs);
      case 'slideIn':
        newKeys = slideInPreset(base, canvasSide: _kCanvasSide);
      default:
        return;
    }
    final maxT = newKeys.map((k) => k.tMs).reduce(math.max);
    setState(() {
      layer.keys
        ..clear()
        ..addAll(newKeys);
      _livePose = null;
      if (maxT > _durationMs) _durationMs = maxT;
    });
  }

  Future<void> _export() async {
    if (_layers.isEmpty) {
      _snack('Добавьте хотя бы один слой');
      return;
    }
    setState(() => _exporting = true);
    try {
      final sticker = RlvSticker(
        width: _kCanvasSide.round(),
        height: _kCanvasSide.round(),
        durationMs: _durationMs,
        loop: true,
        layers: [for (final l in _layers) l.toRlvLayer()],
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
        title: const Text('Векторный стикер'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
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
                child: AspectRatio(aspectRatio: 1, child: _canvas(cs)),
              ),
            ),
          ),
          // Keyed: the opacity row appears/disappears as layers get
          // selected, which shifts every later child's index in this
          // Column. Without stable keys, Flutter's default type+index
          // reconciliation reuses the wrong RenderObject/Element across the
          // shift (e.g. the timeline's Slider ends up painted where the
          // opacity row should be) — a real rendering-corruption bug, not
          // just a lint nicety.
          if (_sel != null && !_drawMode)
            KeyedSubtree(key: const ValueKey('opacityRow'), child: _opacityRow(cs)),
          KeyedSubtree(key: const ValueKey('timeline'), child: _timeline(cs)),
          KeyedSubtree(key: const ValueKey('layerTray'), child: _layerTray(cs)),
          KeyedSubtree(key: const ValueKey('toolbar'), child: _toolbar(cs)),
        ],
      ),
    );
  }

  Widget _canvas(ColorScheme cs) {
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final manipulate = !_drawMode && _selected != null;
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: GestureDetector(
          onScaleStart: manipulate ? (d) => _onScaleStart(d, size) : null,
          onScaleUpdate: manipulate ? (d) => _onScaleUpdate(d, size) : null,
          onScaleEnd: manipulate ? _onScaleEnd : null,
          onPanStart: _drawMode ? (d) => _onDrawStart(d, size) : null,
          onPanUpdate: _drawMode ? (d) => _onDrawUpdate(d, size) : null,
          onPanEnd: _drawMode ? _onDrawEnd : null,
          child: Container(
            color: const Color(0xFF1B1B22),
            child: CustomPaint(
              painter: _RlvEditorPainter(
                layers: _layers,
                selected: _selected,
                tMs: _playheadMs,
                livePose: _livePose,
                activeStroke: _activeStrokePoints,
                penColor: _penColor,
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
      child: Row(
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
            key: ValueKey(_layers[i].id),
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
              child: CustomPaint(painter: _RlvThumbPainter(layer: _layers[i])),
            ),
          );
        },
      ),
    );
  }

  Widget _toolbar(ColorScheme cs) {
    if (_drawMode) return _drawToolbar();
    final layer = _sel;
    return SafeArea(
      top: false,
      child: Container(
        height: 62,
        color: const Color(0xFF17171C),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _toolBtn(Icons.category_outlined, 'Фигура', _pickShape),
              _toolBtn(Icons.edit_outlined, 'Рисовать', () => setState(() => _drawMode = true)),
              _toolBtn(Icons.image_outlined, 'SVG', _addSvgLayer),
              _toolBtn(
                Icons.auto_awesome_rounded,
                'Пресеты',
                layer == null ? null : () => _pickPreset(layer),
              ),
              _toolBtn(Icons.delete_outline, 'Удалить', layer == null ? null : _removeSelectedLayer),
              _easePicker(layer),
              _durationPicker(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _drawToolbar() {
    return SafeArea(
      top: false,
      child: Container(
        height: 62,
        color: const Color(0xFF17171C),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final c in _kPalette)
              GestureDetector(
                onTap: () => setState(() => _penColor = c),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c,
                    border: Border.all(
                      color: c == _penColor ? Colors.white : Colors.white24,
                      width: c == _penColor ? 3 : 1,
                    ),
                  ),
                ),
              ),
            TextButton(
              onPressed: () => setState(() => _drawMode = false),
              child: const Text('Готово'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _easePicker(_RlvEdLayer? layer) {
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
                color: layer == null ? Colors.white24 : Colors.white, size: 22),
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
                    color: onTap == null ? Colors.white24 : Colors.white70, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

void _paintLayerContent(Canvas canvas, _RlvEdLayer layer, double alpha) {
  if (layer.kind == 'svg') {
    final pic = layer.svgPicture;
    if (pic == null) return;
    canvas.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, alpha));
    canvas.drawPicture(pic);
    canvas.restore();
    return;
  }
  final path = layer.path;
  if (path == null) return;
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
    final color = parseRlvHexColor(layer.color) ?? const Color(0xFF000000);
    final strokeWidthPx = layer.strokeWidth * layer.localSize.width;
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

class _RlvEditorPainter extends CustomPainter {
  final List<_RlvEdLayer> layers;
  final int? selected;
  final int tMs;
  final RlvPose? livePose;
  final List<Offset>? activeStroke;
  final Color penColor;

  _RlvEditorPainter({
    required this.layers,
    required this.selected,
    required this.tMs,
    required this.livePose,
    required this.activeStroke,
    required this.penColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / _kCanvasSide;
    canvas.save();
    canvas.scale(scale, scale);
    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      final tr = (i == selected && livePose != null) ? livePose! : layer.transformAt(tMs);
      if (tr.alpha <= 0.003) continue;
      final alpha = tr.alpha.clamp(0.0, 1.0);
      final w = layer.localSize.width, h = layer.localSize.height;
      canvas.save();
      canvas.translate(tr.x, tr.y);
      canvas.rotate(tr.rotDeg * math.pi / 180);
      canvas.scale(tr.sx, tr.sy);
      canvas.translate(-w / 2, -h / 2);
      _paintLayerContent(canvas, layer, alpha);
      if (i == selected) {
        canvas.drawRect(
          Rect.fromLTWH(0, 0, w, h),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 / tr.sx
            ..color = Colors.white70,
        );
      }
      canvas.restore();
    }
    final stroke = activeStroke;
    if (stroke != null && stroke.length > 1) {
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (var i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = penColor,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RlvEditorPainter old) =>
      old.tMs != tMs ||
      old.selected != selected ||
      old.livePose != livePose ||
      old.layers.length != layers.length ||
      old.activeStroke?.length != activeStroke?.length ||
      old.penColor != penColor;
}

/// Layer-tray thumbnail: the layer's raw content at its own neutral pose,
/// scaled to fit — same spirit as the raster editor showing the unposed
/// `ui.Image`, just for vector content.
class _RlvThumbPainter extends CustomPainter {
  final _RlvEdLayer layer;

  _RlvThumbPainter({required this.layer});

  @override
  void paint(Canvas canvas, Size size) {
    final w = layer.kind == 'svg'
        ? (layer.svgPicture == null ? 1.0 : layer.localSize.width)
        : layer.localSize.width;
    final h = layer.kind == 'svg'
        ? (layer.svgPicture == null ? 1.0 : layer.localSize.height)
        : layer.localSize.height;
    if (w <= 0 || h <= 0) return;
    final fit = math.min(size.width / w, size.height / h);
    canvas.save();
    canvas.translate((size.width - w * fit) / 2, (size.height - h * fit) / 2);
    canvas.scale(fit, fit);
    _paintLayerContent(canvas, layer, 1);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RlvThumbPainter old) => old.layer != layer;
}
