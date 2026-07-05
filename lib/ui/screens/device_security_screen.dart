import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/app_lock_service.dart';
import '../../services/rlink_app_reset.dart';
import '../../services/runtime_platform.dart';
import '../../services/web_notification_bridge.dart';

/// Одноразовое (на устройство) предупреждение о рисках web-хранения. Показывается
/// на web при первом заходе; полная информация — в [DeviceSecurityScreen].
Future<void> showWebSecurityNoticeOnce(BuildContext context) async {
  if (!kIsWeb) return;
  final p = await SharedPreferences.getInstance();
  if (p.getBool('web_security_notice_v1') ?? false) return;
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.shield_outlined, color: cs.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Безопасность в браузере',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                ),
              ]),
              const SizedBox(height: 12),
              Text(
                'Переписка и звонки в Rlink шифруются end-to-end — в пути их никто '
                'не прочитает. Но данные в браузере не шифруются на самом '
                'устройстве: у того, кто получит доступ к этому компьютеру или '
                'профилю браузера, будет доступ к переписке.\n\n'
                'Советы: установите Rlink как приложение, включите блокировку по '
                'коду и не пользуйтесь на чужих устройствах.',
                style: TextStyle(color: cs.onSurfaceVariant, height: 1.45),
              ),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const DeviceSecurityScreen()));
                    },
                    child: const Text('Подробнее'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Понятно'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      );
    },
  );
  await p.setBool('web_security_notice_v1', true);
}

/// Честно объясняет уровень защиты данных НА ЭТОМ устройстве и как его повысить.
/// Особенно важно для web: переписка шифруется в пути (E2E), но данные в
/// браузере не шифруются «на диске» — поэтому доступ к устройству = доступ к
/// данным. Здесь — рекомендации + «стереть всё с устройства».
class DeviceSecurityScreen extends StatefulWidget {
  const DeviceSecurityScreen({super.key});

  @override
  State<DeviceSecurityScreen> createState() => _DeviceSecurityScreenState();
}

class _DeviceSecurityScreenState extends State<DeviceSecurityScreen> {
  bool _standalone = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _detect();
  }

  Future<void> _detect() async {
    if (kIsWeb) {
      try {
        final cap = await webNotificationCapability();
        _standalone = cap['standalone'] == true;
      } catch (_) {}
    }
    if (mounted) setState(() => _loaded = true);
  }

  ({String title, String body, Color color, IconData icon}) get _status {
    if (!kIsWeb) {
      if (RuntimePlatform.isDesktop) {
        return (
          title: 'Настольное приложение',
          body:
              'Переписка и звонки шифруются end-to-end. Ключи на этом ПК пока '
              'хранятся не в защищённом хранилище — обязательно включите '
              'блокировку по коду и не оставляйте компьютер разблокированным.',
          color: Colors.orange,
          icon: Icons.desktop_windows_outlined,
        );
      }
      return (
        title: 'Мобильное приложение',
        body:
            'Лучшая защита: ключи в защищённом хранилище системы (Keychain / '
            'Android Keystore), переписка и звонки — end-to-end. Для дополнительной '
            'защиты включите блокировку по коду или биометрию.',
        color: Colors.green,
        icon: Icons.verified_user_outlined,
      );
    }
    if (_standalone) {
      return (
        title: 'Веб-приложение (установлено)',
        body:
            'Переписка и звонки шифруются end-to-end. Но данные в браузере '
            '(история и ключи) не шифруются «на диске» — тот, у кого есть доступ '
            'к этому устройству/профилю браузера, может их прочитать. Включите '
            'блокировку по коду.',
        color: Colors.orange,
        icon: Icons.install_mobile_outlined,
      );
    }
    return (
      title: 'Веб-вкладка браузера',
      body:
          'Переписка и звонки шифруются end-to-end — в пути их никто не прочитает. '
          'Но на ЭТОМ устройстве данные в браузере не шифруются: доступ к '
          'компьютеру/профилю = доступ к переписке. Наименее защищённый режим. '
          'Не используйте на чужих или общих компьютерах.',
      color: Colors.red,
      icon: Icons.public_off_outlined,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!_loaded) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }
    final s = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Безопасность устройства')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: s.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: s.color.withValues(alpha: 0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(s.icon, color: s.color, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 6),
                      Text(s.body,
                          style: TextStyle(
                              color: cs.onSurfaceVariant, height: 1.4)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle('Как повысить защиту'),
          _recTile(
            icon: Icons.lock_outline,
            title: 'Блокировка по коду',
            subtitle: AppLockService.instance.isEnabled
                ? 'Включена ✓'
                : 'Выключена — рекомендуем включить',
            done: AppLockService.instance.isEnabled,
          ),
          if (kIsWeb && !_standalone)
            _recTile(
              icon: Icons.ios_share_outlined,
              title: 'Установить как приложение',
              subtitle:
                  'iPhone: «Поделиться» → «На экран Домой». Изоляция данных лучше, '
                  'чем во вкладке.',
              done: false,
            ),
          _recTile(
            icon: Icons.timer_off_outlined,
            title: 'Исчезающие сообщения',
            subtitle: 'Для чувствительного — чтобы история не копилась на '
                'устройстве (скоро).',
            done: false,
          ),
          _recTile(
            icon: Icons.no_accounts_outlined,
            title: 'Не входите на чужих устройствах',
            subtitle: 'На общих/публичных компьютерах данные могут остаться в '
                'браузере.',
            done: false,
          ),
          const SizedBox(height: 24),
          _sectionTitle('Экстренно'),
          Card(
            color: cs.errorContainer.withValues(alpha: 0.35),
            child: ListTile(
              leading: Icon(Icons.delete_forever_outlined, color: cs.error),
              title: const Text('Стереть все данные с этого устройства'),
              subtitle: const Text(
                  'Удалит ключи, переписку и профиль ИЗ ЭТОГО браузера/устройства. '
                  'На других устройствах данные не тронуты. Отменить нельзя.'),
              onTap: _confirmWipe,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 4),
        child: Text(s,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  Widget _recTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool done,
  }) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, color: done ? Colors.green : cs.primary),
      title: Text(title),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      trailing: done
          ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
          : null,
    );
  }

  Future<void> _confirmWipe() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Стереть все данные?'),
        content: const Text(
            'С ЭТОГО устройства будут удалены ключи, вся переписка и профиль. '
            'Отменить нельзя. Продолжить?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Стереть'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await rlinkPerformFullAppReset(context);
  }
}
