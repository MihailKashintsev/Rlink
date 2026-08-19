import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Telegram sticker interop: **.tgs** — playback/import only, never editable
/// in Rlink's own vector studio (converting arbitrary Lottie/Bodymovin JSON
/// into our simpler shape/path schema is out of scope). A `.tgs` file IS
/// gzip-compressed Lottie JSON; rendering is handled entirely by the `lottie`
/// package (see `lib/ui/widgets/tgs_sticker_view.dart`) — hand-rolling a
/// Lottie parser was explicitly rejected as bad engineering given the size of
/// that spec (keyframed bezier paths, gradients, masks, trim paths).
const String tgsFileExtension = '.tgs';

/// MIME used when a `.tgs` travels as a `data:` URL (web collection).
const String tgsMimeType = 'application/x-tgsticker';

/// Is this renderable ref a Telegram sticker? Same two shapes as
/// [looksLikeRlsRef]/[looksLikeRlvRef].
bool looksLikeTgsRef(String ref) {
  if (ref.startsWith('data:')) return ref.startsWith('data:$tgsMimeType');
  return ref.split('#').first.split('?').first.toLowerCase().endsWith(
        tgsFileExtension,
      );
}

/// Ungzips a `.tgs` file into raw Lottie JSON bytes, ready for
/// `Lottie.memory(...)`. Returns null on any malformed/foreign input rather
/// than throwing, matching `.rls`/`.rlv`'s decode contract — an unreadable
/// sticker reads as "missing", never a crash.
Uint8List? gunzipTgsToLottieJson(Uint8List tgsBytes) {
  try {
    final jsonBytes = Uint8List.fromList(GZipDecoder().decodeBytes(tgsBytes));
    final decoded = jsonDecode(utf8.decode(jsonBytes));
    if (decoded is! Map) return null;
    return jsonBytes;
  } catch (_) {
    return null;
  }
}
