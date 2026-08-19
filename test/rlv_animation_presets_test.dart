import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/models/rlv_animation_presets.dart';
import 'package:rlink/models/rlv_sticker.dart';

void main() {
  const base = (x: 100.0, y: 100.0, sx: 1.0, sy: 1.0, rotDeg: 15.0, alpha: 0.8);

  void expectSortedAndFinite(List<RlvKeyframe> keys) {
    expect(keys, isNotEmpty);
    for (var i = 1; i < keys.length; i++) {
      expect(keys[i].tMs, greaterThanOrEqualTo(keys[i - 1].tMs));
    }
    for (final k in keys) {
      for (final v in [k.x, k.y, k.sx, k.sy, k.rotDeg, k.alpha]) {
        expect(v.isFinite, isTrue);
      }
    }
  }

  test('bounce: sorted, finite, apex is above base, lands back at base', () {
    final keys = bouncePreset(base, canvasSide: 512);
    expectSortedAndFinite(keys);
    final apex = keys.firstWhere((k) => k.tMs == 300);
    expect(apex.y, lessThan(base.y)); // "above" == smaller y in canvas space
    final last = keys.last;
    expect(last.x, base.x);
    expect(last.y, base.y);
    expect(last.sx, base.sx);
    expect(last.sy, base.sy);
  });

  test('pulse: peak scale is larger than base, returns to base', () {
    final keys = pulsePreset(base);
    expectSortedAndFinite(keys);
    final peak = keys.firstWhere((k) => k.tMs == 300);
    expect(peak.sx, greaterThan(base.sx));
    expect(peak.sy, greaterThan(base.sy));
    expect(keys.last.sx, base.sx);
    expect(keys.last.sy, base.sy);
  });

  test('spin: rotates a full 360 from base, position unchanged', () {
    final keys = spinPreset(base);
    expectSortedAndFinite(keys);
    expect(keys.first.rotDeg, base.rotDeg);
    expect(keys.last.rotDeg, base.rotDeg + 360);
    for (final k in keys) {
      expect(k.x, base.x);
      expect(k.y, base.y);
    }
  });

  test('wobble: oscillates around base.x and returns to it', () {
    final keys = wobblePreset(base, canvasSide: 512);
    expectSortedAndFinite(keys);
    expect(keys.first.x, base.x);
    expect(keys.last.x, base.x);
    expect(keys.any((k) => k.x < base.x), isTrue);
    expect(keys.any((k) => k.x > base.x), isTrue);
  });

  test('fadeIn: starts fully transparent, ends at base alpha', () {
    final keys = fadeInPreset(base, holdMs: 1000);
    expectSortedAndFinite(keys);
    expect(keys.first.alpha, 0);
    expect(keys.last.alpha, base.alpha);
  });

  test('fadeOut: starts at base alpha, ends fully transparent', () {
    final keys = fadeOutPreset(base, holdMs: 1000);
    expectSortedAndFinite(keys);
    expect(keys.first.alpha, base.alpha);
    expect(keys.last.alpha, 0);
  });

  test('fadeIn/fadeOut tolerate a short holdMs without inverted timestamps', () {
    expectSortedAndFinite(fadeInPreset(base, holdMs: 50));
    expectSortedAndFinite(fadeOutPreset(base, holdMs: 50));
  });

  test('slideIn: starts off-canvas to the left, ends exactly at base', () {
    final keys = slideInPreset(base, canvasSide: 512);
    expectSortedAndFinite(keys);
    expect(keys.first.x, lessThan(base.x));
    expect(keys.last.x, base.x);
    expect(keys.last.y, base.y);
  });
}
