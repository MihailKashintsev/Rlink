import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_l10n.dart';
import 'package:flutter/rendering.dart';
import '../../services/ocr_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public entry point
// Usage:
//   final bytes = await Navigator.push<Uint8List>(
//     context, MaterialPageRoute(builder: (_) => ImageEditorScreen(imagePath: path)));
//   if (bytes != null) { /* send edited image */ }
// ─────────────────────────────────────────────────────────────────────────────

class ImageEditorScreen extends StatefulWidget {
  final String imagePath;
  const ImageEditorScreen({super.key, required this.imagePath});

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

// ── Models ───────────────────────────────────────────────────────────────────

enum _Mode { draw, text, blur, rotate, crop, ocr }

/// Мазок кисти-блюра / прямоугольник блюра — маска, внутри которой картинка
/// заменяется на размытую версию (редакция скриншотов).
class _BlurStroke {
  final List<Offset> pts;
  final double width;
  const _BlurStroke({required this.pts, required this.width});
}

class _Stroke {
  final List<Offset> pts;
  final Color color;
  final double width;
  final bool eraser;
  const _Stroke(
      {required this.pts,
      required this.color,
      required this.width,
      this.eraser = false});
}

class _TextItem {
  String text;
  Offset pos;
  Color color;
  double size;
  _TextItem({required this.text, required this.pos, required this.color, required this.size});
}

/// Снимок для undo: и рисунок, и блюр-маска.
class _EditSnapshot {
  final List<_Stroke> strokes;
  final List<_BlurStroke> blurStrokes;
  final List<Rect> blurRects;
  const _EditSnapshot({
    required this.strokes,
    required this.blurStrokes,
    required this.blurRects,
  });
}

// ── State ────────────────────────────────────────────────────────────────────

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  _Mode _mode = _Mode.draw;
  final _repaintKey = GlobalKey();

  // Draw
  final List<_Stroke> _strokes = [];
  final List<_EditSnapshot> _undoHistory = [];
  List<Offset> _currentPts = [];
  Color _penColor = Colors.white;
  double _penWidth = 5.0;
  bool _eraser = false;

  // Blur (redaction) — mask over which the image is replaced by a blurred copy.
  final List<_BlurStroke> _blurStrokes = [];
  final List<Rect> _blurRects = [];
  List<Offset> _currentBlur = [];
  Rect? _currentBlurRect;
  Offset? _blurRectStart;
  bool _blurRectMode = false; // false = brush, true = rectangle
  double _blurSigma = 12.0;
  ui.Image? _uiImage; // decoded source, for the blur painter

  // Text
  final List<_TextItem> _texts = [];

  // Rotate
  int _rotateTurns = 0; // ×90°
  bool _flipH = false;

  // Crop (normalised 0–1 of the capture area)
  Rect _cropNorm = const Rect.fromLTWH(0, 0, 1, 1);

  bool _saving = false;

  // OCR
  List<OcrBlock> _ocrBlocks = [];
  bool _ocrRunning = false;
  // White-fill erase rects added when user chooses "Стереть" on an OCR block.
  final List<Rect> _ocrEraseRects = [];

  static const _kPalette = [
    Colors.white,
    Colors.black,
    Color(0xFFFF4444),
    Color(0xFFFF9F43),
    Color(0xFFFFEA00),
    Color(0xFF00C853),
    Color(0xFF40C4FF),
    Color(0xFF7C4DFF),
  ];

  // ── Capture & crop ─────────────────────────────────────────────────────────

  Future<void> _confirm() async {
    setState(() => _saving = true);
    try {
      final boundary =
          _repaintKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 2.5);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || !mounted) return;
      Uint8List bytes = data.buffer.asUint8List();

      if (_cropNorm != const Rect.fromLTWH(0, 0, 1, 1)) {
        bytes = await _crop(bytes, _cropNorm) ?? bytes;
      }

