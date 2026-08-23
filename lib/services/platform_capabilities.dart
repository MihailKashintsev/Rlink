import 'runtime_platform.dart';

/// Platform feature gates used by UI/services to avoid hardcoded checks.
class PlatformCapabilities {
  PlatformCapabilities._();
  static final PlatformCapabilities instance = PlatformCapabilities._();

  // Only true where the native BLE method channel is actually implemented
  // (android/app/.../MainActivity.kt, ios/Runner/AppDelegate.swift,
  // macos/Runner/AppDelegate.swift) — Windows/Linux have no native BLE code
  // at all, so "Рядом"/"Эфир" must show the same disabled state as web there
  // instead of a radar with a dead backend.
  bool get supportsBleMesh =>
      RuntimePlatform.isAndroid || RuntimePlatform.isIos || RuntimePlatform.isDesktopMacos;
  bool get supportsWifiDirect => RuntimePlatform.isAndroid;
  bool get supportsNativeFilePaths => !RuntimePlatform.isWeb;
  bool get isWeb => RuntimePlatform.isWeb;
  bool get supportsBackgroundKeepAlive =>
      RuntimePlatform.isAndroid || RuntimePlatform.isDesktop;
  // Web has VAPID web push; Android keeps its socket alive via a foreground
  // service (see RlinkForegroundService.kt + DeliveryHealthWorker.kt) — no
  // Google/FCM involved, but background delivery is real. iOS has neither
  // APNs nor Firebase wired up (no google-services.json/GoogleService-Info,
  // no push entitlement) — claiming otherwise here was the actual bug.
  bool get supportsSystemPushInBackground =>
      RuntimePlatform.isWeb || RuntimePlatform.isAndroid;
}
