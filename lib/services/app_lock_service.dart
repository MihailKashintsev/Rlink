import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LockMethod { pin4, pattern, text }

class AppLockService {
  AppLockService._();
  static final AppLockService instance = AppLockService._();

  static const _kEnabled = 'applock_enabled';
  static const _kHash = 'applock_hash';
  static const _kSalt = 'applock_salt';
  static const _kLen = 'applock_len';
  static const _kTimeout = 'applock_timeout_sec';
  static const _kMethod = 'applock_method';

  final ValueNotifier<bool> locked = ValueNotifier<bool>(false);

  bool _enabled = false;
  int _timeoutSec = 0;
  int _codeLen = 4;
  LockMethod _method = LockMethod.pin4;
  int _bgAt = 0;

  bool get isEnabled => _enabled;
  int get timeoutSeconds => _timeoutSec;
  int get codeLength => _codeLen;
  LockMethod get method => _method;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _enabled = p.getBool(_kEnabled) ?? false;
    _timeoutSec = p.getInt(_kTimeout) ?? 0;
    _codeLen = p.getInt(_kLen) ?? 4;
    _method = LockMethod.values.firstWhere(
      (m) => m.name == (p.getString(_kMethod) ?? ''),
      orElse: () => LockMethod.pin4,
    );
    if (_enabled) locked.value = true;
  }

  Future<String> _hash(String code, String salt) async {
    final d = await Sha256().hash(utf8.encode('rlink.applock.v1|$salt|$code'));
    return base64.encode(d.bytes);
  }

  Future<void> setPasscode(
    String code, {
    int timeoutSeconds = 0,
    LockMethod method = LockMethod.pin4,
  }) async {
    final p = await SharedPreferences.getInstance();
    final rnd = Random.secure();
    final salt = base64.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    await p.setString(_kSalt, salt);
    await p.setString(_kHash, await _hash(code, salt));
    await p.setInt(_kLen, code.length);
    await p.setBool(_kEnabled, true);
    await p.setInt(_kTimeout, timeoutSeconds);
    await p.setString(_kMethod, method.name);
    _enabled = true;
    _timeoutSec = timeoutSeconds;
    _codeLen = code.length;
    _method = method;
  }

  Future<void> setTimeout(int seconds) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kTimeout, seconds);
    _timeoutSec = seconds;
  }

  Future<bool> verify(String code) async {
    final p = await SharedPreferences.getInstance();
    final salt = p.getString(_kSalt);
    final hash = p.getString(_kHash);
    if (salt == null || hash == null) return false;
    final ok = (await _hash(code, salt)) == hash;
    if (ok) locked.value = false;
    return ok;
  }

  Future<void> disable() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kEnabled);
    await p.remove(_kHash);
    await p.remove(_kSalt);
    await p.remove(_kLen);
    await p.remove(_kTimeout);
    await p.remove(_kMethod);
    _enabled = false;
    locked.value = false;
  }

  void onBackground() {
    if (_enabled) _bgAt = DateTime.now().millisecondsSinceEpoch;
  }

  void onResume() {
    if (!_enabled || locked.value) return;
    final elapsedSec =
        (DateTime.now().millisecondsSinceEpoch - _bgAt) ~/ 1000;
    if (_bgAt == 0 || elapsedSec >= _timeoutSec) locked.value = true;
  }

  void lockNow() {
    if (_enabled) locked.value = true;
  }
}
