import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/channel.dart';
import '../../services/channel_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import 'dart:typed_data';

import '../../services/image_service.dart';
import '../../utils/rlink_deep_link.dart';
import '../../utils/web_file_store.dart';
import '../widgets/avatar_widget.dart';
import 'channel_admin_settings_screen.dart';

/// Профиль канала (баннер, аватар, описание) — доступен подписчикам.
class ChannelProfileScreen extends StatefulWidget {
  final String channelId;

  const ChannelProfileScreen({super.key, required this.channelId});

  @override
  State<ChannelProfileScreen> createState() => _ChannelProfileScreenState();
}

class _ChannelProfileScreenState extends State<ChannelProfileScreen> {
  Channel? _channel;
  List<ChannelPost> _mediaPosts = [];

  @override
  void initState() {
    super.initState();
    _load();
    ChannelService.instance.version.addListener(_load);
  }

  @override
  void dispose() {
    ChannelService.instance.version.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final ch = await ChannelService.instance.getChannel(widget.channelId);
    final posts =
        await ChannelService.instance.getPosts(widget.channelId, limit: 200);
    final media = posts
        .where((p) =>
            (p.imagePath != null &&
                p.imagePath!.isNotEmpty &&
                !p.isSticker) ||
            (p.videoPath != null && p.videoPath!.isNotEmpty))
        .toList();
    if (mounted) {
      setState(() {
        _channel = ch;
        _mediaPosts = media;
      });
    }
  }

