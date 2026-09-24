import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../models/quick_video.dart';
import '../../services/app_settings.dart';

/// Настройки «Быстрого видео» (кружки/квадратики): форма и качество записи.
class QuickVideoSettingsScreen extends StatelessWidget {
  const QuickVideoSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(AppL10n.t('Быстрое видео')),
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: cs.surface,
      ),
      body: ListenableBuilder(
        listenable: AppSettings.instance,
        builder: (_, __) {
          final s = AppSettings.instance;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              const SizedBox(height: 8),
              Center(child: _ShapeFace(shape: s.quickVideoShape, size: 132)),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  s.quickVideoShape.label,
                  style: TextStyle(
                      color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 20),
              _header(context, AppL10n.t('Форма')),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final sh in QuickVideoShape.values)
                    _ShapeTile(
                      shape: sh,
                      selected: sh == s.quickVideoShape,
                      onTap: () => s.setQuickVideoShape(sh),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                AppL10n.t('Получатель увидит видео в выбранной вами форме.'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              _header(context, AppL10n.t('Качество записи')),
              for (final q in QuickVideoQuality.values)
                RadioListTile<QuickVideoQuality>(
                  contentPadding: EdgeInsets.zero,
                  value: q,
                  groupValue: s.quickVideoQuality,
                  onChanged: (v) {
                    if (v != null) s.setQuickVideoQuality(v);
                  },
                  title: Text(q.label),
                  subtitle: Text(
                    switch (q) {
                      QuickVideoQuality.low =>
                        AppL10n.t('Быстрее отправка, меньше трафика'),
                      QuickVideoQuality.standard =>
                        AppL10n.t('Баланс качества и размера'),
                      QuickVideoQuality.high =>
                        AppL10n.t('Чётче картинка, но файл больше'),
                    },
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                AppL10n.t('Запись — до 1 минуты: удерживайте кнопку, проведите вверх, чтобы закрепить, влево — отменить.'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
        child: Text(
          t.toUpperCase(),
          style: TextStyle(
            color: Theme.of(context).hintColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      );
}

class _ShapeTile extends StatelessWidget {
  final QuickVideoShape shape;
  final bool selected;
  final VoidCallback onTap;

  const _ShapeTile(
      {required this.shape, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 92,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? cs.primary : cs.outlineVariant,
            width: selected ? 2 : 1,
          ),
          color: selected ? cs.primary.withValues(alpha: 0.08) : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ShapeFace(shape: shape, size: 52),
            const SizedBox(height: 6),
            Text(shape.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Форма, залитая градиентом (условный «кадр»).
class _ShapeFace extends StatelessWidget {
  final QuickVideoShape shape;
  final double size;
  const _ShapeFace({required this.shape, required this.size});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: QuickVideoClip(
        shape: shape,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [cs.primary, cs.tertiary],
            ),
          ),
          child: Icon(Icons.videocam_rounded,
              color: cs.onPrimary.withValues(alpha: 0.9), size: size * 0.38),
        ),
      ),
    );
  }
}
