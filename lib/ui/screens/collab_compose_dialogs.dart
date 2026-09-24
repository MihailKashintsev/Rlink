import 'package:flutter/material.dart';
import '../../l10n/app_l10n.dart';
import 'package:uuid/uuid.dart';

import '../../models/shared_collab.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/wheel_time_picker.dart';

/// Диалог создания списка дел. Возвращает закодированный `text` сообщения.
Future<String?> showSharedTodoComposeDialog(BuildContext context) async {
  final titleCtrl = TextEditingController();
  final lines = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];

  final ok = await showAdaptiveGlassDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => AlertDialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(AppL10n.t('cm_todo')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: InputDecoration(
                  labelText: AppL10n.t('Заголовок'),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text(AppL10n.t('Пункты'), style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              ...lines.asMap().entries.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: TextField(
                      controller: e.value,
                      decoration: InputDecoration(
                        labelText: AppL10n.f('Пункт {0}', [e.key + 1]),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  )),
              TextButton.icon(
                onPressed: () {
                  setSt(() => lines.add(TextEditingController()));
                },
                icon: const Icon(Icons.add),
                label: Text(AppL10n.t('Добавить пункт')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.t('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.t('В чат')),
          ),
        ],
      ),
    ),
  );

  if (ok != true) return null;
  const uuid = Uuid();
  final items = <SharedTodoItem>[];
  for (final c in lines) {
    final t = c.text.trim();
    if (t.isEmpty) continue;
    items.add(SharedTodoItem(id: uuid.v4(), text: t));
  }
  if (items.isEmpty) return null;
  return SharedTodoPayload(
    ver: 1,
    title: titleCtrl.text.trim(),
    items: items,
  ).encode();
}

Future<String?> showSharedCalendarComposeDialog(BuildContext context) async {
  final titleCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  var date = DateTime.now();
  var time = TimeOfDay.fromDateTime(DateTime.now());

  final ok = await showAdaptiveGlassDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => AlertDialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(AppL10n.t('Событие в календаре')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: InputDecoration(
                  labelText: AppL10n.t('Название'),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(AppL10n.t('Дата и время')),
                subtitle: Text(
                  '${date.day.toString().padLeft(2, '0')}.'
                  '${date.month.toString().padLeft(2, '0')}.${date.year} '
                  '${time.format(ctx)}',
                ),
                trailing: const Icon(Icons.schedule),
                onTap: () async {
                  final picked = await showWheelDateTimeSheet(
                    ctx,
                    initial: DateTime(
                      date.year,
                      date.month,
                      date.day,
                      time.hour,
                      time.minute,
                    ),
                  );
                  if (picked != null) {
                    setSt(() {
                      date = picked;
                      time = TimeOfDay.fromDateTime(picked);
                    });
                  }
                },
              ),
              TextField(
                controller: noteCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: AppL10n.t('Заметка (необязательно)'),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.t('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.t('В чат')),
          ),
        ],
      ),
    ),
  );

  if (ok != true) return null;
  final title = titleCtrl.text.trim();
  if (title.isEmpty) return null;
  final start = DateTime(
    date.year,
    date.month,
    date.day,
    time.hour,
    time.minute,
  );
  final note = noteCtrl.text.trim();
  return SharedCalendarPayload(
    ver: 1,
    title: title,
    startMs: start.millisecondsSinceEpoch,
    note: note.isEmpty ? null : note,
  ).encode();
}
