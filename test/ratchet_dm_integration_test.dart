import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/crypto_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exercises the Double Ratchet wiring through the REAL production code
/// path — `CryptoService.encryptMessage`/`decryptMessage` exactly as
/// chat_screen.dart/outbox_service.dart/outbound_dm_text.dart call them —
/// rather than the ratchet engine in isolation (already covered by
/// double_ratchet_test.dart). This is the substitute for testing on two
/// real devices: no live BLE/relay hardware is available here, but the
/// actual encrypt/decrypt/session-persistence/capability-gating code that
/// ships to production is exercised end to end.
///
/// `CryptoService` is a process-wide singleton (see
/// account_transfer_crypto_test.dart for the established precedent), so
/// "two peers" means generating two independent identities directly via
/// the `cryptography` package and swapping the singleton's live identity
/// between them with `restoreIdentity`. Session state is keyed by the
/// OTHER party's identity, so this naturally holds both directions'
/// sessions without collision even though they share one backing store —
/// exactly as two real, separate devices each hold only their own side.
String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class _Identity {
  final String edPrivB64, edPubB64, xPrivB64, xPubB64;
  final String publicKeyHex;
  final String x25519PublicKeyBase64;
  _Identity({
    required this.edPrivB64,
    required this.edPubB64,
    required this.xPrivB64,
    required this.xPubB64,
    required this.publicKeyHex,
    required this.x25519PublicKeyBase64,
  });
}

Future<_Identity> _generateIdentity() async {
  final ed = await Ed25519().newKeyPair();
  final edPriv = await ed.extractPrivateKeyBytes();
  final edPub = await ed.extractPublicKey();
  final x = await X25519().newKeyPair();
  final xPriv = await x.extractPrivateKeyBytes();
  final xPub = await x.extractPublicKey();
  return _Identity(
    edPrivB64: base64Encode(edPriv),
    edPubB64: base64Encode(edPub.bytes),
    xPrivB64: base64Encode(xPriv),
    xPubB64: base64Encode(xPub.bytes),
    publicKeyHex: _hex(edPub.bytes),
    x25519PublicKeyBase64: base64Encode(xPub.bytes),
  );
}

