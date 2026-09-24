import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:pointycastle/export.dart';

/// Web Push payload encryption (RFC 8291, `aes128gcm` content coding, RFC 8188).
///
/// Push services (Apple's `web.push.apple.com` in particular) reject a body
/// that is not encrypted for the subscription with `400`; FCM merely accepts
/// it and the browser then drops it. The result is the request body — send it
/// with `Content-Encoding: aes128gcm`.
///
/// [asPrivate] / [salt] exist only so the RFC 8291 Appendix A known-answer
/// test can pin them; production callers omit both (fresh random values).
Uint8List encryptWebPushPayload({
  required Uint8List plaintext,
  required String p256dhB64Url,
  required String authB64Url,
  Uint8List? asPrivate,
  Uint8List? salt,
}) {
  final uaPublic = _b64uDecode(p256dhB64Url);
  final authSecret = _b64uDecode(authB64Url);
  if (uaPublic.length != 65 || uaPublic[0] != 4) {
    throw ArgumentError('p256dh must be an uncompressed P-256 point');
  }
  if (authSecret.length != 16) {
    throw ArgumentError('auth secret must be 16 bytes');
  }
  final rng = Random.secure();
  final domain = ECDomainParameters('prime256v1');

  final d = asPrivate != null
      ? _bigFromBytes(asPrivate)
      : _randomScalar(rng, domain.n);
  final asPublic = domain.G * d;
  final asPublicBytes = asPublic!.getEncoded(false); // 65 bytes

  final uaPoint = domain.curve.decodePoint(uaPublic);
  if (uaPoint == null) throw ArgumentError('p256dh is not on the curve');
  final shared = (uaPoint * d)!.x!.toBigInteger()!;
  final ecdhSecret = _bigToBytes(shared, 32);

  final prkKey = _hmac(authSecret, ecdhSecret);
  final keyInfo = Uint8List.fromList([
    ...utf8.encode('WebPush: info'),
    0,
    ...uaPublic,
    ...asPublicBytes,
  ]);
  final ikm = _hkdfExpand(prkKey, keyInfo, 32);

  final s = salt ?? _randomBytes(rng, 16);
  final prk = _hmac(s, ikm);
  final cek = _hkdfExpand(
      prk, Uint8List.fromList([...utf8.encode('Content-Encoding: aes128gcm'), 0]), 16);
  final nonce = _hkdfExpand(
      prk, Uint8List.fromList([...utf8.encode('Content-Encoding: nonce'), 0]), 12);

  // One record: data || 0x02 (last-record delimiter), AES-128-GCM.
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(cek), 128, nonce, Uint8List(0)));
  final record = cipher.process(Uint8List.fromList([...plaintext, 2]));

  const recordSize = 4096;
  return Uint8List.fromList([
    ...s,
    (recordSize >> 24) & 0xff,
    (recordSize >> 16) & 0xff,
    (recordSize >> 8) & 0xff,
    recordSize & 0xff,
    asPublicBytes.length,
    ...asPublicBytes,
    ...record,
  ]);
}

Uint8List _hmac(List<int> key, List<int> data) =>
    Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

/// HKDF-Expand for a single output block (length <= 32).
Uint8List _hkdfExpand(Uint8List prk, Uint8List info, int length) {
  final t = _hmac(prk, [...info, 1]);
  return Uint8List.fromList(t.sublist(0, length));
}

Uint8List _b64uDecode(String s) {
  var n = s.trim().replaceAll('-', '+').replaceAll('_', '/');
  while (n.length % 4 != 0) {
    n += '=';
  }
  return Uint8List.fromList(base64Decode(n));
}

BigInt _bigFromBytes(Uint8List b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x);
  }
  return r;
}

Uint8List _bigToBytes(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

Uint8List _randomBytes(Random rng, int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => rng.nextInt(256)));

BigInt _randomScalar(Random rng, BigInt n) {
  while (true) {
    final k = _bigFromBytes(_randomBytes(rng, 32));
    if (k > BigInt.zero && k < n) return k;
  }
}
