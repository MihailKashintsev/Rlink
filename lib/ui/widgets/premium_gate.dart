import 'package:flutter/material.dart';

import '../../services/channel_service.dart';
import '../../services/crypto_service.dart';
import '../../services/premium_service.dart';
import '../screens/premium_status_screen.dart';

/// Shown instead of a paid screen when there's no active subscription.
///
/// One place for every paid feature, so the wording and the upgrade path can't
/// drift apart between them.
class PremiumRequired extends StatelessWidget {
  final String title;
  final String description;

  const PremiumRequired({
    super.key,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.workspace_premium_outlined,
                      size: 40, color: cs.primary),
                ),
                const SizedBox(height: 16),
                const Text('Нужна подписка Rlink Premium',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const PremiumStatusPage()),
                  ),
                  icon: const Icon(Icons.workspace_premium_outlined),
                  label: const Text('Оформить — 50 ₽/мес или 500 ₽/год'),
                ),
                const SizedBox(height: 10),
                Text(
                  'Всё остальное в Rlink бесплатно.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Guards channel creation. Returns true when creation may proceed, otherwise
/// shows the upgrade screen and returns false.
///
/// Lives here because there are two entry points for creating a channel (the
/// chats-tab menu and the channels screen) and the limit has to hold on both.
/// Counts only channels we admin — subscriptions don't count.
Future<bool> allowNewChannel(BuildContext context) async {
  if (PremiumService.instance.has(PremiumFeature.moreChannels)) return true;
  final myId = CryptoService.instance.publicKeyHex;
  if (myId.isEmpty) return true;
  final all = await ChannelService.instance.getChannels();
  final mine = all.where((c) => c.adminId == myId).length;
  if (mine < PremiumService.freeChannelLimit) return true;
  if (!context.mounted) return false;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => const PremiumRequired(
        title: 'Больше каналов',
        description: 'На бесплатном тарифе можно создать два канала. Создание '
            'следующих входит в Rlink Premium.',
      ),
    ),
  );
  return false;
}

/// Renders [child] when Premium is active, otherwise the upgrade screen.
class PremiumGate extends StatelessWidget {
  final PremiumFeature feature;
  final String title;
  final String description;
  final Widget child;

  const PremiumGate({
    super.key,
    required this.feature,
    required this.title,
    required this.description,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PremiumService.instance,
      builder: (context, _) {
        if (PremiumService.instance.has(feature)) return child;
        return PremiumRequired(title: title, description: description);
      },
    );
  }
}
