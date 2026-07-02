import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/bot_blueprint.dart';
import '../../services/bot_code_generator.dart';
import '../../services/lib_bot_service.dart';
import '../../utils/web_file_store.dart';

/// «Выдаёт код»: готовый Python-файл бота + пошаговое подключение.
/// Логика бота исполняется на ПК/сервере пользователя; relay только доставляет.
class BotBuilderExportScreen extends StatefulWidget {
  final BotBlueprint blueprint;
  const BotBuilderExportScreen({super.key, required this.blueprint});

  @override
  State<BotBuilderExportScreen> createState() => _BotBuilderExportScreenState();
}

class _BotBuilderExportScreenState extends State<BotBuilderExportScreen> {
  final _pubCtrl = TextEditingController();
  bool _registering = false;
  BuilderBotRegisterResult? _result;
  bool _showCode = false;

  BotBlueprint get bp => widget.blueprint;

  @override
  void dispose() {
    _pubCtrl.dispose();
    super.dispose();
  }

  Future<void> _copy(String text, String toast) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(toast)));
  }

  Future<void> _downloadPy() async {
    final code = BotCodeGenerator.python(bp);
    final name = BotCodeGenerator.fileName(bp);
    if (kIsWeb) {
      // Пишем во временный OPFS-файл и отдаём как загрузку.
      await writeWebStoredFile(
        fileName: name,
        bytes: Uint8List.fromList(utf8.encode(code)),
        mimeType: 'text/x-python',
      );
      await downloadWebFile('opfs://rlink/$name',
          fileName: name, mimeType: 'text/x-python');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text('Скачивается $name')));
      }
    } else {
      await _copy(code, 'Код скопирован — сохраните как $name');
    }
  }

  Future<void> _register() async {
    setState(() => _registering = true);
    final res = await LibBotService.instance.registerBuilderBot(
      handle: bp.sanitizedHandle,
      displayName: bp.name,
      botPubHex: _pubCtrl.text,
      description: bp.description,
    );
    if (!mounted) return;
    setState(() {
      _registering = false;
      _result = res;
    });
    if (!res.ok) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(res.error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final handle = bp.sanitizedHandle;
    final fileName = BotCodeGenerator.fileName(bp);

    return Scaffold(
      appBar: AppBar(title: const Text('Код и подключение')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const _InfoCard(
            icon: Icons.dns_outlined,
            text:
                'Бот работает на вашем компьютере или сервере — relay только доставляет '
                'сообщения. Пока процесс запущен, бот отвечает по вашим правилам. Когда он '
                'офлайн, собеседник получает заглушку «Бот не в сети, подождите ответа или '
                'обратитесь к разработчику».',
          ),
          const SizedBox(height: 20),

          // Шаг 1 — код
          const _StepHeader(n:1, title: 'Файл бота'),
          Text(
            'Готовый $fileName — правила уже внутри, редактировать не нужно.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _downloadPy,
                icon: const Icon(kIsWeb ? Icons.download : Icons.copy_all),
                label:
                    const Text(kIsWeb ? 'Скачать .py' : 'Скопировать код'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () => setState(() => _showCode = !_showCode),
                icon: Icon(_showCode ? Icons.visibility_off : Icons.code),
                label: Text(_showCode ? 'Скрыть' : 'Показать'),
              ),
            ],
          ),
          if (_showCode) ...[
            const SizedBox(height: 10),
            _CodeBlock(
              text: BotCodeGenerator.python(bp),
              onCopy: () =>
                  _copy(BotCodeGenerator.python(bp), 'Код бота скопирован'),
              maxLines: 18,
            ),
          ],
          const SizedBox(height: 22),

          // Шаг 2 — установка пакета + ключи
          const _StepHeader(n:2, title: 'Пакет и ключи (на ПК/сервере)'),
          Text(
            'Один раз установите клиента ботов из репозитория Rlink '
            '(папка tools/rlink_bot) и создайте ключи:',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          _CodeBlock(
            text: 'cd tools/rlink_bot\n'
                'python -m pip install -e .\n'
                'python -m rlink_bot keys init --file bot_keys.json\n'
                'python -m rlink_bot keys show-pub --file bot_keys.json',
            onCopy: () => _copy(
                'cd tools/rlink_bot\n'
                'python -m pip install -e .\n'
                'python -m rlink_bot keys init --file bot_keys.json\n'
                'python -m rlink_bot keys show-pub --file bot_keys.json',
                'Команды скопированы'),
          ),
          Text(
            'Последняя команда печатает публичный ключ бота (64 hex) — он нужен ниже.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 22),

          // Шаг 3 — регистрация в один тап
          _StepHeader(n: 3, title: 'Зарегистрировать @$handle'),
          Text(
            'Вставьте публичный ключ бота из шага 2 — приложение зарегистрирует '
            'ник на relay и выдаст код заявки. Вручную писать боту Lib не нужно.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pubCtrl,
            maxLines: 2,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Публичный ключ бота (64 hex)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _registering ? null : _register,
            icon: _registering
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.app_registration),
            label: Text(_registering ? 'Регистрируем…' : 'Зарегистрировать'),
          ),
          if (_result?.ok == true) ...[
            const SizedBox(height: 14),
            _InfoCard(
              icon: Icons.check_circle_outline,
              tone: cs.primary,
              text: 'Готово! @$handle зарегистрирован. '
                  'Код заявки для onboard: ${_result!.claimForOnboard}',
            ),
          ],
          const SizedBox(height: 22),

          // Шаг 4 — onboard + запуск
          const _StepHeader(n:4, title: 'Onboard и запуск'),
          Text(
            'Свяжите ключи с ником (создаст rlink_bot_config.json) и запустите бота:',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          _CodeBlock(
            text: 'python -m rlink_bot onboard '
                '${_result?.claimForOnboard.isNotEmpty == true ? _result!.claimForOnboard : '<код из шага 3>'} '
                '--file bot_keys.json\n'
                'python $fileName',
            onCopy: () => _copy(
                'python -m rlink_bot onboard '
                '${_result?.claimForOnboard.isNotEmpty == true ? _result!.claimForOnboard : '<код из шага 3>'} '
                '--file bot_keys.json\n'
                'python $fileName',
                'Команды скопированы'),
          ),
          Text(
            'Пока «python $fileName» запущен — бот онлайн и отвечает по вашим правилам. '
            'Остановите (Ctrl+C) — включится заглушка на relay.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 22),

          // Правила JSON (для повторного импорта)
          const _StepHeader(n:5, title: 'Резервная копия правил'),
          Text(
            'JSON правил — сохраните, чтобы позже снова открыть бота в конструкторе.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () =>
                _copy(BotCodeGenerator.rulesJson(bp), 'JSON правил скопирован'),
            icon: const Icon(Icons.data_object),
            label: const Text('Скопировать JSON правил'),
          ),
        ],
      ),
    );
  }
}

class _StepHeader extends StatelessWidget {
  final int n;
  final String title;
  const _StepHeader({required this.n, required this.title});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: cs.primary,
            child: Text('$n',
                style: TextStyle(
                    color: cs.onPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  final String text;
  final VoidCallback onCopy;
  final int? maxLines;
  const _CodeBlock({required this.text, required this.onCopy, this.maxLines});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: maxLines != null ? (maxLines! * 18.0) : double.infinity,
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12.5, height: 1.35),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Копировать'),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? tone;
  const _InfoCard({required this.icon, required this.text, this.tone});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = tone ?? cs.onSurfaceVariant;
    return Container(
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.withValues(alpha: 0.25)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: c, size: 22),
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
