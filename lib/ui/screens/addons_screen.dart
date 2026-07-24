import 'package:flutter/material.dart';

import '../../services/addons_registry.dart';
import '../rlink_nav_routes.dart';

/// List of installed add-ons. Built-ins today, user add-ons later — the row
/// shape is the same either way.
class AddonsScreen extends StatelessWidget {
  const AddonsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = addons();

    return Scaffold(
      appBar: AppBar(title: const Text('Дополнения')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final a in items)
                ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: a.color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(a.icon, color: a.color),
                  ),
                  title: Text(a.title),
                  subtitle: Text(a.subtitle,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      Navigator.push(context, rlinkOpaquePushRoute(a.open())),
                ),
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Свои дополнения',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: cs.onSurface),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  'Дополнение — это отдельный экран внутри Rlink, который пользуется '
                  'теми же возможностями, что и встроенные: каталог, воспроизведение, '
                  'локальное хранилище. «Музыка» сделана именно так и служит образцом. '
                  'Как собрать своё — в docs/addons.md.',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
