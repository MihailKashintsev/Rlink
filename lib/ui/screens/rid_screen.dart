import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_l10n.dart';
import '../../services/app_settings.dart';
import '../../services/profile_service.dart';
import '../../services/rlink_app_reset.dart';
import 'settings_screen.dart' show doUnlinkDevice, requestDeviceLink;

/// Dedicated settings screen for the account identity — "RID" (RlinkID),
/// the 64-hex Ed25519 public key. Reachable from Settings → RID. Every
/// destructive/identity action lives here in one place: wipe, transfer to
/// a new device, or link a companion device.
class RidScreen extends StatelessWidget {
  const RidScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final rid = ProfileService.instance.profile?.publicKeyHex ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('RID')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const _RidRevealHeader(),
          const SizedBox(height: 8),
          _RidCard(rid: rid),
          const SizedBox(height: 24),
          const _SectionLabel('Действия'),
          ListenableBuilder(
            listenable: AppSettings.instance,
            builder: (context, _) {
              final settings = AppSettings.instance;
              if (settings.isDeviceLinked) {
                return _ActionTile(
                  icon: Icons.link_off_rounded,
                  iconColor: Colors.red,
                  title: 'Отвязать устройство',
                  subtitle: 'Связка будет снята на обоих устройствах',
                  onTap: () => doUnlinkDevice(context),
                );
              }
              return _ActionTile(
                icon: Icons.link_rounded,
                title: 'Привязать дочернее устройство',
                subtitle: 'Выберите контакт и отправьте запрос на связку',
                onTap: () => requestDeviceLink(context),
              );
            },
          ),
          _ActionTile(
            icon: Icons.swap_horiz_rounded,
            title: 'Перенести аккаунт',
            subtitle: 'Переехать на новое устройство или браузер',
            onTap: () => _showTransferInfo(context, rid),
          ),
          _ActionTile(
            icon: Icons.delete_forever_rounded,
            iconColor: Colors.red,
            titleColor: Colors.red,
            title: 'Удалить RID с устройства',
            subtitle: 'Без возможности сохранения — необратимо',
            onTap: () => _confirmDelete(context),
          ),
        ],
      ),
    );
  }

  Future<void> _showTransferInfo(BuildContext context, String rid) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Перенос аккаунта', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              const Text(
                '1. Откройте Rlink на новом устройстве или в браузере.\n'
                '2. На экране регистрации нажмите «У меня уже есть аккаунт».\n'
                '3. Введите RID, показанный ниже.\n'
                '4. Здесь появится запрос на подтверждение — примите его, чтобы '
                'начать перенос.',
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        rid,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: rid));
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text(AppL10n.t('cm_copied'))),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'После подтверждения это устройство будет очищено. Отменить '
                  'перенос нельзя.',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade300),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить RID?'),
        content: const Text(
          'С этого устройства будут удалены ключи, вся переписка и профиль. '
          'Восстановить RID после этого нельзя — сохранить его для повторного '
          'использования негде. Если вы хотите переехать на другое устройство, '
          'используйте «Перенести аккаунт» вместо этого.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await rlinkPerformFullAppReset(context);
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(color: cs.onSurfaceVariant),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final Color? titleColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    this.iconColor,
    this.titleColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: iconColor ?? cs.primary),
        title: Text(title, style: TextStyle(color: titleColor)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        onTap: onTap,
      ),
    );
  }
}

class _RidCard extends StatelessWidget {
  final String rid;
  const _RidCard({required this.rid});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              rid.isEmpty ? '—' : rid,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: rid.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: rid));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(AppL10n.t('cm_copied'))),
                    );
                  },
          ),
        ],
      ),
    );
  }
}

/// "RID" → letters part → "RlinkID" reveal, played once each time the
/// screen opens. A short static beat on "RID" first (so the acronym reads
/// clearly), then "link" widens+fades in between "R" and "ID" — the Row
/// naturally pushes "ID" aside as the SizeTransition grows, so the letters
/// visibly "move apart" to make room, matching the brand wordmark.
class _RidRevealHeader extends StatefulWidget {
  const _RidRevealHeader();

  @override
  State<_RidRevealHeader> createState() => _RidRevealHeaderState();
}

class _RidRevealHeaderState extends State<_RidRevealHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    Future.delayed(const Duration(milliseconds: 450), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final curved = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    TextStyle style(Color color) => TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: color,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('R', style: style(cs.primary)),
            ClipRect(
              child: SizeTransition(
                sizeFactor: curved,
                axis: Axis.horizontal,
                axisAlignment: -1,
                child: FadeTransition(
                  opacity: curved,
                  child: Text('link', style: style(cs.onSurfaceVariant)),
                ),
              ),
            ),
            Text('ID', style: style(cs.primary)),
          ],
        ),
      ),
    );
  }
}