      if (mounted) Navigator.pop(context, bytes);
    } catch (e) {
      debugPrint('[ImageEditor] capture error: $e');
      if (mounted) Navigator.pop(context, null);
    }
  }

  // ── OCR ──────────────────────────────────────────────────────────────────────

  Future<void> _startOcr() async {
    if (_ocrRunning || kIsWeb) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    setState(() {
      _ocrRunning = true;
      _ocrBlocks = [];
    });
    try {
      final boundary =
          _repaintKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      // pixelRatio 1.0 → block rects map 1:1 to widget pixel coordinates
      final img = await boundary.toImage(pixelRatio: 1.0);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || !mounted) return;
      final blocks =
          await OcrService.recognizeFromBytes(data.buffer.asUint8List());
      if (mounted) setState(() => _ocrBlocks = blocks);
    } catch (e) {
      debugPrint('[ImageEditor] OCR error: $e');
    } finally {
      if (mounted) setState(() => _ocrRunning = false);
    }
  }

  void _ocrBlockTap(BuildContext context, OcrBlock block) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(block.text,
                  style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Копировать'),
            onTap: () async {
              Navigator.pop(context);
              await Clipboard.setData(ClipboardData(text: block.text));
            },
          ),
          ListTile(
            leading: const Icon(Icons.auto_fix_off_outlined),
            title: const Text('Стереть'),
            onTap: () {
              Navigator.pop(context);
              setState(() => _ocrEraseRects.add(block.boundingBox));
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  static Future<Uint8List?> _crop(Uint8List png, Rect norm) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    final iw = src.width.toDouble();
    final ih = src.height.toDouble();

    final srcRect =
        Rect.fromLTWH(norm.left * iw, norm.top * ih, norm.width * iw, norm.height * ih);
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(src, srcRect,
        Rect.fromLTWH(0, 0, srcRect.width, srcRect.height), Paint());
    final pic = rec.endRecording();
    final cropped = await pic.toImage(srcRect.width.round(), srcRect.height.round());
    final bd = await cropped.toByteData(format: ui.ImageByteFormat.png);
    return bd?.buffer.asUint8List();
  }

  @override
  void initState() {
    super.initState();
    _decodeSource();
  }

  Future<void> _decodeSource() async {
    try {
      Uint8List bytes;
      if (widget.imagePath.startsWith('data:')) {
        final b64 =
            widget.imagePath.substring(widget.imagePath.indexOf(',') + 1);
        bytes = base64Decode(b64);
      } else {
        bytes = await File(widget.imagePath).readAsBytes();
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _uiImage = frame.image);
    } catch (e) {
      debugPrint('[ImageEditor] source decode failed: $e');
    }
  }

  _EditSnapshot _snap() => _EditSnapshot(
        strokes: List.from(_strokes),
        blurStrokes: List.from(_blurStrokes),
        blurRects: List.from(_blurRects),
      );

  // ── Draw gestures ──────────────────────────────────────────────────────────

  void _panStart(DragStartDetails d) {
    _undoHistory.add(_snap());
    setState(() => _currentPts = [d.localPosition]);
  }

  void _panUpdate(DragUpdateDetails d) =>
      setState(() => _currentPts.add(d.localPosition));

  void _panEnd(DragEndDetails _) {
    if (_currentPts.isEmpty) return;
    setState(() {
      _strokes.add(_Stroke(
          pts: List.from(_currentPts),
          color: _penColor,
          width: _eraser ? _penWidth * 3 : _penWidth,
          eraser: _eraser));
      _currentPts = [];
    });
  }

  // ── Blur gestures (brush / rectangle) ───────────────────────────────────────

  void _blurStart(DragStartDetails d) {
    _undoHistory.add(_snap());
    setState(() {
      if (_blurRectMode) {
        _blurRectStart = d.localPosition;
        _currentBlurRect = Rect.fromPoints(d.localPosition, d.localPosition);
      } else {
        _currentBlur = [d.localPosition];
      }
    });
  }

  void _blurUpdate(DragUpdateDetails d) {
    setState(() {
      if (_blurRectMode) {
        if (_blurRectStart != null) {
          _currentBlurRect = Rect.fromPoints(_blurRectStart!, d.localPosition);
        }
      } else {
        _currentBlur.add(d.localPosition);
      }
    });
  }

  void _blurEnd(DragEndDetails _) {
    setState(() {
      if (_blurRectMode) {
        final r = _currentBlurRect;
        if (r != null && r.width > 4 && r.height > 4) {
          _blurRects.add(r);
        } else {
          _undoHistory.removeLast(); // nothing committed
        }
        _currentBlurRect = null;
        _blurRectStart = null;
      } else {
        if (_currentBlur.isNotEmpty) {
          _blurStrokes.add(
              _BlurStroke(pts: List.from(_currentBlur), width: _penWidth * 3.5));
        } else {
          _undoHistory.removeLast();
        }
        _currentBlur = [];
      }
    });
  }

  void _undo() {
    if (_undoHistory.isEmpty) return;
    final s = _undoHistory.removeLast();
    setState(() {
      _strokes
        ..clear()
        ..addAll(s.strokes);
      _blurStrokes
        ..clear()
        ..addAll(s.blurStrokes);
      _blurRects
        ..clear()
        ..addAll(s.blurRects);
    });
  }

  // ── Text dialog ────────────────────────────────────────────────────────────

  Future<void> _addText(Offset pos) async {
    final ctrl = TextEditingController();
    Color col = Colors.white;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить текст'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Введите текст...'),
          ),
          const SizedBox(height: 12),
          StatefulBuilder(
            builder: (_, ss) => Wrap(
              spacing: 8,
              children: _kPalette
                  .map((c) => GestureDetector(
                        onTap: () => ss(() => col = c),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: col == c ? Colors.blue : Colors.transparent,
                              width: 2.5,
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppL10n.t('common_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppL10n.t('common_add'))),
        ],
      ),
    );

    if (result == true && ctrl.text.trim().isNotEmpty && mounted) {
      setState(() => _texts.add(_TextItem(
          text: ctrl.text.trim(), pos: pos, color: col, size: 26)));
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context, null),
        ),
        actions: [
          if (_undoHistory.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.undo, color: Colors.white),
              onPressed: _undo,
            ),
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2)),
                )
              : TextButton(
                  onPressed: _confirm,
                  child: Text(AppL10n.t('common_done'),
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w700)),
                ),
        ],
      ),
      body: Column(children: [
        // ── Editing canvas ────────────────────────────────────────────────
        Expanded(
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: _mode == _Mode.draw
                  ? _panStart
                  : (_mode == _Mode.blur ? _blurStart : null),
              onPanUpdate: _mode == _Mode.draw
                  ? _panUpdate
                  : (_mode == _Mode.blur ? _blurUpdate : null),
              onPanEnd: _mode == _Mode.draw
                  ? _panEnd
                  : (_mode == _Mode.blur ? _blurEnd : null),
              onTapUp: _mode == _Mode.text
                  ? (d) => _addText(d.localPosition)
                  : null,
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  RepaintBoundary(
                    key: _repaintKey,
                    child: Stack(
                      fit: StackFit.passthrough,
                      clipBehavior: Clip.none,
                      children: [
                    // Image with rotation & flip
                    Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..rotateZ(_rotateTurns * math.pi / 2)
                        ..multiply(Matrix4.diagonal3Values(
                            _flipH ? -1.0 : 1.0, 1.0, 1.0)),
                      child: widget.imagePath.startsWith('data:')
                          ? Image.network(
                              widget.imagePath,
                              fit: BoxFit.contain,
                            )
                          : Image.file(
                              File(widget.imagePath),
                              fit: BoxFit.contain,
                            ),
                    ),
                    // Blur (redaction) layer — draws a blurred copy of the image
                    // masked to the blur strokes/rects. Under the colored strokes.
                    if (_uiImage != null)
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _BlurPainter(
                            image: _uiImage!,
                            rotateTurns: _rotateTurns,
                            flipH: _flipH,
                            strokes: _blurStrokes,
                            currentStroke: _currentBlur,
                            brushWidth: _penWidth * 3.5,
                            rects: _blurRects,
                            currentRect: _currentBlurRect,
                            sigma: _blurSigma,
                          ),
                        ),
                      ),
                    // White erase rects (OCR "стереть текст") — inside RepaintBoundary so they export
                    if (_ocrEraseRects.isNotEmpty)
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _EraseRectPainter(rects: _ocrEraseRects),
                        ),
                      ),
                    // Drawing layer
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _DrawPainter(
                          strokes: _strokes,
                          current: _currentPts,
                          currentColor: _penColor,
                          currentWidth: _eraser ? _penWidth * 3 : _penWidth,
                          currentEraser: _eraser,
                        ),
                      ),
                    ),
                    // Text items (draggable)
                    ..._texts.asMap().entries.map((e) {
                      final item = e.value;
                      return Positioned(
                        left: item.pos.dx - 60,
                        top: item.pos.dy - item.size / 2,
                        child: GestureDetector(
                          onPanUpdate: (d) =>
                              setState(() => item.pos += d.delta),
                          onDoubleTap: () async {
                            final ctrl = TextEditingController(text: item.text);
                            final result = await showDialog<String>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Изменить текст'),
                                content: TextField(controller: ctrl, autofocus: true),
                                actions: [
                                  TextButton(
                                      onPressed: () {
                                        setState(() => _texts.remove(item));
                                        Navigator.pop(ctx);
                                      },
                                      child: Text(AppL10n.t('common_delete'),
                                          style: TextStyle(color: Colors.red))),
                                  FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, ctrl.text),
                                      child: const Text('OK')),
                                ],
                              ),
                            );
                            if (result != null && mounted) {
                              setState(() => item.text = result);
                            }
                          },
                          child: Text(
                            item.text,
                            style: TextStyle(
                              color: item.color,
                              fontSize: item.size,
                              fontWeight: FontWeight.bold,
                              shadows: const [
                                Shadow(blurRadius: 6, color: Colors.black87)
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              // OCR overlay — outside RepaintBoundary (not exported)
              if (_mode == _Mode.ocr) ...[
                if (_ocrRunning)
                  const Positioned.fill(
                    child: Center(child: CircularProgressIndicator(color: Colors.white)),
                  ),
                ..._ocrBlocks.map((b) => Positioned.fromRect(
                  rect: b.boundingBox,
                  child: GestureDetector(
                    onTap: () => _ocrBlockTap(context, b),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: Colors.yellow.withValues(alpha: 0.85), width: 1.5),
                        color: Colors.yellow.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                )),
              ],
                ],
              ),
            ),
          ),
        ),

        // ── Mode-specific toolbar ─────────────────────────────────────────
        _buildToolbar(),

        // ── Mode selector ─────────────────────────────────────────────────
        _buildModeBar(),
      ]),

      // Crop overlay (outside RepaintBoundary — UI chrome only)
      floatingActionButton: null,
    );
  }

  // Crop overlay rendered via Stack in the whole screen; we use an Overlay
  // approach instead so it sits above the RepaintBoundary.
  Widget _buildToolbar() {
    switch (_mode) {
      case _Mode.draw:
        return _DrawToolbar(
          colors: _kPalette,
          selected: _penColor,
          eraser: _eraser,
          width: _penWidth,
          onColorPick: (c) => setState(() {
            _penColor = c;
            _eraser = false;
          }),
          onEraserToggle: () => setState(() => _eraser = !_eraser),
          onWidthChange: (v) => setState(() => _penWidth = v),
        );
      case _Mode.text:
        return _TextHint(crop: _cropNorm);
      case _Mode.blur:
        return _BlurToolbar(
          rectMode: _blurRectMode,
          width: _penWidth,
          sigma: _blurSigma,
          onRectMode: (v) => setState(() => _blurRectMode = v),
          onWidthChange: (v) => setState(() => _penWidth = v),
          onSigmaChange: (v) => setState(() => _blurSigma = v),
        );
      case _Mode.rotate:
        return _RotateToolbar(
          onLeft: () => setState(() => _rotateTurns = (_rotateTurns - 1) % 4),
          onRight: () => setState(() => _rotateTurns = (_rotateTurns + 1) % 4),
          onFlip: () => setState(() => _flipH = !_flipH),
        );
      case _Mode.crop:
        return _CropToolbar(
          onReset: () => setState(() => _cropNorm = const Rect.fromLTWH(0, 0, 1, 1)),
          onSquare: () => setState(() {
            final s = math.min(_cropNorm.width, _cropNorm.height);
            _cropNorm = Rect.fromCenter(center: _cropNorm.center, width: s, height: s);
          }),
          onWide: () => setState(() {
            const w = 0.9;
            _cropNorm = Rect.fromCenter(
                center: const Offset(0.5, 0.5), width: w, height: w * 9 / 16);
          }),
          crop: _cropNorm,
          onCropChanged: (r) => setState(() => _cropNorm = r),
        );
      case _Mode.ocr:
        if (_ocrRunning) {
          return const SizedBox(
            height: 44,
            child: Center(
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
              SizedBox(width: 10),
              Text('Распознавание текста…',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
            ])),
          );
        }
        return SizedBox(
          height: 44,
          child: Center(
            child: Text(
              _ocrBlocks.isEmpty
                  ? 'Текст не найден'
                  : 'Нажмите на блок текста — Копировать / Стереть',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
        );
    }
  }

  Widget _buildModeBar() {
    final modes = <(
      _Mode,
      IconData,
      String
    )>[
      (_Mode.draw, Icons.brush, 'Рисунок'),
      (_Mode.text, Icons.title, 'Текст'),
      (_Mode.blur, Icons.blur_on, 'Блюр'),
      (_Mode.rotate, Icons.rotate_90_degrees_ccw, 'Поворот'),
      (_Mode.crop, Icons.crop, 'Кадр'),
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS))
        (_Mode.ocr, Icons.document_scanner_outlined, 'OCR'),
    ];
    return Container(
      height: 54,
      color: Colors.black,
      child: Row(
        children: modes.map((entry) {
          final (mode, icon, label) = entry;
          final sel = _mode == mode;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() => _mode = mode);
                if (mode == _Mode.ocr) _startOcr();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                color: sel ? Colors.white12 : Colors.transparent,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(icon, color: sel ? Colors.white : Colors.white38, size: 20),
                  const SizedBox(height: 2),
                  Text(label,
                      style: TextStyle(
                          color: sel ? Colors.white : Colors.white38,
                          fontSize: 10,
                          fontWeight: sel ? FontWeight.w600 : FontWeight.normal)),
                ]),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Drawing custom painter ────────────────────────────────────────────────────

class _DrawPainter extends CustomPainter {
  final List<_Stroke> strokes;
  final List<Offset> current;
  final Color currentColor;
  final double currentWidth;
  final bool currentEraser;

  const _DrawPainter({
    required this.strokes,
    required this.current,
    required this.currentColor,
    required this.currentWidth,
    required this.currentEraser,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());

    void drawPts(List<Offset> pts, Paint p) {
      if (pts.isEmpty) return;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (int i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(path, p);
    }

    for (final s in strokes) {
      final p = Paint()
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..blendMode = s.eraser ? BlendMode.clear : BlendMode.srcOver;
      if (!s.eraser) p.color = s.color;
      drawPts(s.pts, p);
    }

    if (current.isNotEmpty) {
      final p = Paint()
        ..strokeWidth = currentWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..blendMode = currentEraser ? BlendMode.clear : BlendMode.srcOver;
      if (!currentEraser) p.color = currentColor;
      drawPts(current, p);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_DrawPainter o) => true;
}

// ── OCR erase-rect painter ───────────────────────────────────────────────────
// Paints white-filled rectangles over recognised text so it exports clean.

class _EraseRectPainter extends CustomPainter {
  final List<Rect> rects;
  const _EraseRectPainter({required this.rects});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..blendMode = BlendMode.srcOver;
    for (final r in rects) {
      canvas.drawRect(r, p);
    }
  }

  @override
  bool shouldRepaint(_EraseRectPainter o) => o.rects != rects;
}

// ── Blur (redaction) painter ──────────────────────────────────────────────────
//
// Draws a blurred copy of the source image, masked to the blur strokes/rects, at
// the same screen position as the displayed (rotated/flipped, contain) image. It
// paints into the widget tree, so RepaintBoundary.toImage captures it reliably —
// important for redaction (a blur that doesn't export = a leak).
class _BlurPainter extends CustomPainter {
  final ui.Image image;
  final int rotateTurns;
  final bool flipH;
  final List<_BlurStroke> strokes;
  final List<Offset> currentStroke;
  final double brushWidth;
  final List<Rect> rects;
  final Rect? currentRect;
  final double sigma;

  const _BlurPainter({
    required this.image,
    required this.rotateTurns,
    required this.flipH,
    required this.strokes,
    required this.currentStroke,
    required this.brushWidth,
    required this.rects,
    required this.currentRect,
    required this.sigma,
  });

  bool get _hasMask =>
      strokes.isNotEmpty ||
      currentStroke.isNotEmpty ||
      rects.isNotEmpty ||
      currentRect != null;

  @override
  void paint(Canvas canvas, Size size) {
    if (!_hasMask) return;
    canvas.saveLayer(Offset.zero & size, Paint());

    // 1) Blurred image, transformed to match the displayed image.
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(rotateTurns * math.pi / 2);
    canvas.scale(flipH ? -1.0 : 1.0, 1.0);
    canvas.translate(-size.width / 2, -size.height / 2);
    final dst = _containRect(
        Size(image.width.toDouble(), image.height.toDouble()), size);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    );
    canvas.restore();

    // 2) Keep the blurred pixels only inside the mask (screen coords).
    final maskStroke = Paint()
      ..blendMode = BlendMode.dstIn
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFFFFFFFF);
    final maskFill = Paint()
      ..blendMode = BlendMode.dstIn
      ..color = const Color(0xFFFFFFFF);

    void drawStroke(List<Offset> pts, double w) {
      if (pts.isEmpty) return;
      if (pts.length == 1) {
        canvas.drawCircle(pts.first, w / 2, maskFill);
        return;
      }
      maskStroke.strokeWidth = w;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(path, maskStroke);
    }

    for (final s in strokes) {
      drawStroke(s.pts, s.width);
    }
    drawStroke(currentStroke, brushWidth);
    for (final r in rects) {
      canvas.drawRect(r, maskFill);
    }
    if (currentRect != null) canvas.drawRect(currentRect!, maskFill);

    canvas.restore();
  }

  static Rect _containRect(Size img, Size box) {
    final imgAspect = img.width / img.height;
    final boxAspect = box.width / box.height;
    double w, h;
    if (imgAspect > boxAspect) {
      w = box.width;
      h = w / imgAspect;
    } else {
      h = box.height;
      w = h * imgAspect;
    }
    return Rect.fromCenter(
        center: Offset(box.width / 2, box.height / 2), width: w, height: h);
  }

  @override
  bool shouldRepaint(_BlurPainter o) => true;
}

