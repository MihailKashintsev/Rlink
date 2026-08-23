import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image/image.dart' as img;
import 'package:rlink/ui/widgets/photo_vectorize_dialog.dart';

void main() {
  Uint8List samplePng() {
    final image = img.Image(width: 40, height: 40, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(250, 250, 250, 255));
    for (var y = 12; y < 28; y++) {
      for (var x = 12; x < 28; x++) {
        image.setPixelRgba(x, y, 20, 60, 220, 255);
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  testWidgets('shows a live SVG preview and returns a valid SVG on confirm', (tester) async {
    await tester.runAsync(() async {
      final source = samplePng();
      String? result;

      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () async {
              result = await showPhotoVectorizeDialog(context, sourceBytes: source);
            },
            child: const Text('open'),
          );
        }),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Фото в вектор'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.byType(SvgPicture), findsOneWidget);

      final doneButton = find.widgetWithText(FilledButton, 'Готово');
      expect(tester.widget<FilledButton>(doneButton).onPressed, isNotNull);

      await tester.tap(doneButton);
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result, contains('<svg'));
      expect(result, contains('<path'));
    });
  });

  testWidgets('the "remove background first" toggle recomputes the preview', (tester) async {
    await tester.runAsync(() async {
      final source = samplePng();

      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () => showPhotoVectorizeDialog(context, sourceBytes: source),
            child: const Text('open'),
          );
        }),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(find.text('Сначала убрать фон'), findsOneWidget);
      await tester.tap(find.text('Сначала убрать фон'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      // Recompute must not throw and must still leave a usable preview.
      final doneButton = find.widgetWithText(FilledButton, 'Готово');
      expect(tester.widget<FilledButton>(doneButton).onPressed, isNotNull);
    });
  });
}
