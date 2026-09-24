import 'package:flutter/material.dart';
import '../../l10n/app_l10n.dart';

/// One tile in the primary 4-per-row grid or in the "Еще" overflow menu.
class WebPickerItem {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  const WebPickerItem({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });
}

/// Shared web "attach" sheet — the same grid+overflow UI chat, groups and
/// channels all show now (previously each screen had its own, and groups'
/// picker was dead code that was never wired up, channels' was a single
/// "photo only" tile). Returns the chosen [WebPickerItem.value], whether it
/// came from the grid or from "Еще"; null if dismissed.
Future<String?> showWebMediaPickerSheet(
  BuildContext context, {
  required List<WebPickerItem> items,
  List<WebPickerItem> moreItems = const [],
}) async {
  Widget actionTile(BuildContext ctx, WebPickerItem item) {
    final theme = Theme.of(ctx);
    final accent = item.color ?? theme.colorScheme.primary;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.56),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.pop(ctx, item.value),
        child: SizedBox(
          height: 96,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(item.icon, color: accent),
              ),
              const SizedBox(height: 10),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }

  final all = [
    ...items,
    if (moreItems.isNotEmpty)
      WebPickerItem(
        icon: Icons.more_horiz_rounded,
        label: AppL10n.t('Еще'),
        value: 'menu',
        color: Colors.deepPurple,
      ),
  ];

  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.16),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.dividerColor.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.92,
                children: [for (final it in all) actionTile(ctx, it)],
              ),
            ],
          ),
        ),
      );
    },
  );
  if (choice != 'menu') return choice;
  if (!context.mounted) return null;

  return showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final it in moreItems)
            ListTile(
              leading: Icon(it.icon),
              title: Text(it.label),
              onTap: () => Navigator.pop(ctx, it.value),
            ),
        ],
      ),
    ),
  );
}
