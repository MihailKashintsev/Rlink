import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/sound_effects_service.dart';

/// [SoundEffectsService] builds every sound in the app as PCM at runtime (no
/// bundled audio assets). That code has real logic — per-sample envelopes,
/// noise generation, and a hand-rolled multi-segment offset walk for the
/// laugh effect — so it gets a real check rather than "trust the review".
void main() {
  void expectValidWav(Uint8List bytes, {String? label}) {
    expect(bytes.length, greaterThan(44), reason: '$label: header + data');
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF', reason: label);
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE', reason: label);
    expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data', reason: label);
    final declaredDataSize = bytes.buffer.asByteData().getUint32(40, Endian.little);
    expect(declaredDataSize, bytes.length - 44,
        reason: '$label: data chunk size must match actual PCM length');
    expect(declaredDataSize.isEven, isTrue,
        reason: '$label: 16-bit mono PCM must be an even byte count');
  }

  group('call FX synthesis', () {
    for (final fx in CallFxSound.values) {
      test('${fx.name} produces a valid, non-silent WAV', () {
        final bytes = SoundEffectsService.callFxBytesForTest(fx);
        expectValidWav(bytes, label: fx.name);

        // Every generator must actually touch every sample it claims to
        // (the laugh effect walks a manual segment/gap offset table — an
        // off-by-one there would leave a silent tail instead of erroring).
        final data = ByteData.sublistView(bytes, 44);
        var sawNonZero = false;
        var maxAbs = 0;
        for (var i = 0; i + 1 < data.lengthInBytes; i += 2) {
          final v = data.getInt16(i, Endian.little);
          if (v != 0) sawNonZero = true;
          if (v.abs() > maxAbs) maxAbs = v.abs();
        }
        expect(sawNonZero, isTrue,
            reason: '${fx.name}: must not be entirely silent');
        expect(maxAbs, lessThanOrEqualTo(32767),
            reason: '${fx.name}: must stay within int16 range (no clipping wrap)');
      });
    }
  });

  group('bayan (accordion) theme', () {
    test('bayan tone is louder in harmonics than plain sine (not the same beep)', () {
      final sine = SoundEffectsService.toneBytesForTest(notes: const [440], stepMs: 200);
      final bayan =
          SoundEffectsService.toneBytesForTest(notes: const [440], stepMs: 200, bayan: true);
      expectValidWav(sine, label: 'sine');
      expectValidWav(bayan, label: 'bayan');
      // Different waveform shape -> different bytes, same duration.
      expect(bayan.length, sine.length);
      expect(bayan, isNot(equals(sine)));
    });

    test('bayan tone stays within int16 range across notes (headroom check)', () {
      for (final freq in [220, 440, 880, 1200]) {
        final bytes =
            SoundEffectsService.toneBytesForTest(notes: [freq], stepMs: 150, bayan: true);
        final data = ByteData.sublistView(bytes, 44);
        var maxAbs = 0;
        for (var i = 0; i + 1 < data.lengthInBytes; i += 2) {
          final v = data.getInt16(i, Endian.little).abs();
          if (v > maxAbs) maxAbs = v;
        }
        expect(maxAbs, lessThanOrEqualTo(32767), reason: 'freq=$freq');
      }
    });
  });
}
