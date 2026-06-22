import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// One shared AudioContext — browsers cap the number of contexts (~6), so we
// must not create one per voice message. decodeAudioData works on a suspended
// context (no user gesture needed).
web.AudioContext? _ctx;
web.AudioContext _context() => _ctx ??= web.AudioContext();

/// Decode [bytes] into [buckets] normalised RMS peaks via the Web Audio API.
Future<List<double>?> decodeAudioPeaks(Uint8List bytes,
    {int buckets = 56}) async {
  if (bytes.isEmpty || buckets <= 0) return null;
  try {
    // Copy into a fresh buffer — decodeAudioData detaches the ArrayBuffer.
    final copy = Uint8List.fromList(bytes);
    final audio = await _context().decodeAudioData(copy.buffer.toJS).toDart;
    final channels = audio.numberOfChannels;
    if (channels <= 0) return null;
    final data = audio.getChannelData(0).toDart; // Float32List
    final n = data.length;
    if (n == 0) return null;

    final out = List<double>.filled(buckets, 0.0);
    final per = (n / buckets).ceil().clamp(1, n);
    var maxPeak = 0.0;
    for (var b = 0; b < buckets; b++) {
      final start = b * per;
      if (start >= n) break;
      final end = math.min(start + per, n);
      var sumSq = 0.0;
      var cnt = 0;
      for (var i = start; i < end; i++) {
        final v = data[i];
        sumSq += v * v;
        cnt++;
      }
      final rms = cnt > 0 ? math.sqrt(sumSq / cnt) : 0.0;
      out[b] = rms;
      if (rms > maxPeak) maxPeak = rms;
    }
    if (maxPeak <= 0) return null;
    for (var i = 0; i < buckets; i++) {
      // Normalise + a mild curve so quiet speech is still visible.
      out[i] = math.pow((out[i] / maxPeak).clamp(0.0, 1.0), 0.7).toDouble();
    }
    return out;
  } catch (_) {
    return null;
  }
}
