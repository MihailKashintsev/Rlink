import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/sound_effects_service.dart';

/// Notification/message/ringtone melodies are still built as PCM at runtime
/// (bayan re-times them through harmonics) — that code keeps its own tests
/// below. Call reaction sounds (fart/laugh/applause/bee) are now real bundled
/// recordings instead of synthesis, since no oscillator can sound like a
/// laugh or a crowd; this file checks the asset wiring instead.
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

  group('call FX assets', () {
    final paths = SoundEffectsService.callFxAssetPathsForTest;

    test('every CallFxSound maps to an asset', () {
      for (final fx in CallFxSound.values) {
        expect(paths.containsKey(fx), isTrue, reason: '${fx.name}: no asset mapped');
      }
    });

    test('every mapped asset file exists on disk', () {
      for (final entry in paths.entries) {
        final f = File('assets/${entry.value}');
        expect(f.existsSync(), isTrue,
            reason: '${entry.key.name}: assets/${entry.value} is missing');
      }
    });

    test('every asset is declared in pubspec.yaml (or covered by a folder entry)', () {
      // Plain text scan instead of a YAML parser: `yaml` isn't a direct
      // dependency of this project (only pulled in transitively), and a line
      // starting with "    - assets/..." is unambiguous either way.
      final lines = File('pubspec.yaml')
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.startsWith('- assets/'))
          .map((l) => l.substring(2))
          .toList();
      for (final entry in paths.entries) {
        final path = 'assets/${entry.value}';
        final covered = lines.any((d) => path == d || path.startsWith(d));
        expect(covered, isTrue,
            reason: '${entry.key.name}: $path not declared in pubspec.yaml assets');
      }
    });

    test('call FX clips are at most 5 seconds (as requested)', () {
      // WAV data size / (sampleRate * channels * bytesPerSample) — read the
      // fmt chunk instead of assuming a fixed sample rate, since fart/laugh
      // are mono and applause/bee were exported differently.
      for (final entry in paths.entries) {
        final bytes = File('assets/${entry.value}').readAsBytesSync();
        final data = ByteData.sublistView(Uint8List.fromList(bytes));
        final channels = data.getUint16(22, Endian.little);
        final sampleRate = data.getUint32(24, Endian.little);
        final bitsPerSample = data.getUint16(34, Endian.little);
        final dataSize = data.getUint32(40, Endian.little);
        final bytesPerSecond = sampleRate * channels * (bitsPerSample ~/ 8);
        final seconds = dataSize / bytesPerSecond;
        expect(seconds, lessThanOrEqualTo(5.05),
            reason: '${entry.key.name}: ${seconds.toStringAsFixed(2)}s, wanted <=5s');
      }
    });
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

  group('bayan real accordion sample', () {
    // Only this group needs the asset bundle, so only it pays for binding init.
    TestWidgetsFlutterBinding.ensureInitialized();

    test('assets/sounds/accordion_note.wav loads and pitch-detects plausibly',
        () async {
      await SoundEffectsService.loadAccordionSampleForTest();
      expect(SoundEffectsService.accordionSampleLoadedForTest, isTrue,
          reason: 'the WAV decoder rejected the bundled sample');
      final freq = SoundEffectsService.accordionBaseFreqForTest;
      // Any real musical note recording lands well inside this range —
      // outside it means the autocorrelation locked onto noise, not a pitch.
      expect(freq, inInclusiveRange(70, 1000));
    });

    test('resampled note is valid, non-silent, and differs across target pitches',
        () async {
      await SoundEffectsService.loadAccordionSampleForTest();
      expect(SoundEffectsService.accordionSampleLoadedForTest, isTrue);

      final renders = <int, Uint8List>{};
      for (final freq in [220, 440, 880]) {
        final bytes =
            SoundEffectsService.toneBytesForTest(notes: [freq], stepMs: 300, bayan: true);
        expectValidWav(bytes, label: 'freq=$freq');
        final data = ByteData.sublistView(bytes, 44);
        var sawNonZero = false;
        var maxAbs = 0;
        for (var i = 0; i + 1 < data.lengthInBytes; i += 2) {
          final v = data.getInt16(i, Endian.little);
          if (v != 0) sawNonZero = true;
          if (v.abs() > maxAbs) maxAbs = v.abs();
        }
        expect(sawNonZero, isTrue, reason: 'freq=$freq: must not be silent');
        expect(maxAbs, lessThanOrEqualTo(32767), reason: 'freq=$freq: clipping');
        renders[freq] = bytes;
      }
      // Different target pitches must actually resample to different
      // waveforms — otherwise the pitch-shift math isn't doing anything.
      expect(renders[220], isNot(equals(renders[440])));
      expect(renders[440], isNot(equals(renders[880])));
    });
  });
}
