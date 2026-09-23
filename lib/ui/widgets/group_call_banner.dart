import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/group_call_directory.dart';
import '../../services/group_call_service.dart';
import '../screens/group_call_screen.dart';

/// "A call is going on here — join" plate at the top of a group chat / topic.
/// Rooms are per (group, topic), so switching topics switches the banner.
class GroupCallChatBanner extends StatelessWidget {
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
        final rid = GroupCallRoomInfo.groupRoomId(groupId, topicId);
        final inThis = svc.isActive && svc.room.value?.roomId == rid;
        final info = GroupCallDirectory.instance.byId(rid);
        if (!inThis && info == null) return const SizedBox.shrink();
        final count = inThis
            ? svc.participants.value.length
            : info?.participants.length ?? 0;
        final full = !inThis && count >= kMaxCallParticipants;
        final cs = Theme.of(context).colorScheme;
        final video = inThis ? svc.isVideoRoom : (info?.video ?? false);
        return Container(
          margin: const EdgeInsets.fromLTRB(10, 8, 10, 2),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(colors: [
              Colors.green.shade700.withValues(alpha: 0.35),
              cs.primary.withValues(alpha: 0.18),
            ]),
            border: Border.all(color: Colors.green.shade400.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              Icon(video ? Icons.videocam : Icons.call,
                  color: Colors.green.shade300, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(inThis ? 'Вы в звонке' : 'Идёт групповой звонок',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('Участников: $count/$kMaxCallParticipants',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Colors.green.shade600,
                ),
                onPressed: full
                    ? null
                    : () {
                        if (inThis) {
                          openGroupCallScreen(context, groupName);
                        } else {
                          unawaited(startOrJoinGroupCall(
                            context,
                            groupId: groupId,
                            groupName: groupName,
                            topicId: topicId,
                            video: video,
                          ));
                        }
                      },
                child: Text(inThis
                    ? 'Открыть'
                    : (full ? 'Заполнена' : 'Присоединиться')),
              ),
            ],
          ),
        );
      },
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
                          'Звонок · ${svc.participants.value.length} · вернуться',
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
