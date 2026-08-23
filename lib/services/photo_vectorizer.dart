import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Turns a photo into a flat-color vector SVG: downscale → k-means color
/// quantization → per-cluster connected-component extraction → Moore-
/// neighbor boundary tracing → Douglas-Peucker simplification → one `<path>`
/// per region. This is the trimmed-down, pure-Dart cousin of
/// tool/vectorize_mascot.py's potrace-based pipeline (same shape: cluster
/// colors, then trace each cluster's regions) — it produces straight-edged
/// polygons rather than potrace's smooth Bezier curves, which is the actual
/// scope cut: no shelling out to a native potrace binary (not available on
/// web, not bundleable into the app) means no Bezier curve fitting either.
/// Douglas-Peucker simplification is what keeps the polygons from looking
/// like raw pixel staircases.
class PhotoVectorizer {
  PhotoVectorizer._();

  /// [colorCount] — how many flat color regions to quantize into (2-12 is
  /// sane; more looks closer to the photo, fewer looks more like a sticker).
  /// [detail] is 0..1 — 0 simplifies aggressively (few points, blocky
  /// outlines), 1 keeps outlines close to the traced pixel boundary.
  /// Returns a self-contained SVG string sized to the (downscaled) working
  /// resolution — callers embed it exactly like any other imported SVG
  /// layer (see rlv_sticker_editor_screen.dart's `_addSvgLayer`), which
  /// already scales an arbitrary-sized SVG to fit the sticker canvas.
  static String vectorize(
    Uint8List pngBytes, {
    int colorCount = 6,
    double detail = 0.5,
  }) {
    final decoded = img.decodePng(pngBytes) ?? img.decodeImage(pngBytes);
    if (decoded == null) {
      throw const FormatException('PhotoVectorizer.vectorize: not a decodable image');
    }
    // Tracing cost is O(pixels); this is plenty of resolution for a sticker
    // silhouette and keeps the whole pipeline well under a second.
    const workingMaxSide = 220;
    final scale = workingMaxSide / math.max(decoded.width, decoded.height);
    final image = scale < 1
        ? img.copyResize(
            decoded,
            width: scale < 1 ? (decoded.width * scale).round().clamp(1, workingMaxSide) : null,
            height: scale < 1 ? (decoded.height * scale).round().clamp(1, workingMaxSide) : null,
            interpolation: img.Interpolation.average,
          )
        : decoded;

    final w = image.width;
    final h = image.height;
    final k = colorCount.clamp(2, 12);
    final quantized = _kmeans(image, k);

    // Epsilon for Douglas-Peucker, in working-resolution pixels: more detail
    // → smaller epsilon (less simplification).
    final epsilon = (1.0 - detail.clamp(0.0, 1.0)) * 3.0 + 0.4;
    final minComponentPixels = math.max(6, (w * h * 0.004).round());

    final buffer = StringBuffer()
      ..writeln('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $w $h" '
          'width="$w" height="$h">');

    // Larger regions first so small detail regions layer visibly on top,
    // same ordering rationale as the Python pipeline's per-color loop.
    final components = <_Component>[];
    for (var c = 0; c < k; c++) {
      components.addAll(_connectedComponents(quantized.labels, w, h, c, minComponentPixels));
    }
    components.sort((a, b) => b.pixelCount.compareTo(a.pixelCount));

    for (final comp in components) {
      final boundary = _traceBoundary(
        comp.contains,
        comp.startX,
        comp.startY,
        comp.pixelCount,
      );
      if (boundary.length < 3) continue;
      final simplified = _douglasPeuckerClosed(boundary, epsilon);
      if (simplified.length < 3) continue;
      final center = quantized.centers[comp.clusterIndex];
      final hex = _toHex(center.$1, center.$2, center.$3);
      final d = StringBuffer('M ${simplified.first.$1} ${simplified.first.$2} ');
      for (final p in simplified.skip(1)) {
        d.write('L ${p.$1} ${p.$2} ');
      }
      d.write('Z');
      buffer.writeln('<path d="$d" fill="$hex"/>');
    }
    buffer.writeln('</svg>');
    return buffer.toString();
  }

