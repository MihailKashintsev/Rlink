import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../services/app_settings.dart';
import '../../services/model_download_service.dart';
import '../app_palettes.dart';

/// First-launch quick setup: language, theme, accent color and (on platforms
/// that use the on-device whisper.cpp engine) the transcription model to use.
///
/// Shown once, before the promo/guide flow, so the promo already renders in the
/// user's chosen language and theme. It does NOT mark the intro as seen — the
/// guide tour that follows does that. Everything here can also be changed later
/// in Settings, so nothing is mandatory: the user can just tap «Продолжить».
class FirstRunSetupScreen extends StatefulWidget {
  const FirstRunSetupScreen({super.key});

  @override
  State<FirstRunSetupScreen> createState() => _FirstRunSetupScreenState();
}

class _FirstRunSetupScreenState extends State<FirstRunSetupScreen> {
  bool get _isWeb => kIsWeb;
  bool get _isApple => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  final _settings = AppSettings.instance;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
                children: [
                  _Header(cs: cs),
                  const SizedBox(height: 28),
                  _sectionTitle('Язык', Icons.translate_rounded, cs),
                  const SizedBox(height: 10),
                  _LanguagePicker(
                    selected: _settings.locale,
                    onPick: (code) async {
                      await _settings.setLocale(code);
                      if (mounted) setState(() {});
                    },
                  ),
                  const SizedBox(height: 26),
                  _sectionTitle('Тема', Icons.brightness_6_rounded, cs),
                  const SizedBox(height: 10),
                  _ThemePicker(
                    selected: _settings.themeMode,
                    onPick: (mode) async {
                      await _settings.setThemeMode(mode);
                      if (mounted) setState(() {});
                    },
                  ),
                  const SizedBox(height: 26),
                  _sectionTitle('Цветовая палитра', Icons.palette_rounded, cs),
                  const SizedBox(height: 12),
                  _PalettePicker(
                    selectedIndex: _settings.appPalette,
                    onPick: (i) async {
                      await _settings.setAppPalette(i);
                      if (mounted) setState(() {});
                    },
                  ),
                  const SizedBox(height: 26),
                  _sectionTitle(
                      'Расшифровка голосовых', Icons.graphic_eq_rounded, cs),
                  const SizedBox(height: 8),
                  _transcriptionSection(cs),
                ],
              ),
            ),
            _ContinueBar(
              onContinue: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, IconData icon, ColorScheme cs) {
    return Row(
      children: [
        Icon(icon, size: 18, color: cs.primary),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  Widget _transcriptionSection(ColorScheme cs) {
    if (_isApple) {
      return _InfoCard(
        icon: Icons.check_circle_rounded,
        cs: cs,
        text:
            'Расшифровка работает прямо на устройстве через Apple WhisperKit — '
            'ничего скачивать не нужно.',
      );
    }
    if (_isWeb) {
      return _InfoCard(
        icon: Icons.cloud_done_rounded,
        cs: cs,
        text:
            'В браузере расшифровка выполняется локально (WASM) или в облаке — '
            'модель подгрузится автоматически при первом использовании.',
      );
    }
    // Android / Windows / Linux — choose + optionally download a ggml model.
    return _ModelPicker(
      selected: _settings.transcriptionModelSize,
      onPick: (s) async {
        await _settings.setTranscriptionModelSize(s);
        if (mounted) setState(() {});
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.cs});
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [cs.primary, cs.primary.withValues(alpha: 0.55)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.tune_rounded, color: Colors.white, size: 30),
        ),
        const SizedBox(height: 16),
        const Text(
          'Быстрая настройка',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          'Настройте Rlink под себя. Всё это можно поменять позже в Настройках.',
          style: TextStyle(fontSize: 14, height: 1.35, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker({required this.selected, required this.onPick});
  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: AppL10n.supportedLocales.map((l) {
        final isSel = l.code == selected;
        return _Chip(
          label: l.nativeName,
          selected: isSel,
          cs: cs,
          onTap: () => onPick(l.code),
        );
      }).toList(),
    );
  }
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.selected, required this.onPick});
  final ThemeMode selected;
  final ValueChanged<ThemeMode> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const items = [
      (ThemeMode.system, 'Системная', Icons.smartphone_rounded),
      (ThemeMode.light, 'Светлая', Icons.light_mode_rounded),
      (ThemeMode.dark, 'Тёмная', Icons.dark_mode_rounded),
    ];
    return Row(
      children: [
        for (final it in items)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _SegTile(
                label: it.$2,
                icon: it.$3,
                selected: selected == it.$1,
                cs: cs,
                onTap: () => onPick(it.$1),
              ),
            ),
          ),
      ],
    );
  }
}

