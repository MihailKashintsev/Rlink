import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../models/rls_sticker.dart';
import '../../models/rlv_sticker.dart';
import '../../models/tgs_sticker.dart';
import '../../utils/web_file_store.dart';
import 'platform_layout.dart';
import 'rls_sticker_view.dart';
import 'rlv_sticker_view.dart';
import 'tgs_sticker_view.dart';

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
Widget storedImage(String path,
    {required BoxFit fit, double? width, double? height}) {
  Widget broken() => const SizedBox.shrink();
  // Reserve vertical space while loading so the post height stays stable.
  Widget loadingBox() =>
      SizedBox(width: width == double.infinity ? null : width, height: 200);
  // Animated .rls stickers are not images — they need their own player. This
  // is the single place every sticker surface (picker, packs, hub, feeds)
  // resolves a ref through, so handling it here covers all of them.
  if (looksLikeRlsRef(path)) {
    return _RlsFromRef(path: path, width: width, height: height);
  }
  if (looksLikeRlvRef(path)) {
    return _RlvFromRef(path: path, width: width, height: height);
  }
  if (looksLikeTgsRef(path)) {
    return _TgsFromRef(path: path, width: width, height: height);
  }
  if (path.startsWith('data:') ||
      path.startsWith('http://') ||
      path.startsWith('https://')) {
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

/// Loads an `.rls` from any ref shape (inline data:, OPFS, native file) and
/// plays it. Bytes are cached in [_webImgCache] alongside images so scrolling a
/// grid doesn't re-read and restart the animation on every recycle.
class _RlsFromRef extends StatelessWidget {
  final String path;
  final double? width;
  final double? height;

  const _RlsFromRef({required this.path, this.width, this.height});

  Future<Uint8List?> _load() async {
    if (path.startsWith('data:')) {
      return Uri.parse(path).data?.contentAsBytes();
    }
    if (kIsWeb) {
      if (!isWebStoredFile(path)) return null;
      return readWebStoredFile(path.split('#').first);
    }
    final f = File(path.split('#').first);
    return f.existsSync() ? f.readAsBytes() : null;
  }

  @override
  Widget build(BuildContext context) {
    Widget play(Uint8List bytes) {
      final sticker = RlsSticker.decodeBytes(bytes);
      if (sticker == null) return const SizedBox.shrink();
      return RlsStickerView(sticker: sticker, width: width, height: height);
    }

    final cached = _webImgCache[path];
    if (cached != null) return play(cached);
    return FutureBuilder<Uint8List?>(
      future: _load(),
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SizedBox(width: width, height: height);
        }
        final b = snap.data;
        if (b == null || b.isEmpty) return const SizedBox.shrink();
        _cacheWebImg(path, b);
        return play(b);
      },
    );
  }
}

/// Same load-and-cache shape as [_RlsFromRef], for `.rlv` vector stickers.
class _RlvFromRef extends StatelessWidget {
  final String path;
  final double? width;
  final double? height;

  const _RlvFromRef({required this.path, this.width, this.height});

  Future<Uint8List?> _load() async {
    if (path.startsWith('data:')) {
      return Uri.parse(path).data?.contentAsBytes();
    }
    if (kIsWeb) {
      if (!isWebStoredFile(path)) return null;
      return readWebStoredFile(path.split('#').first);
    }
    final f = File(path.split('#').first);
    return f.existsSync() ? f.readAsBytes() : null;
  }

  @override
  Widget build(BuildContext context) {
    Widget play(Uint8List bytes) {
      final sticker = RlvSticker.decodeBytes(bytes);
      if (sticker == null) return const SizedBox.shrink();
      return RlvStickerView(sticker: sticker, width: width, height: height);
    }

    final cached = _webImgCache[path];
    if (cached != null) return play(cached);
    return FutureBuilder<Uint8List?>(
      future: _load(),
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SizedBox(width: width, height: height);
        }
        final b = snap.data;
        if (b == null || b.isEmpty) return const SizedBox.shrink();
        _cacheWebImg(path, b);
        return play(b);
      },
    );
  }
}

/// Same load-and-cache shape as [_RlsFromRef], for `.tgs` Telegram stickers.
class _TgsFromRef extends StatelessWidget {
  final String path;
  final double? width;
  final double? height;

  const _TgsFromRef({required this.path, this.width, this.height});

  Future<Uint8List?> _load() async {
    if (path.startsWith('data:')) {
      return Uri.parse(path).data?.contentAsBytes();
    }
    if (kIsWeb) {
      if (!isWebStoredFile(path)) return null;
      return readWebStoredFile(path.split('#').first);
    }
    final f = File(path.split('#').first);
    return f.existsSync() ? f.readAsBytes() : null;
  }

  @override
  Widget build(BuildContext context) {
    final cached = _webImgCache[path];
    if (cached != null) return TgsStickerView(tgsBytes: cached, width: width, height: height);
    return FutureBuilder<Uint8List?>(
      future: _load(),
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SizedBox(width: width, height: height);
        }
        final b = snap.data;
        if (b == null || b.isEmpty) return const SizedBox.shrink();
        _cacheWebImg(path, b);
        return TgsStickerView(tgsBytes: b, width: width, height: height);
      },
    );
  }
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
      return storedImage(resolvedPath, width: 132, height: 132, fit: BoxFit.cover);
    }
    if (!pc) {
      // Cap the height: an uncapped tall screenshot filled the whole comments
      // screen and there was nothing left to scroll to. Cropped here, full
      // size still available by tapping through to the viewer.
      final maxH = MediaQuery.sizeOf(context).height * 0.55;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: storedImage(resolvedPath,
            width: double.infinity, fit: BoxFit.cover),
      );
    }
    final maxW = isSticker ? 180.0 : (sw * 0.38).clamp(200.0, 360.0);
    final maxH = isSticker ? 180.0 : 280.0;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
        child: storedImage(resolvedPath,
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
      child: storedImage(resolvedPath, fit: BoxFit.contain),
    );
  }
}
