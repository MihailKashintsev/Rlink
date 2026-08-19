import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ui/screens/onboarding_screen.dart';
import 'app_settings.dart';
import 'ble_service.dart';
import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'contact_trust_service.dart';
import 'crypto_service.dart';
import 'emoji_pack_service.dart';
import 'gigachat_service.dart';
import 'group_service.dart';
import 'media_upload_queue.dart';
import 'profile_service.dart';
import 'relay_service.dart';
import 'sticker_collection_service.dart';
import 'story_service.dart';

/// The old device's side of account transfer: wipe everything, same
/// structure as `rlinkPerformFullAppReset`, but NOT a call-through — three
/// real differences from a plain factory reset:
/// 1. Also unlinks any active companion-device link (stale after the
///    identity that owned it is gone) and clears contact-trust/sticker/
///    emoji-pack state — gaps the plain reset already had, worth fixing
///    here regardless since this wipe is meant to be thorough by design.
/// 2. DOES call `CryptoService.regenerateKeys()`, same as the plain reset —
///    this isn't just parity, it's required here specifically: wiping
///    secure storage alone leaves the OLD private key live in THIS
///    process's memory and still connected to the relay under the
///    transferred pubkey until the app is force-quit and relaunched. That
///    would mean two devices both able to act as the transferred identity
///    at once — exactly the dual-live-identity risk this feature's
///    handshake was designed to avoid on the new device's side. Immediately
///    regenerating drops the old identity from the live connection right
///    away rather than leaving that window open.
/// 3. Only ever called after `AccountTransferService` has a verified
///    completion ack from the new device (or the user explicitly forces it
///    via the "wipe anyway" fallback for a dropped-ack edge case) — the
///    caller (`AccountTransferApproveScreen`) enforces that gate, not this
///    function.
Future<void> rlinkPerformAccountTransferWipe(BuildContext context) async {
  try {
    await BleService.instance.stop();
  } catch (_) {}
  BleService.instance.clearMappings();
  await ChatStorageService.instance.resetAll();
  await ChannelService.instance.resetAll();
  await GroupService.instance.resetAll();
  await StoryService.instance.reset();
  await MediaUploadQueue.instance.clearAll();
  try {
    await StickerCollectionService.instance.resetAll();
  } catch (_) {}
  try {
    await EmojiPackService.instance.resetAll();
  } catch (_) {}
  try {
    await ContactTrustService.instance.clearAll();
  } catch (_) {}
  try {
    await AppSettings.instance.unlinkDevice();
  } catch (_) {}
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );
  await storage.deleteAll();
  await GigachatService.instance.clear();
  await CryptoService.instance.regenerateKeys();
  try {
    RelayService.instance.reconnect();
  } catch (_) {}
  ProfileService.instance.clearProfile();
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const OnboardingScreen()),
    (route) => false,
  );
}
