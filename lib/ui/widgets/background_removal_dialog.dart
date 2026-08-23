import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/background_removal.dart';
import 'checkerboard_background.dart';

/// Live-preview tolerance slider for [BackgroundRemoval.remove]. Returns the
/// processed PNG bytes on "Готово", or null if cancelled. Shared by both
/// sticker studios (.rls and .rlv) — background removal works identically on
/// a flat imported photo either way, before it becomes a layer.
Future<Uint8List?> showBackgroundRemovalDialog(
  BuildContext context, {
  required Uint8List sourceBytes,
}) {
  return showDialog<Uint8List>(
    context: context,
    builder: (_) => _BackgroundRemovalDialog(sourceBytes: sourceBytes),
  );
}

class _BackgroundRemovalDialog extends StatefulWidget {
  final Uint8List sourceBytes;
  const _BackgroundRemovalDialog({required this.sourceBytes});

  @override
  State<_BackgroundRemovalDialog> createState() => _BackgroundRemovalDialogState();
}

class _BackgroundRemovalDialogState extends State<_BackgroundRemovalDialog> {
  double _tolerance = 0.12;
  Uint8List? _preview;
  bool _busy = false;
  Timer? _debounce;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _recompute();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onSliderChanged(double v) {
    setState(() => _tolerance = v);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _recompute);
  }

  Future<void> _recompute() async {
    setState(() => _busy = true);
    try {
      // Sticker-layer photos are already capped at 512x512 by the caller, so
      // this runs fast enough on the UI isolate not to need compute().
      final bytes = BackgroundRemoval.remove(widget.sourceBytes, tolerance: _tolerance);
      if (!mounted) return;
      setState(() {
        _preview = bytes;
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
      title: const Text('Удалить фон'),
      content: SizedBox(
        width: 280,
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
                    if (_preview != null)
                      Image.memory(_preview!, fit: BoxFit.contain, gaplessPlayback: true),
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
                const Icon(Icons.tune, size: 18),
                Expanded(
                  child: Slider(
                    value: _tolerance,
                    onChanged: _onSliderChanged,
                  ),
                ),
              ],
            ),
            Text(
              'Допуск: ${(_tolerance * 100).round()}% — больше стирает больше фона, '
              'но может задеть сам объект',
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _preview == null ? null : () => Navigator.pop(context, _preview),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}
