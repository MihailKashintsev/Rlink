import 'dart:typed_data';

import 'audio_waveform_stub.dart'
    if (dart.library.html) 'audio_waveform_web.dart' as impl;

/// Decode compressed audio [bytes] into [buckets] normalised (0..1) amplitude
/// peaks — the real waveform of the sound. Returns null when decoding isn't
/// available (native) or the audio can't be decoded.
Future<List<double>?> decodeAudioPeaks(Uint8List bytes, {int buckets = 56}) =>
    impl.decodeAudioPeaks(bytes, buckets: buckets);
