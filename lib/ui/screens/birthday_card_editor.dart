import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';

import '../../services/image_service.dart';
import '../../utils/web_file_store.dart';
import '../../utils/web_object_url.dart';
import '../widgets/sticker_picker_sheet.dart';

/// Editor for a birthday greeting card: festive background + draggable text,
/// emoji, stickers and gallery photos, composited with your own hands.
///
/// Everything is rendered to a [ui.Picture] on export (never
/// `RepaintBoundary.toImage`, which is broken on web) so it works everywhere.
/// Returns the finished PNG bytes, or null if cancelled.
class BirthdayCardEditor extends StatefulWidget {
  final String recipientName;
  const BirthdayCardEditor({super.key, required this.recipientName});

  @override
  State<BirthdayCardEditor> createState() => _BirthdayCardEditorState();
}

// Export resolution (4:5 portrait card).
const double _kExportW = 1080;
const double _kExportH = 1350;

const List<List<Color>> _kBackgrounds = [
  [Color(0xFFFF6B9D), Color(0xFFFEC76F)],
  [Color(0xFF6A5AE0), Color(0xFF9C6BFF)],
  [Color(0xFF00B4DB), Color(0xFF0083B0)],
  [Color(0xFFFF9A9E), Color(0xFFFAD0C4)],
  [Color(0xFF11998E), Color(0xFF38EF7D)],
  [Color(0xFF232526), Color(0xFF414345)],
];

const List<String> _kEmojiPalette = [
  '🎂', '🎉', '🎁', '🥳', '🎈', '✨', '🌟', '❤️',
  '🍰', '🎊', '🌈', '🔥', '👑', '💐', '🎀', '🕯️',
];

enum _Kind { text, image }

class _CardItem {
  final int id;
  _Kind kind;
  String text; // text / emoji glyph
  Color color; // text colour
  bool bold = true;
  ui.Image? image; // photo / sticker
  double aspect; // image w/h
  Offset center; // normalised 0..1 within the canvas
  double scale; // text: fontSize as fraction of width; image: width fraction
  double rotation = 0; // radians

  _CardItem({
    required this.id,
    required this.kind,
    this.text = '',
    this.color = Colors.white,
    this.image,
    this.aspect = 1,
    required this.center,
    required this.scale,
  });
}

class _BirthdayCardEditorState extends State<BirthdayCardEditor> {
  final _items = <_CardItem>[];
  int _bgIndex = 0;
  int _seq = 0;
  int? _selectedId;
  final _picker = ImagePicker();

