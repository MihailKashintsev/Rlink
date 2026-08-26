import 'package:flutter/foundation.dart';

import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'peer_key_directory.dart';

/// The cheapest correct step toward "real" multi-session: rather than one
/// shared identity fanned out by a redesigned relay/crypto layer, each of
/// your devices keeps its own separate identity (exactly like today's
/// device-linking already does) — a sender who knows a contact has a linked
/// device just also encrypts and sends a second copy there. Zero relay or
/// protocol changes: the linked device is just another peer with its own
/// key, already reachable through the exact same send path.
///
/// Deliberate scope-cut, stated plainly: this covers OUTGOING fan-out (so a
/// message someone sends you shows up on both your devices) and the
/// receiving side already merges history from both keys (see
/// `ChatStorageService.getMessages`/`chatUpdatesFor`). What's NOT covered
/// yet: chat_list_screen.dart's conversation list still groups purely by
/// `peer_id`, so if your linked device receives a message addressed
/// directly to it (rather than fanned out from a contact who doesn't know
/// about the link yet), it can show as a separate list row until that
/// contact's client learns the link and starts fanning out too.
class LinkedDeviceFanout {
  LinkedDeviceFanout._();

  /// Best-effort: any failure here (no linked device, its key not known
  /// yet, network hiccup) is silently swallowed — the PRIMARY send this
  /// accompanies has already gone through by the time this runs, so a
  /// contact never fails to receive a message just because their linked
  /// device happened to be unreachable for the fan-out copy.
  static Future<void> alsoSendToLinkedDevice({
    required String primaryRecipientPeerId,
    required String plaintext,
    required String senderMyId,
    required String messageId,
    double? latitude,
    double? longitude,
    String? replyToMessageId,
  }) async {
    try {
      final contact =
          await ChatStorageService.instance.getContact(primaryRecipientPeerId);
      final linkedKey = contact?.linkedDeviceKey;
      if (linkedKey == null || linkedKey.isEmpty) return;
      final x25519 = PeerKeyDirectory.instance.getX25519(linkedKey);
      if (x25519 == null || x25519.isEmpty) return;

      final encrypted = await CryptoService.instance.encryptMessage(
        plaintext: plaintext,
        recipientX25519KeyBase64: x25519,
        recipientPeerId: linkedKey,
        recipientSupportsRatchet:
            PeerKeyDirectory.instance.supportsRatchet(linkedKey),
      );
      await GossipRouter.instance.sendEncryptedMessage(
        encrypted: encrypted,
        senderId: senderMyId,
        recipientId: linkedKey,
        // Same id as the primary send — these are two copies of one
        // logical message, not two messages, and each recipient device
        // has its own independent local DB so there's no collision risk.
        messageId: messageId,
        latitude: latitude,
        longitude: longitude,
        replyToMessageId: replyToMessageId,
      );
    } catch (e) {
      debugPrint('[RLINK][LinkedDeviceFanout] failed (non-fatal): $e');
    }
  }
}
