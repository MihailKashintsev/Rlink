import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/models/rls_sticker.dart';

void main() {
  test('.rls size overhead over raw PNG layers', () {
    final pngs = Directory('assets/sticker_packs/default')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .take(3)
        .toList();
    expect(pngs, isNotEmpty);

    for (var n = 1; n <= pngs.length; n++) {
      final assets = <String, Uint8List>{};
      final layers = <RlsLayer>[];
      var rawPng = 0;
      for (var i = 0; i < n; i++) {
        final bytes = pngs[i].readAsBytesSync();
        rawPng += bytes.length;
        assets['a$i'] = bytes;
        layers.add(RlsLayer(
          id: 'l$i',
          assetId: 'a$i',
          defaultEase: 'outBack',
          keys: const [
            RlsKeyframe(tMs: 0, x: 256, y: 256),
            RlsKeyframe(tMs: 500, x: 256, y: 200, sx: 1.2, sy: 1.2, rotDeg: 8),
            RlsKeyframe(tMs: 1200, x: 256, y: 256),
          ],
        ));
      }
      final out = RlsSticker(
        width: 512,
        height: 512,
        durationMs: 1200,
        assets: assets,
        layers: layers,
      ).encode();

      final overheadPct = (out.length / rawPng - 1) * 100;
      // ignore: avoid_print
      print('слоёв=$n  PNG=${(rawPng / 1024).toStringAsFixed(1)}КБ  '
          '.rls=${(out.length / 1024).toStringAsFixed(1)}КБ  '
          'накладные=${overheadPct.toStringAsFixed(1)}%  '
          'data:URL=${(base64Encode(out).length / 1024).toStringAsFixed(1)}КБ');

      expect(RlsSticker.decodeBytes(out)?.layers.length, n,
          reason: 'round-trip must survive');
      expect(overheadPct, lessThan(15),
          reason: 'gzip must claw back the base64 expansion');
    }
  });
}
