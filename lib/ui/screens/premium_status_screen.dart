import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/premium_service.dart';

const _premiumInfoUrl = 'https://rendergames.ru/rlink_premium';

/// Subscription status + what it unlocks.
class PremiumStatusPage extends StatelessWidget {
  const PremiumStatusPage({super.key});

  static const _features = <(IconData, String, String)>[
    (Icons.palette_outlined, 'Свой цвет ника',
        'Его видят все ваши собеседники'),
    (Icons.campaign_outlined, 'Больше двух каналов',
        'Без ограничения бесплатного тарифа'),
    (Icons.smart_toy_outlined, 'Конструктор ботов',
        'No-code сборка ботов прямо в мессенджере'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Rlink Premium')),
      body: AnimatedBuilder(
        animation: PremiumService.instance,
        builder: (context, _) {
          final active = PremiumService.instance.isActive;
          final until = PremiumService.instance.activeUntil;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: ListView(
                padding: const EdgeInsets.all(18),
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: (active ? cs.primary : cs.outlineVariant)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          active
                              ? Icons.workspace_premium
                              : Icons.workspace_premium_outlined,
                          size: 34,
                          color: active ? cs.primary : cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                active ? 'Подписка активна' : 'Подписки нет',
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                active && until != null
                                    ? 'Действует до ${until.day.toString().padLeft(2, '0')}.'
                                        '${until.month.toString().padLeft(2, '0')}.${until.year}'
                                    : '50 ₽ в месяц или 500 ₽ в год',
                                style: TextStyle(
                                    fontSize: 13, color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text('Что входит',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  for (final f in _features)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(f.$1, color: cs.primary),
                      title: Text(f.$2),
                      subtitle: Text(f.$3,
                          style: const TextStyle(fontSize: 12)),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Все остальные функции Rlink бесплатны для всех.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  if (!active)
                    FilledButton.icon(
                      onPressed: () => launchUrl(
                        Uri.parse(_premiumInfoUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Оформить подписку'),
                    ),
                  // Payments aren't wired yet (YooKassa → relay). Until then a
                  // debug switch is the only way to exercise the gated screens.
                  if (kDebugMode) ...[
                    const Divider(height: 32),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Debug: включить Premium'),
                      subtitle: const Text(
                          'Только для отладки — оплата ещё не подключена',
                          style: TextStyle(fontSize: 12)),
                      value: active,
                      onChanged: (v) => v
                          ? PremiumService.instance.activateUntil(
                              DateTime.now().add(const Duration(days: 30)))
                          : PremiumService.instance.deactivate(),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
