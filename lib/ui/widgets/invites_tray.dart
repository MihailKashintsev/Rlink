import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../services/channel_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/group_service.dart';
import '../../services/profile_service.dart';
import '../screens/channels_screen.dart' show ChannelViewScreen;
import '../screens/groups_screen.dart' show GroupChatScreen;
import 'avatar_widget.dart';

class _InviteItem {
  final bool isChannel;
  final String id;
  final String name;
  final String inviterId;
  final String inviterNick;
  final int avatarColor;
  final String avatarEmoji;
  final int createdAt;
  final String? creatorId;
  final List<String>? memberIds;
  final String? adminId;

  const _InviteItem({
    required this.isChannel,
    required this.id,
    required this.name,
    required this.inviterId,
    required this.inviterNick,
    required this.avatarColor,
    required this.avatarEmoji,
    required this.createdAt,
    this.creatorId,
    this.memberIds,
    this.adminId,
  });
}

/// Port of skiper-ui's InviteDisclosure: a collapsed "Приглашения · N" pill
/// that expands in place into every pending group/channel invite. This is a
/// second, aggregated place to see them — the inviter's own DM still shows
/// its own invite card too, untouched.
class InvitesTray extends StatefulWidget {
  const InvitesTray({super.key});

  @override
  State<InvitesTray> createState() => _InvitesTrayState();
}

class _InvitesTrayState extends State<InvitesTray> {
  bool _expanded = false;

  List<_InviteItem> _merge() {
    final items = <_InviteItem>[
      for (final i in GroupService.instance.pendingInvites.value)
        _InviteItem(
          isChannel: false,
          id: i.groupId,
          name: i.groupName,
          inviterId: i.inviterId,
          inviterNick: i.inviterNick,
          avatarColor: i.avatarColor,
          avatarEmoji: i.avatarEmoji,
          createdAt: i.createdAt,
          creatorId: i.creatorId,
          memberIds: i.memberIds,
        ),
      for (final i in ChannelService.instance.pendingChannelInvites.value)
        _InviteItem(
          isChannel: true,
          id: i.channelId,
          name: i.channelName,
          inviterId: i.inviterId,
          inviterNick: i.inviterNick,
          avatarColor: i.avatarColor,
          avatarEmoji: i.avatarEmoji,
          createdAt: i.createdAt,
          adminId: i.adminId,
        ),
    ];
    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return items;
  }

  void _decline(_InviteItem it) {
    if (it.isChannel) {
      ChannelService.instance.removeChannelInvite(it.id);
    } else {
      GroupService.instance.removeInvite(it.id);
    }
  }

  Future<void> _accept(_InviteItem it) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    if (it.isChannel) {
      final adminId = it.adminId;
      if (adminId == null) return;
      final channel = Channel(
        id: it.id,
        name: it.name,
        adminId: adminId,
        subscriberIds: [adminId, myId],
        avatarColor: it.avatarColor,
        avatarEmoji: it.avatarEmoji,
        createdAt: it.createdAt,
      );
      await ChannelService.instance.saveChannelFromBroadcast(channel);
      await ChannelService.instance.subscribe(it.id, myId);
      unawaited(GossipRouter.instance.broadcastChannelSubscribe(
        channelId: it.id,
        userId: myId,
        x25519: CryptoService.instance.x25519PublicKeyBase64,
      ));
      final lastPost = await ChannelService.instance.getLastPost(it.id);
      unawaited(GossipRouter.instance.sendChannelHistoryRequest(
        channelId: it.id,
        requesterId: myId,
        adminId: adminId,
        sinceTs: lastPost?.timestamp ?? 0,
        requesterX25519: CryptoService.instance.x25519PublicKeyBase64,
      ));
      ChannelService.instance.removeChannelInvite(it.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.f('Вы подписались на «{0}»', [it.name]))),
      );
      final ch = await ChannelService.instance.getChannel(it.id);
      if (ch != null && mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ChannelViewScreen(channel: ch)),
        );
      }
    } else {
      final creatorId = it.creatorId;
      if (creatorId == null) return;
      final myProfile = ProfileService.instance.profile;
      final group = Group(
        id: it.id,
        name: it.name,
        creatorId: creatorId,
        memberIds: [...?it.memberIds, myId],
        avatarColor: it.avatarColor,
        avatarEmoji: it.avatarEmoji,
        createdAt: it.createdAt,
      );
      await GroupService.instance.saveGroupFromInvite(group);
      GroupService.instance.removeInvite(it.id);
      await GossipRouter.instance.sendGroupAccept(
        groupId: it.id,
        accepterId: myId,
        accepterNick: myProfile?.nickname ?? '',
        inviterId: it.inviterId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.t('cs_you_in_group'))),
      );
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => GroupChatScreen(group: group)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        GroupService.instance.pendingInvites,
        ChannelService.instance.pendingChannelInvites,
      ]),
      builder: (context, _) {
        final items = _merge();
        if (items.isEmpty) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: const Cubic(0.23, 1, 0.32, 1),
          alignment: Alignment.topCenter,
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 8, 10, 2),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(_expanded ? 20 : 24),
            ),
            child: _expanded
                ? _ExpandedInvites(
                    items: items,
                    onAccept: _accept,
                    onDecline: _decline,
                    onClose: () => setState(() => _expanded = false),
                  )
                : InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => setState(() => _expanded = true),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(AppL10n.t('Приглашения'),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 16)),
                          const SizedBox(width: 10),
                          Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                                color: cs.primary, shape: BoxShape.circle),
                            child: Text(
                              '${items.length}',
                              style: TextStyle(
                                  color: cs.onPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _ExpandedInvites extends StatelessWidget {
  final List<_InviteItem> items;
  final ValueChanged<_InviteItem> onAccept;
  final ValueChanged<_InviteItem> onDecline;
  final VoidCallback onClose;

  const _ExpandedInvites({
    required this.items,
    required this.onAccept,
    required this.onDecline,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(AppL10n.t('Приглашения'),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 18)),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: onClose,
              ),
            ],
          ),
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  AvatarWidget(
                    initials:
                        it.name.isNotEmpty ? it.name[0].toUpperCase() : '?',
                    color: it.avatarColor,
                    emoji: it.avatarEmoji,
                    size: 44,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(it.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                          it.isChannel
                              ? AppL10n.f('Канал · от {0}', [it.inviterNick])
                              : AppL10n.f('Группа · от {0}', [it.inviterNick]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: AppL10n.t('common_cancel'),
                    icon: Icon(Icons.close, color: cs.onSurfaceVariant, size: 20),
                    onPressed: () => onDecline(it),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    onPressed: () => onAccept(it),
                    child: Text(AppL10n.t('common_accept')),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
