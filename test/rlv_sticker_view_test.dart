import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/models/rlv_sticker.dart';
import 'package:rlink/ui/widgets/rlv_sticker_view.dart';

void main() {
  testWidgets('RlvStickerView decodes a shape+path sticker and paints without throwing',
      (tester) async {
    final sticker = RlvSticker(
      width: 512,
      height: 512,
      durationMs: 1000,
      layers: [
        const RlvLayer(
          id: 'l1',
          kind: 'shape',
          shapeType: 'star',
          sides: 5,
          fill: '#FFD60AFF',
          size: [200, 200],
          keys: [
            RlvKeyframe(tMs: 0, x: 256, y: 256, sx: 1, sy: 1),
            RlvKeyframe(tMs: 1000, x: 256, y: 256, sx: 1.2, sy: 1.2),
          ],
        ),
        const RlvLayer(
          id: 'l2',
          kind: 'path',
          points: [0.1, 0.1, 0.5, 0.9, 0.9, 0.1],
          color: '#000000FF',
          strokeWidth: 0.03,
          size: [512, 512],
          keys: [RlvKeyframe(tMs: 0, x: 256, y: 256)],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: Center(child: RlvStickerView(sticker: sticker, width: 128, height: 128))),
    );
    // Let the async layer-decode step (shape/path build synchronously, no
    // real await needed for these two kinds) settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(RlvStickerView), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RlvStickerView with no layers still renders (nothing to paint)',
      (tester) async {
    const sticker = RlvSticker(width: 64, height: 64, durationMs: 500, layers: []);
    await tester.pumpWidget(const MaterialApp(home: RlvStickerView(sticker: sticker)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