  Widget _thumbFallback(ColorScheme cs) => Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.image_outlined, color: cs.onSurfaceVariant),
      );

  /// Web-safe banner image for the strip below the avatar.
  Widget _bannerImage(ColorScheme cs, Channel ch, String? raw, String? resolved,
      bool isData) {
    Widget fallback() =>
        Container(color: Color(ch.avatarColor).withValues(alpha: 0.35));
    if (isData && raw != null) {
      return Image.network(raw,
          fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback());
    }
    if (kIsWeb) {
      final p = resolved ?? raw ?? '';
      if (!isWebStoredFile(p)) return fallback();
      return FutureBuilder<Uint8List?>(
        future: readWebStoredFile(p),
        builder: (_, snap) => (snap.data != null && snap.data!.isNotEmpty)
            ? Image.memory(snap.data!, fit: BoxFit.cover)
            : fallback(),
      );
    }
    if (resolved != null && File(resolved).existsSync()) {
      return Image.file(File(resolved),
          fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback());
    }
    return fallback();
  }

  /// Web-safe square media thumbnail for the grid.
  Widget _mediaThumb(ColorScheme cs, ChannelPost post) {
    final isVideo = post.videoPath != null && post.videoPath!.isNotEmpty;
    final raw = post.imagePath;
    Widget content;
    if (isVideo) {
      content = Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.play_circle_outline,
            color: cs.onSurfaceVariant, size: 30),
      );
    } else if (raw != null && raw.startsWith('data:')) {
      content = Image.network(raw,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _thumbFallback(cs));
    } else if (kIsWeb) {
      final p = ImageService.instance.resolveStoredPath(raw) ?? raw ?? '';
      content = isWebStoredFile(p)
          ? FutureBuilder<Uint8List?>(
              future: readWebStoredFile(p),
              builder: (_, snap) =>
                  (snap.data != null && snap.data!.isNotEmpty)
                      ? Image.memory(snap.data!, fit: BoxFit.cover)
                      : _thumbFallback(cs),
            )
          : _thumbFallback(cs);
    } else {
      final p = ImageService.instance.resolveStoredPath(raw);
      if (p != null && File(p).existsSync()) {
        content = Image.file(File(p),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _thumbFallback(cs));
      } else {
        content = _thumbFallback(cs);
      }
    }
    return GestureDetector(
      onTap: isVideo ? null : () => _openImagePost(post),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox.expand(child: content),
      ),
    );
  }

  void _openImagePost(ChannelPost post) {
    final raw = post.imagePath;
    if (raw == null) return;
    Widget img;
    if (raw.startsWith('data:')) {
      img = Image.network(raw, fit: BoxFit.contain);
    } else {
      final p = ImageService.instance.resolveStoredPath(raw);
      if (!kIsWeb && p != null && File(p).existsSync()) {
        img = Image.file(File(p), fit: BoxFit.contain);
      } else {
        return;
      }
    }
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            Positioned.fill(child: InteractiveViewer(child: Center(child: img))),
            Positioned(
              top: 40,
              right: 12,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleSubscribe() async {
    final ch = _channel;
    if (ch == null) return;
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    if (ch.adminId == myId) return;
    if (ch.subscriberIds.contains(myId)) {
      await ChannelService.instance.unsubscribe(ch.id, myId);
      await GossipRouter.instance.broadcastChannelSubscribe(
        channelId: ch.id,
        userId: myId,
        unsubscribe: true,
      );
    } else {
      await ChannelService.instance.subscribe(ch.id, myId);
      await GossipRouter.instance.broadcastChannelSubscribe(
        channelId: ch.id,
        userId: myId,
        unsubscribe: false,
        x25519: CryptoService.instance.x25519PublicKeyBase64,
      );
      final lastPost = await ChannelService.instance.getLastPost(ch.id);
      unawaited(GossipRouter.instance.sendChannelHistoryRequest(
        channelId: ch.id,
        requesterId: myId,
        adminId: ch.adminId,
        sinceTs: lastPost?.timestamp ?? 0,
      ));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ch = _channel;
    if (ch == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Канал')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final myId = CryptoService.instance.publicKeyHex;
    final isAdmin = ch.adminId == myId;
    final isMod = ch.moderatorIds.contains(myId);
    final canOpenGeneralSettings =
        isAdmin || (isMod && ch.allowModeratorsManageDriveAccount);
    final subscribed = ch.subscriberIds.contains(myId) || isAdmin;
    final bannerRaw = ch.bannerImagePath;
    final bannerResolved =
        ImageService.instance.resolveStoredPath(bannerRaw);
    final bannerIsData = bannerRaw != null && bannerRaw.startsWith('data:');
    // Web-safe: never touch dart:io File on web (it throws), and render data:
    // URLs (web-set/received banners) via Image.network.
    final hasBanner = bannerIsData ||
        (!kIsWeb &&
            bannerResolved != null &&
            File(bannerResolved).existsSync());

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title:
                Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                icon: const Icon(Icons.share_outlined),
                tooltip: 'Поделиться каналом',
                onPressed: () {
                  unawaited(RlinkDeepLink.shareChannelInvite(
                    context: context,
                    channelTitle: ch.name,
                    channelId: ch.id,
                  ));
                },
              ),
              IconButton(
                icon: const Icon(Icons.link_rounded),
                tooltip: 'Копировать ссылку',
                onPressed: () {
                  final uri = RlinkDeepLink.channelInviteWebUri(ch.id);
                  Clipboard.setData(ClipboardData(text: uri.toString()));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Ссылка скопирована: $uri'),
                    ),
                  );
                },
              ),
              if (canOpenGeneralSettings)
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Настройки канала',
                  onPressed: () {
                    Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ChannelAdminSettingsScreen(
                          channelId: ch.id,
                          allowModeratorDriveManagement: isMod &&
                              !isAdmin &&
                              ch.allowModeratorsManageDriveAccount,
                        ),
                      ),
                    ).then((_) => _load());
                  },
                ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Banner on top; avatar overlaps its bottom edge (Telegram-style).
                  SizedBox(
                    height: hasBanner ? 206 : 112,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        if (hasBanner)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: SizedBox(
                                height: 150,
                                width: double.infinity,
                                child: _bannerImage(cs, ch, bannerRaw,
                                    bannerResolved, bannerIsData),
                              ),
                            ),
                          ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: cs.surface, width: 4),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.35),
                                    blurRadius: 14,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: AvatarWidget(
                                key: ValueKey(
                                    'ch_prof_av_${ch.id}_${ch.avatarImagePath ?? ''}'),
                                initials: ch.name.isNotEmpty
                                    ? ch.name[0].toUpperCase()
                                    : '?',
                                color: ch.avatarColor,
                                emoji: ch.avatarEmoji,
                                imagePath: ch.avatarImagePath,
                                size: 104,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                ch.name,
                                maxLines: 2,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (ch.verified) ...[
                              const SizedBox(width: 6),
                              const Icon(Icons.verified,
                                  color: Colors.blue, size: 20),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text('${ch.subscriberIds.length} подписчиков',
                            style: TextStyle(
                                color: cs.onSurfaceVariant, fontSize: 14)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (ch.description != null &&
                            ch.description!.isNotEmpty) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('О канале',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: cs.primary,
                                        fontSize: 13)),
                                const SizedBox(height: 6),
                                Text(ch.description!,
                                    style: TextStyle(
                                        fontSize: 15,
                                        height: 1.4,
                                        color: cs.onSurface)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (ch.universalCode.isNotEmpty) ...[
                          Row(
                            children: [
                              Icon(Icons.tag_rounded,
                                  size: 18, color: cs.onSurfaceVariant),
                              const SizedBox(width: 6),
                              SelectableText('Код: ${ch.universalCode}',
                                  style: const TextStyle(
                                      fontFamily: 'monospace', fontSize: 13)),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (!isAdmin)
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _toggleSubscribe,
                              icon: Icon(subscribed
                                  ? Icons.notifications_off_outlined
                                  : Icons.notifications_active_outlined),
                              label: Text(
                                  subscribed ? 'Отписаться' : 'Подписаться'),
                            ),
                          ),
                        if (isAdmin)
                          Row(
                            children: [
                              Icon(Icons.shield_outlined,
                                  size: 18, color: cs.onSurfaceVariant),
                              const SizedBox(width: 8),
                              Text('Вы администратор',
                                  style:
                                      TextStyle(color: cs.onSurfaceVariant)),
                            ],
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          if (_mediaPosts.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    Icon(Icons.grid_view_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    const Text('Медиа',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(width: 8),
                    Text('${_mediaPosts.length}',
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 13)),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
              sliver: SliverGrid(
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _mediaThumb(cs, _mediaPosts[i]),
                  childCount: _mediaPosts.length,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
