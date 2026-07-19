import 'package:flutter/material.dart';

import '../../services/update_service.dart';

/// Красивый прогресс обновления. Загрузка стартует сразу (принудительно).
/// Десктоп: скачал → распаковал → перезапуск (сюда уже не вернётся).
/// Android: скачал → системный установщик поверх диалога.
class UpdateProgressDialog extends StatefulWidget {
  final UpdateInfo update;
  const UpdateProgressDialog({super.key, required this.update});

  @override
  State<UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<UpdateProgressDialog>
    with SingleTickerProviderStateMixin {
  String? _error;
  bool _launched = false; // download done, installer launched (mobile)
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    UpdateService.instance.downloadProgress.addListener(_rebuild);
    _run();
  }

  Future<void> _run() async {
    try {
      await UpdateService.instance.downloadAndInstall(widget.update);
      if (mounted) setState(() => _launched = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pulse.dispose();
    UpdateService.instance.downloadProgress.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final progress = UpdateService.instance.downloadProgress.value;
    final failed = _error != null;

    final String status = failed
        ? 'Не удалось загрузить'
        : _launched
            ? 'Загрузка завершена'
            : (progress == null ? 'Подготовка…' : 'Загрузка обновления');
    final bool bg = UpdateService.instance.supportsBackgroundDownload;
    final bool downloading = !failed && !_launched;
    final String sub = failed
        ? '$_error'
        : _launched
            ? 'Подтверди установку в системном окне.'
            : bg
                ? 'Можно свернуть — загрузка продолжится в фоне.'
                : 'Пожалуйста, не закрывай приложение…';

    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 32, 28, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Hero(
              cs: cs,
              pulse: _pulse,
              progress: progress,
              done: _launched,
              failed: failed,
            ),
            const SizedBox(height: 24),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                (!failed && !_launched && progress != null)
                    ? '${(progress * 100).round()}%'
                    : status,
                key: ValueKey('$status-$progress-$_launched-$failed'),
                style: TextStyle(
                  fontSize: (!failed && !_launched && progress != null) ? 32 : 20,
                  fontWeight: FontWeight.w800,
                  color: failed ? cs.error : cs.onSurface,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Rlink ${widget.update.version}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              sub,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
            ),
            if (failed || _launched) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Закрыть'),
                ),
              ),
            ] else if (downloading && bg) ...[
              // Android качает в фоне — можно спрятать диалог, загрузка не
              // прервётся; по готовности откроется системный установщик.
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.expand_more_rounded, size: 20),
                  label: const Text('Свернуть'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Animated hero circle: progress ring + pulsing download arrow while loading,
/// a scale-in check when done, an error mark on failure.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.cs,
    required this.pulse,
    required this.progress,
    required this.done,
    required this.failed,
  });

  final ColorScheme cs;
  final AnimationController pulse;
  final double? progress;
  final bool done;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final Color accent = failed ? cs.error : cs.primary;
    return SizedBox(
      width: 108,
      height: 108,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Soft glow behind
          Container(
            width: 108,
            height: 108,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.08),
            ),
          ),
          // Progress / spinner ring
          SizedBox(
            width: 92,
            height: 92,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: (done || failed) ? 1.0 : (progress ?? 0)),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
              builder: (_, v, __) => CircularProgressIndicator(
                value: (progress == null && !done && !failed) ? null : v,
                strokeWidth: 5,
                strokeCap: StrokeCap.round,
                backgroundColor: accent.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation(accent),
              ),
            ),
          ),
          // Center icon
          if (failed)
            Icon(Icons.close_rounded, color: accent, size: 40)
          else if (done)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 400),
              curve: Curves.elasticOut,
              builder: (_, v, __) => Transform.scale(
                scale: v,
                child: Icon(Icons.check_rounded, color: accent, size: 44),
              ),
            )
          else
            ScaleTransition(
              scale: pulse.drive(
                Tween(begin: 0.9, end: 1.12)
                    .chain(CurveTween(curve: Curves.easeInOut)),
              ),
              child: Icon(Icons.arrow_downward_rounded, color: accent, size: 38),
            ),
        ],
      ),
    );
  }
}
