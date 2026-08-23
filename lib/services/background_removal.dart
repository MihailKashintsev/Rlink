import 'dart:collection';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Flood-fills the background out of a photo: estimates the background color
/// from the border pixels' average, then erases every pixel within
/// [tolerance] of that color that's reachable from the border without
/// crossing a pixel outside that tolerance — the same "magic wand from the
/// edges" idea that cleaned the white halo off the mascot stickers earlier
/// in this codebase's history (see tool/vectorize_mascot.py's topological
/// background-pocket detection for the more elaborate cousin of this idea).
///
/// Using one estimated reference color (rather than comparing each pixel to
/// whichever neighbor reached it) keeps the result predictable: a subject
/// that happens to touch the image border is never erased just because it's
/// on an edge — only pixels that actually look like the background do.
class BackgroundRemoval {
  BackgroundRemoval._();

  /// [tolerance] is 0..1 — 0 only erases pixels matching the estimated
  /// background color exactly, 1 is loose enough to potentially eat into the
  /// subject. Callers should offer this as a live slider with a preview;
  /// there's no single tolerance that's right for every photo.
  static Uint8List remove(Uint8List pngBytes, {double tolerance = 0.12}) {
    final image = img.decodePng(pngBytes) ?? img.decodeImage(pngBytes);
    if (image == null) {
      throw const FormatException('BackgroundRemoval.remove: not a decodable image');
    }
    final w = image.width;
    final h = image.height;

    var sumR = 0, sumG = 0, sumB = 0, count = 0;
    void sample(int x, int y) {
      final p = image.getPixel(x, y);
      sumR += p.r.toInt();
      sumG += p.g.toInt();
      sumB += p.b.toInt();
      count++;
    }

    for (var x = 0; x < w; x++) {
      sample(x, 0);
      sample(x, h - 1);
    }
    for (var y = 0; y < h; y++) {
      sample(0, y);
      sample(w - 1, y);
    }
    final bgR = sumR / count;
    final bgG = sumG / count;
    final bgB = sumB / count;

    // Max possible per-channel-squared distance is 3*255^2; square the
    // tolerance fraction of that so the inner loop can compare without sqrt.
    final maxDistSq = 3 * 255 * 255 * tolerance.clamp(0.0, 1.0) * tolerance.clamp(0.0, 1.0);

    bool looksLikeBackground(img.Pixel p) {
      final dr = p.r - bgR, dg = p.g - bgG, db = p.b - bgB;
      return (dr * dr + dg * dg + db * db) <= maxDistSq;
    }

    final visited = List<bool>.filled(w * h, false);
    final queue = Queue<int>();

    void seed(int x, int y) {
      final idx = y * w + x;
      if (visited[idx]) return;
      if (!looksLikeBackground(image.getPixel(x, y))) return;
      visited[idx] = true;
      queue.add(idx);
    }

    for (var x = 0; x < w; x++) {
      seed(x, 0);
      seed(x, h - 1);
    }
    for (var y = 0; y < h; y++) {
      seed(0, y);
      seed(w - 1, y);
    }

    const dxs = [-1, 1, 0, 0];
    const dys = [0, 0, -1, 1];

    while (queue.isNotEmpty) {
      final idx = queue.removeFirst();
      final x = idx % w;
      final y = idx ~/ w;
      final p = image.getPixel(x, y);
      image.setPixelRgba(x, y, p.r, p.g, p.b, 0);
      for (var i = 0; i < 4; i++) {
        final nx = x + dxs[i];
        final ny = y + dys[i];
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        final nidx = ny * w + nx;
        if (visited[nidx]) continue;
        if (!looksLikeBackground(image.getPixel(nx, ny))) continue;
        visited[nidx] = true;
        queue.add(nidx);
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }
}
