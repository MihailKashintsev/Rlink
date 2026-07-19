import 'package:flutter/material.dart';

import '../../services/update_service.dart';
import 'update_restart_dialog.dart';

/// Обновление скачивается В ФОНЕ, пока человек пользуется мессенджером (прогресс
/// виден в Настройках). Когда загрузка завершена — показываем окно-предупреждение
/// «приложение перезапустится для установки», и только потом установка.
///
/// Флаги на уровне модуля, чтобы не сработать дважды с разных экранов
/// (chat_list + home оба подмешивают миксин).
bool _bgDownloadStarted = false;
bool _restartPromptShown = false;

mixin UpdateAvailableBannerMixin<T extends StatefulWidget> on State<T> {
  void registerUpdateBannerListener() {
    pendingUpdateNotifier.addListener(_onPendingUpdate);
    UpdateService.instance.readyToInstall.addListener(_onReadyToInstall);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Обновление могло стать готовым ещё до маунта (resumePendingInstall на
      // старте) — проверяем текущее значение сразу.
      _onReadyToInstall();
      _onPendingUpdate();
    });
  }

  void unregisterUpdateBannerListener() {
    pendingUpdateNotifier.removeListener(_onPendingUpdate);
    UpdateService.instance.readyToInstall.removeListener(_onReadyToInstall);
  }

  void _onPendingUpdate() {
    if (!mounted) return;
    final u = pendingUpdateNotifier.value;
    if (u == null) return;
    // iOS / внешняя страница: сами установить не можем — показываем баннер с
    // ссылкой на страницу загрузки (не качаем молча).
    if (u.openExternalDownloadPage) {
      showUpdateAvailableBanner(u);
      return;
    }
    if (_bgDownloadStarted) return;
    _bgDownloadStarted = true;
    // Тихо качаем в фоне; прогресс отображается в Настройках.
    UpdateService.instance.startDownload(u);
  }

  void _onReadyToInstall() {
    if (!mounted) return;
    final u = UpdateService.instance.readyToInstall.value;
    if (u == null) return;
    if (_restartPromptShown) return;
    _restartPromptShown = true;
    _showRestartWarning(u);
  }

  Future<void> _showRestartWarning(UpdateInfo update) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateRestartDialog(update: update),
    );
    // Диалог закрыли кнопкой «Позже»: повторно в этом запуске не тревожим, но
    // статус «готово к установке» остаётся в Настройках (там есть «Установить»).
  }

  /// Ручной баннер (используется для iOS/внешней страницы, где авто-загрузки нет).
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
              UpdateService.instance.openDownloadPage(update);
            },
            child: const Text('Сайт загрузки'),
          ),
        ],
      ),
    );
  }
}
