import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/user_profile.dart';
import '../../services/profile_service.dart';
import '../screens/profile_screen.dart';
import '../screens/qr_contact_screen.dart';
import '../rlink_nav_routes.dart';
import 'avatar_widget.dart';
import 'avatar_viewer.dart';
import '../../services/music_catalog_service.dart'
    show parseMusicRef, rememberTrackRef;
import '../../services/voice_service.dart';
import 'channel_feed_image.dart' show storedImage;
import 'status_emoji_view.dart';

/// Rich profile header for the Settings tab: banner background, centred avatar,
/// QR + edit actions, name/username/code/tags and (optional) profile music.
class SettingsProfileHeader extends StatelessWidget {
  /// 0..1 open amount from the settings list's overscroll.
  final ValueListenable<double>? pull;
  const SettingsProfileHeader({super.key, this.pull});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UserProfile?>(
      valueListenable: ProfileService.instance.profileNotifier,
      builder: (context, p, _) {
        p ??= ProfileService.instance.profile;
        if (p == null) return const SizedBox.shrink();
        return ProfileCard(profile: p, selfActions: true, pull: pull);
      },
    );
  }
}

/// The profile card used for both our own profile (Settings) and someone
/// else's (peer profile screen) so both read the same.
class ProfileCard extends StatelessWidget {
  final UserProfile profile;

  /// Show the QR + "edit profile" corner buttons (our own profile only).
  final bool selfActions;

  /// Render the profile-music row. Off where the caller has its own player.
  final bool showMusic;

  /// Render the unique-code chip. Off for Favorites (that's ourselves).
  final bool showCode;

  final bool hasStory;
  final bool hasUnviewedStory;

  /// 0..1 open amount, driven by the list's overscroll. The owner snaps it to
  /// 0 or 1 on release; we just tween toward whatever it reports.
  final ValueListenable<double>? pull;

  const ProfileCard({
    super.key,
    required this.profile,
    this.selfActions = false,
    this.showMusic = true,
    this.showCode = true,
    this.hasStory = false,
    this.hasUnviewedStory = false,
    this.pull,
  });

  static const double _bannerH = 132;
  static const double _avatar = 92;
  static const double _open = 210; // expanded (square) avatar side

  @override
  Widget build(BuildContext context) {
    final listenable = pull;
    if (listenable == null) return _build(context, 0);
    return ValueListenableBuilder<double>(
      valueListenable: listenable,
      builder: (context, target, _) => TweenAnimationBuilder<double>(
        tween: Tween<double>(end: target),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        builder: (context, t, __) => _build(context, t),
      ),
    );
  }

