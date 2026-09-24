import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which quick videos ("кружки") have been watched WITH SOUND (played by the
/// user, not just the preview frame). Drives the dot next to the duration:
/// incoming — I haven't played it yet; outgoing — the recipient hasn't
/// (learned through a `qv_seen` receipt, see GossipRouter.sendQuickVideoSeen).
class QuickVideoSeenService extends ChangeNotifier {
  QuickVideoSeenService._();
  static final QuickVideoSeenService instance = QuickVideoSeenService._();

  static const _key = 'quick_video_seen_v1';
  static const _cap = 3000;

  final Set<String> _seen = <String>{}; // insertion-ordered
  bool _loaded = false;

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _seen.addAll(prefs.getStringList(_key) ?? const <String>[]);
      notifyListeners();
    } catch (_) {}
  }

  bool isSeen(String messageId) => _seen.contains(messageId);

  Future<void> markSeen(String messageId) async {
    if (messageId.isEmpty || !_seen.add(messageId)) return;
    while (_seen.length > _cap) {
      _seen.remove(_seen.first);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, _seen.toList());
    } catch (_) {}
  }
}
