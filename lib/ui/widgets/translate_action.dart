import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_l10n.dart';
import '../../services/translate_service.dart';

/// Переводит [text] на язык интерфейса и показывает результат в нижнем листе.
/// Используется из меню выделения (композер, сообщения) — работает и в web, и
/// в нативной сборке.
Future<void> showTranslateResult(BuildContext context, String text) async {
  final src = text.trim();
  if (src.isEmpty) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  final translated = await TranslateService.instance
      .translate(src, targetLang: AppL10n.currentLang);

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop(); // убрать индикатор

  if (translated == null) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(
          content: Text('Не удалось перевести. Проверьте соединение.')));
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.translate, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Text('Перевод',
                    style: Theme.of(ctx)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.45),
                child: SingleChildScrollView(
                  child: SelectableText(translated,
                      style: const TextStyle(fontSize: 16, height: 1.4)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: translated));
                      Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Копировать'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
