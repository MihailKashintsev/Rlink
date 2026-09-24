import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Tracks whether the OS reports an active VPN (connectivity_plus reports it on
/// Android/iOS; elsewhere it simply stays false). Used for a small heads-up
/// banner: calls, relay and Drive sync can misbehave behind a VPN.
class VpnStatusService {
  VpnStatusService._();
  static final VpnStatusService instance = VpnStatusService._();

  final ValueNotifier<bool> active = ValueNotifier(false);
  StreamSubscription<List<ConnectivityResult>>? _sub;

  Future<void> start() async {
    if (kIsWeb || _sub != null) return;
    try {
      _apply(await Connectivity().checkConnectivity());
      _sub = Connectivity().onConnectivityChanged.listen(_apply);
    } catch (_) {/* no connectivity plugin on this platform */}
  }

  void _apply(List<ConnectivityResult> results) {
    active.value = results.contains(ConnectivityResult.vpn);
  }
}
