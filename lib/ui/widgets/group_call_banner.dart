import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/group_call_directory.dart';
import '../../services/group_call_service.dart';
import '../screens/group_call_screen.dart';
import '../../l10n/app_l10n.dart';
import 'avatar_widget.dart';

/// "A call is going on here — join" plate at the top of a group chat / topic.
/// Rooms are per (group, topic), so switching topics switches the banner.
///
/// Port of skiper-ui's VoiceChatDisclosure: collapsed avatar cluster (+
/// talking bars when someone in the room is speaking) expands in place into
/// a participant grid. Uses AnimatedSize rather than an overlay — unlike the
/// "+" menu/search/forward panels elsewhere in this batch, this banner
/// already lives inline at the top of the chat, so expanding it should push
/// the message list down like Telegram's own call banner does, not float
/// over it.
class GroupCallChatBanner extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? topicId;

  const GroupCallChatBanner({
    super.key,
    required this.groupId,
    required this.groupName,
    this.topicId,
  });

  @override
  State<GroupCallChatBanner> createState() => _GroupCallChatBannerState();
}

class _GroupCallChatBannerState extends State<GroupCallChatBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final svc = GroupCallService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        GroupCallDirectory.instance.version,
        svc.phase,
        svc.room,
        svc.participants,
      ]),
      builder: (context, _) {
        final rid = GroupCallRoomInfo.groupRoomId(widget.groupId, widget.topicId);
        final inThis = svc.isActive && svc.room.value?.roomId == rid;
        final info = GroupCallDirectory.instance.byId(rid);
        if (!inThis && info == null) return const SizedBox.shrink();

        final ids = inThis
            ? svc.participants.value.keys.toList()
            : (info?.participants ?? const <String>[]);
        final speakingIds = inThis
            ? svc.participants.value.entries
                .where((e) => e.value.speaking)
                .map((e) => e.key)
                .toSet()
            : const <String>{};
        final count = ids.length;
        final full = !inThis && count >= kMaxCallParticipants;
        final cs = Theme.of(context).colorScheme;
        final video = inThis ? svc.isVideoRoom : (info?.video ?? false);

        void onAction() {
          if (full) return;
          if (inThis) {
            openGroupCallScreen(context, widget.groupName);
          } else {
            unawaited(startOrJoinGroupCall(
              context,
              groupId: widget.groupId,
              groupName: widget.groupName,
              topicId: widget.topicId,
              video: video,
            ));
          }
        }

        return AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: const Cubic(0.23, 1, 0.32, 1),
          alignment: Alignment.topCenter,
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 8, 10, 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_expanded ? 20 : 14),
              gradient: LinearGradient(colors: [
                Colors.green.shade700.withValues(alpha: 0.35),
                cs.primary.withValues(alpha: 0.18),
              ]),
              border:
                  Border.all(color: Colors.green.shade400.withValues(alpha: 0.5)),
            ),
            child: _expanded
                ? _ExpandedCall(
                    ids: ids,
                    speakingIds: speakingIds,
                    count: count,
                    video: video,
                    title: inThis
                        ? AppL10n.t('Вы в звонке')
                        : AppL10n.t('Идёт групповой звонок'),
                    buttonLabel: inThis
                        ? AppL10n.t('Открыть')
                        : (full ? AppL10n.t('Заполнена') : AppL10n.t('Присоединиться')),
                    buttonEnabled: !full,
                    onClose: () => setState(() => _expanded = false),
                    onAction: onAction,
                  )
                : InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _expanded = true),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                      child: Row(
                        children: [
                          _AvatarCluster(
                              ids: ids, speaking: speakingIds.isNotEmpty),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  inThis
                                      ? AppL10n.t('Вы в звонке')
                                      : AppL10n.t('Идёт групповой звонок'),
                                  style:
                                      const TextStyle(fontWeight: FontWeight.w700),
                                ),
                                Text(
                                  AppL10n.f('Участников: {0}/{1}',
                                      [count, kMaxCallParticipants]),
                                  style: TextStyle(
                                      fontSize: 12, color: cs.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Colors.green.shade600,
                            ),
                            onPressed: full ? null : onAction,
                            child: Text(inThis
                                ? AppL10n.t('Открыть')
                                : (full
                                    ? AppL10n.t('Заполнена')
                                    : AppL10n.t('Присоединиться'))),
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

class _AvatarCluster extends StatelessWidget {
  final List<String> ids;
  final bool speaking;
  const _AvatarCluster({required this.ids, required this.speaking});

  @override
  Widget build(BuildContext context) {
    final shown = ids.take(3).toList();
    return SizedBox(
      width: 22.0 * shown.length + 18 + (speaking ? 4 : 0),
      height: 36,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * 22.0,
              child: _MiniAvatar(id: shown[i]),
            ),
          if (speaking)
            Positioned(
              right: 0,
              top: 4,
              child: _TalkingBars(size: 10, color: Colors.green.shade300),
            ),
        ],
      ),
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  final String id;
  const _MiniAvatar({required this.id});

  @override
  Widget build(BuildContext context) {
    final c = callContactOf(id);
    final name = callNameOf(id);
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
      ),
      child: AvatarWidget(
        initials: name.isNotEmpty ? name[0].toUpperCase() : '?',
        color: c?.avatarColor ?? 0xFF607D8B,
        emoji: c?.avatarEmoji ?? '',
        imagePath: c?.avatarImagePath,
        size: 32,
      ),
    );
  }
}

