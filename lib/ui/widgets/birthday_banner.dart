import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/contact.dart';
import '../../services/premium_service.dart';

/// Shown above the chat list and inside a DM on the contact's birthday.
/// "<name> празднует день рождения! Поздравьте" + a Поздравить button.
class BirthdayBanner extends StatelessWidget {
  final Contact contact;

  /// Opens the DM with [contact] so the user can write a congratulation with
  /// the normal composer (stickers / photos / emoji). Optional.
  final VoidCallback? onWrite;

  const BirthdayBanner({super.key, required this.contact, this.onWrite});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [
            cs.primary.withValues(alpha: 0.18),
            cs.tertiary.withValues(alpha: 0.14),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: cs.primary.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          const Text('🎂', style: TextStyle(fontSize: 24)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${contact.nickname} празднует день рождения!',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text('Поздравьте его',
                    style:
                        TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () =>
                showBirthdayGiftSheet(context, contact, onWrite: onWrite),
            child: const Text('Поздравить'),
          ),
        ],
      ),
    );
  }
}

/// The "как поздравить" panel: real-life gift advice + gift Premium + write.
Future<void> showBirthdayGiftSheet(
  BuildContext context,
  Contact contact, {
  VoidCallback? onWrite,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (ctx) => _GiftSheet(contact: contact, onWrite: onWrite),
  );
}

class _GiftSheet extends StatefulWidget {
  final Contact contact;
  final VoidCallback? onWrite;
  const _GiftSheet({required this.contact, this.onWrite});

  @override
  State<_GiftSheet> createState() => _GiftSheetState();
}

class _GiftSheetState extends State<_GiftSheet> {
  bool _busy = false;
  bool _awaiting = false;

  Future<void> _gift(String plan) async {
    setState(() => _busy = true);
    final url = await PremiumService.instance
        .giftPremium(plan, widget.contact.publicKeyHex);
    if (!mounted) return;
    setState(() => _busy = false);
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось начать оплату. Попробуйте ещё раз.'),
      ));
      return;
    }
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!mounted) return;
    setState(() => _awaiting = true);
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    final recipient = await PremiumService.instance.settleGiftPending();
    if (!mounted) return;
    setState(() => _busy = false);
    if (recipient != null) {
      // Gift went through → let them write the card (v1: the DM composer).
      Navigator.pop(context);
      widget.onWrite?.call();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Подписка подарена! Напишите поздравление 🎉'),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Оплата пока не подтверждена. Попробуйте через минуту.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          bottom: 18 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text('🎁', style: const TextStyle(fontSize: 40)),
            ),
            const SizedBox(height: 8),
            Text(
              'Поздравить ${widget.contact.nickname}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              'Подарите этому человеку Rlink Premium, но мы советуем сделать '
              'подарок в реальной жизни. Самый приятный подарок — это подарок, '
              'сделанный своими руками!',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            if (_awaiting) ...[
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
                      'Оплатите на открывшейся странице и вернитесь — после '
                      'этого напишете поздравительную открытку.',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonal(
                      onPressed: _busy ? null : _check,
                      child: const Text('Проверить оплату'),
                    ),
                  ],
                ),
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: _busy ? null : () => _gift('month'),
                icon: const Icon(Icons.workspace_premium_outlined),
                label: const Text('Подарить Premium на месяц — 50 ₽'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : () => _gift('year'),
                child: const Text('Подарить на год — 500 ₽'),
              ),
            ],
            if (widget.onWrite != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onWrite!.call();
                },
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Просто написать поздравление'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
