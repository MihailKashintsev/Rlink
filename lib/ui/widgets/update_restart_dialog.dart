import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/update_service.dart';

/// Окно-предупреждение, которое показывается, когда обновление УЖЕ скачано в
/// фоне: «приложение перезапустится для установки». Небольшой обратный отсчёт,
/// затем установка; можно отложить («Позже») или установить сразу.
class UpdateRestartDialog extends StatefulWidget {
  final UpdateInfo update;
  const UpdateRestartDialog({super.key, required this.update});

  @override
  State<UpdateRestartDialog> createState() => _UpdateRestartDialogState();
}

class _UpdateRestartDialogState extends State<UpdateRestartDialog> {
  static const _kSeconds = 10;
  int _left = _kSeconds;
  Timer? _timer;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left -= 1);
      if (_left <= 0) _install();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _install() async {
    if (_installing) return;
    _timer?.cancel();
    setState(() => _installing = true);
    // Android: системный установщик открывается поверх; desktop: приложение
    // распаковывает обновление и перезапускается (внутри exit(0)).
    await UpdateService.instance.install();
    if (mounted) Navigator.of(context).maybePop();
  }

  void _later() {
    _timer?.cancel();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.system_update_rounded, color: cs.primary, size: 34),
      title: Text('Обновление ${widget.update.version} загружено'),
      content: Text(
        _installing
            ? 'Устанавливаем обновление…'
            : 'Приложение перезапустится для установки'
                '${_left > 0 ? ' через $_left с' : ''}.\n'
                'Заверши то, что не хочешь потерять.',
        textAlign: TextAlign.center,
        style: TextStyle(color: cs.onSurfaceVariant, height: 1.35),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: _installing
          ? [
              const Center(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ),
              ),
            ]
          : [
              TextButton(onPressed: _later, child: const Text('Позже')),
              FilledButton(
                onPressed: _install,
                child: const Text('Перезапустить'),
              ),
            ],
    );
  }
}

/// Строка статуса обновления для экрана «Настройки»: во время фоновой загрузки
/// показывает прогресс, а когда обновление скачано — кнопку «Установить».
/// Сам скрывается, когда ничего не происходит.
class UpdateProgressTile extends StatelessWidget {
  const UpdateProgressTile({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: UpdateService.instance.readyToInstall,
      builder: (context, ready, __) {
        return ValueListenableBuilder<double?>(
          valueListenable: UpdateService.instance.downloadProgress,
          builder: (context, progress, ___) {
            final downloading =
                ready == null && progress != null && progress < 1.0;
            if (ready == null && !downloading) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(14),
                border:
                    Border.all(color: cs.primary.withValues(alpha: 0.25)),
              ),
              child: ready != null
                  ? Row(
                      children: [
                        Icon(Icons.check_circle_rounded, color: cs.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Обновление ${ready.version} загружено',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13.5),
                          ),
                        ),
                        FilledButton(
                          onPressed: () => UpdateService.instance.install(),
                          child: const Text('Установить'),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Загрузка обновления…',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13.5),
                              ),
                            ),
                            Text(
                              '${(((progress ?? 0)) * 100).round()}%',
                              style: TextStyle(
                                  color: cs.onSurfaceVariant, fontSize: 12.5),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 5,
                            backgroundColor:
                                cs.primary.withValues(alpha: 0.12),
                          ),
                        ),
                      ],
                    ),
            );
          },
        );
      },
    );
  }
}
