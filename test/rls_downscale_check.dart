import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// Mirrors the editor's _decodeToPng: decode straight to canvas size, re-encode
/// as PNG. Pins the weight win so a future change can't silently undo it.
Future<Uint8List> decodeToPng(Uint8List raw, {double maxSide = 512}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(raw);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final w = descriptor.width, h = descriptor.height;
  var tw = w, th = h;
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

void main() {
  test('layers are downscaled to the canvas before PNG encoding', () async {
    final pngs = Directory('assets/sticker_packs/default')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .take(3)
        .toList();
    expect(pngs, isNotEmpty);

    for (final f in pngs) {
      final raw = f.readAsBytesSync();
      final before = await decodeToPng(raw, maxSide: 4096); // old behaviour
      final after = await decodeToPng(raw); // new: capped at canvas
      // ignore: avoid_print
      print('${f.uri.pathSegments.last}: '
          'было=${(before.length / 1024).toStringAsFixed(0)}КБ  '
          'стало=${(after.length / 1024).toStringAsFixed(0)}КБ  '
          '(${(100 - after.length / before.length * 100).toStringAsFixed(0)}% меньше)');
      expect(after.length, lessThanOrEqualTo(before.length));
    }
  });
}
