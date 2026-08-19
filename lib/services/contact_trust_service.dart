import 'package:shared_preferences/shared_preferences.dart';

/// Локальное состояние доверия к ключу контакта: какой X25519-ключ пользователь
/// подтвердил (сверив safety number) и менялся ли ключ с тех пор. Хранится в
/// SharedPreferences (без миграции БД). Смена ключа у уже проверенного контакта —
/// сигнал возможного MITM, показываем предупреждение.
class ContactTrustService {
  ContactTrustService._();
  static final ContactTrustService instance = ContactTrustService._();

  String _norm(String id) => id.trim().toLowerCase();
  String _verifiedKeyPref(String id) => 'ct_verified_x25519_${_norm(id)}';
  String _changedPref(String id) => 'ct_key_changed_${_norm(id)}';

  /// Пользователь сверил safety number и подтверждает текущий ключ.
  Future<void> markVerified(String id, String x25519Key) async {
    if (x25519Key.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(_verifiedKeyPref(id), x25519Key);
    await p.remove(_changedPref(id));
  }

  Future<void> clearVerified(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_verifiedKeyPref(id));
    await p.remove(_changedPref(id));
  }

  /// Wipes trust state for every contact — used by a full account reset
  /// (including account transfer's old-device wipe), where no single [id]
  /// applies.
  Future<void> clearAll() async {
    final p = await SharedPreferences.getInstance();
    final keys = p.getKeys().where(
        (k) => k.startsWith('ct_verified_x25519_') || k.startsWith('ct_key_changed_'));
    for (final k in keys.toList()) {
      await p.remove(k);
    }
  }

  Future<String?> verifiedKey(String id) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_verifiedKeyPref(id));
  }

  /// true, если текущий ключ совпадает с ранее подтверждённым.
  Future<bool> isVerified(String id, String currentX25519Key) async {
    if (currentX25519Key.isEmpty) return false;
    return (await verifiedKey(id)) == currentX25519Key;
  }

  /// Вызывается при получении/обновлении X25519-ключа контакта. Если контакт был
  /// проверен, а ключ стал другим — помечаем «ключ изменился».
  Future<void> onKeyObserved(String id, String newKey) async {
    if (newKey.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final verified = p.getString(_verifiedKeyPref(id));
    if (verified != null && verified.isNotEmpty && verified != newKey) {
      await p.setInt(_changedPref(id), DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// Момент (ms) смены ключа у проверенного контакта, или null.
  Future<int?> keyChangedAt(String id) async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_changedPref(id));
  }

  /// Пользователь увидел предупреждение — снимаем флаг (но контакт больше не
  /// «проверен», пока не сверит номер заново).
  Future<void> acknowledgeChange(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_changedPref(id));
    await p.remove(_verifiedKeyPref(id));
  }
}