// ── Toolbars ──────────────────────────────────────────────────────────────────

class _BlurToolbar extends StatelessWidget {
  final bool rectMode;
  final double width;
  final double sigma;
  final ValueChanged<bool> onRectMode;
  final ValueChanged<double> onWidthChange;
  final ValueChanged<double> onSigmaChange;

  const _BlurToolbar({
    required this.rectMode,
    required this.width,
    required this.sigma,
    required this.onRectMode,
    required this.onWidthChange,
    required this.onSigmaChange,
  });

  @override
  Widget build(BuildContext context) {
    Widget seg(IconData ic, String label, bool selected, VoidCallback onTap) =>
        Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: selected ? Colors.white24 : Colors.white10,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(ic, color: Colors.white, size: 20),
                Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ]),
            ),
          ),
        );
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            seg(Icons.brush, 'Кисть', !rectMode, () => onRectMode(false)),
            seg(Icons.crop_square, 'Область', rectMode, () => onRectMode(true)),
          ]),
          Row(children: [
            const Text('Сила',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            Expanded(
              child: Slider(
                  value: sigma, min: 4, max: 28, onChanged: onSigmaChange),
            ),
            if (!rectMode) ...[
              const Text('Кисть',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              Expanded(
                child: Slider(
                    value: width, min: 3, max: 30, onChanged: onWidthChange),
              ),
            ],
          ]),
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('Проведите по тому, что нужно скрыть',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

class _DrawToolbar extends StatelessWidget {
  final List<Color> colors;
  final Color selected;
  final bool eraser;
  final double width;
  final ValueChanged<Color> onColorPick;
  final VoidCallback onEraserToggle;
  final ValueChanged<double> onWidthChange;

  const _DrawToolbar({
    required this.colors,
    required this.selected,
    required this.eraser,
    required this.width,
    required this.onColorPick,
    required this.onEraserToggle,
    required this.onWidthChange,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 78,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        // Color dots
        ...colors.map((c) => GestureDetector(
              onTap: () => onColorPick(c),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(right: 6),
                width: selected == c && !eraser ? 30 : 22,
                height: selected == c && !eraser ? 30 : 22,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected == c && !eraser ? Colors.white : Colors.transparent,
                    width: 2.5,
                  ),
                ),
              ),
            )),
        const Spacer(),
        // Eraser toggle
        GestureDetector(
          onTap: onEraserToggle,
          child: Icon(Icons.auto_fix_normal,
              size: 28, color: eraser ? Colors.white : Colors.white38),
        ),
        const SizedBox(width: 8),
        // Brush width slider
        SizedBox(
          width: 100,
          child: Slider(
            value: width,
            min: 2,
            max: 24,
            activeColor: Colors.white,
            inactiveColor: Colors.white24,
            onChanged: onWidthChange,
          ),
        ),
      ]),
    );
  }
}

