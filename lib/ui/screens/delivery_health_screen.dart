import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/delivery_health_service.dart';
import '../../services/relay_service.dart';
import '../../services/runtime_platform.dart';
import '../../l10n/app_l10n.dart';

/// "Why didn't my message arrive" diagnostics + fixes: foreground-service
/// status, battery-optimization exemption, OEM autostart deep link, and live
/// relay connection state. Android-specific — the things it fixes only exist
/// there (see [DeliveryHealthService]).
class DeliveryHealthScreen extends StatefulWidget {
  const DeliveryHealthScreen({super.key});

  @override
  State<DeliveryHealthScreen> createState() => _DeliveryHealthScreenState();
}

class _DeliveryHealthScreenState extends State<DeliveryHealthScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _fgRunning = false;
  int _fgLastStartedAtMs = 0;
  bool _batteryIgnored = false;
  String _manufacturer = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from a system settings screen the user was sent to below.
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final svc = DeliveryHealthService.instance;
    final running = await svc.isForegroundServiceRunning();
    final lastStarted = await svc.foregroundServiceLastStartedAtMs();
    final ignored = await svc.isIgnoringBatteryOptimizations();
    final manufacturer = await svc.manufacturer();
    if (!mounted) return;
    setState(() {
      _fgRunning = running;
      _fgLastStartedAtMs = lastStarted;
      _batteryIgnored = ignored;
      _manufacturer = manufacturer;
      _loading = false;
    });
  }

  String _formatAgo(int ms) {
    if (ms <= 0) return AppL10n.t('ещё не запускался');
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return AppL10n.t('только что');
    if (d.inHours < 1) return AppL10n.f('{0} мин назад', [d.inMinutes]);
    if (d.inDays < 1) return AppL10n.f('{0} ч назад', [d.inHours]);
    return AppL10n.f('{0} дн назад', [d.inDays]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (!RuntimePlatform.isAndroid) {
      return Scaffold(
        appBar: AppBar(title: Text(AppL10n.t('Доставка сообщений'))),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            RuntimePlatform.isIos
                ? AppL10n.t('На iOS фоновая доставка ограничена системой: сообщения, пришедшие пока приложение закрыто, вы увидите при следующем открытии Rlink. Это ограничение платформы, а не Rlink.')
                : AppL10n.t('Приложение открыто в браузере/на этой платформе — фоновая доставка не требует отдельной настройки здесь.'),
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.t('Доставка сообщений'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  Text(
                    AppL10n.t('Почему сообщение могло не прийти, пока Rlink закрыт, и как это исправить.'),
                    style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  _StatusTile(
                    icon: Icons.dns_outlined,
                    title: AppL10n.t('Соединение с relay'),
                    valueBuilder: (context) => ValueListenableBuilder<RelayState>(
                      valueListenable: RelayService.instance.state,
                      builder: (context, state, _) => _StatusBadge(
                        ok: state == RelayState.connected,
                        text: state == RelayState.connected
                            ? AppL10n.t('подключено')
                            : AppL10n.t('нет соединения'),
                      ),
                    ),
                  ),
                  _StatusTile(
                    icon: Icons.settings_backup_restore,
                    title: AppL10n.t('Фоновая служба Rlink'),
                    subtitle: AppL10n.f('Последний запуск: {0}', [_formatAgo(_fgLastStartedAtMs)]),
                    valueBuilder: (_) =>
                        _StatusBadge(ok: _fgRunning, text: _fgRunning ? AppL10n.t('активна') : AppL10n.t('не активна')),
                  ),
                  _StatusTile(
                    icon: Icons.battery_charging_full,
                    title: AppL10n.t('Исключение из оптимизации батареи'),
                    subtitle: _batteryIgnored
                        ? null
                        : AppL10n.t('Без этого система может останавливать приём сообщений, пока приложение закрыто'),
                    valueBuilder: (_) => _StatusBadge(
                      ok: _batteryIgnored,
                      text: _batteryIgnored ? AppL10n.t('разрешено') : AppL10n.t('не разрешено'),
                    ),
                    trailing: _batteryIgnored
                        ? null
                        : FilledButton(
                            onPressed: () async {
                              await DeliveryHealthService.instance
                                  .requestIgnoreBatteryOptimizations();
                              await _refresh();
                            },
                            child: Text(AppL10n.t('Разрешить')),
                          ),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.rocket_launch_outlined, color: cs.primary),
                    title: Text(AppL10n.t('Автозапуск')),
                    subtitle: Text(
                      _manufacturer.isEmpty
                          ? AppL10n.t('На некоторых производителях (Xiaomi, Huawei, Oppo, Vivo…) нужно отдельно разрешить автозапуск — иначе система выгружает приложение из памяти.')
                          : AppL10n.f('Производитель устройства: {0}. Если сообщения приходят с задержкой, проверьте автозапуск для Rlink в настройках устройства.', [_manufacturer]),
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => DeliveryHealthService.instance.openAutostartSettings(),
                  ),
                ],
              ),
            ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final WidgetBuilder valueBuilder;
  final Widget? trailing;

  const _StatusTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.valueBuilder,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: cs.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
                  valueBuilder(context),
                ]),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.35)),
                ],
                if (trailing != null) ...[
                  const SizedBox(height: 8),
                  trailing!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool ok;
  final String text;

  const _StatusBadge({required this.ok, required this.text});

  @override
  Widget build(BuildContext context) {
    final color = ok ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
