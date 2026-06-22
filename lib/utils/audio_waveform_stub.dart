import 'dart:typed_data';

/// Native fallback — no Web Audio decoder. Callers fall back to a procedural
/// waveform when this returns null.
Future<List<double>?> decodeAudioPeaks(Uint8List bytes,
        {int buckets = 56}) async =>
    null;
