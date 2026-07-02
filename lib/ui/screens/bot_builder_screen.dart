import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/bot_blueprint.dart';
import '../../services/bot_blueprint_store.dart';
import 'bot_builder_export_screen.dart';

/// No-code конструктор бота: правила «триггер → ответ» без единой строки кода.
/// На выходе — готовый Python-файл (см. [BotBuilderExportScreen]).
class BotBuilderScreen extends StatefulWidget {
  /// Существующий черновик для редактирования; null — создать новый.
  final BotBlueprint? existing;
  const BotBuilderScreen({super.key, this.existing});

  @override
  State<BotBuilderScreen> createState() => _BotBuilderScreenState();
}

class _BotBuilderScreenState extends State<BotBuilderScreen> {
  late BotBlueprint _bp;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _handleCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _welcomeCtrl;
  late final TextEditingController _fallbackCtrl;
  final _previewCtrl = TextEditingController();
  final List<_PreviewLine> _preview = [];

  static const _emojiChoices = [
    '🤖', '📚', '😀', '💬', '⚡', '🛎️', '🎧', '🛒', '📊', '🧠', '🎮', '🌤️',
    '💡', '🔔', '🌟', '🐱', '🚀', '🍕', '🎯', '❤️',
  ];
  static const _colorChoices = [
    0xFF5C6BC0, 0xFF21A038, 0xFFFFB300, 0xFFE53935, 0xFF8E24AA,
    0xFF00897B, 0xFF3949AB, 0xFFF4511E, 0xFF6D4C41, 0xFF546E7A,
  ];

  @override
  void initState() {
    super.initState();
    _bp = widget.existing?.clone() ??
        BotBlueprint.fresh(BotBlueprintStore.instance.newId());
    _nameCtrl = TextEditingController(text: _bp.name);
    _handleCtrl = TextEditingController(text: _bp.handle);
    _descCtrl = TextEditingController(text: _bp.description);
    _welcomeCtrl = TextEditingController(text: _bp.welcomeText);
    _fallbackCtrl = TextEditingController(text: _bp.fallbackText);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _handleCtrl.dispose();
    _descCtrl.dispose();
    _welcomeCtrl.dispose();
    _fallbackCtrl.dispose();
    _previewCtrl.dispose();
    super.dispose();
  }

  void _syncFromControllers() {
    _bp.name = _nameCtrl.text.trim();
    _bp.handle = _handleCtrl.text.trim();
    _bp.description = _descCtrl.text.trim();
    _bp.welcomeText = _welcomeCtrl.text;
    _bp.fallbackText = _fallbackCtrl.text;
  }

  Future<void> _save() async {
    _syncFromControllers();
    await BotBlueprintStore.instance.save(_bp);
  }

