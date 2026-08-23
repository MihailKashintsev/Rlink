import 'package:flutter/services.dart';

import 'runtime_platform.dart';

/// Android-only bridge to native delivery-health signals: whether the app is
/// exempt from battery optimization, the OEM's undocumented autostart screen,
/// and [RlinkForegroundService]'s persisted running state. Backs the
/// delivery-diagnostics screen and the one-shot exemption prompt — see
/// `android/app/src/main/kotlin/.../MainActivity.kt`'s DELIVERY_HEALTH_CHANNEL
/// handler for the native side.
class DeliveryHealthService {
  DeliveryHealthService._();
  static final DeliveryHealthService instance = DeliveryHealthService._();

  static const _channel = MethodChannel('com.rendergames.rlink/delivery_health');

  bool get isSupported => RuntimePlatform.isAndroid;

  Future<String> manufacturer() async {
    if (!isSupported) return '';
    try {
      return (await _channel.invokeMethod<String>('manufacturer')) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!isSupported) return true;
    try {
      return (await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system dialog to request exemption. Returns false if the
  /// dialog itself couldn't be shown (some OEMs block the intent) — the
  /// native side falls back to the app's own settings page in that case.
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!isSupported) return false;
    try {
      return (await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort deep link into the OEM's autostart/protected-apps screen.
  /// Returns true if an OEM-specific screen was found; false means it fell
  /// back to the app's generic settings page (still opened, just not the
  /// exact right one — the caller should tell the user what to look for).
  Future<bool> openAutostartSettings() async {
    if (!isSupported) return false;
    try {
      return (await _channel.invokeMethod<bool>('openAutostartSettings')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isForegroundServiceRunning() async {
    if (!isSupported) return false;
    try {
      return (await _channel.invokeMethod<bool>('isForegroundServiceRunning')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 0 if the service has never started this install.
  Future<int> foregroundServiceLastStartedAtMs() async {
    if (!isSupported) return 0;
    try {
      return (await _channel.invokeMethod<int>('foregroundServiceLastStartedAtMs')) ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