class _TextHint extends StatelessWidget {
  final Rect crop;
  const _TextHint({required this.crop});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 78,
      color: Colors.black,
      alignment: Alignment.center,
      child: const Text(
        'Нажми на фото, чтобы добавить текст\nДважды нажми на текст, чтобы изменить',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white54, fontSize: 13),
      ),
    );
  }
}

class _RotateToolbar extends StatelessWidget {
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onFlip;

  const _RotateToolbar(
      {required this.onLeft, required this.onRight, required this.onFlip});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 78,
      color: Colors.black,
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _Btn(Icons.rotate_left, '90° влево', onLeft),
        _Btn(Icons.rotate_right, '90° вправо', onRight),
        _Btn(Icons.flip, 'Зеркало', onFlip),
      ]),
    );
  }
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Btn(this.icon, this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: Colors.white, size: 28),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ]),
    );
  }
}

// ── Crop toolbar with interactive overlay ─────────────────────────────────────

class _CropToolbar extends StatelessWidget {
  final VoidCallback onReset;
  final VoidCallback onSquare;
  final VoidCallback onWide;
  final Rect crop;
  final ValueChanged<Rect> onCropChanged;

  const _CropToolbar({
    required this.onReset,
    required this.onSquare,
    required this.onWide,
    required this.crop,
    required this.onCropChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // Interactive crop handles rendered over the image via Overlay
      // We use a LayoutBuilder-based widget embedded in a fixed-height row
      Container(
        height: 78,
        color: Colors.black,
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _Btn(Icons.crop_square, '1:1', onSquare),
          _Btn(Icons.crop_landscape, '16:9', onWide),
          _Btn(Icons.crop_free, 'Сбросить', onReset),
          Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(
              '${(crop.width * 100).round()}×${(crop.height * 100).round()}%',
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ]),
        ]),
      ),
    ]);
  }
}

