import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

import 'app_settings.dart';

/// Computes the effective animation intensity (0.0 = off … 1.0 = full) from the
/// user's chosen level plus battery-saver rules. Widgets read [scale] to decide
/// whether/how strongly to animate. Battery access is best-effort (the Web
/// Battery API is unavailable in Safari/Firefox — we just skip reduction there).
class MotionController {
  MotionController._();
  static final MotionController instance = MotionController._();

  final Battery _battery = Battery();
  int _level = 100; // percent
  bool _charging = true; // assume charging until known (avoids false throttling)
  bool _started = false;

  StreamSubscription<BatteryState>? _stateSub;
  Timer? _levelTimer;

  /// Effective animation intensity, 0..1. UI listens to this.
  final ValueNotifier<double> scale = ValueNotifier<double>(1.0);

  bool get enabled => scale.value > 0.02;

  /// Scale a duration by intensity (shorter when reduced, zero when off).
  Duration duration(Duration full) {
    final s = scale.value;
    if (s <= 0.02) return Duration.zero;
    if (s >= 0.99) return full;
    return Duration(milliseconds: (full.inMilliseconds * s).round());
  }

  Future<void> init() async {
    if (_started) return;
    _started = true;
    AppSettings.instance.addListener(_recompute);
    try {
      _level = await _battery.batteryLevel;
      final st = await _battery.batteryState;
      _charging = st == BatteryState.charging || st == BatteryState.full;
      _stateSub = _battery.onBatteryStateChanged.listen((st) {
        _charging = st == BatteryState.charging || st == BatteryState.full;
        unawaited(_refreshLevel());
      });
      // battery_plus doesn't push level changes — poll occasionally.
      _levelTimer = Timer.periodic(
          const Duration(minutes: 2), (_) => unawaited(_refreshLevel()));
    } catch (_) {
      // Battery API unavailable (e.g. web Safari/Firefox) — no throttling.
      _level = 100;
      _charging = true;
    }
    _recompute();
  }

  Future<void> _refreshLevel() async {
    try {
      _level = await _battery.batteryLevel;
    } catch (_) {}
    _recompute();
  }

  void _recompute() {
    final s = AppSettings.instance;
    var v = s.animationLevel.clamp(0.0, 1.0);
    if (s.batterySaverAnimations && !_charging) {
      if (_level <= s.batteryAnimOffAt) {
        v = 0.0; // critical battery → all animations off
      } else if (_level <= s.batteryAnimReduceAt) {
        v = (v * 0.4).clamp(0.0, 0.4); // low battery → reduced
      }
    }
    if ((scale.value - v).abs() > 0.001) scale.value = v;
  }

  void dispose() {
    _stateSub?.cancel();
    _levelTimer?.cancel();
    AppSettings.instance.removeListener(_recompute);
  }
}
