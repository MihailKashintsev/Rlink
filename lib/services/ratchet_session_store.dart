import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'double_ratchet.dart';
import 'runtime_platform.dart';
import 'web_account_bundle.dart';

/// Persists one [RatchetSession] per peer, keyed by the peer's long-term
/// Ed25519 public key hex (the same identifier used everywhere else as
/// "who is this"). Session state — the private ratchet keypair, root key,
/// chain keys — is exactly as sensitive as the long-term identity keys
/// [CryptoService] stores, so it follows the same per-platform tiering:
/// OS keychain on mobile, [WebAccountBundle]'s layered storage on web,
/// SharedPreferences on desktop (the same accepted trade-off CryptoService
/// already makes there — desktop Keychain/secure storage isn't reliable).
class RatchetSessionStore {
  RatchetSessionStore._();
  static final RatchetSessionStore instance = RatchetSessionStore._();

  static bool get _isMobile =>
      RuntimePlatform.isIos || RuntimePlatform.isAndroid;

  final _secureSt = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  String _keyFor(String peerId) => 'ratchet_session_${peerId.toLowerCase()}';

  Future<String?> _read(String key) async {
    if (RuntimePlatform.isWeb) return WebAccountBundle.layeredRead(key);
    if (_isMobile) return _secureSt.read(key: key);
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  Future<void> _write(String key, String value) async {
    if (RuntimePlatform.isWeb) {
      await WebAccountBundle.layeredWrite(key, value);
      return;
    }
    if (_isMobile) {
      await _secureSt.write(key: key, value: value);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  Future<void> _delete(String key) async {
    if (RuntimePlatform.isWeb) {
      await WebAccountBundle.layeredWrite(key, '');
      return;
    }
    if (_isMobile) {
      await _secureSt.delete(key: key);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    }
  }

  Future<RatchetSession?> load(String peerId) async {
    try {
      final raw = await _read(_keyFor(peerId));
      if (raw == null || raw.isEmpty) return null;
      return RatchetSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[RatchetSessionStore] failed to load session for '
          '${peerId.substring(0, peerId.length.clamp(0, 8))}: $e');
      return null;
    }
  }

  Future<void> save(String peerId, RatchetSession session) async {
    final json = await session.toJson();
    await _write(_keyFor(peerId), jsonEncode(json));
  }

  Future<void> delete(String peerId) => _delete(_keyFor(peerId));
}
