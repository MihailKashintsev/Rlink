import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto_service.dart';
import 'relay_service.dart';

/// What Premium unlocks. Everything else in Rlink is free for everyone.
enum PremiumFeature {
  /// Custom nickname colour, visible to everyone you chat with.
  nickColor,

  /// More than [PremiumService.freeChannelLimit] channels.
  moreChannels,

  /// The no-code bot constructor.
  botBuilder,
}

/// Subscription state, owned by the relay.
///
/// The account is the long public key, so the subscription follows the user
/// across reinstalls and devices. The local copy is only a cache to keep the
/// UI usable offline — [refresh] re-reads the relay's answer, which is what
/// actually decides.
class PremiumService extends ChangeNotifier {
  PremiumService._();
  static final PremiumService instance = PremiumService._();

  static const _keyUntil = 'premium_active_until_ms';
  static const _keyPendingPayment = 'premium_pending_payment_id';

  /// Channels anyone can create without paying.
  static const int freeChannelLimit = 2;

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 15),
  ));

  DateTime? _activeUntil;

  DateTime? get activeUntil => _activeUntil;

  bool get isActive =>
      _activeUntil != null && _activeUntil!.isAfter(DateTime.now());

  bool has(PremiumFeature _) => isActive;

  /// Days left, 0 when there's no subscription.
  int get daysLeft {
    final u = _activeUntil;
    if (u == null) return 0;
    final d = u.difference(DateTime.now()).inDays;
    return d < 0 ? 0 : d + 1;
  }

  String _httpBase() {
    final url = RelayService.instance.serverUrl ?? RelayService.defaultServerUrl;
    if (url.startsWith('wss://')) return url.replaceFirst('wss://', 'https://');
    if (url.startsWith('ws://')) return url.replaceFirst('ws://', 'http://');
    return url;
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_keyUntil);
      if (ms != null) {
        _activeUntil = DateTime.fromMillisecondsSinceEpoch(ms);
        notifyListeners();
      }
    } catch (_) {}
    // A payment left mid-flight (app closed on the bank page) settles here.
    await settlePending();
    await refresh();
  }

  Future<void> _store(int untilMs) async {
    _activeUntil =
        untilMs > 0 ? DateTime.fromMillisecondsSinceEpoch(untilMs) : null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (untilMs > 0) {
        await prefs.setInt(_keyUntil, untilMs);
      } else {
        await prefs.remove(_keyUntil);
      }
    } catch (_) {}
  }

  /// Re-reads the subscription from the relay. Silently keeps the cached value
  /// when the relay can't be reached — going offline must not revoke Premium.
  Future<void> refresh() async {
    final id = CryptoService.instance.publicKeyHex;
    if (id.isEmpty) return;
    try {
      final resp = await _dio.get<dynamic>(
        '${_httpBase()}/premium/status',
        queryParameters: {'user_id': id},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        await _store((data['until_ms'] as num?)?.toInt() ?? 0);
      }
    } catch (_) {}
  }

  /// Starts a purchase. Returns the YooKassa payment page URL to open, or null
  /// when the relay can't create the payment (not configured, offline, …).
  ///
  /// [plan] is 'month' or 'year'; the price lives on the relay so it can't be
  /// tampered with here. [email] is optional and only used for the receipt.
  Future<String?> startPurchase(String plan, {String? email}) async {
    final id = CryptoService.instance.publicKeyHex;
    if (id.isEmpty) return null;
    try {
      final resp = await _dio.post<dynamic>(
        '${_httpBase()}/premium/create',
        data: {
          'user_id': id,
          'plan': plan,
          if (email != null && email.contains('@')) 'email': email,
        },
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        final paymentId = data['payment_id'] as String?;
        final url = data['confirmation_url'] as String?;
        if (paymentId != null && url != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_keyPendingPayment, paymentId);
          return url;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Asks the relay to settle the payment we're waiting on. The relay verifies
  /// it against YooKassa, so calling this can't grant anything on its own.
  /// Returns true once the subscription is active.
  Future<bool> settlePending() async {
    String? paymentId;
    try {
      final prefs = await SharedPreferences.getInstance();
      paymentId = prefs.getString(_keyPendingPayment);
    } catch (_) {}
    if (paymentId == null || paymentId.isEmpty) return false;
    try {
      final resp = await _dio.post<dynamic>(
        '${_httpBase()}/premium/check',
        data: {'payment_id': paymentId},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        final until = (data['until_ms'] as num?)?.toInt() ?? 0;
        if (until > DateTime.now().millisecondsSinceEpoch) {
          await _store(until);
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(_keyPendingPayment);
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// True while a started payment hasn't been confirmed yet.
  Future<bool> hasPendingPayment() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_keyPendingPayment);
      return id != null && id.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> clearPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyPendingPayment);
    } catch (_) {}
  }
}
