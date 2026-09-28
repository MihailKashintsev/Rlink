import 'package:flutter/material.dart';

import '../../models/contact.dart';
import '../../services/chat_storage_service.dart';
import '../../services/group_service.dart';
import '../widgets/forward_target_sheet.dart';
import '../widgets/invites_tray.dart';
import '../widgets/markdown_editing_controller.dart';
import '../widgets/spring_menu_button.dart';
import '../widgets/spring_search_palette.dart';
import '../widgets/spring_value_text.dart';
import '../widgets/timed_undo_button.dart';

/// Debug-only gallery for the skiper-ui-inspired components being built up
/// this batch — lets them be checked with fake data instead of needing real
/// contacts/messages/unread counts in the account under test. Add a new
/// section here for each new component as it lands; delete the whole file
/// once the batch has shipped and doesn't need side-by-side review anymore.
class DesignPreviewScreen extends StatefulWidget {
  const DesignPreviewScreen({super.key});

  @override
  State<DesignPreviewScreen> createState() => _DesignPreviewScreenState();
}

const _demoMentionId =
    'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12';

class _DesignPreviewScreenState extends State<DesignPreviewScreen> {
  int _counter = 3;
  bool _searchOpen = false;
  final _searchController = TextEditingController();
  late final _mentionDemoController =
      MarkdownEditingController(text: 'Привет, &$_demoMentionId как дела?');

  @override
  void initState() {
    super.initState();
    final existing = ChatStorageService.instance.contactsNotifier.value;
    if (!existing.any((c) => c.publicKeyHex == _demoMentionId)) {
      ChatStorageService.instance.contactsNotifier.value = [
        ...existing,
        Contact(
          publicKeyHex: _demoMentionId,
          nickname: 'Алиса',
          avatarColor: 0xFF8E24AA,
          avatarEmoji: '',
          addedAt: DateTime.now(),
        ),
      ];
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _mentionDemoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Витрина новых анимаций')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section(
            context,
            title: '«+»-меню (SpringMenuButton)',
            subtitle: 'Заменяет "..." на главном экране чатов.',
            child: Align(
              // Панель раскрывается от нижне-правого угла кнопки влево-вверх
              // (как у правого края AppBar) — кнопку тоже держим справа.
              alignment: Alignment.centerRight,
              child: SpringMenuButton(
                tooltip: 'Меню',
                actions: [
                  SpringMenuAction(
                    icon: Icons.smart_toy_outlined,
                    label: 'Боты',
                    onTap: () {},
                  ),
                  SpringMenuAction(
                    icon: Icons.extension_outlined,
                    label: 'Дополнения',
                    onTap: () {},
                  ),
                  SpringMenuAction(
                    icon: Icons.group_add_outlined,
                    label: 'Новая группа',
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
          _section(
            context,
            title: 'Анимация чисел (SpringValueText)',
            subtitle:
                'Висит на бейдже непрочитанных в списке чатов — там пусто, '
                'пока нет непрочитанных сообщений, поэтому демо здесь.',
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SpringValueText(
                    value: _counter > 99 ? '99+' : '$_counter',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton.tonal(
                  onPressed: () => setState(() => _counter++),
                  child: const Text('+1'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () => setState(() => _counter = 0),
                  child: const Text('Сброс'),
                ),
              ],
            ),
          ),
          _section(
            context,
            title: 'Поиск (SpringSearchPalette)',
            subtitle:
                'Иконка морфится в плавающую панель с блюром. Результаты '
                'здесь — заглушка, не настоящий поиск.',
            child: Align(
              alignment: Alignment.centerRight,
              child: SpringSearchPalette(
                open: _searchOpen,
                onToggle: () => setState(() => _searchOpen = !_searchOpen),
                controller: _searchController,
                onQueryChanged: (_) => setState(() {}),
                hintText: 'Поиск...',
                tooltip: _searchOpen ? 'Закрыть' : 'Поиск',
                resultsBuilder: (ctx) {
                  final q = _searchController.text.trim().toLowerCase();
                  final all = ['Алиса', 'Борис', 'Виктор', 'Галя', 'Дима'];
                  final matches = q.isEmpty
                      ? all
                      : all.where((n) => n.toLowerCase().contains(q)).toList();
                  return ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      for (final n in matches)
                        ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.person)),
                          title: Text(n),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          _section(
            context,
            title: 'Кнопка-с-таймером (TimedUndoButton)',
            subtitle:
                'На удалении сообщения/чата/канала и выходе из группы — тап '
                'вооружает обратный отсчёт, повторный тап отменяет его.',
            child: Align(
              alignment: Alignment.centerLeft,
              child: TimedUndoButton(
                actionLabel: 'Удалить',
                undoLabel: 'Отмена',
                seconds: 4,
                onConfirmed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Удалено (демо)')),
                  );
                },
              ),
            ),
          ),
          _section(
            context,
            title: 'Пересылка (ForwardDmTargetSheet)',
            subtitle:
                'Настоящая функция пересылки — список реальный, но '
                'единственная строка "Избранное" не исключена, так что '
                'есть куда переслать. Панель растёт из самой кнопки.',
            child: Align(
              alignment: Alignment.centerLeft,
              child: Builder(
                builder: (btnCtx) => FilledButton.tonalIcon(
                  onPressed: () => showForwardDmTargetSheet(
                    btnCtx,
                    anchorRect: forwardAnchorRectOf(btnCtx),
                  ),
                  icon: const Icon(Icons.forward_rounded),
                  label: const Text('Переслать...'),
                ),
              ),
            ),
          ),
          _section(
            context,
            title: 'Приглашения (InvitesTray)',
            subtitle:
                'Реальный виджет — жмите "Добавить тестовое", появится '
                'сворачиваемый блок ниже.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton.tonal(
                  onPressed: () {
                    final n = GroupService.instance.pendingInvites.value.length;
                    GroupService.instance.addInvite(GroupInvite(
                      groupId: 'demo-group-$n',
                      groupName: 'Тестовая группа $n',
                      inviterId: 'demo-inviter',
                      inviterNick: 'Другдругов',
                      creatorId: 'demo-inviter',
                      memberIds: const ['demo-inviter'],
                      createdAt: DateTime.now().millisecondsSinceEpoch,
                    ));
                  },
                  child: const Text('Добавить тестовое приглашение'),
                ),
                const SizedBox(height: 10),
                const InvitesTray(),
              ],
            ),
          ),
          _section(
            context,
            title: 'Упоминания в поле ввода (MarkdownEditingController)',
            subtitle:
                'Поле уже содержит "&<id>" — реальный токен из @-пикера. '
                'Известный контакт показывается как "@Алиса"; наберите '
                '"&что-то-ещё" вручную, чтобы увидеть нераспознанный вид '
                '(просто "@").',
            child: TextField(
              controller: _mentionDemoController,
              maxLines: 2,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 4),
          Text(subtitle, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}
