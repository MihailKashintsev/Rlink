import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/crypto_service.dart';
import 'package:rlink/services/gossip_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exercises the real production sign/verify path for 'profile' gossip
/// packets (GossipRouter.broadcastProfile / onPacketReceived) added after a
/// security review found that unsigned profile packets let any mesh/relay
/// peer silently overwrite an already-known contact's X25519 key or claim
/// an arbitrary "linked device" key for a victim — see
/// gossip_router.dart's `_profileSensitiveFieldsCanonical`.
///
/// Same identity-swap pattern as ratchet_dm_integration_test.dart.
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

// Mirrors gossip_router.dart's private `_profileSensitiveFieldsCanonical` —
// intentionally duplicated here (same trade-off as message_search_fts_test.dart)
// so tests (d)/(c) below can hand-craft a forged packet without needing the
// production code to expose it.
String _canonical(String id, String x25519Key, String? linkedDeviceKey, bool rk) =>
    '$id|$x25519Key|${linkedDeviceKey ?? ''}|${rk ? 1 : 0}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

  late GossipPacket? forwarded;
  late List<dynamic>? received;

  setUp(() {
    forwarded = null;
    received = null;
    GossipRouter.instance.onForwardPacket = (packet) async {
      forwarded = packet;
    };
    GossipRouter.instance.onProfileReceived = (
      bleId,
      publicKey,
      nick,
      username,
      color,
      emoji,
      x25519Key,
      tags,
      statusEmojiPayload,
      statusEmojiAutoPayloadJson,
      nickColor,
      birthday,
      supportsRatchet,
      linkedDeviceKey,
      sensitiveFieldsSigned,
    ) {
      received = [publicKey, x25519Key, linkedDeviceKey, sensitiveFieldsSigned];
    };
  });

  test('a genuine profile broadcast verifies and its fields are trusted',
      () async {
    final alice = await _generateIdentity();
    await _becomeIdentity(alice);

    await GossipRouter.instance.broadcastProfile(
      id: alice.publicKeyHex,
      nick: 'Alice',
      color: 1,
      emoji: '',
      x25519Key: alice.x25519PublicKeyBase64,
    );
    expect(forwarded, isNotNull);

    // Re-id before "receiving" it — GossipRouter's own dedup cache already
    // marked the original packet id as seen when broadcastProfile sent it
    // (same singleton acting as both sender and receiver here), so feeding
    // that exact id back in would be silently dropped before ever reaching
    // onProfileReceived. A real second device wouldn't have that entry.
    final asReceived = GossipPacket(
      id: '${forwarded!.id}-received',
      type: forwarded!.type,
      ttl: forwarded!.ttl,
      timestamp: forwarded!.timestamp,
      payload: forwarded!.payload,
    );
    await GossipRouter.instance.onPacketReceived(asReceived.encode());
    expect(received, isNotNull);
    expect(received![0], alice.publicKeyHex);
    expect(received![1], alice.x25519PublicKeyBase64);
    expect(received![3], isTrue, reason: 'genuine signature must verify');
  });

  test(
      'tampering with the X25519 key after signing (e.g. a malicious relay '
      'hop rewriting the packet) is caught as unsigned', () async {
    final alice = await _generateIdentity();
    final mallory = await _generateIdentity();
    await _becomeIdentity(alice);

    await GossipRouter.instance.broadcastProfile(
      id: alice.publicKeyHex,
      nick: 'Alice',
      color: 1,
      emoji: '',
      x25519Key: alice.x25519PublicKeyBase64,
    );
    final packet = forwarded!;
    final tamperedPayload = Map<String, dynamic>.from(packet.payload)
      ..['x'] = mallory.x25519PublicKeyBase64;
    final tamperedPacket = GossipPacket(
      id: '${packet.id}-tampered',
      type: packet.type,
      ttl: packet.ttl,
      timestamp: packet.timestamp,
      payload: tamperedPayload,
    );

    await GossipRouter.instance.onPacketReceived(tamperedPacket.encode());
    expect(received, isNotNull);
    expect(received![1], mallory.x25519PublicKeyBase64);
    expect(received![3], isFalse,
        reason: 'signature was over the original key, not the tampered one');
  });

  test('a profile packet with no signature at all is treated as unsigned',
      () async {
    final alice = await _generateIdentity();
    final packet = GossipPacket(
      id: 'no-sig-packet',
      type: 'profile',
      ttl: 4,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'id': alice.publicKeyHex,
        'nick': 'Alice',
        'color': 1,
        'emoji': '',
        'x': alice.x25519PublicKeyBase64,
      },
    );

    await GossipRouter.instance.onPacketReceived(packet.encode());
    expect(received, isNotNull);
    expect(received![3], isFalse);
  });

  test(
      'an attacker cannot forge a signature that verifies against a '
      "victim's id using the attacker's own key", () async {
    final alice = await _generateIdentity();
    final mallory = await _generateIdentity();

    // Mallory signs the canonical string as if she were Alice, then claims
    // Alice's id in the payload — the classic "linked device" / key
    // substitution forgery this fix exists to stop.
    await _becomeIdentity(mallory);
    final forgedSig = await CryptoService.instance.signUtf8Message(
      _canonical(alice.publicKeyHex, mallory.x25519PublicKeyBase64, null, false),
    );

    final packet = GossipPacket(
      id: 'forged-packet',
      type: 'profile',
      ttl: 4,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'id': alice.publicKeyHex,
        'nick': 'Alice',
        'color': 1,
        'emoji': '',
        'x': mallory.x25519PublicKeyBase64,
        'sig': forgedSig,
      },
    );

    await GossipRouter.instance.onPacketReceived(packet.encode());
    expect(received, isNotNull);
    expect(received![3], isFalse,
        reason: "a signature made with the attacker's key must not verify "
            "against the victim's claimed id");
  });
}
