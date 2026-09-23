import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/group.dart';
import '../../services/app_settings.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/group_service.dart';
import 'avatar_widget.dart';

/// WhatsApp-style "message info" for a group message you sent: who has it and
/// who has read it. Delivered is per message (each device reports the ids it
/// received); read is a per-member cursor (everything up to a timestamp).
Future<void> showGroupMessageInfo(
  BuildContext context, {
  required Group group,
  required GroupMessage message,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _GroupMessageInfoSheet(group: group, message: message),
  );
}

class _GroupMessageInfoSheet extends StatefulWidget {
  final Group group;
  final GroupMessage message;

  const _GroupMessageInfoSheet({required this.group, required this.message});

  @override
  State<_GroupMessageInfoSheet> createState() => _GroupMessageInfoSheetState();
}

class _GroupMessageInfoSheetState extends State<_GroupMessageInfoSheet> {
  Map<String, ({bool delivered, bool read})> _receipts = const {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    GroupService.instance.version.addListener(_load);
    unawaited(_load());
  }

  @override
  void dispose() {
    GroupService.instance.version.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final r = await GroupService.instance.getMessageReceipts(
      widget.group.id,
      widget.message.id,
      widget.message.timestamp,
    );
    if (!mounted) return;
    setState(() {
      _receipts = r;
      _loaded = true;
    });
  }

  String _name(String id) {
    final c = ChatStorageService.instance.contactsNotifier.value
        .where((c) => c.publicKeyHex == id)
        .firstOrNull;
    return c?.nickname ?? '${id.substring(0, id.length.clamp(0, 8))}…';
  }

  Widget _row(String id) {
    final c = ChatStorageService.instance.contactsNotifier.value
        .where((c) => c.publicKeyHex == id)
        .firstOrNull;
    final name = _name(id);
    return ListTile(
      dense: true,
      leading: AvatarWidget(
        initials: name.isNotEmpty ? name[0].toUpperCase() : '?',
        color: c?.avatarColor ?? 0xFF5C6BC0,
        emoji: c?.avatarEmoji ?? '',
        imagePath: c?.avatarImagePath,
        size: 36,
      ),
      title: Text(name),
    );
  }

  Widget _section(BuildContext context, IconData icon, Color color,
      String title, List<String> ids) {
    if (ids.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text('$title · ${ids.length}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        for (final id in ids) _row(id),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = CryptoService.instance.publicKeyHex;
    final cs = Theme.of(context).colorScheme;
    final showRead = AppSettings.instance.showReadReceipts;
    final others = widget.group.memberIds.where((m) => m != me).toList();

    final read = <String>[];
    final delivered = <String>[];
    final pending = <String>[];
    for (final id in others) {
      final r = _receipts[id];
      if (r == null || !r.delivered) {
        pending.add(id);
      } else if (r.read && showRead) {
        read.add(id);
      } else {
        delivered.add(id);
      }
    }

    final dt = DateTime.fromMillisecondsSinceEpoch(widget.message.timestamp);
    final text = widget.message.text.trim();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Информация о сообщении',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text.isEmpty ? '📎 Вложение' : text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Отправлено ${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}, ${AppSettings.instance.formatTime(dt)}',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            if (!_loaded)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (showRead)
                _section(context, Icons.done_all, Colors.blue.shade400,
                    'Прочитали', read),
              _section(context, Icons.done_all, cs.onSurfaceVariant,
                  'Доставлено', delivered),
              _section(context, Icons.check, cs.onSurfaceVariant.withValues(alpha: 0.6),
                  'Пока не доставлено', pending),
              if (others.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('В группе больше никого нет'),
                ),
              if (!showRead)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Text(
                    'Отчёты о прочтении выключены в настройках — кто прочитал, не показывается.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
