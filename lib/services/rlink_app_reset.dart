import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ui/screens/onboarding_screen.dart';
import 'ble_service.dart';
import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gigachat_service.dart';
import 'group_service.dart';
import 'media_upload_queue.dart';
import 'profile_service.dart';
import 'relay_service.dart';
import 'story_service.dart';

/// Полный сброс приложения и переход на экран регистрации.
Future<void> rlinkPerformFullAppReset(BuildContext context) async {
  try {
    await BleService.instance.stop();
  } catch (_) {}
  BleService.instance.clearMappings();
  try {
    await ChatStorageService.instance.resetAll();
  } catch (_) {}
  try {
    await ChannelService.instance.resetAll();
  } catch (_) {}
  try {
    await GroupService.instance.resetAll();
  } catch (_) {}
  try {
    await StoryService.instance.reset();
  } catch (_) {}
  try {
    await MediaUploadQueue.instance.clearAll();
  } catch (_) {}
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );
  try {
    await storage.deleteAll();
  } catch (_) {}
  try {
    await GigachatService.instance.clear();
  } catch (_) {}
  try {
    await CryptoService.instance.regenerateKeys();
  } catch (_) {}
  try {
    RelayService.instance.reconnect();
  } catch (_) {}
  try {
    await ProfileService.instance.clearProfile();
  } catch (_) {}
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const OnboardingScreen()),
    (route) => false,
  );
}
