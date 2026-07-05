import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/crypto_service.dart';

// Mirrors CryptoService._envelopeSigningInput exactly.
String signingInput({
  required String from,
  required String epk,
  required String nonce,
  required String ct,
  required String mac,
}) =>
    'rlink.msg.v1|$from|$epk|$nonce|$ct|$mac';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int> unhex(String h) {
  final o = <int>[];
  for (var i = 0; i < h.length; i += 2) {
    o.add(int.parse(h.substring(i, i + 2), radix: 16));
  }
  return o;
}

void main() {
  final ed = Ed25519();

  Future<bool> verify(String input, String sigHex, String senderHex) => ed.verify(
        utf8.encode(input),
        signature: Signature(
          unhex(sigHex),
          publicKey:
              SimplePublicKey(unhex(senderHex), type: KeyPairType.ed25519),
        ),
      );

  test('valid envelope signature verifies', () async {
    final kp = await ed.newKeyPair();
    final from = hex((await kp.extractPublicKey()).bytes);
    final input =
        signingInput(from: from, epk: 'EPK', nonce: 'N', ct: 'CT', mac: 'M');
    final sig = hex((await ed.sign(utf8.encode(input), keyPair: kp)).bytes);
    expect(await verify(input, sig, from), isTrue);
  });

  test('tampered ciphertext is rejected', () async {
    final kp = await ed.newKeyPair();
    final from = hex((await kp.extractPublicKey()).bytes);
    final input =
        signingInput(from: from, epk: 'EPK', nonce: 'N', ct: 'CT', mac: 'M');
    final sig = hex((await ed.sign(utf8.encode(input), keyPair: kp)).bytes);
    final tampered =
        signingInput(from: from, epk: 'EPK', nonce: 'N', ct: 'EVIL', mac: 'M');
    expect(await verify(tampered, sig, from), isFalse);
  });

  test('sender spoofing (relay swaps `from`) is rejected', () async {
    final alice = await ed.newKeyPair();
    final aliceHex = hex((await alice.extractPublicKey()).bytes);
    final input = signingInput(
        from: aliceHex, epk: 'EPK', nonce: 'N', ct: 'CT', mac: 'M');
    final sig = hex((await ed.sign(utf8.encode(input), keyPair: alice)).bytes);

    // Relay rewrites the envelope's `from` to a victim/attacker key but keeps
    // Alice's signature — verification against the new claimed sender must fail.
    final attacker = await ed.newKeyPair();
    final attackerHex = hex((await attacker.extractPublicKey()).bytes);
    final rewritten = signingInput(
        from: attackerHex, epk: 'EPK', nonce: 'N', ct: 'CT', mac: 'M');
    expect(await verify(rewritten, sig, attackerHex), isFalse);
  });

  // ── Safety numbers ────────────────────────────────────────────────────────
  final keyA = 'a' * 64; // valid 32-byte hex
  final keyB = 'b' * 64;
  final keyC =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('safety number is 12 groups of 5 digits', () async {
    final sn = await CryptoService.computeSafetyNumber(keyA, keyB);
    final groups = sn.split(' ');
    expect(groups.length, 12);
    for (final g in groups) {
      expect(g.length, 5);
      expect(int.tryParse(g), isNotNull);
    }
  });

  test('safety number is symmetric (order-independent) and deterministic',
      () async {
    final ab = await CryptoService.computeSafetyNumber(keyA, keyB);
    final ba = await CryptoService.computeSafetyNumber(keyB, keyA);
    expect(ab, equals(ba));
    expect(ab, equals(await CryptoService.computeSafetyNumber(keyA, keyB)));
  });

  test('different key pairs produce different safety numbers', () async {
    final ab = await CryptoService.computeSafetyNumber(keyA, keyB);
    final ac = await CryptoService.computeSafetyNumber(keyA, keyC);
    expect(ab, isNot(equals(ac)));
  });

  test('invalid key returns empty safety number', () async {
    expect(await CryptoService.computeSafetyNumber('xyz', keyB), '');
  });
}
