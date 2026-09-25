import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Decodes gzip bytes from a network peer with hard caps on both ends — a
/// crafted `.rls`/`.rlv`/`.tgs` sticker otherwise decompresses to gigabytes in
/// memory before any content check runs (`GZipDecoder.decodeBytes` has no
/// size limit of its own). Returns null on anything malformed or oversized,
/// matching every caller's existing "unreadable sticker = missing" contract.
///
/// ponytail: still a single in-memory decode, not a streaming one that aborts
/// mid-way — [maxDecompressedBytes] only stops it from being KEPT/used, the
/// transient peak allocation during decode can briefly exceed it. Upgrade to
/// a chunked decoder with an abort callback if that peak itself proves to be
/// the binding constraint (would need a per-platform stream, `archive`'s
/// decoder is single-shot on the fast path).
Uint8List? boundedGunzip(
  List<int> bytes, {
  int maxCompressedBytes = 15 * 1024 * 1024,
  int maxDecompressedBytes = 30 * 1024 * 1024,
}) {
  if (bytes.length > maxCompressedBytes) return null;
  try {
    final out = GZipDecoder().decodeBytes(bytes);
    if (out.length > maxDecompressedBytes) return null;
    return Uint8List.fromList(out);
  } catch (_) {
    return null;
  }
}
