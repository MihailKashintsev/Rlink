import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/motion_controller.dart';
import '../../utils/audio_waveform.dart';
import '../../utils/web_file_store.dart';

/// Telegram-style voice-message waveform: rounded vertical bars whose heights
/// follow the *real* decoded amplitude of the audio at [path] (cached per path;
/// falls back to a stable procedural envelope until decoded / where no decoder
/// exists). The played portion is drawn in [activeColor], the rest in
/// [inactiveColor]; while [animating] the bars breathe subtly near the playhead.
class VoiceWaveLine extends StatefulWidget {
  final String path;
  final double progress;
  final bool animating;
  final Color activeColor;
  final Color inactiveColor;
  final double strokeWidth; // used as the bar width

  const VoiceWaveLine({
    super.key,
    required this.path,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    this.animating = false,
    this.strokeWidth = 3.0,
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
    return _VoiceBars(
      seed: widget.path.hashCode,
      samples: _samples,
      progress: widget.progress,
      animating: widget.animating,
      activeColor: widget.activeColor,
      inactiveColor: widget.inactiveColor,
      barWidth: widget.strokeWidth,
    );
  }
}

class _VoiceBars extends StatefulWidget {
  final int seed;
  final List<double>? samples;
  final double progress;
  final bool animating;
  final Color activeColor;
  final Color inactiveColor;
  final double barWidth;

  const _VoiceBars({
    required this.seed,
    required this.samples,
    required this.progress,
    required this.animating,
    required this.activeColor,
    required this.inactiveColor,
    required this.barWidth,
  });

  @override
  State<_VoiceBars> createState() => _VoiceBarsState();
}

class _VoiceBarsState extends State<_VoiceBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    MotionController.instance.scale.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _VoiceBars old) {
    super.didUpdateWidget(old);
    if (old.animating != widget.animating) _sync();
  }

  void _sync() {
    final on = widget.animating && MotionController.instance.enabled;
    if (on) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      if (_ctrl.isAnimating) _ctrl.stop();
    }
  }

  @override
  void dispose() {
    MotionController.instance.scale.removeListener(_sync);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _VoiceBarsPainter(
          seed: widget.seed,
          samples: widget.samples,
          progress: widget.progress,
          phase: _ctrl.value * 2 * math.pi,
          breathing: widget.animating ? 1.0 : 0.0,
          activeColor: widget.activeColor,
          inactiveColor: widget.inactiveColor,
          barWidth: widget.barWidth,
        ),
      ),
    );
  }
}

class _VoiceBarsPainter extends CustomPainter {
  final int seed;
  final List<double>? samples;
  final double progress;
  final double phase;
  final double breathing;
  final Color activeColor;
  final Color inactiveColor;
  final double barWidth;

  const _VoiceBarsPainter({
    required this.seed,
    required this.samples,
    required this.progress,
    required this.phase,
    required this.breathing,
    required this.activeColor,
    required this.inactiveColor,
    required this.barWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final gap = math.max(1.6, barWidth * 0.7);
    final pitch = barWidth + gap;
    final barCount = math.max(1, (w / pitch).floor());

    // Build the amplitude envelope: resample real peaks to [barCount], or an
    // organic per-seed envelope when no real data is available.
    final env = _envelope(barCount);

    final radius = Radius.circular(barWidth / 2);
    final maxBarH = h * 0.92;
    final minBarH = math.max(barWidth, h * 0.16);
    final midY = h / 2;
    final splitX = progress.clamp(0.0, 1.0) * w;

    // Center the bar block horizontally.
    final totalW = barCount * barWidth + (barCount - 1) * gap;
    final startX = (w - totalW) / 2;

    final paint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.fill;

    for (var i = 0; i < barCount; i++) {
      var amp = env[i];
      // Subtle "breathing" near the playhead while playing (emil: barely-there).
      if (breathing > 0) {
        final t = barCount == 1 ? 0.0 : i / (barCount - 1);
        final near = 1.0 - (t - progress.clamp(0.0, 1.0)).abs();
        final pulse = math.sin(phase + i * 0.55) * 0.10 * near.clamp(0.0, 1.0);
        amp = (amp + pulse).clamp(0.06, 1.0);
      }
      final barH = lerpDouble(minBarH, maxBarH, amp)!;
      final x = startX + i * pitch;
      final cx = x + barWidth / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, midY - barH / 2, barWidth, barH),
        radius,
      );
      paint.color = cx <= splitX ? activeColor : inactiveColor;
      canvas.drawRRect(rect, paint);
    }
  }

  List<double> _envelope(int n) {
    final s = samples;
    if (s != null && s.isNotEmpty) {
      if (s.length == n) return s;
      return List<double>.generate(n, (i) {
        final f = n == 1 ? 0.0 : i / (n - 1) * (s.length - 1);
        final lo = f.floor().clamp(0, s.length - 1);
        final hi = math.min(lo + 1, s.length - 1);
        return lerpDouble(s[lo], s[hi], f - lo)!.clamp(0.0, 1.0);
      });
    }
    // Procedural fallback: stable per-seed pseudo-random envelope, smoothed.
    final rng = math.Random(seed == 0 ? 1 : seed);
    final raw = List<double>.generate(n, (_) => 0.25 + rng.nextDouble() * 0.75);
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final a = raw[(i - 1).clamp(0, n - 1)];
      final b = raw[i];
      final c = raw[(i + 1).clamp(0, n - 1)];
      out[i] = (a + b * 2 + c) / 4;
    }
    return out;
  }

  @override
  bool shouldRepaint(_VoiceBarsPainter old) =>
      old.progress != progress ||
      old.phase != phase ||
      old.breathing != breathing ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      old.barWidth != barWidth ||
      old.seed != seed ||
      !identical(old.samples, samples);
}
