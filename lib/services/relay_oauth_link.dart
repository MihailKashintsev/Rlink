import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_l10n.dart';

/// Durable OAuth account linking against the relay's own `/oauth/<provider>/*`
/// backend (see relay_server/bin/oauth.dart) — the relay holds the refresh
/// token and hands out short-lived access tokens, so linking survives app
/// reinstalls and works on platforms (iOS PWA) that can't hold a refresh
/// token client-side. Shared by every non-Google provider; Google Drive
/// keeps its own longer-lived implementation in google_drive_channel_backup.dart
/// (it also supports native GoogleSignIn + a manual-token-paste fallback that
/// don't apply here) rather than being rewired onto this — same wire
/// protocol, not worth the churn on a working path.
class RelayOauthLink {
  RelayOauthLink(this.providerId);

  /// 'onedrive' | 'dropbox' — must match a key in relay_server's provider
  /// table.
  final String providerId;

  static const String relayOauthBase = 'https://185.244.172.90.nip.io';

  final List<Map<String, String>> _accounts = [];
  String? _activePairing;
  String? _pendingPairing;
  final Map<String, ({String token, DateTime expiry})> _tokenCache = {};
  String? _lastError;

  String? get lastError => _lastError;
  bool get hasAccount => _activePairing != null && _accounts.isNotEmpty;
  String? get activeEmail => _accountFor(_activePairing)?['email'];
  String? get activePairing => _activePairing;
  List<Map<String, String>> get accounts =>
      _accounts.map((a) => Map<String, String>.from(a)).toList();

  Map<String, String>? _accountFor(String? pairing) {
    if (pairing == null) return null;
    for (final a in _accounts) {
      if (a['pairing'] == pairing) return a;
    }
    return null;
  }

  String _randomToken() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(20, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Begin a durable link: returns the consent URL to open in a browser.
  String startLink() {
    final pairing = 'rl_${DateTime.now().millisecondsSinceEpoch}_${_randomToken()}';
    _pendingPairing = pairing;
    return '$relayOauthBase/oauth/$providerId/start?p=${Uri.encodeQueryComponent(pairing)}';
  }

  /// After the user consents in the browser, confirm the link by polling the
  /// relay for a token. On success the account is added and made active.
  Future<bool> finishLink() async {
    final pairing = _pendingPairing;
    if (pairing == null || pairing.isEmpty) {
      _lastError = AppL10n.t('Сначала откройте вход');
      return false;
    }
    final res = await _fetchToken(pairing);
    if (res == null) {
      _lastError = AppL10n.t('Вход ещё не подтверждён. Завершите его в браузере.');
      return false;
    }
    final email = res.email;
    if (email.isNotEmpty) {
      _accounts.removeWhere((a) => a['email'] == email);
    }
    _accounts.add({'pairing': pairing, 'email': email});
    _activePairing = pairing;
    _pendingPairing = null;
    await _persist();
    return true;
  }

  Future<({String token, DateTime expiry, String email})?> _fetchToken(
      String pairing) async {
    try {
      final uri = Uri.parse(
          '$relayOauthBase/oauth/$providerId/token?p=${Uri.encodeQueryComponent(pairing)}');
      final resp = await http.get(uri).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      if (m['ok'] != true) return null;
      final token = m['access_token'] as String?;
      if (token == null || token.isEmpty) return null;
      final expiryMs = (m['expiry_ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch + 3000 * 1000;
      final expiry = DateTime.fromMillisecondsSinceEpoch(expiryMs, isUtc: true);
      _tokenCache[pairing] = (token: token, expiry: expiry);
      return (token: token, expiry: expiry, email: m['email'] as String? ?? '');
    } catch (e) {
      debugPrint('[RLINK][$providerId] relay token fetch failed: $e');
      return null;
    }
  }

  /// A valid bearer token for [pairing] (or the active account), refreshing
  /// via the relay as needed.
  Future<String?> accessToken([String? pairing]) async {
    final p = pairing ?? _activePairing;
    if (p == null) return null;
    final cached = _tokenCache[p];
    if (cached != null &&
        cached.expiry.isAfter(DateTime.now().toUtc().add(const Duration(seconds: 60)))) {
      return cached.token;
    }
    final res = await _fetchToken(p);
    if (res == null) return null;
    final acc = _accountFor(p);
    if (acc != null && res.email.isNotEmpty) acc['email'] = res.email;
    return res.token;
  }

  Future<void> setActiveAccount(String pairing) async {
    if (_accountFor(pairing) == null) return;
    _activePairing = pairing;
    await _persist();
  }

  Future<void> removeAccount(String pairing) async {
    _accounts.removeWhere((a) => a['pairing'] == pairing);
    _tokenCache.remove(pairing);
    if (_activePairing == pairing) {
      _activePairing = _accounts.isNotEmpty ? _accounts.first['pairing'] : null;
    }
    await _persist();
  }

  String get _accountsKey => '${providerId}_relay_accounts';
  String get _activeKey => '${providerId}_relay_active';

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_accountsKey, jsonEncode(_accounts));
      if (_activePairing != null) {
        await p.setString(_activeKey, _activePairing!);
      } else {
        await p.remove(_activeKey);
      }
    } catch (_) {}
  }

  Future<void> restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_accountsKey);
      if (raw != null) {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        _accounts
          ..clear()
          ..addAll(list.map((m) => m.map((k, v) => MapEntry(k, v as String))));
      }
      _activePairing = p.getString(_activeKey);
      if (_activePairing != null && _accountFor(_activePairing) == null) {
        _activePairing = _accounts.isNotEmpty ? _accounts.first['pairing'] : null;
      }
    } catch (_) {}
  }
}
