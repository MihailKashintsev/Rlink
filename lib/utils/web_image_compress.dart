import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Compress image [input] bytes to a small JPEG `data:` URL — web-safe (no
/// dart:io). Used for avatars/banners on web where there's no file path.
/// Returns null if the image can't be decoded or stays too large (>500 KB,
/// to avoid blowing up localStorage/IndexedDB quotas).
Future<String?> webCompressedImageDataUrl(
  Uint8List input, {
  required bool isBanner,
}) async {
  try {
    final decoded = img.decodeImage(input);
    if (decoded == null) return null;
    final maxEdge = isBanner ? 1280 : 512;
    final resized = (decoded.width > maxEdge || decoded.height > maxEdge)
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? maxEdge : null,
            height: decoded.height > decoded.width ? maxEdge : null,
            interpolation: img.Interpolation.average,
          )
        : decoded;
    final quality = isBanner ? 72 : 68;
    final jpg = img.encodeJpg(resized, quality: quality);
    if (jpg.length > 500 * 1024) return null;
    return 'data:image/jpeg;base64,${base64Encode(jpg)}';
  } catch (_) {
    return null;
  }
}

/// Decode a `data:...;base64,...` URL into bytes (web-safe). Null if not a
/// base64 data URL.
Uint8List? bytesFromDataUrl(String value) {
  try {
    if (!value.startsWith('data:')) return null;
    final comma = value.indexOf(',');
    if (comma < 0) return null;
    final meta = value.substring(0, comma);
    final data = value.substring(comma + 1);
    if (!meta.contains(';base64')) return null;
    return base64Decode(data);
  } catch (_) {
    return null;
  }
}
