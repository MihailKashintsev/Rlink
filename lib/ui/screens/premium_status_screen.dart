import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/premium_service.dart';

/// Subscription status, what it unlocks, and the purchase flow.
///
/// Buying happens here (and in the web build) rather than on the site: the
/// relay ties the payment to this device's public key, which is what makes the
/// subscription survive a reinstall.
class PremiumStatusPage extends StatefulWidget {
  const PremiumStatusPage({super.key});

  @override
  State<PremiumStatusPage> createState() => _PremiumStatusPageState();
}

class _PremiumStatusPageState extends State<PremiumStatusPage> {
  static const _features = <(IconData, String, String)>[
    (Icons.palette_outlined, 'Свой цвет ника',
        'Его видят все ваши собеседники'),
    (Icons.campaign_outlined, 'Больше двух каналов',
        'Без ограничения бесплатного тарифа'),
    (Icons.smart_toy_outlined, 'Конструктор ботов',
        'No-code сборка ботов прямо в мессенджере'),
  ];

  bool _busy = false;
  bool _awaitingPayment = false;

  @override
  void initState() {
    super.initState();
    _resume();
  }

  /// A payment started earlier may already have gone through (the user paid in
  /// the browser and came back), so ask the relay before showing anything.
  Future<void> _resume() async {
    if (await PremiumService.instance.hasPendingPayment()) {
      if (mounted) setState(() => _awaitingPayment = true);
      final ok = await PremiumService.instance.settlePending();
      if (mounted && ok) setState(() => _awaitingPayment = false);
    }
    await PremiumService.instance.refresh();
  }

  Future<void> _buy(String plan) async {
    setState(() => _busy = true);
    final url = await PremiumService.instance.startPurchase(plan);
    if (!mounted) return;
    setState(() => _busy = false);
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Не удалось начать оплату. Проверьте соединение и попробуйте ещё раз.'),
      ));
      return;
    }
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!mounted) return;
    setState(() => _awaitingPayment = true);
  }

  Future<void> _checkPayment() async {
    setState(() => _busy = true);
    final ok = await PremiumService.instance.settlePending();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _awaitingPayment = false;
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Оплата пока не подтверждена. Попробуйте через минуту.'),
      ));
    }
  }

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
          final days = PremiumService.instance.daysLeft;
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
                                    ? 'До ${until.day.toString().padLeft(2, '0')}.'
                                        '${until.month.toString().padLeft(2, '0')}.${until.year}'
                                        ' · осталось $days дн.'
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
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  for (final f in _features)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(f.$1, color: cs.primary),
                      title: Text(f.$2),
                      subtitle:
                          Text(f.$3, style: const TextStyle(fontSize: 12)),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Все остальные функции Rlink бесплатны для всех.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    active ? 'Продлить подписку' : 'Оформить подписку',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    active
                        ? 'Купленное время добавится к оставшемуся — ничего не сгорает.'
                        : 'Подписка привязывается к вашему аккаунту, а не к устройству.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  _PlanCard(
                    title: '1 месяц',
                    price: '50 ₽',
                    note: '+30 дней',
                    enabled: !_busy,
                    onTap: () => _buy('month'),
                  ),
                  const SizedBox(height: 10),
                  _PlanCard(
                    title: '1 год',
                    price: '500 ₽',
                    note: '+365 дней · выгоднее на 2 месяца',
                    highlight: true,
                    enabled: !_busy,
                    onTap: () => _buy('year'),
                  ),
                  if (_awaitingPayment) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Ждём подтверждения оплаты',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(
                            'Оплатите на открывшейся странице и вернитесь сюда. '
                            'Подписка включится автоматически.',
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              FilledButton.tonal(
                                onPressed: _busy ? null : _checkPayment,
                                child: const Text('Проверить оплату'),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () async {
                                        await PremiumService.instance
                                            .clearPending();
                                        if (mounted) {
                                          setState(
                                              () => _awaitingPayment = false);
                                        }
                                      },
                                child: const Text('Отменить'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Center(
                    child: TextButton(
                      onPressed: () => launchUrl(
                        Uri.parse('https://rendergames.ru/offert'),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: const Text('Публичная оферта',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String title;
  final String price;
  final String note;
  final bool highlight;
  final bool enabled;
  final VoidCallback onTap;

  const _PlanCard({
    required this.title,
    required this.price,
    required this.note,
    required this.enabled,
    required this.onTap,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: highlight
          ? cs.primary.withValues(alpha: 0.14)
          : cs.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(note,
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              Text(price,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: highlight ? cs.primary : cs.onSurface,
                  )),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
