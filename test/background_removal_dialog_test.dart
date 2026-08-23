import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rlink/services/background_removal.dart';
import 'package:rlink/ui/widgets/background_removal_dialog.dart';

// Image.memory's decode is a real async codec op — per this codebase's own
// established finding (see rls_sticker_view tests), it only progresses
// inside tester.runAsync when that wraps the WHOLE sequence starting at
// pumpWidget, not just the final read.
void main() {
  Uint8List samplePng() {
    final image = img.Image(width: 20, height: 20, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(255, 255, 255, 255));
    for (var y = 7; y < 13; y++) {
      for (var x = 7; x < 13; x++) {
        image.setPixelRgba(x, y, 220, 30, 30, 255);
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  testWidgets('shows a live preview and returns processed bytes on confirm', (tester) async {
    await tester.runAsync(() async {
      final source = samplePng();
      Uint8List? result;

      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () async {
              result = await showBackgroundRemovalDialog(context, sourceBytes: source);
            },
            child: const Text('open'),
          );
        }),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Удалить фон'), findsOneWidget);
      // The preview Image.memory needs a real decode pass to appear.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);

      final doneButton = find.widgetWithText(FilledButton, 'Готово');
      expect(tester.widget<FilledButton>(doneButton).onPressed, isNotNull,
          reason: 'a preview must already be computed by the time the dialog settles');

      await tester.tap(doneButton);
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result, BackgroundRemoval.remove(source, tolerance: 0.12));
    });
  });

  testWidgets('cancel returns null and leaves the source untouched', (tester) async {
    await tester.runAsync(() async {
      final source = samplePng();
      Uint8List? result = Uint8List(0);

      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () async {
              result = await showBackgroundRemovalDialog(context, sourceBytes: source);
            },
            child: const Text('open'),
          );
        }),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });
  });
}