// ── Crop overlay (rendered as an Overlay entry above everything) ───────────────
// Used from outside _ImageEditorScreenState via a Stack over the editing canvas.

class _CropOverlay extends StatefulWidget {
  final Rect cropNorm;
  final ValueChanged<Rect> onChanged;
  const _CropOverlay({required this.cropNorm, required this.onChanged});

  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

enum _CropHandle { tl, tr, bl, br }

class _CropOverlayState extends State<_CropOverlay> {
  _CropHandle? _active;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      final w = c.maxWidth;
      final h = c.maxHeight;
      final r = Rect.fromLTWH(widget.cropNorm.left * w, widget.cropNorm.top * h,
          widget.cropNorm.width * w, widget.cropNorm.height * h);

      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (d) => _active = _hit(d.localPosition, r),
        onPanUpdate: (d) {
          if (_active == null) return;
          final p = Offset(
            d.localPosition.dx.clamp(0.0, w),
            d.localPosition.dy.clamp(0.0, h),
          );
          Rect nr;
          const kMin = 40.0;
          switch (_active!) {
            case _CropHandle.tl:
              nr = Rect.fromLTRB(
                  p.dx.clamp(0, r.right - kMin),
                  p.dy.clamp(0, r.bottom - kMin),
                  r.right,
                  r.bottom);
            case _CropHandle.tr:
              nr = Rect.fromLTRB(
                  r.left,
                  p.dy.clamp(0, r.bottom - kMin),
                  p.dx.clamp(r.left + kMin, w),
                  r.bottom);
            case _CropHandle.bl:
              nr = Rect.fromLTRB(
                  p.dx.clamp(0, r.right - kMin),
                  r.top,
                  r.right,
                  p.dy.clamp(r.top + kMin, h));
            case _CropHandle.br:
              nr = Rect.fromLTRB(
                  r.left,
                  r.top,
                  p.dx.clamp(r.left + kMin, w),
                  p.dy.clamp(r.top + kMin, h));
          }
          widget.onChanged(Rect.fromLTRB(
              nr.left / w, nr.top / h, nr.right / w, nr.bottom / h));
        },
        onPanEnd: (_) => _active = null,
        child: CustomPaint(
          painter: _CropPainter(cropRect: r),
          size: Size(w, h),
        ),
      );
    });
  }

  _CropHandle? _hit(Offset p, Rect r) {
    const k = 32.0;
    if ((p - r.topLeft).distance < k) return _CropHandle.tl;
    if ((p - r.topRight).distance < k) return _CropHandle.tr;
    if ((p - r.bottomLeft).distance < k) return _CropHandle.bl;
    if ((p - r.bottomRight).distance < k) return _CropHandle.br;
    return null;
  }
}

