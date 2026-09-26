import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto_service.dart';

/// Ed25519-signed channel / group / app-admin actions.
///
/// These packets used to carry only claims — `by`, `updaterId`, `adminId`,
/// `moderatorIds`… — that the receiver believed verbatim, so anyone who could
/// reach a client could make themselves a moderator, delete other people's
/// posts, block or "verify" a channel (verified: all of it, by simply naming
/// the current owner, whose id is public). Now each such packet is signed with
/// the acting user's identity key over a canonical encoding of the WHOLE
/// payload, and the receiver decides authorisation from the *verified* signer
/// (`_signer`, set by the gossip router only after the check) against roles it
/// already knows locally — never from a field inside the packet.
///
/// Hard cutover (agreed): unsigned versions of these packets are dropped, so a
/// not-yet-updated app can't apply or originate them until it updates.
class SignedAction {
  SignedAction._();

  /// Packet types the router authenticates before they reach any handler.
  static const kinds = <String>{
    'channel_meta',
    'channel_delete_post',
    'channel_comment_del',
    'channel_subscribe',
    'channel_foreign_agent',
    'channel_block',
    'channel_admin_delete',
    'verify_ok',
    'verify_revoke',
    'group_update',
    'group_accept',
    'group_message_delete',
    'group_topic_update',
  };

  static const _domain = 'rlink-act1';
  static const _seenKey = 'signed_act_seen_v1';
  static const _storeKey = 'signed_act_store_v1';

  /// Deterministic JSON: keys sorted recursively, whole-number doubles printed
  /// as ints (dart2js decodes `5` as a double, the VM as an int — both must
  /// hash to the same bytes).
  static String canonical(Object? v) {
    if (v == null) return 'null';
    if (v is String) return jsonEncode(v);
    if (v is bool) return v ? 'true' : 'false';
    if (v is num) {
      return v == v.truncateToDouble() && v.abs() < 9e15
          ? v.truncate().toString()
          : v.toString();
    }
    if (v is List) return '[${v.map(canonical).join(',')}]';
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${canonical(v[k])}').join(',')}}';
    }
    return jsonEncode(v.toString());
  }

  static String _input(String kind, Map<String, dynamic> body) =>
      '$_domain|$kind|${canonical(body)}';

  /// [payload] plus `sk` (signer), `sts` (signing time, ms) and `sg`
  /// (signature over everything else, bound to [kind]).
  static Future<Map<String, dynamic>> sign(
      String kind, Map<String, dynamic> payload) async {
    final body = Map<String, dynamic>.from(payload)
      ..remove('sg')
      ..remove('_signer')
      ..['sk'] = CryptoService.instance.publicKeyHex
      ..['sts'] = DateTime.now().millisecondsSinceEpoch;
    final sig = await CryptoService.instance.signUtf8Message(_input(kind, body));
    return {...body, 'sg': sig};
  }

  /// The signer's public key (lowercase hex) if [payload] carries a valid
  /// signature for [kind]; null for anything unsigned, tampered or re-labelled.
  static Future<String?> verify(String kind, Map<String, dynamic> payload) async {
    final sk = payload['sk'], sg = payload['sg'], sts = payload['sts'];
    if (sk is! String || sg is! String || sts is! num) return null;
    final body = Map<String, dynamic>.from(payload)
      ..remove('sg')
      ..remove('_signer');
    final ok = await CryptoService.instance
        .verifyUtf8Signature(sk, _input(kind, body), sg);
    return ok ? sk.toLowerCase() : null;
  }

  /// Replay guard: true only if [sts] is newer than the last accepted action
  /// under [key] (an old, validly signed packet — e.g. a previous moderator
  /// list — can't be re-sent to undo a later change). Rejects timestamps more
  /// than a day in the future so a skewed clock can't freeze a key forever.
  static Future<bool> acceptNewer(String key, num sts) async {
    final t = sts.toInt();
    if (t > DateTime.now().millisecondsSinceEpoch + 86400000) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final m = _readMap(prefs.getString(_seenKey));
      final last = (m[key] as num?)?.toInt() ?? 0;
      if (t <= last) return false;
      m[key] = t;
      if (m.length > 3000) {
        final keys = m.keys.toList();
        for (var i = 0; i < 500; i++) {
          m.remove(keys[i]);
        }
      }
      await prefs.setString(_seenKey, jsonEncode(m));
    } catch (e) {
      debugPrint('[SignedAction] acceptNewer failed: $e');
    }
    return true;
  }

  /// Keeps the last accepted signed payload for [key] so a non-owner can
  /// forward the OWNER's signed packet verbatim (it can't re-sign it).
  static Future<void> remember(String key, Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final m = _readMap(prefs.getString(_storeKey));
      m[key] = jsonEncode(Map<String, dynamic>.from(payload)..remove('_signer'));
      if (m.length > 500) m.remove(m.keys.first);
      await prefs.setString(_storeKey, jsonEncode(m));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> stored(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = _readMap(prefs.getString(_storeKey))[key];
      if (raw is! String) return null;
      final d = jsonDecode(raw);
      return d is Map ? Map<String, dynamic>.from(d) : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _readMap(String? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final d = jsonDecode(raw);
      return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}

/// Identities allowed to issue app-level moderation (channel checkmark,
/// "foreign agent", network-wide block/delete). Previously any peer could —
/// the packets carried a `by` nobody checked. Add the public key of every
/// device the admin panel is used from (Settings → diagnostics shows `pk=`).
const kAppAdminPublicKeys = <String>{
  'b1fe9c1d3113929e1c47245c87f494206d0f66996ec9cb9b77a5cc33196c4f22',
};

bool isAppAdminKey(String? k) =>
    k != null && kAppAdminPublicKeys.contains(k.toLowerCase());
