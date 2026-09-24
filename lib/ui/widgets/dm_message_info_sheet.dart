import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../services/app_settings.dart';
import '../../services/chat_storage_service.dart';
import '../../l10n/app_l10n.dart';

/// "Message info" for a DM you sent: sent / delivered / read.
/// Read comes from the other side's read cursor (see ChatStorageService
/// .peerReadTs) and only exists if they run a build that sends read receipts
/// and haven't turned them off.
Future<void> showDmMessageInfo(BuildContext context, ChatMessage msg) {
  final cs = Theme.of(context).colorScheme;
  final dt = msg.timestamp;
  final delivered = msg.status == MessageStatus.delivered;
  final readTs = ChatStorageService.instance.peerReadTs(msg.peerId);
  final read = delivered && readTs >= dt.millisecondsSinceEpoch;
  final myReceipts = AppSettings.instance.showReadReceipts;

  Widget row(IconData icon, Color color, String title, String sub) => ListTile(
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: Text(sub, style: TextStyle(color: cs.onSurfaceVariant)),
      );

  final text = msg.text.trim();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(AppL10n.t('Информация о сообщении'),
                style: Theme.of(context).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(text.isEmpty ? AppL10n.t('📎 Вложение') : text,
                  maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
          ),
          row(
            Icons.check,
            cs.onSurfaceVariant,
            AppL10n.t('Отправлено'),
            '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}, ${AppSettings.instance.formatTime(dt)}',
          ),
          row(
            Icons.done_all,
            delivered ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.5),
            delivered ? AppL10n.t('Доставлено') : AppL10n.t('Пока не доставлено'),
            delivered ? AppL10n.t('Сообщение получено на устройстве') : AppL10n.t('Ждём подтверждения'),
          ),
          row(
            Icons.done_all,
            read ? Colors.blue.shade400 : cs.onSurfaceVariant.withValues(alpha: 0.5),
            read ? AppL10n.t('Прочитано') : AppL10n.t('Пока не прочитано'),
            read
                ? AppL10n.t('Собеседник открыл чат')
                : (myReceipts
                    ? AppL10n.t('Покажется, когда собеседник прочитает (если у него включены отчёты)')
                    : AppL10n.t('Вы отключили отчёты о прочтении — они не показываются')),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
