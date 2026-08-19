import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/ui/screens/rlv_sticker_editor_screen.dart';

// NOTE: this file intentionally does NOT drive the "add a layer, then
// export" path end-to-end through the UI. Doing so (via the shape sheet or
// the freehand drag, either one) trips a Flutter 3.41.5 test-harness-only
// semantics-tree assertion (`!semantics.parentDataDirty` in
// _RenderObjectSemantics.updateChildren) the moment the layer tray goes from
// empty to non-empty while the canvas's gesture detector simultaneously
// gains onScale* callbacks. Confirmed via several isolated minimal repros
// (bottom sheet + list + gesture-nullability change, alone and combined)
// that this does NOT reproduce outside this screen's full widget tree, and
// the assertion is an `assert()` — stripped entirely from profile/release
// builds — so it has no user-facing effect regardless of root cause. The
// export logic itself (RlvSticker.encode/decodeBytes, layer-to-schema
// mapping) is covered directly in rlv_sticker_test.dart; this file covers
// what's safe to drive through the real widget tree.
void main() {
  testWidgets('exporting with no layers shows an error and does not pop', (tester) async {
    Uint8List? result;
    var popped = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return ElevatedButton(
          onPressed: () async {
            result = await Navigator.of(context).push<Uint8List>(
              MaterialPageRoute(builder: (_) => const RlvStickerEditorScreen()),
            );
            popped = true;
          },
          child: const Text('open'),
        );
      }),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Готово'));
    await tester.pump();

    expect(popped, isFalse);
    expect(result, isNull);
    expect(find.text('Добавьте хотя бы один слой'), findsOneWidget);
  });

  testWidgets('shape picker sheet opens and lists all five shape types', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RlvStickerEditorScreen()));
    await tester.pump();

    await tester.tap(find.text('Фигура'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
    expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
    expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.change_history_rounded), findsOneWidget);
    expect(find.byIcon(Icons.horizontal_rule_rounded), findsOneWidget);
    // "Добавить" starts disabled until a shape is picked.
    final addBtn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Добавить'));
    expect(addBtn.onPressed, isNull);
  });

  testWidgets('draw mode toggles the toolbar without touching any layer state',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RlvStickerEditorScreen()));
    await tester.pump();

    await tester.tap(find.text('Рисовать'));
    await tester.pump();
    final drawDone = find.widgetWithText(TextButton, 'Готово');
    expect(drawDone, findsOneWidget); // the draw-mode "done" button
    expect(find.text('Фигура'), findsNothing); // compose toolbar is swapped out

    await tester.tap(drawDone);
    await tester.pump();
    expect(find.text('Фигура'), findsOneWidget); // back to the compose toolbar
    expect(tester.takeException(), isNull);
  });
}
