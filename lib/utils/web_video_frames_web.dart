import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

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
