import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/diagnostics_log_service.dart';
import '../../l10n/app_l10n.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppL10n.t('Диагностика сети')),
        actions: [
          IconButton(
            tooltip: AppL10n.t('Очистить лог'),
            onPressed: DiagnosticsLogService.instance.clear,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: AppL10n.t('Скопировать'),
            onPressed: () async {
              final text = DiagnosticsLogService.instance.dump();
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppL10n.t('Лог скопирован'))),
              );
            },
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: DiagnosticsLogService.instance.entries,
        builder: (_, entries, __) {
          if (entries.isEmpty) {
            return Center(
              child: Text(AppL10n.t('Лог пуст. Выполните отправку сообщения/запроса.')),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: entries.length,
            itemBuilder: (_, i) => SelectableText(
              entries[i],
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.35,
              ),
            ),
          );
        },
      ),
    );
  }
}