  double _gestureStartScale = 1;
  double _gestureStartRotation = 0;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    // Seed a friendly starting layout so the card is never blank.
    _items.add(_CardItem(
      id: _seq++,
      kind: _Kind.text,
      text: 'С Днём Рождения!',
      color: Colors.white,
      center: const Offset(0.5, 0.30),
      scale: 0.085,
    ));
    _items.add(_CardItem(
      id: _seq++,
      kind: _Kind.text,
      text: '🎂',
      center: const Offset(0.5, 0.58),
      scale: 0.22,
    ));
  }

  _CardItem? get _selected {
    for (final it in _items) {
      if (it.id == _selectedId) return it;
    }
    return null;
  }

  void _addText() async {
    final res = await _promptText(initial: '');
    if (res == null || res.$1.trim().isEmpty) return;
    setState(() {
      final it = _CardItem(
        id: _seq++,
        kind: _Kind.text,
        text: res.$1.trim(),
        color: res.$2,
        center: const Offset(0.5, 0.5),
        scale: 0.075,
      );
      _items.add(it);
      _selectedId = it.id;
    });
  }

  void _addEmoji(String e) {
    setState(() {
      final it = _CardItem(
        id: _seq++,
        kind: _Kind.text,
        text: e,
        center: const Offset(0.5, 0.5),
        scale: 0.18,
      );
      _items.add(it);
      _selectedId = it.id;
    });
  }

  Future<void> _addPhoto() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 82,
        requestFullMetadata: false,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await _addImageFromBytes(bytes);
    } catch (e) {
      _snack('Не удалось добавить фото: $e');
    }
  }

  Future<void> _addSticker() async {
    await showStickerPickerSheet(
      context,
      onPickedSticker: (absolutePath) async {
        final bytes = await _loadImageBytes(absolutePath);
        if (bytes == null || bytes.isEmpty) {
          _snack('Не удалось загрузить стикер');
          return;
        }
        await _addImageFromBytes(bytes);
      },
    );
  }

  Future<void> _addImageFromBytes(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        final it = _CardItem(
          id: _seq++,
          kind: _Kind.image,
          image: img,
          aspect: img.width / img.height,
          center: const Offset(0.5, 0.5),
          scale: 0.5,
        );
        _items.add(it);
        _selectedId = it.id;
      });
    } catch (e) {
      _snack('Не удалось прочитать картинку: $e');
    }
  }

  /// Cross-platform bytes for a sticker path (native file, web stored file, or
  /// bundled asset).
  Future<Uint8List?> _loadImageBytes(String path) async {
    try {
      final resolved = ImageService.instance.resolveStoredPath(path) ?? path;
      if (resolved.startsWith('opfs://') ||
          resolved.startsWith('blob:') ||
          resolved.startsWith('http')) {
        final url = resolved.startsWith('opfs://')
            ? await webStoredFileObjectUrl(resolved.split('#').first,
                mimeType: 'image/png')
            : resolved;
        if (url == null) return null;
        return readWebObjectUrlBytes(url);
      }
      if (resolved.startsWith('assets/')) {
        final bd = await rootBundle.load(resolved);
        return bd.buffer.asUint8List();
      }
      if (!kIsWeb) {
        final f = File(resolved);
        if (await f.exists()) return f.readAsBytes();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void _deleteSelected() {
    final sel = _selected;
    if (sel == null) return;
    setState(() {
      sel.image?.dispose();
      _items.removeWhere((e) => e.id == sel.id);
      _selectedId = null;
    });
  }

  Future<void> _editSelectedText() async {
    final sel = _selected;
    if (sel == null || sel.kind != _Kind.text) return;
    final res = await _promptText(initial: sel.text, initialColor: sel.color);
    if (res == null) return;
    setState(() {
      sel.text = res.$1.trim().isEmpty ? sel.text : res.$1.trim();
      sel.color = res.$2;
    });
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final bytes = await _renderToPng();
      if (!mounted) return;
      Navigator.of(context).pop(bytes);
    } catch (e) {
      if (mounted) {
        setState(() => _exporting = false);
        _snack('Не удалось собрать открытку: $e');
      }
    }
  }

  Future<Uint8List?> _renderToPng() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder,
        Rect.fromLTWH(0, 0, _kExportW, _kExportH));

    // Background gradient.
    final bg = _kBackgrounds[_bgIndex];
    final shader = ui.Gradient.linear(
      const Offset(0, 0),
      const Offset(_kExportW, _kExportH),
      bg,
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, _kExportW, _kExportH),
      Paint()..shader = shader,
    );

    for (final it in _items) {
      canvas.save();
      final cx = it.center.dx * _kExportW;
      final cy = it.center.dy * _kExportH;
      canvas.translate(cx, cy);
      if (it.rotation != 0) canvas.rotate(it.rotation);
      if (it.kind == _Kind.text) {
        final tp = _textPainter(it, _kExportW);
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      } else if (it.image != null) {
        final w = it.scale * _kExportW;
        final h = w / it.aspect;
        final dst = Rect.fromCenter(center: Offset.zero, width: w, height: h);
        canvas.drawImageRect(
          it.image!,
          Rect.fromLTWH(
              0, 0, it.image!.width.toDouble(), it.image!.height.toDouble()),
          dst,
          Paint()..filterQuality = FilterQuality.high,
        );
      }
      canvas.restore();
    }

    final pic = recorder.endRecording();
    final img = await pic.toImage(_kExportW.round(), _kExportH.round());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    pic.dispose();
    return data?.buffer.asUint8List();
  }

  TextPainter _textPainter(_CardItem it, double canvasW) {
    final fontSize = it.scale * canvasW;
    return TextPainter(
      text: TextSpan(
        text: it.text,
        style: TextStyle(
          fontSize: fontSize,
          color: it.color,
          fontWeight: it.bold ? FontWeight.w800 : FontWeight.w500,
          height: 1.1,
          shadows: const [
            Shadow(color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: canvasW * 0.9);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<(String, Color)?> _promptText(
      {required String initial, Color initialColor = Colors.white}) {
    final ctrl = TextEditingController(text: initial);
    var color = initialColor;
    const swatches = [
      Colors.white,
      Colors.black,
      Color(0xFFFFD54F),
      Color(0xFFFF5252),
      Color(0xFF69F0AE),
      Color(0xFF448AFF),
      Color(0xFFE040FB),
    ];
    return showDialog<(String, Color)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Текст'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  hintText: 'Ваше поздравление',
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in swatches)
                    GestureDetector(
                      onTap: () => setD(() => color = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color == c
                                ? Theme.of(ctx).colorScheme.primary
                                : Colors.black26,
                            width: color == c ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, (ctrl.text, color)),
              child: const Text('Готово'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final it in _items) {
      it.image?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF101014),
        foregroundColor: Colors.white,
        title: Text('Открытка · ${widget.recipientName}',
            style: const TextStyle(fontSize: 16)),
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
              label: const Text('Отправить'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: AspectRatio(
                  aspectRatio: _kExportW / _kExportH,
                  child: _canvas(),
                ),
              ),
            ),
          ),
          _emojiStrip(),
          _toolbar(),
        ],
      ),
    );
  }

  Widget _canvas() {
    final bg = _kBackgrounds[_bgIndex];
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final h = box.maxHeight;
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: GestureDetector(
          onTap: () => setState(() => _selectedId = null),
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: bg,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                ),
              ),
              for (final it in _items) _itemWidget(it, w, h),
            ],
          ),
        ),
      );
    });
  }

  Widget _itemWidget(_CardItem it, double boxW, double boxH) {
    final selected = it.id == _selectedId;
    Widget content;
    double renderW;
    double renderH;
    if (it.kind == _Kind.text) {
      final fontSize = it.scale * boxW;
      content = Text(
        it.text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: fontSize,
          color: it.color,
          fontWeight: it.bold ? FontWeight.w800 : FontWeight.w500,
          height: 1.1,
          shadows: const [
            Shadow(
                color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
      );
      // Approximate hit box; text is centre-anchored.
      renderW = boxW * 0.9;
      renderH = fontSize * 2.4;
    } else {
      renderW = it.scale * boxW;
      renderH = renderW / it.aspect;
      content = it.image == null
          ? const SizedBox.shrink()
          : RawImage(image: it.image, fit: BoxFit.contain);
    }

    final left = it.center.dx * boxW - renderW / 2;
    final top = it.center.dy * boxH - renderH / 2;

    return Positioned(
      left: left,
      top: top,
      width: renderW,
      height: renderH,
      child: Transform.rotate(
        angle: it.rotation,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _selectedId = it.id),
          onDoubleTap: it.kind == _Kind.text ? _editSelectedText : null,
          onScaleStart: (_) {
            setState(() => _selectedId = it.id);
            _gestureStartScale = it.scale;
            _gestureStartRotation = it.rotation;
          },
          onScaleUpdate: (d) {
            setState(() {
              it.center = Offset(
                (it.center.dx + d.focalPointDelta.dx / boxW).clamp(0.02, 0.98),
                (it.center.dy + d.focalPointDelta.dy / boxH).clamp(0.02, 0.98),
              );
              if (d.scale != 1.0) {
                it.scale = (_gestureStartScale * d.scale).clamp(0.03, 1.4);
              }
              if (d.rotation != 0) {
                it.rotation = _gestureStartRotation + d.rotation;
              }
            });
          },
          child: Container(
            alignment: Alignment.center,
            decoration: selected
                ? BoxDecoration(
                    border: Border.all(color: Colors.white70, width: 1.5),
                    borderRadius: BorderRadius.circular(6),
                  )
                : null,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                content,
                if (selected)
                  Positioned(
                    right: -10,
                    top: -10,
                    child: GestureDetector(
                      onTap: _deleteSelected,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close,
                            size: 16, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emojiStrip() {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _kEmojiPalette.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (_, i) => InkWell(
          onTap: () => _addEmoji(_kEmojiPalette[i]),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Center(
              child: Text(_kEmojiPalette[i],
                  style: const TextStyle(fontSize: 24)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    return SafeArea(
      top: false,
      child: Container(
        height: 62,
        color: const Color(0xFF17171C),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _toolBtn(Icons.gradient_rounded, 'Фон',
                () => setState(() => _bgIndex = (_bgIndex + 1) % _kBackgrounds.length)),
            _toolBtn(Icons.text_fields_rounded, 'Текст', _addText),
            _toolBtn(Icons.emoji_emotions_outlined, 'Эмодзи', () {
              // The strip above already shows the palette; nudge focus there.
              _snack('Выберите эмодзи из строки выше');
            }),
            _toolBtn(Icons.sticky_note_2_outlined, 'Стикер', _addSticker),
            _toolBtn(Icons.photo_outlined, 'Фото', _addPhoto),
          ],
        ),
      ),
    );
  }

  Widget _toolBtn(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
