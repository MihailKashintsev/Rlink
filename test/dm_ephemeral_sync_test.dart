import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/gossip_router.dart';

/// Disappearing-messages timer sync: setting it on one side must reach the
/// other so both devices purge on the same schedule — otherwise only the
/// sender's copy would ever vanish. Exercises the real
/// sendDmEphemeralSetting -> onPacketReceived -> onDmEphemeral path (plaintext,
/// like dm_pin — no crypto involved, so no identity setup needed here).
void main() {
  test('sendDmEphemeralSetting delivers the duration and sender to onDmEphemeral', () async {
    final router = GossipRouter.instance;
    GossipPacket? forwarded;
    router.onForwardPacket = (packet) async => forwarded = packet;

    Map<String, dynamic>? received;
    router.onDmEphemeral = (payload) async => received = payload;
    addTearDown(() {
      router.onForwardPacket = null;
      router.onDmEphemeral = null;
      router.myPublicKey = null;
    });

    final sender = 'a' * 64;
    final recipient = 'b' * 64;
    // _matchesRecipient needs to see the recipient as "us", or the directed
    // dm_ephemeral packet is dropped before reaching onDmEphemeral.
    router.myPublicKey = recipient;
    await router.sendDmEphemeralSetting(
      recipientId: recipient,
      durationSeconds: 3600,
      fromId: sender,
    );

    expect(forwarded, isNotNull);
    expect(forwarded!.type, 'dm_ephemeral');
    expect(forwarded!.payload['sec'], 3600);
    expect(forwarded!.payload['from'], sender);

    // Simulate the recipient's router receiving this packet — re-id it
    // first, since GossipRouter's own dedup cache already marked the
    // original id "seen" the moment it was sent (same singleton acting as
    // both sender and receiver here; a real second device wouldn't have
    // that entry — see profile_gossip_signature_test.dart for the same fix).
    final asReceived = GossipPacket(
      id: '${forwarded!.id}-received',
      type: forwarded!.type,
      ttl: forwarded!.ttl,
      timestamp: forwarded!.timestamp,
      recipientId: forwarded!.recipientId,
      payload: forwarded!.payload,
    );
    await router.onPacketReceived(asReceived.encode());
    expect(received, isNotNull);
    expect(received!['sec'], 3600);
    expect(received!['from'], sender);
  });

  test('durationSeconds null/0 turns the timer off (sec: 0)', () async {
    final router = GossipRouter.instance;
    GossipPacket? forwarded;
    router.onForwardPacket = (packet) async => forwarded = packet;
    addTearDown(() => router.onForwardPacket = null);

    await router.sendDmEphemeralSetting(
      recipientId: 'b' * 64,
      durationSeconds: null,
      fromId: 'a' * 64,
    );

    expect(forwarded!.payload['sec'], 0);
  });
}
