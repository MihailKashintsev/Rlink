import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

/// Extracts a single aspect-preserved poster frame (JPEG bytes) from a video
/// [url], capped to [maxSide] on the long edge. Null on failure.
Future<Uint8List?> webVideoPoster(String url, {int maxSide = 480}) async {
  final video = html.VideoElement()
    ..src = url
    ..muted = true
    ..preload = 'auto';
  video.setAttribute('playsinline', 'true');
  video.style
    ..position = 'fixed'
    ..left = '-9999px'
    ..width = '2px'
    ..height = '2px';
  html.document.body?.append(video);
  try {
    await video.onLoadedMetadata.first.timeout(const Duration(seconds: 6));
    final vw = video.videoWidth;
    final vh = video.videoHeight;
    if (vw <= 0 || vh <= 0) return null;
    final dur = video.duration;
    video.currentTime =
        (dur.isFinite && dur > 0) ? math.min(0.1, dur / 2) : 0.0;
    await video.onSeeked.first.timeout(const Duration(seconds: 4));
    final scale = (vw >= vh ? maxSide / vw : maxSide / vh).clamp(0.0, 1.0);
    final w = math.max(1, (vw * scale).round());
    final h = math.max(1, (vh * scale).round());
    final canvas = html.CanvasElement(width: w, height: h);
    canvas.context2D.drawImageScaledFromSource(video, 0, 0, vw, vh, 0, 0, w, h);
    final dataUrl = canvas.toDataUrl('image/jpeg', 0.72);
    final comma = dataUrl.indexOf(',');
    return comma > 0 ? base64Decode(dataUrl.substring(comma + 1)) : null;
  } catch (_) {
    return null;
  } finally {
    try {
      video.pause();
      video.removeAttribute('src');
      video.load();
      video.remove();
    } catch (_) {}
  }
}

/// Extracts [count] evenly-spaced frame thumbnails from a video [url]
/// (blob/object URL) using a hidden <video> + <canvas>. Returns JPEG bytes per
/// frame; empty on failure.
Future<List<Uint8List>> webVideoThumbnails(String url, {int count = 8}) async {
  final video = html.VideoElement()
    ..src = url
    ..muted = true
    ..preload = 'auto';
  video.setAttribute('playsinline', 'true');
  video.style
    ..position = 'fixed'
    ..left = '-9999px'
    ..width = '2px'
    ..height = '2px';
  html.document.body?.append(video);
  final thumbs = <Uint8List>[];
  try {
    await video.onLoadedMetadata.first.timeout(const Duration(seconds: 6));
    final dur = video.duration;
    if (dur.isNaN || dur.isInfinite || dur <= 0) return thumbs;
    const w = 96;
    const h = 96;
    final canvas = html.CanvasElement(width: w, height: h);
    final ctx = canvas.context2D;
    for (var i = 0; i < count; i++) {
      final t = dur * (i + 0.5) / count;
      video.currentTime = t;
      await video.onSeeked.first.timeout(const Duration(seconds: 4));
      final vw = video.videoWidth;
      final vh = video.videoHeight;
      if (vw <= 0 || vh <= 0) continue;
      ctx.drawImageScaledFromSource(video, 0, 0, vw, vh, 0, 0, w, h);
      final dataUrl = canvas.toDataUrl('image/jpeg', 0.55);
      final comma = dataUrl.indexOf(',');
      if (comma > 0) {
        thumbs.add(base64Decode(dataUrl.substring(comma + 1)));
      }
    }
  } catch (_) {
  } finally {
    try {
      video.pause();
      video.removeAttribute('src');
      video.load();
      video.remove();
    } catch (_) {}
  }
  return thumbs;
}
