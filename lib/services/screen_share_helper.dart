import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Screen capture for calls. Shared by 1:1 [CallService] and the group mesh
/// [GroupCallService] so the platform quirks live in one place.
///
/// Android needs a `mediaProjection` foreground service running between the
/// user granting capture permission and the capture starting (Android 14+
/// throws otherwise) — see ScreenShareService.kt. iOS needs a broadcast
/// extension and is intentionally not supported.
class ScreenShareHelper {
  ScreenShareHelper._();

  static const _channel = MethodChannel('com.rendergames.rlink/call_ui');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get supported {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

  /// Returns the capture stream, or null if the user declined / it's
  /// unsupported. Throws only for unexpected failures.
  static Future<MediaStream?> start() async {
    if (!supported) return null;
    if (_isAndroid) {
      final granted = await Helper.requestCapturePermission();
      if (!granted) return null;
      final ok = await _channel.invokeMethod<bool>('startScreenShareService');
      if (ok != true) return null;
    }
    try {
      return await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
        'video': true,
        'audio': false,
      });
    } catch (e) {
      debugPrint('[RLINK][ScreenShare] getDisplayMedia failed: $e');
      if (_isAndroid) await _stopService();
      return null;
    }
  }

  static Future<void> stop(MediaStream? stream) async {
    if (stream != null) {
      for (final t in stream.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await stream.dispose();
      } catch (_) {}
    }
    if (_isAndroid) await _stopService();
  }

  static Future<void> _stopService() async {
    try {
      await _channel.invokeMethod('stopScreenShareService');
    } catch (_) {}
  }
}
