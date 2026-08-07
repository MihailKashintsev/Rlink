import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../main.dart' show broadcastMyBanner, sendProfileToAllContacts;
import '../../models/user_profile.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/profile_service.dart';
import 'avatar_widget.dart';
import 'desktop_image_picker.dart';

// Direct profile edits for the settings tiles — pick straight into the
// gallery / emoji picker, save, and broadcast (same propagation as the full
// profile editor's Save).

Future<String?> _pickBannerPath(BuildContext context) async {
  if (kIsWeb) {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    final bytes = r?.files.single.bytes;
    if (bytes == null) return null;
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    const maxEdge = 1280;
    final resized = (decoded.width > maxEdge || decoded.height > maxEdge)
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? maxEdge : null,
            height: decoded.height > decoded.width ? maxEdge : null,
            interpolation: img.Interpolation.average,
          )
        : decoded;
    final jpg = img.encodeJpg(resized, quality: 72);
    if (jpg.length > 500 * 1024) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Баннер слишком большой. Выберите меньше.')),
        );
      }
      return null;
    }
    return 'data:image/jpeg;base64,${base64Encode(jpg)}';
  }
  final raw = await pickImagePathDesktopAware(imagePicker: ImagePicker());
  if (raw == null) return null;
  return ImageService.instance.compressAndSave(raw, maxSize: 1200);
}

void _broadcastMeta(UserProfile p) {
  sendProfileToAllContacts();
  GossipRouter.instance.broadcastProfile(
    id: p.publicKeyHex,
    nick: p.nickname,
    username: p.username,
    color: p.avatarColor,
    emoji: p.avatarEmoji,
    x25519Key: CryptoService.instance.x25519PublicKeyBase64,
    tags: p.tags,
    statusEmoji: p.statusEmoji,
    nickColor: p.nickColor,
    birthday: p.birthday,
  );
}

/// Pick a new banner straight from the gallery and propagate it.
Future<void> quickChangeBanner(BuildContext context) async {
  final path = await _pickBannerPath(context);
  if (path == null) return;
  final updated =
      await ProfileService.instance.updateProfile(bannerImagePath: path);
  _broadcastMeta(updated);
  unawaited(broadcastMyBanner());
}

/// Open the emoji picker straight for the status emoji and propagate it.
Future<void> quickChangeStatusEmoji(BuildContext context) async {
  final current = ProfileService.instance.profile?.statusEmoji ?? '';
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
          height: 380,
          child: AvatarEmojiPicker(
            selected: current,
            onSelected: (e) async {
              Navigator.pop(ctx);
              final updated = await ProfileService.instance
                  .updateProfile(statusEmoji: e);
              _broadcastMeta(updated);
            },
          ),
        ),
      ),
    ),
  );
}
