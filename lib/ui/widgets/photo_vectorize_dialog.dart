import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../services/background_removal.dart';
import '../../services/photo_vectorizer.dart';
import 'checkerboard_background.dart';

/// Live-preview color-count/detail tuning for [PhotoVectorizer.vectorize].
/// Returns the resulting SVG string on "Готово", or null if cancelled.
Future<String?> showPhotoVectorizeDialog(
  BuildContext context, {
  required Uint8List sourceBytes,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PhotoVectorizeDialog(sourceBytes: sourceBytes),
  );
}

class _PhotoVectorizeDialog extends StatefulWidget {
  final Uint8List sourceBytes;
  const _PhotoVectorizeDialog({required this.sourceBytes});

  @override
  State<_PhotoVectorizeDialog> createState() => _PhotoVectorizeDialogState();
}

class _PhotoVectorizeDialogState extends State<_PhotoVectorizeDialog> {
  int _colorCount = 6;
  double _detail = 0.5;
  bool _removeBackgroundFirst = false;
  String? _svg;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _recompute();
  }

  Future<void> _recompute() async {
    setState(() => _busy = true);
    try {
      // Vectorizing is heavier than the background-removal preview, so this
      // runs on slider release rather than continuously during a drag.
      // Stripping the background first (fixed, moderate tolerance — this
      // dialog only has room for one more control) keeps it from becoming
      // one of the k-means color clusters, so the traced result is just the
      // subject instead of subject-plus-a-background-shaped path.
      final source = _removeBackgroundFirst
          ? BackgroundRemoval.remove(widget.sourceBytes, tolerance: 0.12)
          : widget.sourceBytes;
      final svg = PhotoVectorizer.vectorize(
        source,
        colorCount: _colorCount,
        detail: _detail,
      );
      if (!mounted) return;
      setState(() {
        _svg = svg;
        _error = null;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Фото в вектор'),
      content: SizedBox(
        width: 280,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const CheckerboardBackground(),
                      if (_svg != null)
                        SvgPicture.string(_svg!, fit: BoxFit.contain),
                      if (_busy)
                        const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Не удалось обработать: $_error',
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.palette_outlined, size: 18),
                  Expanded(
                    child: Slider(
                      value: _colorCount.toDouble(),
                      min: 2,
                      max: 12,
                      divisions: 10,
                      label: '$_colorCount',
                      onChanged: (v) => setState(() => _colorCount = v.round()),
                      onChangeEnd: (_) => _recompute(),
                    ),
                  ),
                ],
              ),
              Text('Цветов: $_colorCount',
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              Row(
                children: [
                  const Icon(Icons.tune, size: 18),
                  Expanded(
                    child: Slider(
                      value: _detail,
                      onChanged: (v) => setState(() => _detail = v),
                      onChangeEnd: (_) => _recompute(),
                    ),
                  ),
                ],
              ),
              Text('Детализация: ${(_detail * 100).round()}%',
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _removeBackgroundFirst,
                title: const Text('Сначала убрать фон',
                    style: TextStyle(fontSize: 13)),
                onChanged: (v) {
                  setState(() => _removeBackgroundFirst = v ?? false);
                  _recompute();
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _svg == null ? null : () => Navigator.pop(context, _svg),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}
