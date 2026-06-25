import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../utils/web_file_store.dart';
import 'platform_layout.dart';

// Cache of decoded OPFS image bytes so that scrolling a feed (which recycles
// list items) doesn't re-read from OPFS each time — the async gap produced a
// 0-height placeholder → full-height image flip on every recycle, i.e. scroll
// jitter. Bounded LRU.
final Map<String, Uint8List> _webImgCache = {};
final List<String> _webImgCacheOrder = [];
void _cacheWebImg(String path, Uint8List b) {
  if (_webImgCache.containsKey(path)) return;
  _webImgCache[path] = b;
  _webImgCacheOrder.add(path);
  if (_webImgCacheOrder.length > 80) {
    _webImgCache.remove(_webImgCacheOrder.removeAt(0));
  }
}

/// Web-safe image for a channel path that may be a `data:` URL, an OPFS web
/// path, or a native file path. Never touches dart:io File on web.
Widget _feedImg(String path,
    {required BoxFit fit, double? width, double? height}) {
  Widget broken() => const SizedBox.shrink();
  // Reserve vertical space while loading so the post height stays stable.
  Widget loadingBox() =>
      SizedBox(width: width == double.infinity ? null : width, height: 200);
  if (path.startsWith('data:')) {
    return Image.network(path,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, __, ___) => broken());
  }
  if (kIsWeb) {
    if (!isWebStoredFile(path)) return broken();
    final cached = _webImgCache[path];
    if (cached != null) {
      return Image.memory(cached,
          width: width,
          height: height,
          fit: fit,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => broken());
    }
    return FutureBuilder<Uint8List?>(
      future: readWebStoredFile(path),
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) return loadingBox();
        final b = snap.data;
        if (b == null || b.isEmpty) return broken();
        _cacheWebImg(path, b);
        return Image.memory(b,
            width: width,
            height: height,
            fit: fit,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => broken());
      },
    );
  }
  final f = File(path);
  if (!f.existsSync()) return broken();
  return Image.file(f,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, __, ___) => broken());
}

/// Картинка в ленте канала / шапке поста: на ПК — компактнее, без полноэкранной ширины.
class ChannelFeedImage extends StatelessWidget {
  final String resolvedPath;
  final bool isSticker;

  const ChannelFeedImage({
    super.key,
    required this.resolvedPath,
    this.isSticker = false,
  });

  @override
  Widget build(BuildContext context) {
    final pc = isDesktopShell();
    final sw = MediaQuery.sizeOf(context).width;
    if (isSticker && !pc) {
      return _feedImg(resolvedPath, width: 132, height: 132, fit: BoxFit.cover);
    }
    if (!pc) {
      return _feedImg(resolvedPath, width: double.infinity, fit: BoxFit.cover);
    }
    final maxW = isSticker ? 132.0 : (sw * 0.38).clamp(200.0, 360.0);
    final maxH = isSticker ? 132.0 : 280.0;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
        child: _feedImg(resolvedPath,
            fit: isSticker ? BoxFit.cover : BoxFit.contain),
      ),
    );
  }
}

/// Вложение-картинка в пузырьке комментария (уже узкий; на ПК чуть меньше и без жёсткого кропа).
class ChannelCommentImage extends StatelessWidget {
  final String resolvedPath;

  const ChannelCommentImage({super.key, required this.resolvedPath});

  @override
  Widget build(BuildContext context) {
    final pc = isDesktopShell();
    final maxW = pc ? 168.0 : 200.0;
    final maxH = pc ? 200.0 : 240.0;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
      child: _feedImg(resolvedPath, fit: BoxFit.contain),
    );
  }
}
