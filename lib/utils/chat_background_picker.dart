import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'web_file_store.dart';

/// Lets the user pick a chat wallpaper and stores it durably. On web the bytes
/// go to OPFS (an `opfs://` path renderable via `storedImage`); on native the
/// file is copied into the app documents folder (a picker's temp path can vanish).
Future<String?> pickAndStoreChatBackground() async {
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (picked == null) return null;
  final ts = DateTime.now().millisecondsSinceEpoch;
  if (kIsWeb) {
    final bytes = await picked.readAsBytes();
    return writeWebStoredFile(
      fileName: 'chat_bg_$ts.jpg',
      bytes: bytes,
      mimeType: webMimeForFileName(picked.name.isEmpty ? 'bg.jpg' : picked.name),
    );
  }
  final dir = await getApplicationDocumentsDirectory();
  final dest = File(p.join(dir.path, 'chat_bg_$ts.jpg'));
  await File(picked.path).copy(dest.path);
  return dest.path;
}
