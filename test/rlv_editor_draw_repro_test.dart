import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/ui/screens/rlv_sticker_editor_screen.dart';

void main() {
  testWidgets(
      'drawing a freehand stroke does not blank out the rest of the editor',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: RlvStickerEditorScreen()),
    );
    await tester.pumpAndSettle();

    // Enter draw mode.
    await tester.tap(find.text('Рисовать'));
    await tester.pump();
    expect(find.text('Готово'), findsWidgets); // draw-mode "done" button

    // Find the canvas (the CustomPaint driving _RlvEditorPainter) and drag
    // across it — this is the exact user action that reproduced the bug.
    final canvasFinder = find.byType(CustomPaint).first;
    final center = tester.getCenter(canvasFinder);
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(80, 80));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);

    // After finishing the stroke, drawMode exits and the new layer is
    // selected — the toolbar (with "Фигура"/shape button) and layer tray
    // must both still be present and laid out, not blanked out.
    expect(find.text('Фигура'), findsOneWidget);
    expect(find.text('Удалить'), findsOneWidget);
  });
}
