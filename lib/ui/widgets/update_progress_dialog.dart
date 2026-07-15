import 'package:flutter/material.dart';

import '../../services/update_service.dart';

/// Прогресс скачивания обновления. Загрузка стартует сразу (принудительно).
/// Десктоп: скачал → распаковал → перезапуск (сюда уже не вернётся).
/// Android: скачал → системный установщик поверх диалога.
class UpdateProgressDialog extends StatefulWidget {
  final UpdateInfo update;
  const UpdateProgressDialog({super.key, required this.update});

  @override
  State<UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<UpdateProgressDialog> {
  String? _error;
  bool _launched = false; // download done, installer launched (mobile)

  @override
  void initState() {
    super.initState();
    UpdateService.instance.downloadProgress.addListener(_rebuild);
    _run();
  }

  Future<void> _run() async {
    try {
      await UpdateService.instance.downloadAndInstall(widget.update);
      // Desktop exits inside the install step and never returns here.
      // Android/iOS return after launching the system installer / page.
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
    UpdateService.instance.downloadProgress.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = UpdateService.instance.downloadProgress.value;

    if (_error != null) {
      return AlertDialog(
        title: Text('Обновление ${widget.update.version}'),
        content: Text('Не удалось загрузить обновление.\n$_error'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Закрыть'),
          ),
        ],
      );
    }

    if (_launched) {
      return AlertDialog(
        title: Text('Обновление ${widget.update.version}'),
        content: const Text(
            'Загрузка завершена. Подтверди установку в системном окне.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Закрыть'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: Text('Обновление ${widget.update.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (progress == null)
            const CircularProgressIndicator()
          else ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text('${(progress * 100).toStringAsFixed(0)}%'),
          ],
          const SizedBox(height: 8),
          const Text('Пожалуйста, не закрывай приложение...'),
        ],
      ),
    );
  }
}
