import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_kv_store.dart';
import 'runtime_platform.dart';
import 'web_secret_box.dart';
import 'web_state_store.dart';

/// Single JSON blob for web/Tilda iframe: reduces torn writes and survives
/// flaky first-frame bridge reads by mirroring to SharedPreferences + KV.
const _bundleLogicalKey = 'rlink_account_bundle_v1';

const _prefsPrefix = 'rlink_account_v2_';

/// Same logical keys as [CryptoService] / [ProfileService].
const kMeshIdentityPrivate = 'mesh_identity_private';
const kMeshIdentityPublic = 'mesh_identity_public';
const kMeshX25519Private = 'mesh_x25519_private';
const kMeshX25519Public = 'mesh_x25519_public';
const kUserProfile = 'rlink_user_profile';
const kAppSettingsBackup = 'rlink_app_settings_backup';
const kChannelsBackup = 'rlink_channels_backup';
const kGroupsBackup = 'rlink_groups_backup';
const kChatsBackup = 'rlink_chats_backup';

/// Set to `'1'` after web identity file import; cleared in [ProfileService.init].
const kRlinkPostKeyImportFlag = 'rlink_post_key_import';

class WebAccountBundle {
  WebAccountBundle._();

  static Future<String?> _prefsRead(String logicalKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_prefsPrefix$logicalKey');
    } catch (_) {
      return null;
    }
  }

  static Future<void> _prefsWrite(String logicalKey, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefsPrefix$logicalKey', value);
    } catch (_) {}
  }

  /// Decrypt a stored value. Legacy plaintext passes through; ciphertext that
  /// can't be decrypted (e.g. key evicted) comes back null so the caller falls
  /// through to another store rather than treating garbage as the value.
  static Future<String?> _decode(String? raw) async {
    if (raw == null || raw.isEmpty) return null;
    return decryptSecret(raw);
  }

  /// Legacy plaintext found on disk → rewrite it encrypted so it stops showing
  /// up in DevTools. No-op if the value is already encrypted or WebCrypto isn't
  /// available (encryptSecret returns null → we leave the plaintext untouched).
  static Future<void> _migrateIfPlaintext(
      String logicalKey, String raw, String plain) async {
    if (secretBoxLooksEncrypted(raw)) return;
    final enc = await encryptSecret(plain);
    if (enc == null) return;
    await writeWebState(logicalKey, enc);
    await AccountKvStore.write(logicalKey, enc);
    await _prefsWrite(logicalKey, enc);
  }

  /// One-shot read: web bridge/localStorage → prefs mirror → durable KV.
  static Future<String?> layeredRead(String logicalKey) async {
    if (!RuntimePlatform.isWeb) return null;
    final wRaw = await readWebState(logicalKey);
    final w = await _decode(wRaw);
    if (w != null && w.isNotEmpty) {
      await _migrateIfPlaintext(logicalKey, wRaw!, w);
      return w;
    }
    final pRaw = await _prefsRead(logicalKey);
    final p = await _decode(pRaw);
    if (p != null && p.isNotEmpty) {
      await writeWebState(logicalKey, pRaw!);
      await _migrateIfPlaintext(logicalKey, pRaw, p);
      return p;
    }
    final dRaw = await AccountKvStore.read(logicalKey);
    final d = await _decode(dRaw);
    if (d != null && d.isNotEmpty) {
      await writeWebState(logicalKey, dRaw!);
      await _prefsWrite(logicalKey, dRaw);
      await _migrateIfPlaintext(logicalKey, dRaw, d);
      return d;
    }
    return null;
  }

  static Future<void> layeredWrite(String logicalKey, String value) async {
    if (!RuntimePlatform.isWeb) return;
    // Store ciphertext when WebCrypto is available; fall back to plaintext so a
    // browser without it keeps working exactly as before.
    final stored = (await encryptSecret(value)) ?? value;
    await writeWebState(logicalKey, stored);
    await AccountKvStore.write(logicalKey, stored);
    await _prefsWrite(logicalKey, stored);
  }

  static Map<String, dynamic>? _tryDecodeBundle(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if ((j['v'] as num?)?.toInt() != 1) return null;
      return j;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _validateCryptoPayload(Map<String, dynamic> j) async {
    try {
      final edPr = j['edPr'] as String?;
      final edPu = j['edPu'] as String?;
      final xPr = j['xPr'] as String?;
      final xPu = j['xPu'] as String?;
      if (edPr == null ||
          edPu == null ||
          xPr == null ||
          xPu == null ||
          edPr.isEmpty ||
          edPu.isEmpty ||
          xPr.isEmpty ||
          xPu.isEmpty) {
        return false;
      }
      final edPriv = base64.decode(edPr);
      final edPub = base64.decode(edPu);
      final xPriv = base64.decode(xPr);
      final xPub = base64.decode(xPu);
      if (edPriv.isEmpty || edPub.isEmpty || xPriv.isEmpty || xPub.isEmpty) {
        return false;
      }
      final edKp = SimpleKeyPairData(
        edPriv,
        publicKey: SimplePublicKey(edPub, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
      final derivedEd = await edKp.extractPublicKey();
      if (!_bytesEq(derivedEd.bytes, edPub)) return false;

      final xKp = SimpleKeyPairData(
        xPriv,
        publicKey: SimplePublicKey(xPub, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
      final derivedX = await xKp.extractPublicKey();
      if (!_bytesEq(derivedX.bytes, xPub)) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool _bytesEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<String?> _readRawBundleAllSources() async {
    // Returns decrypted plaintext JSON (callers jsonDecode it). Try each store
    // and skip any copy that can't be decrypted.
    for (final raw in [
      await readWebState(_bundleLogicalKey),
      await _prefsRead(_bundleLogicalKey),
      await AccountKvStore.read(_bundleLogicalKey),
    ]) {
      final dec = await _decode(raw);
      if (dec != null && dec.isNotEmpty) return dec;
    }
    return null;
  }

  /// Cold start in iframe: bridge can answer late — retry before giving up.
  static Future<Map<String, dynamic>?> loadValidatedBundleWithRetries({
    int maxAttempts = 10,
  }) async {
    if (!RuntimePlatform.isWeb) return null;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final raw = await _readRawBundleAllSources();
      if (raw != null) {
        final j = _tryDecodeBundle(raw);
        if (j != null && await _validateCryptoPayload(j)) {
          return j;
        }
      }
      await Future<void>.delayed(Duration(milliseconds: 80 + attempt * 60));
    }
    return null;
  }

  static Future<void> persistBundle({
    required String edPrivB64,
    required String edPubB64,
    required String xPrivB64,
    required String xPubB64,
    String? profileJson,
    // When true, a null/empty [profileJson] means "no profile", full stop —
    // skips recovering whatever profile is still sitting in the existing
    // bundle. Regular boot wants that recovery (e.g. localStorage got wiped
    // but the OPFS-backed bundle survived); an explicit wipe/regenerate does
    // not — recovering there silently undoes "delete RID"'s profile clear.
    bool clearProfile = false,
  }) async {
    if (!RuntimePlatform.isWeb) return;
    var prof = profileJson;
    if (!clearProfile && (prof == null || prof.isEmpty)) {
      final raw = await _readRawBundleAllSources();
      if (raw != null) {
        try {
          final ej = jsonDecode(raw) as Map<String, dynamic>;
          final p = ej['prof'] as String?;
          if (p != null && p.isNotEmpty) prof = p;
        } catch (_) {}
      }
    }
    final j = <String, dynamic>{
      'v': 1,
      'edPr': edPrivB64,
      'edPu': edPubB64,
      'xPr': xPrivB64,
      'xPu': xPubB64,
      if (prof != null && prof.isNotEmpty) 'prof': prof,
    };
    final raw = jsonEncode(j);
    final stored = (await encryptSecret(raw)) ?? raw;
    await writeWebState(_bundleLogicalKey, stored);
    await AccountKvStore.write(_bundleLogicalKey, stored);
    await _prefsWrite(_bundleLogicalKey, stored);
  }

  static Future<String?> profileJsonFromBundle() async {
    if (!RuntimePlatform.isWeb) return null;
    final j = await loadValidatedBundleWithRetries(maxAttempts: 4);
    final p = j?['prof'] as String?;
    if (p != null && p.isNotEmpty) return p;
    return null;
  }

  /// After profile save: re-read keys from layered storage and refresh bundle.
  static Future<void> mergeProfileIntoBundle(String profileEncoded) async {
    if (!RuntimePlatform.isWeb) return;
    final edPr = await layeredRead(kMeshIdentityPrivate);
    final edPu = await layeredRead(kMeshIdentityPublic);
    final xPr = await layeredRead(kMeshX25519Private);
    final xPu = await layeredRead(kMeshX25519Public);
    if (edPr == null ||
        edPu == null ||
        xPr == null ||
        xPu == null ||
        edPr.isEmpty ||
        edPu.isEmpty ||
        xPr.isEmpty ||
        xPu.isEmpty) {
      return;
    }
    await persistBundle(
      edPrivB64: edPr,
      edPubB64: edPu,
      xPrivB64: xPr,
      xPubB64: xPu,
      profileJson: profileEncoded,
    );
  }

  /// Erases the profile from every layer this class writes to (flat key +
  /// the merged bundle). Used by account wipes — without this, a stale
  /// nickname/avatar survives "delete RID" and reappears on next boot,
  /// because [persistBundle] otherwise recovers whatever profile was
  /// already in the bundle when none is passed explicitly.
  static Future<void> clearProfileEverywhere() async {
    if (!RuntimePlatform.isWeb) return;
    await writeWebState(kUserProfile, '');
    await AccountKvStore.write(kUserProfile, '');
    await _prefsWrite(kUserProfile, '');
    final edPr = await layeredRead(kMeshIdentityPrivate);
    final edPu = await layeredRead(kMeshIdentityPublic);
    final xPr = await layeredRead(kMeshX25519Private);
    final xPu = await layeredRead(kMeshX25519Public);
    if (edPr == null ||
        edPu == null ||
        xPr == null ||
        xPu == null ||
        edPr.isEmpty ||
        edPu.isEmpty ||
        xPr.isEmpty ||
        xPu.isEmpty) {
      return;
    }
    final j = <String, dynamic>{
      'v': 1,
      'edPr': edPr,
      'edPu': edPu,
      'xPr': xPr,
      'xPu': xPu,
    };
    final raw = jsonEncode(j);
    final stored = (await encryptSecret(raw)) ?? raw;
    await writeWebState(_bundleLogicalKey, stored);
    await AccountKvStore.write(_bundleLogicalKey, stored);
    await _prefsWrite(_bundleLogicalKey, stored);
  }
}