  static String _toHex(int r, int g, int b) =>
      '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';
}

class _KMeansResult {
  final Int32List labels;
  final List<(int, int, int)> centers;
  _KMeansResult(this.labels, this.centers);
}

_KMeansResult _kmeans(img.Image image, int k, {int iterations = 6}) {
  final w = image.width;
  final h = image.height;
  final n = w * h;
  final labels = Int32List(n);
  // Deterministic init: k evenly-spaced pixels across the image, not random
  // — makes results reproducible for the same photo+settings.
  final centers = <List<double>>[];
  for (var i = 0; i < k; i++) {
    final idx = (((i + 0.5) * n) / k).floor().clamp(0, n - 1);
    final p = image.getPixel(idx % w, idx ~/ w);
    centers.add([p.r.toDouble(), p.g.toDouble(), p.b.toDouble()]);
  }

  for (var iter = 0; iter < iterations; iter++) {
    final sums = List.generate(k, (_) => [0.0, 0.0, 0.0]);
    final counts = List.filled(k, 0);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
        var best = 0;
        var bestDist = double.infinity;
        for (var c = 0; c < k; c++) {
          final cc = centers[c];
          final dr = r - cc[0], dg = g - cc[1], db = b - cc[2];
          final dist = dr * dr + dg * dg + db * db;
          if (dist < bestDist) {
            bestDist = dist;
            best = c;
          }
        }
        labels[y * w + x] = best;
        sums[best][0] += r;
        sums[best][1] += g;
        sums[best][2] += b;
        counts[best]++;
      }
    }
    for (var c = 0; c < k; c++) {
      if (counts[c] == 0) continue;
      centers[c] = [
        sums[c][0] / counts[c],
        sums[c][1] / counts[c],
        sums[c][2] / counts[c],
      ];
    }
  }

  final intCenters = centers
      .map((c) => (c[0].round().clamp(0, 255), c[1].round().clamp(0, 255), c[2].round().clamp(0, 255)))
      .toList();
  return _KMeansResult(labels, intCenters);
}

class _Component {
  final int clusterIndex;
  final int startX;
  final int startY;
  final int pixelCount;
  final Set<int> _indices;
  final int _w;

  _Component(this.clusterIndex, this.startX, this.startY, this.pixelCount, this._indices, this._w);

  bool contains(int x, int y) => _indices.contains(y * _w + x);
}

/// Flood-fills every connected region (4-connectivity) of [labels] equal to
/// [clusterIndex], dropping anything smaller than [minPixels] as noise.
List<_Component> _connectedComponents(
  Int32List labels,
  int w,
  int h,
  int clusterIndex,
  int minPixels,
) {
  final visited = List<bool>.filled(w * h, false);
  final out = <_Component>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = y * w + x;
      if (visited[idx] || labels[idx] != clusterIndex) continue;
      final stack = <int>[idx];
      visited[idx] = true;
      final indices = <int>{};
      // (x, y) is guaranteed to be this component's topmost-then-leftmost
      // pixel: raster scan visits every earlier position first, so any
      // same-component pixel preceding it in scan order would already be
      // visited — Moore-neighbor tracing below relies on exactly this.
      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        indices.add(cur);
        final cx = cur % w, cy = cur ~/ w;
        for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
          final nx = cx + dx, ny = cy + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final nidx = ny * w + nx;
          if (visited[nidx] || labels[nidx] != clusterIndex) continue;
          visited[nidx] = true;
          stack.add(nidx);
        }
      }
      if (indices.length >= minPixels) {
        out.add(_Component(clusterIndex, x, y, indices.length, indices, w));
      }
    }
  }
  return out;
}