Future<void> _becomeIdentity(_Identity id) => CryptoService.instance.restoreIdentity(
      edPrivB64: id.edPrivB64,
      edPubB64: id.edPubB64,
      xPrivB64: id.xPrivB64,
      xPubB64: id.xPubB64,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  // RatchetSessionStore (like CryptoService itself) picks flutter_secure_storage
  // vs SharedPreferences by platform; force desktop so it takes the
  // SharedPreferences path, same reasoning as account_transfer_crypto_test.dart.
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

  test(
      'two peers exchange several DMs through encryptMessage/decryptMessage '
      'and every message upgrades to Double Ratchet after the first', () async {
    final a = await _generateIdentity();
    final b = await _generateIdentity();
    // Role assignment is deterministic and symmetric — whichever identity
    // happens to sort first is the one that can bootstrap the very first
    // ratchet message; label by that, not by generation order, so the test
    // doesn't depend on which of a/b happened to come out smaller.
    final initiator = a.publicKeyHex.compareTo(b.publicKeyHex) < 0 ? a : b;
    final responder = identical(initiator, a) ? b : a;

    final crypto = CryptoService.instance;

    // Initiator's first message: no session yet, but it IS the deterministic
    // initiator, so this should already ride the ratchet.
    await _becomeIdentity(initiator);
    final msg1 = await crypto.encryptMessage(
      plaintext: 'hi, this is message one',
      recipientX25519KeyBase64: responder.x25519PublicKeyBase64,
      recipientPeerId: responder.publicKeyHex,
      recipientSupportsRatchet: true,
    );
    expect(msg1.isRatchet, isTrue);
    expect(msg1.ratchetN, 0);
    expect(await crypto.verifyEncryptedEnvelope(msg1), isTrue);

    // Responder decrypts it, bootstrapping its own session from the
    // initiator's X25519 identity key (the only thing needed to derive the
    // same root key seed via commutative ECDH).
    await _becomeIdentity(responder);
    final plain1 = await crypto.decryptMessage(
      msg1,
      senderX25519KeyBase64: initiator.x25519PublicKeyBase64,
    );
    expect(plain1, 'hi, this is message one');

    // Responder can reply via the ratchet immediately — its first DH ratchet
    // step (triggered by decrypting msg1) already derived a fresh sending
    // chain, so it doesn't need to wait for a second incoming message.
    final msg2 = await crypto.encryptMessage(
      plaintext: 'reply from the responder',
      recipientX25519KeyBase64: initiator.x25519PublicKeyBase64,
      recipientPeerId: initiator.publicKeyHex,
      recipientSupportsRatchet: true,
    );
    expect(msg2.isRatchet, isTrue);
    expect(await crypto.verifyEncryptedEnvelope(msg2), isTrue);

    await _becomeIdentity(initiator);
    final plain2 = await crypto.decryptMessage(
      msg2,
      senderX25519KeyBase64: responder.x25519PublicKeyBase64,
    );
    expect(plain2, 'reply from the responder');

    // A longer back-and-forth keeps working — each side's persisted session
    // survives the identity swap (i.e. survives what would be an app
    // restart / new decrypt call on a real device) and stays in sync.
    for (var i = 0; i < 4; i++) {
      final fromInitiator = i.isEven;
      final sender = fromInitiator ? initiator : responder;
      final recipient = fromInitiator ? responder : initiator;
      await _becomeIdentity(sender);
      final env = await crypto.encryptMessage(
        plaintext: 'round $i',
        recipientX25519KeyBase64: recipient.x25519PublicKeyBase64,
        recipientPeerId: recipient.publicKeyHex,
        recipientSupportsRatchet: true,
      );
      expect(env.isRatchet, isTrue, reason: 'round $i should already be on an established session');

      await _becomeIdentity(recipient);
      final plain = await crypto.decryptMessage(
        env,
        senderX25519KeyBase64: sender.x25519PublicKeyBase64,
      );
      expect(plain, 'round $i');
    }
  });

  test('the deterministic responder cannot ratchet-bootstrap its own first '
      'message — it falls back to the legacy scheme rather than failing',
      () async {
    final a = await _generateIdentity();
    final b = await _generateIdentity();
    final initiator = a.publicKeyHex.compareTo(b.publicKeyHex) < 0 ? a : b;
    final responder = identical(initiator, a) ? b : a;

    final crypto = CryptoService.instance;
    await _becomeIdentity(responder);
    final msg = await crypto.encryptMessage(
      plaintext: 'responder speaks first',
      recipientX25519KeyBase64: initiator.x25519PublicKeyBase64,
      recipientPeerId: initiator.publicKeyHex,
      recipientSupportsRatchet: true,
    );

    // Not ratchet-tagged — but still a perfectly valid, decryptable message
    // via today's scheme. This is the documented scope-cut, not a bug: the
    // second exchange onward gets full ratchet protection either way.
    expect(msg.isRatchet, isFalse);

    await _becomeIdentity(initiator);
    final plain = await crypto.decryptMessage(msg);
    expect(plain, 'responder speaks first');
  });

  test('a peer that has not advertised ratchet support is never sent a '
      'ratchet envelope, even as the deterministic initiator', () async {
    final a = await _generateIdentity();
    final b = await _generateIdentity();
    final initiator = a.publicKeyHex.compareTo(b.publicKeyHex) < 0 ? a : b;
    final responder = identical(initiator, a) ? b : a;

    await _becomeIdentity(initiator);
    final msg = await CryptoService.instance.encryptMessage(
      plaintext: 'legacy only',
      recipientX25519KeyBase64: responder.x25519PublicKeyBase64,
      recipientPeerId: responder.publicKeyHex,
      recipientSupportsRatchet: false,
    );
    expect(msg.isRatchet, isFalse);
  });

  test('a ratchet-tagged message that arrives with no known sender X25519 '
      'key fails closed instead of throwing', () async {
    final a = await _generateIdentity();
    final b = await _generateIdentity();
    final initiator = a.publicKeyHex.compareTo(b.publicKeyHex) < 0 ? a : b;
    final responder = identical(initiator, a) ? b : a;

    await _becomeIdentity(initiator);
    final msg = await CryptoService.instance.encryptMessage(
      plaintext: 'first contact',
      recipientX25519KeyBase64: responder.x25519PublicKeyBase64,
      recipientPeerId: responder.publicKeyHex,
      recipientSupportsRatchet: true,
    );
    expect(msg.isRatchet, isTrue);

    await _becomeIdentity(responder);
    // No senderX25519KeyBase64 passed — nothing to bootstrap a session from.
    final plain = await CryptoService.instance.decryptMessage(msg);
    expect(plain, isNull);
  });
}