/// Полноценный выбор палитры (тех же, что в основных настройках): пишет
/// [AppSettings.setAppPalette], который РЕАЛЬНО читает тема (_buildTheme).
/// Кружки — градиенты палитр, а не плоские цвета.
class _PalettePicker extends StatelessWidget {
  const _PalettePicker({required this.selectedIndex, required this.onPick});
  final int selectedIndex;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: List.generate(kAppPalettes.length, (i) {
        final p = kAppPalettes[i];
        final isSel = i == selectedIndex;
        return GestureDetector(
          onTap: () => onPick(i),
          child: Tooltip(
            message: p.name,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: p.gradient,
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSel ? cs.onSurface : cs.outlineVariant,
                  width: isSel ? 3 : 1,
                ),
              ),
              child: isSel
                  ? const Icon(Icons.check_rounded,
                      color: Colors.white, size: 22)
                  : null,
            ),
          ),
        );
      }),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.selected, required this.onPick});
  final WhisperModelSize selected;
  final ValueChanged<WhisperModelSize> onPick;

  String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} МБ';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Модель скачивается один раз и работает офлайн. Можно скачать сейчас '
          'или позже — она подтянется при первом использовании.',
          style: TextStyle(
              fontSize: 12.5, height: 1.35, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final s in WhisperModelSize.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ModelRow(
              size: s,
              sizeLabel: _mb(s.approxBytes),
              selected: selected == s,
              cs: cs,
              onTap: () => onPick(s),
            ),
          ),
      ],
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.size,
    required this.sizeLabel,
    required this.selected,
    required this.cs,
    required this.onTap,
  });
  final WhisperModelSize size;
  final String sizeLabel;
  final bool selected;
  final ColorScheme cs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WhisperModelSize?>(
      valueListenable: ModelDownloadService.instance.downloading,
      builder: (context, downloadingSize, _) {
        return FutureBuilder<bool>(
          future: ModelDownloadService.instance.isDownloaded(size),
          builder: (context, snap) {
            final installed = snap.data ?? false;
            final isDownloading = downloadingSize == size;
            return Material(
              color: selected
                  ? cs.primary.withValues(alpha: 0.10)
                  : cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                  child: Row(
                    children: [
                      Icon(
                        selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected ? cs.primary : cs.onSurfaceVariant,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(size.displayName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 14.5)),
                            const SizedBox(height: 2),
                            Text(
                              '≈ $sizeLabel${installed ? ' · скачана' : ''}',
                              style: TextStyle(
                                  fontSize: 12, color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _downloadControl(context, installed, isDownloading),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _downloadControl(
      BuildContext context, bool installed, bool isDownloading) {
    if (installed) {
      return Icon(Icons.check_circle_rounded, color: cs.primary, size: 22);
    }
    if (isDownloading) {
      return ValueListenableBuilder<double?>(
        valueListenable: ModelDownloadService.instance.progress,
        builder: (context, p, _) => SizedBox(
          width: 30,
          height: 30,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(strokeWidth: 2.5, value: p),
              if (p != null)
                Text('${(p * 100).round()}',
                    style: const TextStyle(fontSize: 8)),
            ],
          ),
        ),
      );
    }
    return IconButton(
      tooltip: 'Скачать',
      icon: const Icon(Icons.download_rounded),
      color: cs.primary,
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        try {
          await ModelDownloadService.instance.ensureDownloaded(size);
          messenger.showSnackBar(SnackBar(
              content: Text('Модель «${size.displayName}» установлена')));
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text('$e')));
        }
      },
    );
  }
}

// ─── Small shared building blocks ────────────────────────────────────────────

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.cs,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final ColorScheme cs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? cs.primary : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: selected ? cs.primary : cs.outlineVariant,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : cs.onSurface,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

class _SegTile extends StatelessWidget {
  const _SegTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.cs,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final ColorScheme cs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.12)
              : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? cs.primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Icon(icon,
                color: selected ? cs.primary : cs.onSurfaceVariant, size: 22),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? cs.primary : cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.text, required this.cs});
  final IconData icon;
  final String text;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: cs.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 13, height: 1.35, color: cs.onSurface)),
          ),
        ],
      ),
    );
  }
}

class _ContinueBar extends StatelessWidget {
  const _ContinueBar({required this.onContinue});
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: cs.primary,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: onContinue,
          child: const Text('Продолжить',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}