/// Three bars pulsing at staggered phases — speaking indicator, port of the
/// reference's `animate={{height:[2,16,6]}}` loop.
class _TalkingBars extends StatefulWidget {
  final double size;
  final Color color;
  const _TalkingBars({required this.size, required this.color});

  @override
  State<_TalkingBars> createState() => _TalkingBarsState();
}

class _TalkingBarsState extends State<_TalkingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (ctx, _) {
        return SizedBox(
          height: widget.size,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                Container(
                  width: 2.5,
                  height: widget.size *
                      (0.35 +
                          0.65 *
                              (0.5 +
                                  0.5 *
                                      math.sin((_c.value * 2 * math.pi) +
                                          i * 1.4))),
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ExpandedCall extends StatelessWidget {
  final List<String> ids;
  final Set<String> speakingIds;
  final int count;
  final bool video;
  final String title;
  final String buttonLabel;
  final bool buttonEnabled;
  final VoidCallback onClose;
  final VoidCallback onAction;

  const _ExpandedCall({
    required this.ids,
    required this.speakingIds,
    required this.count,
    required this.video,
    required this.title,
    required this.buttonLabel,
    required this.buttonEnabled,
    required this.onClose,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(video ? Icons.videocam : Icons.call,
                  color: Colors.green.shade300, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onClose,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded,
                      size: 18, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 10,
            children: [
              for (final id in ids)
                SizedBox(
                  width: 56,
                  child: Column(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _MiniAvatar(id: id),
                          if (speakingIds.contains(id))
                            Positioned(
                              right: -4,
                              top: -4,
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  color: cs.surface,
                                  shape: BoxShape.circle,
                                ),
                                child: _TalkingBars(
                                    size: 10, color: Colors.green.shade400),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        callNameOf(id),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.green.shade600),
            onPressed: buttonEnabled ? onAction : null,
            child: Text(buttonLabel),
          ),
        ],
      ),
    );
  }
}

/// App-wide pill shown while you're in a call but the call screen isn't on
/// top (you minimized it to read a chat) — one tap returns to the call.
class GroupCallReturnPill extends StatelessWidget {
  final void Function() onTap;

  const GroupCallReturnPill({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final svc = GroupCallService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([svc.phase, svc.screenOpen, svc.participants]),
      builder: (context, _) {
        if (!svc.isActive || svc.screenOpen.value) {
          return const SizedBox.shrink();
        }
        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Material(
                color: Colors.green.shade700,
                borderRadius: BorderRadius.circular(20),
                elevation: 4,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 7),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.call, size: 16, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(
                          AppL10n.f('Звонок · {0} · вернуться', [svc.participants.value.length]),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
