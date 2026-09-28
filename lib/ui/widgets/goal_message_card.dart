import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../models/group_goal.dart';
import '../../services/broadcast_outbox_service.dart';
import '../../services/crypto_service.dart';
import '../../services/group_service.dart';

/// Карточка цели темы группы — сворачиваемая (как TaskWidget): заголовок +
/// прогресс всегда видны, чек-лист и участники раскрываются по тапу.
class GoalMessageCard extends StatefulWidget {
  final String messageId;
  final GroupGoal goal;
  final ColorScheme cs;
  final bool isOutgoing;

  const GoalMessageCard({
    super.key,
    required this.messageId,
    required this.goal,
    required this.cs,
    this.isOutgoing = false,
  });

  @override
  State<GoalMessageCard> createState() => _GoalMessageCardState();
}

class _GoalMessageCardState extends State<GoalMessageCard> {
  bool _expanded = false;

  Future<void> _send(String action, {int? itemIndex, bool? completed}) async {
    final myId = CryptoService.instance.publicKeyHex;
    await GroupService.instance.applyGoalAction(
      widget.messageId,
      myId,
      action,
      itemIndex: itemIndex,
      completed: completed,
    );
    await BroadcastOutboxService.instance.enqueueGoalAction(
      targetId: widget.messageId,
      actorId: myId,
      action: action,
      itemIndex: itemIndex,
      completed: completed,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final goal = widget.goal;
    final cs = widget.cs;
    final isOutgoing = widget.isOutgoing;
    final myId = CryptoService.instance.publicKeyHex;
    final joined = goal.joinedIds.contains(myId);
    final fg = isOutgoing ? cs.onPrimary : cs.onSurface;
    final border = cs.outline.withValues(alpha: 0.25);
    final bg = isOutgoing
        ? Colors.black.withValues(alpha: 0.12)
        : cs.surfaceContainerHighest.withValues(alpha: 0.35);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Icon(Icons.flag_outlined, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    goal.title.isEmpty ? AppL10n.t('Цель') : goal.title,
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14, color: fg),
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: fg.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: goal.progress,
                    minHeight: 5,
                    backgroundColor: cs.outline.withValues(alpha: 0.15),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      goal.isOverdue ? cs.error : cs.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${goal.completedCount}/${goal.totalCount}',
                style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.6)),
              ),
            ],
          ),
          if (goal.deadlineMs > 0) ...[
            const SizedBox(height: 4),
            Text(
              AppL10n.f('До {0}', [_fmtDeadline(goal.deadlineMs)]),
              style: TextStyle(
                fontSize: 11,
                color: goal.isOverdue
                    ? cs.error
                    : fg.withValues(alpha: 0.5),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            AppL10n.f('Участников: {0}', [goal.joinedIds.length]),
            style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.5)),
          ),
          if (_expanded) ...[
            const SizedBox(height: 8),
            ...List.generate(goal.items.length, (i) {
              final item = goal.items[i];
              return CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: item.completed,
                onChanged: joined
                    ? (v) => _send('toggle_item',
                        itemIndex: i, completed: v ?? false)
                    : null,
                title: Text(
                  item.title,
                  style: TextStyle(
                    fontSize: 13,
                    color: fg,
                    decoration:
                        item.completed ? TextDecoration.lineThrough : null,
                  ),
                ),
              );
            }),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(
                onPressed: () => _send(joined ? 'leave' : 'join'),
                child: Text(joined
                    ? AppL10n.t('Выйти из цели')
                    : AppL10n.t('Присоединиться')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _fmtDeadline(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
  }
}
