import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'runtime_platform.dart';

class CallProximityService {
  CallProximityService._() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static final CallProximityService instance = CallProximityService._();

  static const MethodChannel _channel =
      MethodChannel('com.rendergames.rlink/proximity');

  final ValueNotifier<bool> isNear = ValueNotifier<bool>(false);
  bool _active = false;

  bool get active => _active;

  Future<void> setEnabled(bool enabled) async {
    if (RuntimePlatform.isWeb || RuntimePlatform.isDesktop) {
      isNear.value = false;
      _active = false;
      return;
    }
    if (_active == enabled) return;
    _active = enabled;
    try {
      await _channel.invokeMethod<void>(enabled ? 'start' : 'stop');
    } catch (e) {
      debugPrint('[CallProximity] ${enabled ? 'start' : 'stop'} failed: $e');
      _active = false;
      isNear.value = false;
    }
  }

  Future<void> stop() => setEnabled(false);

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onProximityChanged') return null;
    final near = call.arguments == true;
    if (isNear.value != near) {
      isNear.value = near;
    }
    return null;
  }
}