class _CropPainter extends CustomPainter {
  final Rect cropRect;
  const _CropPainter({required this.cropRect});

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black54;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, cropRect.top), dim);
    canvas.drawRect(
        Rect.fromLTWH(0, cropRect.bottom, size.width, size.height - cropRect.bottom), dim);
    canvas.drawRect(
        Rect.fromLTWH(0, cropRect.top, cropRect.left, cropRect.height), dim);
    canvas.drawRect(
        Rect.fromLTWH(cropRect.right, cropRect.top, size.width - cropRect.right, cropRect.height),
        dim);

    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(cropRect, border);

    // Rule-of-thirds grid
    final grid = Paint()
      ..color = Colors.white30
      ..strokeWidth = 0.6;
    for (int i = 1; i < 3; i++) {
      canvas.drawLine(
          Offset(cropRect.left + cropRect.width * i / 3, cropRect.top),
          Offset(cropRect.left + cropRect.width * i / 3, cropRect.bottom),
          grid);
      canvas.drawLine(
          Offset(cropRect.left, cropRect.top + cropRect.height * i / 3),
          Offset(cropRect.right, cropRect.top + cropRect.height * i / 3),
          grid);
    }

    // L-shaped corner handles
    const L = 18.0;
    final corner = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square;
    for (final pt in [
      (cropRect.topLeft, const Offset(L, 0), const Offset(0, L)),
      (cropRect.topRight, const Offset(-L, 0), const Offset(0, L)),
      (cropRect.bottomLeft, const Offset(L, 0), const Offset(0, -L)),
      (cropRect.bottomRight, const Offset(-L, 0), const Offset(0, -L)),
    ]) {
      canvas.drawLine(pt.$1, pt.$1 + pt.$2, corner);
      canvas.drawLine(pt.$1, pt.$1 + pt.$3, corner);
    }
  }

  @override
  bool shouldRepaint(_CropPainter o) => o.cropRect != cropRect;
}
