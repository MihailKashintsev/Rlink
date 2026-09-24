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
import 'nick_text.dart';
import 'status_emoji_view.dart';
import '../../l10n/app_l10n.dart';

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
  // Cap for the expanded square photo. High enough that on phones the card
  // width is the limit → the photo fills the width and covers the banner;
  // only very wide desktop cards clamp to this.
  static const double _open = 460;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, box) => pull == null
            ? _staticBody(context, box.maxWidth)
            : _pullBody(context, box.maxWidth, pull!),
      ),
    );
  }

  Widget _banner(ColorScheme cs) {
    final bannerPath = profile.bannerImagePath ?? '';
    return SizedBox(
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
                fit: BoxFit.cover, width: double.infinity, height: _bannerH),
        ],
      ),
    );
  }

  Widget _nameRow(BuildContext context, {double fontSize = 21, Color? color}) {
    final p = profile;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            p.nickname,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              // Premium nick colour applies unless a fixed colour is forced
              // (white over the opened photo).
              color: color ?? NickText.resolve(context, p.nickColor),
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
  }

  static const EdgeInsets _pad = EdgeInsets.symmetric(horizontal: 16);

  /// Name / @username / code, centred under the avatar (collapsed state).
  Widget _nameSection(BuildContext context, ColorScheme cs) {
    final p = profile;
    return Column(
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: _pad,
          child: Align(alignment: Alignment.center, child: _nameRow(context)),
        ),
        const SizedBox(height: 4),
        if (p.username.isNotEmpty)
          Padding(
            padding: _pad,
            child: Align(
              alignment: Alignment.center,
              child: Text('@${p.username}',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
            ),
          ),
        if (showCode) ...[
          const SizedBox(height: 2),
          Padding(
            padding: _pad,
            child: Align(
              alignment: Alignment.center,
              child: _CodeChip(code: p.shortId, full: p.publicKeyHex),
            ),
          ),
        ],
      ],
    );
  }

  /// Tags, birthday and music — below the header, aligned to the photo when open.
  Widget _tail(BuildContext context, ColorScheme cs, bool open) {
    final p = profile;
    return Column(
      children: [
        if (p.tags.isNotEmpty) ...[
          const SizedBox(height: 10),
          Padding(
            padding: _pad,
            child: Wrap(
              alignment: open ? WrapAlignment.start : WrapAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in p.tags)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: cs.secondaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(tag,
                        style: TextStyle(
                            fontSize: 12, color: cs.onSecondaryContainer)),
                  ),
              ],
            ),
          ),
        ],
        if ((p.birthday ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          Padding(
            padding: _pad,
            child: Row(
              mainAxisAlignment:
                  open ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                const Text('🎂', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 6),
                Text(
                  UserProfile.birthdayLabel(p.birthday),
                  style: TextStyle(fontSize: 14, color: cs.onSurface),
                ),
              ],
            ),
          ),
        ],
        if (showMusic && (p.profileMusicPath ?? '').isNotEmpty) ...[
          const SizedBox(height: 12),
          _MusicTile(path: p.profileMusicPath!),
        ],
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _cornerButtons(BuildContext context) => Stack(
        children: [
          Positioned(
            top: 10,
            left: 10,
            child: _GlassIconButton(
              icon: Icons.qr_code_2_rounded,
              tooltip: AppL10n.t('Мой QR-код'),
              onTap: () => Navigator.of(context)
                  .push(rlinkPushRoute(const MyQrScreen())),
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: _GlassIconButton(
              icon: Icons.edit_outlined,
              tooltip: AppL10n.t('Изменить профиль'),
              onTap: () => Navigator.of(context).push(
                  rlinkPushRoute(const ProfileScreen(startEditing: true))),
            ),
          ),
        ],
      );

  void _openViewer(BuildContext context) => showAvatarViewer(
        context,
        imagePath: profile.avatarImagePath,
        color: profile.avatarColor,
        emoji: profile.avatarEmoji,
        initials: profile.initials,
      );

  /// Plain card (no pull gesture): banner + circular avatar on its edge.
  Widget _staticBody(BuildContext context, double w) {
    final p = profile;
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        SizedBox(
          height: _bannerH + _avatar / 2,
          width: double.infinity,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _banner(cs),
              Positioned(
                left: (w - _avatar) / 2,
                top: _bannerH - _avatar / 2,
                child: GestureDetector(
                  onTap: () => _openViewer(context),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_avatar / 2),
                      border: Border.all(color: cs.surface, width: 4),
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
                      size: _avatar,
                      cornerRadius: _avatar / 2,
                      hasStory: hasStory,
                      hasUnviewedStory: hasUnviewedStory,
                    ),
                  ),
                ),
              ),
              if (selfActions) _cornerButtons(context),
            ],
          ),
        ),
        _nameSection(context, cs),
        _tail(context, cs, false),
      ],
    );
  }

  /// Pull-to-open card. Only cheap paint/transform work runs per frame: the
  /// banner, the (large, decoded-once) avatar and the text blocks are built a
  /// single time and merely scaled / clipped / faded as [pull] moves.
  Widget _pullBody(BuildContext context, double w, ValueListenable<double> pull) {
    final p = profile;
    final cs = Theme.of(context).colorScheme;
    final openSide = w < _open ? w : _open;
    final collapsedH = _bannerH + _avatar / 2;

    final banner = RepaintBoundary(child: _banner(cs));
    // One decode at the largest size; smaller sizes are a GPU scale of it.
    final bigAvatar = RepaintBoundary(
      child: SizedBox(
        width: openSide,
        height: openSide,
        child: AvatarWidget(
          initials: p.initials,
          color: p.avatarColor,
          emoji: p.avatarEmoji,
          imagePath: p.avatarImagePath,
          size: openSide,
          cornerRadius: 0,
        ),
      ),
    );
    final overlayText = RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _nameRow(context, fontSize: 19, color: Colors.white),
          if (p.username.isNotEmpty)
            Text('@${p.username}',
                style: const TextStyle(fontSize: 13, color: Colors.white70)),
        ],
      ),
    );
    final nameSection = RepaintBoundary(child: _nameSection(context, cs));
    final corner = selfActions ? _cornerButtons(context) : const SizedBox.shrink();

    return Column(
      children: [
        ValueListenableBuilder<double>(
          valueListenable: pull,
          builder: (context, t, _) {
            final headerH = lerpDouble(collapsedH, openSide, t)!;
            final aSize = lerpDouble(_avatar, openSide, t)!;
            final aLeft = lerpDouble((w - _avatar) / 2, 0, t)!;
            final aTop = lerpDouble(_bannerH - _avatar / 2, 0, t)!;
            final radius = BorderRadius.circular(lerpDouble(_avatar / 2, 20, t)!);
            final ring = 4 * (1 - t * 2).clamp(0.0, 1.0);
            return Column(
              children: [
                SizedBox(
                  height: headerH,
                  width: double.infinity,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      banner,
                      Positioned(
                        left: aLeft,
                        top: aTop,
                        width: aSize,
                        height: aSize,
                        child: GestureDetector(
                          onTap: () => _openViewer(context),
                          child: DecoratedBox(
                            position: DecorationPosition.foreground,
                            decoration: BoxDecoration(
                              borderRadius: radius,
                              border: ring > 0.05
                                  ? Border.all(color: cs.surface, width: ring)
                                  : null,
                            ),
                            child: ClipRRect(
                              borderRadius: radius,
                              child: FittedBox(
                                fit: BoxFit.cover,
                                child: bigAvatar,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Name on the photo — only once it (nearly) covers the card.
                      if (t > 0.55)
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 10,
                          child: Opacity(
                              opacity: ((t - 0.55) / 0.45).clamp(0.0, 1.0),
                              child: overlayText),
                        ),
                      corner,
                    ],
                  ),
                ),
                // Name block squeezes away as the photo opens (clip only — no
                // saveLayer fade).
                ClipRect(
                  child: Align(
                    alignment: Alignment.topCenter,
                    heightFactor: (1 - t).clamp(0.0, 1.0),
                    // Cached layer + alpha: fades without re-rasterising.
                    child: Opacity(
                        opacity: (1 - t * 1.8).clamp(0.0, 1.0),
                        child: nameSection),
                  ),
                ),
              ],
            );
          },
        ),
        _PullFlag(
          source: pull,
          test: (t) => t > 0.5,
          builder: (open) => _tail(context, cs, open),
        ),
      ],
    );
  }
}

/// Rebuilds its child only when [test] flips, not on every frame of [source].
class _PullFlag extends StatefulWidget {
  final ValueListenable<double> source;
  final bool Function(double) test;
  final Widget Function(bool) builder;
  const _PullFlag(
      {required this.source, required this.test, required this.builder});

  @override
  State<_PullFlag> createState() => _PullFlagState();
}

class _PullFlagState extends State<_PullFlag> {
  late bool _v = widget.test(widget.source.value);

  @override
  void initState() {
    super.initState();
    widget.source.addListener(_tick);
  }

  @override
  void dispose() {
    widget.source.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    final n = widget.test(widget.source.value);
    if (n != _v) setState(() => _v = n);
  }

  @override
  Widget build(BuildContext context) => widget.builder(_v);
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
          SnackBar(content: Text(AppL10n.t('Код скопирован'))),
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
                          ref.artist.isNotEmpty ? ref.artist : AppL10n.t('Музыка профиля'),
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
