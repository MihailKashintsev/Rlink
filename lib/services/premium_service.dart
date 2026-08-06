import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What Premium unlocks. Everything else in Rlink is free for everyone.
enum PremiumFeature {
  /// Custom nickname colour, visible to everyone you chat with.
  nickColor,

  /// More than [PremiumService.freeChannelLimit] channels.
  moreChannels,

  /// The no-code bot constructor.
  botBuilder,
}

/// Local Premium state.
///
/// Deliberately client-side for now: the paid flow (YooKassa → relay webhook →
/// server-side entitlement) isn't built yet, so this only gates the UI and
/// must NOT be treated as an anti-piracy measure. When the relay learns to
/// confirm payments, [isActive] should read the server's answer instead.
class PremiumService extends ChangeNotifier {
  PremiumService._();
  static final PremiumService instance = PremiumService._();

  static const _keyUntil = 'premium_active_until_ms';

  /// Channels anyone can create without paying.
  static const int freeChannelLimit = 2;

  DateTime? _activeUntil;

  DateTime? get activeUntil => _activeUntil;

  bool get isActive =>
      _activeUntil != null && _activeUntil!.isAfter(DateTime.now());

  bool has(PremiumFeature _) => isActive;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_keyUntil);
      if (ms != null) {
        _activeUntil = DateTime.fromMillisecondsSinceEpoch(ms);
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Grant/extend the subscription. Called after a confirmed payment (and by
  /// the debug switch until payments exist).
  Future<void> activateUntil(DateTime until) async {
    _activeUntil = until;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyUntil, until.millisecondsSinceEpoch);
    } catch (_) {}
  }

  Future<void> deactivate() async {
    _activeUntil = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyUntil);
    } catch (_) {}
  }
}
