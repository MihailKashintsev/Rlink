import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/crypto_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String base64EncodeBytes(List<int> bytes) => base64Encode(bytes);

/// Exercises the crypto primitives account transfer relies on:
/// `restoreIdentity` (adopting received key material live, no restart) and
/// the existing `encryptMessage`/`decryptMessage`/`verifyEncryptedEnvelope`
/// path, which the transfer feature reuses as-is for every `xfer_data`
/// packet instead of the plaintext transport the device-link mirror uses.
///
/// `CryptoService` is a process-wide singleton, so "two devices" here means
/// generating a second keypair independently (via the `cryptography` package
/// directly, not through the singleton) and swapping the singleton's live
/// identity between them with `restoreIdentity` — exactly the operation the
/// real feature performs when a device adopts a transferred identity.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  // CryptoService picks flutter_secure_storage vs SharedPreferences by
  // platform; flutter test's default target platform is Android (mobile),
  // which needs a real secure-storage plugin implementation we don't have
  // here. Force a desktop platform so it takes the SharedPreferences path.
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

  test('encryptMessage -> verifyEncryptedEnvelope -> decryptMessage round-trips '
      'across a restoreIdentity swap between two independent identities', () async {
    final crypto = CryptoService.instance;

    // "Device A": the singleton adopts a freshly generated identity.
    final aEd = await Ed25519().newKeyPair();
    final aEdPriv = await aEd.extractPrivateKeyBytes();
    final aEdPub = await aEd.extractPublicKey();
    final aX = await X25519().newKeyPair();
    final aXPriv = await aX.extractPrivateKeyBytes();
    final aXPub = await aX.extractPublicKey();
    await crypto.restoreIdentity(
      edPrivB64: base64EncodeBytes(aEdPriv),
      edPubB64: base64EncodeBytes(aEdPub.bytes),
      xPrivB64: base64EncodeBytes(aXPriv),
      xPubB64: base64EncodeBytes(aXPub.bytes),
    );
    expect(crypto.publicKeyHex, isNotEmpty);
    final devicePubHex = crypto.publicKeyHex;

    // "Device B": generated independently, never touches the singleton yet.
    final bEd = await Ed25519().newKeyPair();
    final bEdPriv = await bEd.extractPrivateKeyBytes();
    final bEdPub = await bEd.extractPublicKey();
    final bX = await X25519().newKeyPair();
    final bXPriv = await bX.extractPrivateKeyBytes();
    final bXPub = await bX.extractPublicKey();
    final deviceBX25519B64 = base64EncodeBytes(bXPub.bytes);

    // Device A encrypts something addressed to device B's X25519 key —
    // this is exactly what the old device does for every xfer_data packet.
    final msg = await crypto.encryptMessage(
      plaintext: '{"edPriv":"secret-key-material"}',
      recipientX25519KeyBase64: deviceBX25519B64,
    );
    expect(msg.senderPublicKey, devicePubHex);

    // Gate 1 (non-negotiable per the plan): verify before trust. The
    // signature is over device A's real Ed25519 key, checkable without
    // needing to be device A or device B.
    expect(await crypto.verifyEncryptedEnvelope(msg), isTrue);

    // Now the singleton becomes "device B" — restoreIdentity is the exact
    // operation a real transfer performs on receipt of the keys packet.
    await crypto.restoreIdentity(
      edPrivB64: base64EncodeBytes(bEdPriv),
      edPubB64: base64EncodeBytes(bEdPub.bytes),
      xPrivB64: base64EncodeBytes(bXPriv),
      xPubB64: base64EncodeBytes(bXPub.bytes),
    );
    expect(crypto.publicKeyHex, isNot(devicePubHex));

    // Device B can now decrypt what was sealed for its X25519 key.
    final decrypted = await crypto.decryptMessage(msg);
    expect(decrypted, '{"edPriv":"secret-key-material"}');

    // Gate 2: proof-of-possession — device B signs an ack with its NEWLY
    // adopted key, verifiable by anyone who knows device B's (new) pubkey.
    const nonce = 'rlink.xfer.ack.v1|test-req-id';
    final proof = await crypto.signUtf8Message(nonce);
    expect(await crypto.verifyUtf8Signature(crypto.publicKeyHex, nonce, proof),
        isTrue);
  });

  test('verifyEncryptedEnvelope rejects a message whose senderPublicKey does not '
      'match who actually signed it — the auth-before-trust gate', () async {
    final crypto = CryptoService.instance;

    final realEd = await Ed25519().newKeyPair();
    await crypto.restoreIdentity(
      edPrivB64: base64EncodeBytes(await realEd.extractPrivateKeyBytes()),
      edPubB64: base64EncodeBytes((await realEd.extractPublicKey()).bytes),
      xPrivB64:
          base64EncodeBytes(await (await X25519().newKeyPair()).extractPrivateKeyBytes()),
      xPubB64: base64EncodeBytes(
          (await (await X25519().newKeyPair()).extractPublicKey()).bytes),
    );

    final recipientX = await X25519().newKeyPair();
    final msg = await crypto.encryptMessage(
      plaintext: 'hello',
      recipientX25519KeyBase64:
          base64EncodeBytes((await recipientX.extractPublicKey()).bytes),
    );

    // Tamper: claim a different (attacker-controlled) sender identity while
    // keeping the real signature — must fail, since the signature was made
    // over the ORIGINAL senderPublicKey as part of the signed input.
    final attackerEd = await Ed25519().newKeyPair();
    final attackerPubHex = (await attackerEd.extractPublicKey())
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final forged = EncryptedMessage(
      senderPublicKey: attackerPubHex,
      ephemeralPublicKey: msg.ephemeralPublicKey,
      nonce: msg.nonce,
      cipherText: msg.cipherText,
      mac: msg.mac,
      signature: msg.signature,
    );
    expect(await crypto.verifyEncryptedEnvelope(forged), isFalse);

    // Sanity: the original, untampered envelope still verifies fine.
    expect(await crypto.verifyEncryptedEnvelope(msg), isTrue);
  });

  test('verifyUtf8Signature rejects a signature from the wrong key', () async {
    final crypto = CryptoService.instance;
    final ed = await Ed25519().newKeyPair();
    await crypto.restoreIdentity(
      edPrivB64: base64EncodeBytes(await ed.extractPrivateKeyBytes()),
      edPubB64: base64EncodeBytes((await ed.extractPublicKey()).bytes),
      xPrivB64:
          base64EncodeBytes(await (await X25519().newKeyPair()).extractPrivateKeyBytes()),
      xPubB64: base64EncodeBytes(
          (await (await X25519().newKeyPair()).extractPublicKey()).bytes),
    );

    final sig = await crypto.signUtf8Message('rlink.xfer.ack.v1|abc');
    final otherEd = await Ed25519().newKeyPair();
    final otherPubHex = (await otherEd.extractPublicKey())
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    expect(
      await crypto.verifyUtf8Signature(otherPubHex, 'rlink.xfer.ack.v1|abc', sig),
      isFalse,
    );
    expect(
      await crypto.verifyUtf8Signature(
          crypto.publicKeyHex, 'rlink.xfer.ack.v1|abc', sig),
      isTrue,
    );
  });
}
