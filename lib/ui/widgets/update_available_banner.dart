import 'package:flutter/material.dart';

import '../../services/update_service.dart';
import 'update_progress_dialog.dart';

/// Обновление принудительное: как только оно найдено — сразу стартуем загрузку
/// (не ждём тапа). Флаг на уровне модуля, чтобы не запуститься дважды с разных
/// экранов (chat_list + home оба подмешивают миксин).
bool _updateFlowStarted = false;

/// Подписка на [pendingUpdateNotifier] и принудительный запуск обновления.
mixin UpdateAvailableBannerMixin<T extends StatefulWidget> on State<T> {
  void registerUpdateBannerListener() {
    pendingUpdateNotifier.addListener(_onPendingUpdateNotifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final u = pendingUpdateNotifier.value;
      if (u != null) _autoStartUpdate(u);
    });
  }

  void unregisterUpdateBannerListener() {
    pendingUpdateNotifier.removeListener(_onPendingUpdateNotifier);
  }

  void _onPendingUpdateNotifier() {
    if (!mounted) return;
    final u = pendingUpdateNotifier.value;
    if (u != null) _autoStartUpdate(u);
  }

  /// Принудительный старт: сразу открываем поток загрузки/установки.
  void _autoStartUpdate(UpdateInfo update) {
    if (_updateFlowStarted) return;
    _updateFlowStarted = true;
    openUpdateFlow(update);
  }

  void showUpdateAvailableBanner(UpdateInfo update) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentMaterialBanner();
    messenger.showMaterialBanner(
      MaterialBanner(
        content: Text('Доступно обновление ${update.version}'),
        leading: const Icon(Icons.system_update, color: Colors.green),
        actions: [
          TextButton(
            onPressed: () => messenger.hideCurrentMaterialBanner(),
            child: const Text('Позже'),
          ),
          FilledButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              openUpdateFlow(update);
            },
            child: Text(
              update.openExternalDownloadPage ? 'Сайт загрузки' : 'Обновить',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> openUpdateFlow(UpdateInfo update) async {
    if (!mounted) return;
    if (update.openExternalDownloadPage) {
      await UpdateService.instance.downloadAndInstall(update);
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateProgressDialog(update: update),
    );
  }
}
