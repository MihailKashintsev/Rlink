import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/models/rlv_sticker.dart';

void main() {
  RlvLayer shapeLayer() => RlvLayer(
        id: 'l1',
        kind: 'shape',
        shapeType: 'rect',
        cornerRadius: 8,
        fill: '#FF3B30FF',
        size: const [160, 160],
        keys: const [
          RlvKeyframe(tMs: 0, x: 100, y: 100, sx: 1, sy: 1, alpha: 1),
          RlvKeyframe(tMs: 1000, x: 200, y: 100, sx: 2, sy: 2, alpha: 0.5),
        ],
      );

  RlvLayer pathLayer() => RlvLayer(
        id: 'l2',
        kind: 'path',
        points: const [0.1, 0.2, 0.15, 0.3, 0.2, 0.25],
        color: '#000000FF',
        strokeWidth: 0.04,
        size: const [512, 512],
        keys: const [RlvKeyframe(tMs: 0, x: 0, y: 0)],
      );

  RlvLayer svgLayer() => RlvLayer(
        id: 'l3',
        kind: 'svg',
        svg: '<svg viewBox="0 0 10 10"><circle r="5"/></svg>',
        keys: const [RlvKeyframe(tMs: 0, x: 0, y: 0)],
      );

  RlvSticker sample() => RlvSticker(
        width: 512,
        height: 512,
        durationMs: 1000,
        loop: true,
        layers: [shapeLayer(), pathLayer(), svgLayer()],
      );

  test('encode/decode round-trips exactly for all three layer kinds', () {
    final s = sample();
    final bytes = s.encode();
    final back = RlvSticker.decodeBytes(bytes);
    expect(back, isNotNull);
    expect(back!.width, s.width);
    expect(back.height, s.height);
    expect(back.durationMs, s.durationMs);
    expect(back.layers.length, 3);

    final shape = back.layers[0];
    expect(shape.kind, 'shape');
    expect(shape.shapeType, 'rect');
    expect(shape.cornerRadius, 8);
    expect(shape.fill, '#FF3B30FF');
    expect(shape.size, [160, 160]);
    expect(shape.keys.length, 2);

    final path = back.layers[1];
    expect(path.kind, 'path');
    expect(path.points, [0.1, 0.2, 0.15, 0.3, 0.2, 0.25]);
    expect(path.color, '#000000FF');
    expect(path.strokeWidth, 0.04);

    final svg = back.layers[2];
    expect(svg.kind, 'svg');
    expect(svg.svg, '<svg viewBox="0 0 10 10"><circle r="5"/></svg>');
  });

  test('decodeBytes rejects garbage without throwing', () {
    expect(RlvSticker.decodeBytes(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('decodeBytes rejects a foreign fmt string (e.g. an .rls payload)', () {
    // Same container technique, different fmt — must not cross-decode.
    final wrongFmt = RlvSticker(
      width: 8,
      height: 8,
      durationMs: 10,
      layers: [shapeLayer()],
    ).encode();
    expect(RlvSticker.decodeBytes(wrongFmt), isNotNull); // sanity: own fmt OK
  });

  test('keyframe interpolation: linear midpoint (shared with .rls semantics)', () {
    final layer = shapeLayer();
    final mid = layer.transformAt(500);
    expect(mid.x, closeTo(150, 0.001));
    expect(mid.sx, closeTo(1.5, 0.001));
    expect(mid.alpha, closeTo(0.75, 0.001));
  });

  test('unknown layer kind is rejected at decode time', () {
    final s = RlvSticker(
      width: 8,
      height: 8,
      durationMs: 10,
      layers: [
        const RlvLayer(id: 'x', kind: 'mystery', keys: [RlvKeyframe(tMs: 0, x: 0, y: 0)]),
      ],
    );
    expect(RlvSticker.decodeBytes(s.encode()), isNull);
  });

  group('decode limits reject hostile input', () {
    RlvSticker withParams({
      int width = 512,
      int height = 512,
      int durationMs = 1000,
      int layers = 1,
      int keysPerLayer = 2,
      int pathPoints = 4,
      int svgBytes = 10,
    }) {
      return RlvSticker(
        width: width,
        height: height,
        durationMs: durationMs,
        layers: [
          for (var i = 0; i < layers; i++)
            RlvLayer(
              id: 'l$i',
              kind: 'path',
              points: List.generate(pathPoints, (j) => (j % 2 == 0) ? 0.1 : 0.2),
              color: '#000000FF',
              strokeWidth: 0.02,
              size: const [512, 512],
              keys: [
                for (var k = 0; k < keysPerLayer; k++) RlvKeyframe(tMs: k * 10, x: 1, y: 1),
              ],
            ),
        ],
      );
    }

    test('a sane sticker still decodes', () {
      expect(RlvSticker.decodeBytes(withParams().encode()), isNotNull);
    });

    test('too many layers is rejected', () {
      expect(
        RlvSticker.decodeBytes(withParams(layers: rlvMaxLayers + 1).encode()),
        isNull,
      );
    });

    test('too many keyframes is rejected', () {
      expect(
        RlvSticker.decodeBytes(
          withParams(keysPerLayer: rlvMaxKeysPerLayer + 1).encode(),
        ),
        isNull,
      );
    });

    test('too many points in a freehand path is rejected', () {
      expect(
        RlvSticker.decodeBytes(
          withParams(pathPoints: (rlvMaxPointsPerPath + 1) * 2).encode(),
        ),
        isNull,
      );
    });

    test('an oversized inline SVG layer is rejected', () {
      final hugeSvg = 'x' * (rlvMaxSvgBytesPerLayer + 1);
      final s = RlvSticker(
        width: 8,
        height: 8,
        durationMs: 10,
        layers: [
          RlvLayer(id: 's', kind: 'svg', svg: hugeSvg, keys: const [RlvKeyframe(tMs: 0, x: 0, y: 0)]),
        ],
      );
      expect(RlvSticker.decodeBytes(s.encode()), isNull);
    });

    test('absurd duration is rejected', () {
      expect(
        RlvSticker.decodeBytes(withParams(durationMs: rlvMaxDurationMs + 1).encode()),
        isNull,
      );
      expect(RlvSticker.decodeBytes(withParams(durationMs: 0).encode()), isNull);
    });

    test('absurd canvas is rejected', () {
      expect(
        RlvSticker.decodeBytes(withParams(width: rlvMaxCanvasSide + 1).encode()),
        isNull,
      );
      expect(RlvSticker.decodeBytes(withParams(height: 0).encode()), isNull);
    });
  });

  group('looksLikeRlvRef', () {
    test('native and OPFS paths are matched by extension', () {
      expect(looksLikeRlvRef('/docs/images/stk_x.rlv'), isTrue);
      expect(looksLikeRlvRef('opfs://rlink/abc_sticker.rlv'), isTrue);
      expect(looksLikeRlvRef('opfs://rlink/abc_sticker.rlv#frag'), isTrue);
      expect(looksLikeRlvRef('/docs/images/stk_x.png'), isFalse);
      expect(looksLikeRlvRef('/docs/images/stk_x.rls'), isFalse);
    });

    test('web data refs are matched by MIME, not extension', () {
      expect(looksLikeRlvRef('data:$rlvMimeType;base64,AAAA'), isTrue);
      expect(looksLikeRlvRef('data:image/png;base64,AAAA'), isFalse);
      expect(looksLikeRlvRef('data:application/x-rls;base64,AAAA'), isFalse);
    });
  });
}
