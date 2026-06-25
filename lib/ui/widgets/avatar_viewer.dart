import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../services/image_service.dart';
import '../../utils/web_file_store.dart';
import 'avatar_widget.dart';

/// Opens a fullscreen, zoomable view of an avatar/profile photo. Falls back to
/// the emoji/initials avatar when there's no photo. Motion follows
/// emil-design-eng: fade the scrim, scale the photo from 0.96 (never from 0),
/// ease-out, ~220ms.
Future<void> showAvatarViewer(
  BuildContext context, {
  required String? imagePath,
  required int color,
  String emoji = '',
  String initials = '',
  String? heroTag,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, anim, __) => _AvatarViewer(
        anim: anim,
        imagePath: imagePath,
        color: color,
        emoji: emoji,
        initials: initials,
        heroTag: heroTag,
      ),
    ),
  );
}

class _AvatarViewer extends StatelessWidget {
  final Animation<double> anim;
  final String? imagePath;
  final int color;
  final String emoji;
  final String initials;
  final String? heroTag;

  const _AvatarViewer({
    required this.anim,
    required this.imagePath,
    required this.color,
    required this.emoji,
    required this.initials,
    required this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
    Widget photo = _AvatarViewerImage(
      imagePath: imagePath,
      color: color,
      emoji: emoji,
      initials: initials,
    );
    if (heroTag != null) photo = Hero(tag: heroTag!, child: photo);

    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        final t = curved.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            // Scrim — fades in. Tap to dismiss.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(
                color: Colors.black.withValues(alpha: 0.92 * t),
              ),
            ),
            Center(
              child: Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: 0.96 + 0.04 * t,
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 5,
                    clipBehavior: Clip.none,
                    child: photo,
                  ),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 8,
              child: Opacity(
                opacity: t,
                child: _CircleIconButton(
                  icon: Icons.close_rounded,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AvatarViewerImage extends StatelessWidget {
  final String? imagePath;
  final int color;
  final String emoji;
  final String initials;
  const _AvatarViewerImage({
    required this.imagePath,
    required this.color,
    required this.emoji,
    required this.initials,
  });

  @override
  Widget build(BuildContext context) {
    final side = (MediaQuery.sizeOf(context).shortestSide * 0.86).clamp(240, 560).toDouble();
    final raw = imagePath;
    Widget fallback() => AvatarWidget(
          initials: initials,
          color: color,
          emoji: emoji,
          imagePath: null,
          size: side,
        );
    if (raw == null || raw.isEmpty) return fallback();

    final resolved = ImageService.instance.resolveStoredPath(raw) ?? raw;
    Widget img;
    if (resolved.startsWith('http') ||
        resolved.startsWith('blob:') ||
        resolved.startsWith('data:')) {
      img = Image.network(resolved,
          fit: BoxFit.contain, errorBuilder: (_, __, ___) => fallback());
    } else if (kIsWeb && isWebStoredFile(resolved)) {
      img = FutureBuilder<Uint8List?>(
        future: readWebStoredFile(resolved),
        builder: (_, snap) {
          final b = snap.data;
          if (b == null || b.isEmpty) return fallback();
          return Image.memory(b,
              fit: BoxFit.contain, errorBuilder: (_, __, ___) => fallback());
        },
      );
    } else if (kIsWeb) {
      return fallback();
    } else {
      final f = File(resolved);
      if (!f.existsSync()) return fallback();
      img = Image.file(f,
          fit: BoxFit.contain, errorBuilder: (_, __, ___) => fallback());
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: side * 1.6, maxHeight: side * 1.6),
      child: ClipRRect(borderRadius: BorderRadius.circular(20), child: img),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

/// Has a real photo (not just emoji/initials)?
bool avatarHasPhoto(String? imagePath) {
  if (imagePath == null || imagePath.isEmpty) return false;
  final r = ImageService.instance.resolveStoredPath(imagePath) ?? imagePath;
  if (r.startsWith('data:') || r.startsWith('http') || r.startsWith('blob:')) {
    return true;
  }
  if (kIsWeb) return isWebStoredFile(r);
  try {
    return File(r).existsSync();
  } catch (_) {
    return false;
  }
}