/// Moore-neighbor boundary tracing: walks the outer edge of a connected
/// region one pixel at a time, always scanning the 8 neighbors clockwise
/// starting just past the direction it arrived from. [startX]/[startY] must
/// be the topmost-then-leftmost pixel of the component (guaranteed by
/// [_connectedComponents]'s raster-scan discovery order), so the pixel to
/// its west is guaranteed background — the standard initial backtrack point.
List<(int, int)> _traceBoundary(
  bool Function(int, int) isFg,
  int startX,
  int startY,
  int componentPixelCount,
) {
  const dx = [1, 1, 0, -1, -1, -1, 0, 1]; // E, SE, S, SW, W, NW, N, NE
  const dy = [0, 1, 1, 1, 0, -1, -1, -1];

  int dirOf(int fx, int fy, int tx, int ty) {
    final ddx = tx - fx, ddy = ty - fy;
    for (var i = 0; i < 8; i++) {
      if (dx[i] == ddx && dy[i] == ddy) return i;
    }
    throw StateError('non-adjacent boundary step');
  }

  final boundary = <(int, int)>[(startX, startY)];
  var cx = startX, cy = startY;
  var bx = startX - 1, by = startY;
  // A legitimate boundary visits roughly O(sqrt(area)) to O(area) pixels
  // depending on how spindly the shape is; scaling the safety cap by the
  // component's own pixel count (instead of one large global constant)
  // keeps a pathological 1-pixel-wide sliver — the kind photo gradients
  // produce in abundance at a high color count — from burning tens of
  // thousands of steps it was never going to legitimately need.
  final maxSteps = math.min(200000, componentPixelCount * 8 + 64);

  for (var step = 0; step < maxSteps; step++) {
    final backDir = dirOf(cx, cy, bx, by);
    int? foundDir;
    var nx = 0, ny = 0;
    for (var i = 1; i <= 8; i++) {
      final dir = (backDir + i) % 8;
      final tx = cx + dx[dir], ty = cy + dy[dir];
      if (isFg(tx, ty)) {
        foundDir = dir;
        nx = tx;
        ny = ty;
        break;
      }
    }
    if (foundDir == null) break; // isolated single-pixel component
    final prevDir = (foundDir - 1 + 8) % 8;
    bx = cx + dx[prevDir];
    by = cy + dy[prevDir];
    cx = nx;
    cy = ny;
    if (cx == startX && cy == startY) break;
    boundary.add((cx, cy));
  }
  return boundary;
}

/// Douglas-Peucker over a closed loop: recurses on the open list between its
/// first and last point (the loop's "seam"), which for a boundary that
/// starts and ends adjacent to each other is a fine approximation — the
/// polygon closes back to its start with an implicit `Z` in the SVG path.
List<(double, double)> _douglasPeuckerClosed(List<(int, int)> pts, double epsilon) {
  final asDouble = pts.map((p) => (p.$1.toDouble(), p.$2.toDouble())).toList();
  return _douglasPeucker(asDouble, epsilon);
}

List<(double, double)> _douglasPeucker(List<(double, double)> pts, double epsilon) {
  if (pts.length < 3) return pts;
  double perpDist((double, double) p, (double, double) a, (double, double) b) {
    final abx = b.$1 - a.$1, aby = b.$2 - a.$2;
    final len2 = abx * abx + aby * aby;
    if (len2 == 0) {
      final dx = p.$1 - a.$1, dy = p.$2 - a.$2;
      return math.sqrt(dx * dx + dy * dy);
    }
    final t = ((p.$1 - a.$1) * abx + (p.$2 - a.$2) * aby) / len2;
    final projX = a.$1 + t * abx, projY = a.$2 + t * aby;
    final dx = p.$1 - projX, dy = p.$2 - projY;
    return math.sqrt(dx * dx + dy * dy);
  }

  var maxDist = 0.0;
  var splitIndex = 0;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = perpDist(pts[i], pts.first, pts.last);
    if (d > maxDist) {
      maxDist = d;
      splitIndex = i;
    }
  }
  if (maxDist > epsilon) {
    final left = _douglasPeucker(pts.sublist(0, splitIndex + 1), epsilon);
    final right = _douglasPeucker(pts.sublist(splitIndex), epsilon);
    return [...left.sublist(0, left.length - 1), ...right];
  }
  return [pts.first, pts.last];
}
