import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/relay_service.dart';
import 'bot_builder_screen.dart';

/// Справка для разработчиков сторонних ботов: как создать, развернуть,
/// зарегистрировать бота Rlink и отправить заявку на галочку.
class BotDeveloperGuideScreen extends StatefulWidget {
  const BotDeveloperGuideScreen({super.key});

  @override
  State<BotDeveloperGuideScreen> createState() =>
      _BotDeveloperGuideScreenState();
}

class _BotDeveloperGuideScreenState extends State<BotDeveloperGuideScreen> {
  bool _verifyBusy = false;

  Future<void> _copy(String text, String toast) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(toast)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Справка для разработчиков')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _Info(
            icon: Icons.lock_outline,
            text:
                'Бот в Rlink — это ваш процесс на вашем ПК или сервере. Relay только '
                'доставляет E2E-зашифрованные сообщения и не читает их. Пока процесс '
                'запущен — бот отвечает по вашим правилам; когда офлайн, собеседник '
                'видит заглушку «Бот не в сети…», а сообщение ждёт в очереди.',
          ),
          const SizedBox(height: 20),

          _h('Путь 1 — без кода (рекомендуется)'),
          _p('Соберите ответы в конструкторе — приложение выдаст готовый '
              'Python-файл и зарегистрирует бота в один тап.'),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BotBuilderScreen()),
            ),
            icon: const Icon(Icons.smart_toy_outlined),
            label: const Text('Открыть конструктор'),
          ),
          const SizedBox(height: 24),

          _h('Путь 2 — свой код (полный контроль)'),
          _step(1, 'Установите клиента ботов (один раз)',
              'Пакет rlink_bot лежит в репозитории Rlink, папка tools/rlink_bot.'),
          _code(
            'cd tools/rlink_bot\npython -m pip install -e .',
            () => _copy('cd tools/rlink_bot\npython -m pip install -e .',
                'Скопировано'),
          ),
          _step(2, 'Создайте ключи бота',
              'Второй командой печатается публичный ключ (64 hex) — он нужен для регистрации.'),
          _code(
            'python -m rlink_bot keys init --file bot_keys.json\n'
            'python -m rlink_bot keys show-pub --file bot_keys.json',
            () => _copy(
                'python -m rlink_bot keys init --file bot_keys.json\n'
                'python -m rlink_bot keys show-pub --file bot_keys.json',
                'Скопировано'),
          ),
          _step(3, 'Зарегистрируйте ник',
              'В чате с ботом Lib: /newbot ваш_ник, затем вставьте 64 hex ключа. '
                  'Lib выдаст код заявки (claimCode).'),
          _step(4, 'Привяжите ключи (создаст rlink_bot_config.json)', ''),
          _code(
            'python -m rlink_bot onboard <код из Lib> --file bot_keys.json',
            () => _copy(
                'python -m rlink_bot onboard <код из Lib> --file bot_keys.json',
                'Скопировано'),
          ),
          _step(5, 'Опишите логику ответов',
              'Возьмите tools/rlink_bot/example_echo_bot.py как шаблон: функция '
                  'handle(sender, text) возвращает ответ. Кнопки-чипы: [btn:Метка|/команда].'),
          _step(6, 'Запустите и держите онлайн', ''),
          _code(
            'python -m rlink_bot run --file rlink_bot_config.json',
            () => _copy('python -m rlink_bot run --file rlink_bot_config.json',
                'Скопировано'),
          ),
          const SizedBox(height: 8),
          const _Info(
            icon: Icons.dns_outlined,
            text:
                'Чтобы бот был онлайн постоянно, запускайте его на сервере под '
                'systemd / screen / tmux / docker — так процесс переживёт выход из '
                'сессии и перезагрузку.',
          ),
          const SizedBox(height: 24),

          _h('Галочка (верификация)'),
          _p('Когда бот готов и стабильно онлайн, отправьте заявку на галочку. '
              'Админ увидит её в панели и примет решение. Заявку можно также '
              'отправить командой Lib: /verify @ваш_ник [комментарий].'),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _verifyBusy ? null : _requestVerification,
            icon: _verifyBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.verified_outlined),
            label: Text(_verifyBusy ? 'Загрузка…' : 'Запросить галочку'),
          ),
        ],
      ),
    );
  }

  Future<void> _requestVerification() async {
    setState(() => _verifyBusy = true);
    try {
      if (!RelayService.instance.isConnected) {
        await RelayService.instance.connect();
      }
      final ack = await RelayService.instance.sendBotOwnerList();
      if (!mounted) return;
      if (ack['ok'] != true) {
        _snack('Relay: ${ack['error'] ?? 'не удалось получить список ботов'}');
        return;
      }
      final raw = ack['bots'];
      final bots = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final b in raw) {
          if (b is Map) bots.add(Map<String, dynamic>.from(b));
        }
      }
      if (bots.isEmpty) {
        _snack('У вас пока нет зарегистрированных ботов на relay.');
        return;
      }
      final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Выберите бота для заявки',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              ...bots.map((b) {
                final h = b['handle'] as String? ?? '';
                final verified = b['verified'] == true;
                return ListTile(
                  leading: const Icon(Icons.smart_toy_outlined),
                  title: Text('@$h'),
                  subtitle: Text(b['displayName'] as String? ?? ''),
                  trailing: verified
                      ? const Icon(Icons.verified, color: Colors.blue)
                      : null,
                  enabled: !verified,
                  onTap: () => Navigator.pop(ctx, b),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) return;
      final note = await _askNote();
      if (!mounted) return;
      final botId = (picked['botId'] as String?)?.toLowerCase() ?? '';
      final handle = picked['handle'] as String? ?? '';
      final res = await RelayService.instance
          .sendBotVerifyRequest(botId: botId, note: note ?? '');
      if (!mounted) return;
      if (res['ok'] == true) {
        _snack('Заявка на галочку для @$handle отправлена ✓');
      } else {
        _snack('Не удалось отправить заявку: ${res['error'] ?? 'ошибка'}');
      }
    } finally {
      if (mounted) setState(() => _verifyBusy = false);
    }
  }

  Future<String?> _askNote() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Комментарий к заявке'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Необязательно: что делает бот, зачем галочка…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('Без комментария'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Отправить'),
          ),
        ],
      ),
    );
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  // ── маленькие строительные блоки ──────────────────────────────────────────

  Widget _h(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
      );

  Widget _p(String s) => Text(s,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4));

  Widget _step(int n, String title, String body) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text('$n',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(body,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            height: 1.35)),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  Widget _code(String text, VoidCallback onCopy) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 34),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.outlineVariant),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(text,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12.5, height: 1.4)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.copy, size: 15),
                label: const Text('Копировать'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Info({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.onSurfaceVariant.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurfaceVariant.withValues(alpha: 0.22)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(height: 1.4)),
          ),
        ],
      ),
    );
  }
}
