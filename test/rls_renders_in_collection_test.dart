import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/models/rls_sticker.dart';
import 'package:rlink/ui/widgets/channel_feed_image.dart';
import 'package:rlink/ui/widgets/rls_sticker_view.dart';

/// 1x1 transparent PNG — a real decodable layer asset.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

Uint8List _sampleRls() => RlsSticker(
      width: 512,
      height: 512,
      durationMs: 1000,
      assets: {'a': _png},
      layers: [
        RlsLayer(id: 'l', assetId: 'a', keys: const [
          RlsKeyframe(tMs: 0, x: 256, y: 256),
          RlsKeyframe(tMs: 1000, x: 256, y: 200),
        ]),
      ],
    ).encode();

void main() {
  testWidgets('storedImage plays an .rls handed to it as a web data ref',
      (tester) async {
    final ref = 'data:$rlsMimeType;base64,${base64Encode(_sampleRls())}';
    await tester.pumpWidget(MaterialApp(
      home: storedImage(ref, fit: BoxFit.contain, width: 96, height: 96),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(RlsStickerView), findsOneWidget,
        reason: 'the collection grid must animate .rls, not show a blank box');
  });

  testWidgets('a plain image ref is still rendered as an image', (tester) async {
    final ref = 'data:image/png;base64,${base64Encode(_png)}';
    await tester.pumpWidget(MaterialApp(
      home: storedImage(ref, fit: BoxFit.contain, width: 96, height: 96),
    ));
    await tester.pump();
    expect(find.byType(RlsStickerView), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });
}
