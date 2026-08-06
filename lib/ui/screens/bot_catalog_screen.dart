import 'package:flutter/material.dart';

import '../../models/bot_blueprint.dart';
import '../../models/contact.dart';
import '../../services/ai_bot_constants.dart';
import '../../services/app_settings.dart';
import '../../services/bot_blueprint_store.dart';
import '../../services/chat_storage_service.dart';
import '../rlink_nav_routes.dart';
import 'bot_builder_screen.dart';
import '../../services/premium_service.dart';
import '../widgets/premium_gate.dart';
import 'bot_developer_guide_screen.dart';
import 'chat_screen.dart';

class BotCatalogScreen extends StatefulWidget {
  const BotCatalogScreen({super.key});

  @override
  State<BotCatalogScreen> createState() => _BotCatalogScreenState();
}

class _BotCatalogScreenState extends State<BotCatalogScreen> {
  bool _starting = false;
  List<BotBlueprint> _myBots = [];

  @override
  void initState() {
    super.initState();
    _loadMyBots();
  }

  Future<void> _loadMyBots() async {
    final list = await BotBlueprintStore.instance.load();
    if (!mounted) return;
    setState(() => _myBots = List.of(list));
  }

  Future<void> _openBuilder({BotBlueprint? existing}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => PremiumGate(
                feature: PremiumFeature.botBuilder,
                title: 'Конструктор ботов',
                description:
                    'Создание ботов в no-code конструкторе входит в Rlink Premium.',
                child: BotBuilderScreen(existing: existing),
              )),
    );
    await _loadMyBots();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = AppSettings.instance.enabledBotIds.toSet();
    const bots = kBuiltinAiBots;
    return Scaffold(
      appBar: AppBar(title: const Text('Боты')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _buildCreateCard(context),
          _buildDevGuideTile(context),
          if (_myBots.isNotEmpty) ...[
            _sectionLabel('Мои боты (черновики)'),
            ..._myBots.map(_buildMyBotTile),
          ],
          _sectionLabel('Встроенные'),
          Card(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Сторонние боты (из каталога relay) отвечают, когда запущен их процесс '
                'и есть связь с ретранслятором. В приложении с ними — как в обычной личке, '
                'но только текст: без файлов, голоса, видео и звонков. Сообщения идут по тем же '
                'E2E-правилам, что и с людьми; ваш профиль на них автоматически не «пушится» для проверки сети.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
          ...bots.map((bot) {
            final isEnabled = enabled.contains(bot.id);
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(bot.avatarColor),
                  child: Text(bot.avatarEmoji),
                ),
                title: Text(bot.name),
                subtitle: Text(
                  isEnabled
                      ? '${bot.description}\n${bot.link}'
                      : '${bot.description}\n${bot.link}\nНе активирован',
                ),
                trailing: FilledButton(
                  onPressed: _starting ? null : () => _startBot(bot),
                  child: Text(isEnabled ? 'Старт' : 'Активировать'),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _sectionLabel(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 6),
        child: Text(s,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                )),
      );

  Widget _buildCreateCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openBuilder(),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: cs.primary,
                child: Icon(Icons.smart_toy_outlined, color: cs.onPrimary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Создать своего бота',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      'No-code конструктор: правила «сообщение → ответ» без кода. '
                      'На выходе — готовый Python-файл для запуска у себя.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDevGuideTile(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: cs.secondaryContainer,
          child: Icon(Icons.menu_book_outlined, color: cs.onSecondaryContainer),
        ),
        title: const Text('Справка для разработчиков'),
        subtitle: const Text(
          'Как создать, развернуть и зарегистрировать своего бота + заявка на галочку',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BotDeveloperGuideScreen()),
        ),
      ),
    );
  }

  Widget _buildMyBotTile(BotBlueprint bp) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Color(bp.color),
          child: Text(bp.emoji),
        ),
        title: Text(bp.name.isEmpty ? 'Без имени' : bp.name),
        subtitle: Text(
          '${bp.sanitizedHandle.isEmpty ? 'без ника' : '@${bp.sanitizedHandle}'} · '
          '${bp.rules.length} правил',
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'edit') {
              await _openBuilder(existing: bp);
            } else if (v == 'delete') {
              await BotBlueprintStore.instance.delete(bp.id);
              await _loadMyBots();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Открыть / изменить')),
            PopupMenuItem(value: 'delete', child: Text('Удалить')),
          ],
        ),
        onTap: () => _openBuilder(existing: bp),
      ),
    );
  }

  Future<void> _startBot(AiBotDefinition bot) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final enabled = AppSettings.instance.enabledBotIds.toSet();
      if (!enabled.contains(bot.id)) {
        enabled.add(bot.id);
        await AppSettings.instance.setEnabledBotIds(enabled.toList());
      }
      final existing = await ChatStorageService.instance.getContact(bot.id);
      if (existing == null) {
        await ChatStorageService.instance.saveContact(Contact(
          publicKeyHex: bot.id,
          nickname: bot.name,
          avatarColor: bot.avatarColor,
          avatarEmoji: bot.avatarEmoji,
          addedAt: DateTime.now(),
        ));
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        rlinkChatRoute(ChatScreen(
          peerId: bot.id,
          peerNickname: bot.name,
          peerAvatarColor: bot.avatarColor,
          peerAvatarEmoji: bot.avatarEmoji,
        )),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}
