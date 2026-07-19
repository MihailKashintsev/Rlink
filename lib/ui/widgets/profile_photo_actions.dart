import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../main.dart' show broadcastMyAvatar;
import '../../services/image_service.dart';
import '../../services/profile_service.dart';
import 'avatar_crop_screen.dart';
import 'desktop_image_picker.dart';

/// Pick a new profile photo and save + broadcast it directly — no profile-edit
/// screen needed (the avatar is managed via its long-press menu; the edit screen
/// handles everything else). Returns true if the photo changed.
Future<bool> pickAndSaveProfileAvatar(BuildContext context) async {
  // Сначала получаем исходные байты (web/native), затем ОБЯЗАТЕЛЬНО показываем
  // экран обрезки с круглым предпросмотром — так пользователь видит, как аватар
  // обрежется, и результат всегда квадратный (не растягивается).
  Uint8List? srcBytes;
  if (kIsWeb) {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    srcBytes = r?.files.single.bytes;
  } else {
    final raw = await pickImagePathDesktopAware(imagePicker: ImagePicker());
    if (raw != null) srcBytes = await File(raw).readAsBytes();
  }
  if (srcBytes == null) return false;
  if (!context.mounted) return false;

  final cropped = await Navigator.of(context).push<Uint8List?>(
    MaterialPageRoute(builder: (_) => AvatarCropScreen(imageBytes: srcBytes!)),
  );
  if (cropped == null) return false; // отменил обрезку

  String? newPath;
  if (kIsWeb) {
    final dataUrl = webAvatarDataUrl(cropped);
    if (dataUrl == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Фото слишком большое. Выберите меньше.')),
        );
      }
      return false;
    }
    newPath = dataUrl;
  } else {
    newPath = await ImageService.instance.saveAvatarFromBytes(cropped);
  }
  await ProfileService.instance.updateProfile(
    setAvatarImagePath: true,
    avatarImagePath: newPath,
  );
  unawaited(broadcastMyAvatar());
  return true;
}

/// Remove the profile photo and broadcast the change.
Future<void> deleteProfileAvatar() async {
  await ProfileService.instance.updateProfile(
    setAvatarImagePath: true,
    avatarImagePath: null,
  );
  unawaited(broadcastMyAvatar());
}

/// Downscale + JPEG-encode picked avatar bytes into a data-URL (web-safe
/// avatar storage). Public: reused by the group avatar picker.
String? webAvatarDataUrl(Uint8List input) {
  try {
    final decoded = img.decodeImage(input);
    if (decoded == null) return null;
    const maxEdge = 512;
    final resized = (decoded.width > maxEdge || decoded.height > maxEdge)
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? maxEdge : null,
            height: decoded.height > decoded.width ? maxEdge : null,
            interpolation: img.Interpolation.average,
          )
        : decoded;
    final jpg = img.encodeJpg(resized, quality: 68);
    if (jpg.length > 500 * 1024) return null;
    return 'data:image/jpeg;base64,${base64Encode(jpg)}';
  } catch (_) {
    return null;
  }
}
