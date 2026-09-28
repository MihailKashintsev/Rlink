import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges to native iOS CallKit (CXProvider) so an incoming Rlink call shows
/// the real system incoming-call screen (native ring UI + ringtone, Accept/
/// Decline) instead of a generic notification. No-op on every other
/// platform — Android already has its own dedicated call notification.
class CallKitService {
  CallKitService._();
  static final CallKitService instance = CallKitService._();

  static const _channel = MethodChannel('com.rendergames.rlink/callkit');

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Fired when the user answers via the native CallKit screen.
  void Function(String callId)? onAnswered;

  /// Fired when the user declines via CallKit, or ends an active call from
  /// the system call UI (lock screen / status bar).
  void Function(String callId)? onEnded;

  bool _initialized = false;
  void init() {
    if (!_supported || _initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      final args =
          (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
      final callId = args['callId'] as String? ?? '';
      switch (call.method) {
        case 'callAnswered':
          onAnswered?.call(callId);
          break;
        case 'callEnded':
          onEnded?.call(callId);
          break;
      }
      return null;
    });
  }

  Future<void> reportIncomingCall({
    required String callId,
    required String handle,
    required bool hasVideo,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('reportIncomingCall', {
        'callId': callId,
        'handle': handle,
        'hasVideo': hasVideo,
      });
    } catch (_) {}
  }

  /// Reports an app-initiated outgoing call so CallKit manages the audio
  /// session for the caller side too (the same didActivate/didDeactivate
  /// bridge the callee gets via [reportIncomingCall]) instead of leaving it
  /// entirely to WebRTC's own auto-activation.
  Future<void> reportOutgoingCall({
    required String callId,
    required String handle,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('reportOutgoingCall', {
        'callId': callId,
        'handle': handle,
      });
    } catch (_) {}
  }

  Future<void> reportOutgoingCallConnected(String callId) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('reportOutgoingCallConnected', {
        'callId': callId,
      });
    } catch (_) {}
  }

  Future<void> endCall(String callId) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('endCall', {'callId': callId});
    } catch (_) {}
  }
}