  Future<void> _generate() async {
    _syncFromControllers();
    if (_bp.name.trim().isEmpty) {
      _toast('Дайте боту имя.');
      return;
    }
    if (!_bp.handleValid) {
      _toast('Ник: 2–32 символа (a-z, 0-9, _).');
      return;
    }
    await _save();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BotBuilderExportScreen(blueprint: _bp.clone()),
      ),
    );
  }

  void _toast(String s) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  void _runPreview() {
    final text = _previewCtrl.text;
    if (text.trim().isEmpty) return;
    _syncFromControllers();
    setState(() {
      _preview.add(_PreviewLine(text: text, mine: true));
      _preview.add(_PreviewLine(text: _bp.previewReply(text), mine: false));
      _previewCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Новый бот' : 'Бот'),
        actions: [
          IconButton(
            tooltip: 'Сохранить черновик',
            icon: const Icon(Icons.save_outlined),
            onPressed: () async {
              await _save();
              if (mounted) _toast('Черновик сохранён');
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _sectionTitle('Профиль'),
          _profileCard(),
          const SizedBox(height: 20),
          _sectionTitle('Приветствие'),
          _hint('Ответ на /start, /menu и на первое сообщение.'),
          const SizedBox(height: 8),
          TextField(
            controller: _welcomeCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Привет! Я бот…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          _ButtonsEditor(
            title: 'Кнопки приветствия',
            buttons: _bp.welcomeButtons,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 20),
          _sectionTitle('Правила'),
          _hint('Срабатывает первое подходящее правило сверху вниз.'),
          const SizedBox(height: 8),
          ..._bp.rules.asMap().entries.map((e) => _ruleCard(e.key, e.value)),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: () => setState(() => _bp.rules.add(BotRule(
                  type: BotTriggerType.command,
                  pattern: '',
                  reply: '',
                ))),
            icon: const Icon(Icons.add),
            label: const Text('Добавить правило'),
          ),
          const SizedBox(height: 20),
          _sectionTitle('Если ничего не совпало'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _bp.echoOnUnmatched,
            onChanged: (v) => setState(() => _bp.echoOnUnmatched = v),
            title: const Text('Эхо — повторять сообщение пользователя'),
          ),
          if (!_bp.echoOnUnmatched) ...[
            TextField(
              controller: _fallbackCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                hintText: 'Не понял. Напишите /help…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            _ButtonsEditor(
              title: 'Кнопки ответа',
              buttons: _bp.fallbackButtons,
              onChanged: () => setState(() {}),
            ),
          ],
          const SizedBox(height: 20),
          _sectionTitle('Предпросмотр'),
          _previewPanel(),
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: _generate,
            icon: const Icon(Icons.terminal),
            label: const Text('Готово → получить код'),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(s,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
      );

  Widget _hint(String s) => Text(s,
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant));

  Widget _profileCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: _pickAvatar,
                  child: CircleAvatar(
                    radius: 28,
                    backgroundColor: Color(_bp.color),
                    child: Text(_bp.emoji,
                        style: const TextStyle(fontSize: 26)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _nameCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Имя бота',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _handleCtrl,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[a-zA-Z0-9_]')),
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: '@ник',
                          isDense: true,
                          prefixText: '@',
                          border: const OutlineInputBorder(),
                          helperText: _handleCtrl.text.isEmpty
                              ? 'a-z, 0-9, _  (2–32)'
                              : (_bp.handleValid
                                  ? '@${_bp.sanitizedHandle}'
                                  : 'слишком коротко'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                labelText: 'Описание (для каталога)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAvatar() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Эмодзи',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _emojiChoices
                    .map((e) => InkWell(
                          onTap: () {
                            setState(() => _bp.emoji = e);
                            setSheet(() {});
                          },
                          child: CircleAvatar(
                            radius: 20,
                            backgroundColor: _bp.emoji == e
                                ? Color(_bp.color)
                                : Theme.of(ctx)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            child: Text(e,
                                style: const TextStyle(fontSize: 20)),
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 16),
              const Text('Цвет',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _colorChoices
                    .map((c) => InkWell(
                          onTap: () {
                            setState(() => _bp.color = c);
                            setSheet(() {});
                          },
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: Color(c),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _bp.color == c
                                    ? Theme.of(ctx).colorScheme.onSurface
                                    : Colors.transparent,
                                width: 3,
                              ),
                            ),
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Готово'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ruleCard(int index, BotRule rule) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Правило ${index + 1}',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant)),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () =>
                      setState(() => _bp.rules.removeAt(index)),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  flex: 4,
                  child: DropdownButtonFormField<BotTriggerType>(
                    initialValue: rule.type,
                    isDense: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: BotTriggerType.values
                        .map((t) => DropdownMenuItem(
                              value: t,
                              child: Text(t.label,
                                  style: const TextStyle(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => rule.type = v ?? rule.type),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 5,
                  child: TextFormField(
                    initialValue: rule.pattern,
                    onChanged: (v) => rule.pattern = v,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: rule.type.hint,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: rule.reply,
              maxLines: 3,
              onChanged: (v) => rule.reply = v,
              decoration: const InputDecoration(
                labelText: 'Ответ',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            _ButtonsEditor(
              title: 'Кнопки',
              buttons: rule.buttons,
              onChanged: () => setState(() {}),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewPanel() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          if (_preview.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Напишите сообщение — увидите ответ бота',
                  style: TextStyle(color: cs.onSurfaceVariant)),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView(
                shrinkWrap: true,
                children:
                    _preview.map((l) => _PreviewBubble(line: l)).toList(),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _previewCtrl,
                  onSubmitted: (_) => _runPreview(),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Тест-сообщение…',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _runPreview,
                icon: const Icon(Icons.send),
              ),
              if (_preview.isNotEmpty)
                IconButton(
                  tooltip: 'Очистить',
                  onPressed: () => setState(_preview.clear),
                  icon: const Icon(Icons.clear_all),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewLine {
  final String text;
  final bool mine;
  _PreviewLine({required this.text, required this.mine});
}

class _PreviewBubble extends StatelessWidget {
  final _PreviewLine line;
  const _PreviewBubble({required this.line});

  static final _btnRe = RegExp(r'\[btn:([^\|\]]+)\|([^\]]+)\]');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final chips = _btnRe
        .allMatches(line.text)
        .map((m) => m.group(1)!.trim())
        .toList();
    final body = line.text.replaceAll(_btnRe, '').trim();
    return Align(
      alignment: line.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.62),
        decoration: BoxDecoration(
          color: line.mine ? cs.primary : cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: line.mine ? null : Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (body.isNotEmpty)
              Text(body,
                  style: TextStyle(
                      color: line.mine ? cs.onPrimary : cs.onSurface)),
            if (chips.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: chips
                      .map((c) => Chip(
                            label: Text(c,
                                style: const TextStyle(fontSize: 12)),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ))
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Компактный редактор набора кнопок (метка + команда).
class _ButtonsEditor extends StatelessWidget {
  final String title;
  final List<BotButton> buttons;
  final VoidCallback onChanged;
  const _ButtonsEditor({
    required this.title,
    required this.buttons,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 12.5,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
              onPressed: () {
                buttons.add(BotButton(label: '', command: '/'));
                onChanged();
              },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Кнопка'),
            ),
          ],
        ),
        ...buttons.asMap().entries.map((e) {
          final i = e.key;
          final b = e.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: TextFormField(
                    initialValue: b.label,
                    onChanged: (v) => b.label = v,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Метка',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 5,
                  child: TextFormField(
                    initialValue: b.command,
                    onChanged: (v) => b.command = v,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '/команда',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    buttons.removeAt(i);
                    onChanged();
                  },
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
