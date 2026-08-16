import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/models/rls_sticker.dart';

void main() {
  // A minimal 1x1 PNG so encode/decode exercises real bytes, not empty ones.
  final onePxPng = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, //
    0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, //
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
    0x42, 0x60, 0x82, //
  ]);

  RlsSticker sample() => RlsSticker(
        width: 512,
        height: 512,
        durationMs: 1000,
        loop: true,
        assets: {'a1': onePxPng},
        layers: [
          RlsLayer(
            id: 'l1',
            assetId: 'a1',
            keys: const [
              RlsKeyframe(tMs: 0, x: 100, y: 100, sx: 1, sy: 1, alpha: 1),
              RlsKeyframe(tMs: 1000, x: 200, y: 100, sx: 2, sy: 2, alpha: 0.5),
            ],
          ),
        ],
      );

  test('encode/decode round-trips exactly', () {
    final s = sample();
    final bytes = s.encode();
    final back = RlsSticker.decodeBytes(bytes);
    expect(back, isNotNull);
    expect(back!.width, s.width);
    expect(back.height, s.height);
    expect(back.durationMs, s.durationMs);
    expect(back.assets['a1'], onePxPng);
    expect(back.layers.single.keys.length, 2);
  });

  test('gzip actually shrinks a repetitive payload', () {
    // Ten identical layers referencing the same asset — the point of the
    // shared asset table is that this does NOT multiply the PNG bytes.
    final layers = List.generate(
      10,
      (i) => RlsLayer(
        id: 'l$i',
        assetId: 'a1',
        keys: const [
          RlsKeyframe(tMs: 0, x: 0, y: 0),
          RlsKeyframe(tMs: 1000, x: 10, y: 10),
        ],
      ),
    );
    final s = RlsSticker(
      width: 512,
      height: 512,
      durationMs: 1000,
      assets: {'a1': onePxPng},
      layers: layers,
    );
    final bytes = s.encode();
    // Sanity: still round-trips with all 10 layers, and the encoded size is
    // nowhere near 10x the raw PNG (proving assets are stored once, not per
    // layer, and gzip is doing real work on the repeated keyframe shape).
    final back = RlsSticker.decodeBytes(bytes)!;
    expect(back.layers.length, 10);
    expect(bytes.length, lessThan(onePxPng.length * 10));
  });

  test('decodeBytes rejects garbage without throwing', () {
    expect(RlsSticker.decodeBytes(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('keyframe interpolation: linear midpoint', () {
    final layer = sample().layers.single;
    final mid = layer.transformAt(500);
    expect(mid.x, closeTo(150, 0.001)); // 100 -> 200
    expect(mid.sx, closeTo(1.5, 0.001)); // 1 -> 2
    expect(mid.alpha, closeTo(0.75, 0.001)); // 1 -> 0.5
  });

  test('keyframe interpolation: holds before first / after last key', () {
    final layer = sample().layers.single;
    expect(layer.transformAt(-100).x, 100);
    expect(layer.transformAt(5000).x, 200);
  });

  test('outBack easing overshoots past 1 before settling', () {
    final layer = RlsLayer(
      id: 'l',
      assetId: 'a1',
      defaultEase: 'outBack',
      keys: const [
        RlsKeyframe(tMs: 0, x: 0, y: 0, sx: 1),
        RlsKeyframe(tMs: 1000, x: 0, y: 0, sx: 2),
      ],
    );
    // outBack overshoots the target before t=1 for some portion of the curve.
    final sx = layer.transformAt(850).sx;
    expect(sx, greaterThan(2.0));
  });
  group('decode limits reject hostile input', () {
    Uint8List encodeWith({
      int width = 512,
      int height = 512,
      int durationMs = 1000,
      int layers = 1,
      int keysPerLayer = 2,
    }) {
      return RlsSticker(
        width: width,
        height: height,
        durationMs: durationMs,
        assets: {'a': Uint8List.fromList([1, 2, 3])},
        layers: [
          for (var i = 0; i < layers; i++)
            RlsLayer(
              id: 'l$i',
              assetId: 'a',
              keys: [
                for (var k = 0; k < keysPerLayer; k++)
                  RlsKeyframe(tMs: k * 10, x: 1, y: 1),
              ],
            ),
        ],
      ).encode();
    }

    test('a sane sticker still decodes', () {
      expect(RlsSticker.decodeBytes(encodeWith()), isNotNull);
    });

    test('too many layers is rejected', () {
      expect(RlsSticker.decodeBytes(encodeWith(layers: rlsMaxLayers + 1)),
          isNull);
    });

    test('too many keyframes is rejected', () {
      expect(
          RlsSticker.decodeBytes(
              encodeWith(keysPerLayer: rlsMaxKeysPerLayer + 1)),
          isNull);
    });

    test('absurd duration is rejected', () {
      expect(
          RlsSticker.decodeBytes(encodeWith(durationMs: rlsMaxDurationMs + 1)),
          isNull);
      expect(RlsSticker.decodeBytes(encodeWith(durationMs: 0)), isNull);
    });

    test('absurd canvas is rejected', () {
      expect(
          RlsSticker.decodeBytes(encodeWith(width: rlsMaxCanvasSide + 1)),
          isNull);
      expect(RlsSticker.decodeBytes(encodeWith(height: 0)), isNull);
    });
  });

  group('looksLikeRlsRef', () {
    test('native and OPFS paths are matched by extension', () {
      expect(looksLikeRlsRef('/docs/images/stk_x.rls'), isTrue);
      expect(looksLikeRlsRef('opfs://rlink/abc_sticker.rls'), isTrue);
      expect(looksLikeRlsRef('opfs://rlink/abc_sticker.rls#frag'), isTrue);
      expect(looksLikeRlsRef('/docs/images/stk_x.png'), isFalse);
    });

    test('web data refs are matched by MIME, not extension', () {
      expect(looksLikeRlsRef('data:$rlsMimeType;base64,AAAA'), isTrue);
      expect(looksLikeRlsRef('data:image/png;base64,AAAA'), isFalse);
      // The old octet-stream form must NOT be treated as a sticker.
      expect(
          looksLikeRlsRef('data:application/octet-stream;base64,AAAA'), isFalse);
    });
  });

}
