import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/channel.dart';
import '../../services/channel_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../utils/rlink_deep_link.dart';
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
    if (mounted) setState(() => _channel = ch);
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
            expandedHeight: hasBanner ? 200 : 120,
            pinned: true,
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
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasBanner && bannerIsData)
                    Image.network(
                      bannerRaw,
                      key: ValueKey(bannerRaw),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                          color:
                              Color(ch.avatarColor).withValues(alpha: 0.35)),
                    )
                  else if (hasBanner)
                    Image.file(
                      File(bannerResolved!),
                      key: ValueKey(bannerResolved),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                          color:
                              Color(ch.avatarColor).withValues(alpha: 0.35)),
                    )
                  else
                    Container(
                        color: Color(ch.avatarColor).withValues(alpha: 0.35)),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.15),
                          Colors.black.withValues(alpha: 0.55),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header: avatar overlaps the banner edge with a surface ring,
                  // name + stats beside it (no awkward floating overlap).
                  Transform.translate(
                    offset: const Offset(0, -34),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: cs.surface, width: 4),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
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
                            size: 92,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        ch.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700,
                                          height: 1.1,
                                        ),
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
                                Text(
                                  '${ch.subscriberIds.length} подписчиков',
                                  style: TextStyle(
                                      color: cs.onSurfaceVariant, fontSize: 14),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Close part of the translate gap.
                  Transform.translate(
                    offset: const Offset(0, -18),
                    child: Column(
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
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
