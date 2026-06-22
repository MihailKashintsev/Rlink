import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../utils/audio_waveform.dart';
import '../../utils/web_file_store.dart';
import 'wave_line.dart';

/// [WaveLine] whose shape is the *real* waveform of the audio at [path].
/// It decodes the audio to amplitude peaks once (cached per path) and renders
/// the actual sound; until decoded (or on platforms without a decoder) it
/// falls back to the procedural wave keyed by the path.
class VoiceWaveLine extends StatefulWidget {
  final String path;
  final double progress;
  final bool animating;
  final Color activeColor;
  final Color inactiveColor;
  final double strokeWidth;

  const VoiceWaveLine({
    super.key,
    required this.path,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    this.animating = false,
    this.strokeWidth = 2.4,
  });

  @override
  State<VoiceWaveLine> createState() => _VoiceWaveLineState();
}

class _VoiceWaveLineState extends State<VoiceWaveLine> {
  // Cache decoded peaks across rebuilds and across all bubbles.
  static final Map<String, List<double>> _cache = {};
  static final Set<String> _inFlight = {};

  List<double>? _samples;

  @override
  void initState() {
    super.initState();
    _samples = _cache[widget.path];
    if (_samples == null) _load();
  }

  @override
  void didUpdateWidget(covariant VoiceWaveLine old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _samples = _cache[widget.path];
      if (_samples == null) _load();
    }
  }

  Future<void> _load() async {
    if (!kIsWeb) return; // decoder only available on web
    final path = widget.path;
    if (_inFlight.contains(path)) return;
    _inFlight.add(path);
    try {
      final bytes = await _readBytes(path);
      if (bytes == null || bytes.isEmpty) return;
      final peaks = await decodeAudioPeaks(bytes);
      if (peaks != null && peaks.isNotEmpty) {
        _cache[path] = peaks;
        if (mounted && widget.path == path) setState(() => _samples = peaks);
      }
    } catch (_) {
      // Ignore — falls back to the procedural wave.
    } finally {
      _inFlight.remove(path);
    }
  }

  Future<Uint8List?> _readBytes(String path) async {
    if (isWebStoredFile(path)) return readWebStoredFile(path);
    if (path.startsWith('data:')) {
      final comma = path.indexOf(',');
      if (comma < 0) return null;
      final meta = path.substring(0, comma);
      final data = path.substring(comma + 1);
      if (meta.contains(';base64')) {
        return base64Decode(Uri.decodeFull(data));
      }
      return Uint8List.fromList(utf8.encode(Uri.decodeFull(data)));
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return WaveLine(
      seed: widget.path.hashCode,
      samples: _samples,
      progress: widget.progress,
      animating: widget.animating,
      activeColor: widget.activeColor,
      inactiveColor: widget.inactiveColor,
      strokeWidth: widget.strokeWidth,
    );
  }
}
