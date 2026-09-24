import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/call_history_service.dart';
import '../../services/call_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/relay_service.dart';
import '../rlink_nav_routes.dart';
import 'call_screen.dart';
import 'call_recording_playback_screen.dart';
import 'chat_screen.dart';
import '../../l10n/app_l10n.dart';

/// Вкладка «История звонков»: дата, длительность, контакт; повторный звонок и чат.
class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(CallHistoryService.instance.ensureLoaded());
  }

  static String _fmtDateTime(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')}.'
        '${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  static String _fmtDuration(Duration d) {
    if (d.inMilliseconds <= 0) return '—';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return AppL10n.f('{0} ч {1} мин {2} с', [h, m.toString().padLeft(2, '0'), s.toString().padLeft(2, '0')]);
    }
    if (d.inMinutes > 0) {
      return AppL10n.f('{0} мин {1} с', [m, s.toString().padLeft(2, '0')]);
    }
    return AppL10n.f('{0} с', [s]);
  }

  Future<void> _openRecording(CallHistoryEntry e) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CallRecordingPlaybackScreen(entry: e),
      ),
    );
  }

  Future<void> _openChat(CallHistoryEntry e) async {
    final c = await ChatStorageService.instance.getContact(e.peerId);
    if (!mounted) return;
    await Navigator.of(context).push(
      rlinkChatRoute(
        ChatScreen(
          peerId: e.peerId,
          peerNickname:
              c?.nickname.isNotEmpty == true ? c!.nickname : e.peerDisplayName,
          peerAvatarColor: c?.avatarColor ?? 0xFF607D8B,
          peerAvatarEmoji: c?.avatarEmoji ?? '',
          peerAvatarImagePath: c?.avatarImagePath,
        ),
      ),
    );
  }

  Future<void> _placeCall(CallHistoryEntry e, {required bool video}) async {
    if (!RelayService.instance.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppL10n.t('Собеседник офлайн в relay. Звонок недоступен.'))),
        );
      }
      return;
    }
    try {
      final session = await CallService.instance.startOutgoing(
        peerId: e.peerId,
        video: video,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CallScreen(
            session: session,
            peerName: e.peerDisplayName,
          ),
        ),
      );
    } on StateError catch (err) {
      if (!mounted) return;
      final r = err.message;
      String msg = AppL10n.t('Звонок недоступен');
      if (r == 'busy') {
        msg = AppL10n.t('Уже идёт звонок. Завершите текущий.');
      } else if (r == 'peer_offline') {
        msg = AppL10n.t('Собеседник офлайн в relay.');
      } else if (r == 'invalid_recipient') {
        msg = AppL10n.t('Некорректный контакт для звонка.');
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: CallHistoryService.instance.version,
      builder: (context, _) {
        final list = CallHistoryService.instance.entries;
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                AppL10n.t('Пока нет звонков.\nПосле звонка запись появится здесь.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant, height: 1.35),
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
          itemCount: list.length,
          separatorBuilder: (_, __) => Divider(
            height: 1,
            color: cs.outline.withValues(alpha: 0.2),
          ),
          itemBuilder: (_, i) {
            final e = list[i];
            final sub = '${e.incoming ? AppL10n.t('Входящий') : AppL10n.t('Исходящий')} · '
                '${e.video ? AppL10n.t('Видео') : AppL10n.t('Аудио')} · ${_fmtDuration(e.duration)}';
            return ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              title: Text(
                e.peerDisplayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${_fmtDateTime(e.endedAt)}\n$sub',
                style: TextStyle(
                    fontSize: 12, color: cs.onSurfaceVariant, height: 1.35),
              ),
              isThreeLine: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (e.recordingPath != null && e.recordingPath!.isNotEmpty)
                    IconButton(
                      tooltip: e.video ? AppL10n.t('Смотреть запись') : AppL10n.t('Слушать запись'),
                      icon: Icon(e.video
                          ? Icons.play_circle_outline
                          : Icons.headphones),
                      onPressed: () => _openRecording(e),
                    ),
                  IconButton(
                    tooltip: AppL10n.t('Позвонить (аудио)'),
                    icon: const Icon(Icons.call),
                    onPressed: () => _placeCall(e, video: false),
                  ),
                  IconButton(
                    tooltip: AppL10n.t('Позвонить (видео)'),
                    icon: const Icon(Icons.videocam_outlined),
                    onPressed: () => _placeCall(e, video: true),
                  ),
                  IconButton(
                    tooltip: AppL10n.t('Открыть чат'),
                    icon: const Icon(Icons.chat_bubble_outline),
                    onPressed: () => _openChat(e),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