  Widget _build(BuildContext context, double t) {
    final p = profile;
    final cs = Theme.of(context).colorScheme;
    final bannerPath = p.bannerImagePath ?? '';
    const pad = EdgeInsets.symmetric(horizontal: 16);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final collapsedH = _bannerH + _avatar / 2;
          final openSide = w < _open ? w : _open;
          final headerH = lerpDouble(collapsedH, openSide, t)!;
          final aSize = lerpDouble(_avatar, openSide, t)!;
          final aLeft = lerpDouble((w - _avatar) / 2, 0, t)!;
          final aTop = lerpDouble(_bannerH - _avatar / 2, 0, t)!;
          final aRadius = lerpDouble(_avatar / 2, 20, t)!;
          final align =
              Alignment.lerp(Alignment.center, Alignment.centerLeft, t)!;

          final nameRow = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  p.nickname,
                  style: TextStyle(
                    fontSize: lerpDouble(21, 19, t),
                    fontWeight: FontWeight.w700,
                    color: t > 0.5 ? Colors.white : null,
                  ),
                ),
              ),
              if (p.statusEmoji.isNotEmpty) ...[
                const SizedBox(width: 6),
                StatusEmojiView(
                  statusEmoji: p.statusEmoji,
                  fontSize: 18,
                  style: const TextStyle(fontSize: 18),
                ),
              ],
            ],
          );

          return Column(
            children: [
              // ── Banner + avatar + corner actions ─────────────────────
              SizedBox(
                height: headerH,
                width: double.infinity,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Banner: gradient, image over it when set.
                    SizedBox(
                      height: _bannerH,
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  cs.primary.withValues(alpha: 0.85),
                                  cs.tertiary.withValues(alpha: 0.75),
                                ],
                              ),
                            ),
                          ),
                          if (bannerPath.isNotEmpty)
                            storedImage(bannerPath,
                                fit: BoxFit.cover,
                                width: double.infinity,
                                height: _bannerH),
                        ],
                      ),
                    ),
                    // Avatar: circle on the banner's edge → square cover.
                    Positioned(
                      left: aLeft,
                      top: aTop,
                      child: GestureDetector(
                        onTap: () => showAvatarViewer(
                          context,
                          imagePath: p.avatarImagePath,
                          color: p.avatarColor,
                          emoji: p.avatarEmoji,
                          initials: p.initials,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(aRadius),
                            border: Border.all(
                              color: cs.surface,
                              width: lerpDouble(4, 0, t)!,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.18),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: AvatarWidget(
                            initials: p.initials,
                            color: p.avatarColor,
                            emoji: p.avatarEmoji,
                            imagePath: p.avatarImagePath,
                            size: aSize,
                            cornerRadius: aRadius,
                            hasStory: hasStory,
                            hasUnviewedStory: hasUnviewedStory,
                          ),
                        ),
                      ),
                    ),
                    // Open state: name + @username sit on the photo itself.
                    if (t > 0.01)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 10,
                        child: Opacity(
                          opacity: t.clamp(0.0, 1.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              nameRow,
                              if (p.username.isNotEmpty)
                                Text('@${p.username}',
                                    style: const TextStyle(
                                        fontSize: 13, color: Colors.white70)),
                            ],
                          ),
                        ),
                      ),
                    if (selfActions) ...[
                      Positioned(
                        top: 10,
                        left: 10,
                        child: _GlassIconButton(
                          icon: Icons.qr_code_2_rounded,
                          tooltip: 'Мой QR-код',
                          onTap: () => Navigator.of(context)
                              .push(rlinkPushRoute(const MyQrScreen())),
                        ),
                      ),
                      Positioned(
                        top: 10,
                        right: 10,
                        child: _GlassIconButton(
                          icon: Icons.edit_outlined,
                          tooltip: 'Изменить профиль',
                          onTap: () => Navigator.of(context).push(
                              rlinkPushRoute(
                                  const ProfileScreen(startEditing: true))),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // ── Name / username / code — collapse away as the photo opens.
              ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: (1 - t).clamp(0.0, 1.0),
                  child: Opacity(
                    opacity: (1 - t).clamp(0.0, 1.0),
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        Padding(
                          padding: pad,
                          child: Align(alignment: align, child: nameRow),
                        ),
                        const SizedBox(height: 4),
                        if (p.username.isNotEmpty)
                          Padding(
                            padding: pad,
                            child: Align(
                              alignment: align,
                              child: Text('@${p.username}',
                                  style: TextStyle(
                                      color: cs.onSurfaceVariant,
                                      fontSize: 14)),
                            ),
                          ),
                        if (showCode) ...[
                          const SizedBox(height: 2),
                          Padding(
                            padding: pad,
                            child: Align(
                              alignment: align,
                              child: _CodeChip(
                                  code: p.shortId, full: p.publicKeyHex),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              // ── Tags ─────────────────────────────────────────────────
              if (p.tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: pad,
                  child: Wrap(
                    alignment:
                        t > 0.5 ? WrapAlignment.start : WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in p.tags)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: cs.secondaryContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(tag,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSecondaryContainer)),
                        ),
                    ],
                  ),
                ),
              ],
              // ── Profile music (only if set) ──────────────────────────
              if (showMusic && (p.profileMusicPath ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                _MusicTile(path: p.profileMusicPath!),
              ],
              const SizedBox(height: 14),
            ],
          );
        },
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _GlassIconButton(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.28),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: Colors.white, size: 20),
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      ),
    );
  }
}

class _CodeChip extends StatelessWidget {
  final String code;
  final String full;
  const _CodeChip({required this.code, required this.full});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Clipboard.setData(ClipboardData(text: full));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Код скопирован')),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('#$code',
                style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 13,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: 0.5)),
            const SizedBox(width: 4),
            Icon(Icons.copy_rounded, size: 13, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _MusicTile extends StatelessWidget {
  final String path;
  const _MusicTile({required this.path});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ref = parseMusicRef(path);
    final voice = VoiceService.instance;

    return ValueListenableBuilder<VoicePlaybackSession?>(
      valueListenable: voice.playbackSession,
      builder: (context, session, _) {
        // Playback lives in VoiceService, so leaving the profile hands the
        // track to the global mini player exactly like a voice message.
        final isCurrent = session?.path == ref.url;
        final isPaused = isCurrent && session!.isPaused;
        final isPlaying = isCurrent && !isPaused;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ref.artwork != null
                        ? Image.network(
                            ref.artwork!,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _fallbackArt(cs),
                          )
                        : _fallbackArt(cs),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(ref.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        Text(
                          ref.artist.isNotEmpty ? ref.artist : 'Музыка профиля',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                      color: cs.primary,
                      size: 30,
                    ),
                    onPressed: () {
                      if (isPlaying) {
                        voice.pausePlayback();
                      } else if (isPaused) {
                        voice.resumePlayback();
                      } else {
                        rememberTrackRef(path);
                        voice.play(ref.url, title: ref.title);
                      }
                    },
                  ),
                ],
              ),
              if (isCurrent)
                ValueListenableBuilder<double>(
                  valueListenable: voice.playProgress,
                  builder: (_, progress, __) => Padding(
                    padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
                    child: LinearProgressIndicator(
                      value: progress.clamp(0.0, 1.0),
                      minHeight: 3,
                      backgroundColor: cs.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _fallbackArt(ColorScheme cs) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.primary, cs.tertiary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Icon(Icons.album_rounded, color: Colors.white, size: 22),
      );
}
