import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../models/contact.dart';
import '../../models/group.dart';
import '../../models/group_goal.dart';
import '../../services/chat_storage_service.dart';
import '../../services/group_service.dart';
import '../design/rlink_design.dart';
import '../widgets/forward_target_sheet.dart';
import '../widgets/goal_message_card.dart';
import '../widgets/invites_tray.dart';
import '../widgets/markdown_editing_controller.dart';
import '../widgets/smooth_caret_field.dart';
import '../widgets/spring_menu_button.dart';
import '../widgets/spring_search_palette.dart';
import '../widgets/spring_value_text.dart';
import '../widgets/timed_undo_button.dart';
import '../widgets/video_scrubber.dart';

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
  final _smoothCaretController = TextEditingController(text: 'smooth caret');
  final _plainCaretController = TextEditingController(text: 'normal caret');
  int _scrubberPosMs = 40000;
  static const _scrubberDurationMs = 180000;
  static const _demoGoalMessageId = 'demo-goal-message-1';

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
    unawaited(_ensureDemoGoal());
  }

  Future<void> _ensureDemoGoal() async {
    final existingMsg = await GroupService.instance.getMessage(_demoGoalMessageId);
    if (existingMsg != null) return;
    final goal = GroupGoal(
      title: 'Прочитать 3 книги в этом месяце',
      deadlineMs: DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch,
      creatorId: 'demo-creator',
      items: const [
        GoalItem(title: 'Книга 1'),
        GoalItem(title: 'Книга 2'),
        GoalItem(title: 'Книга 3'),
      ],
    );
    await GroupService.instance.saveMessage(GroupMessage(
      id: _demoGoalMessageId,
      groupId: 'demo-group',
      senderId: 'demo-creator',
      isOutgoing: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      goalJson: goal.encode(),
    ));
  }

  @override
  void dispose() {
    _searchController.dispose();
    _mentionDemoController.dispose();
    _smoothCaretController.dispose();
    _plainCaretController.dispose();
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
          _section(
            context,
            title: 'Плавный курсор (SmoothCaretField)',
            subtitle:
                'Кликайте/печатайте в верхнем поле — курсор плавно "долетает" '
                'до новой позиции вместо мгновенного скачка. Нижнее — обычное '
                'поле для сравнения. Однострочный виджет — в реальный '
                'многострочный композер пока не встраивал, см. пояснение в '
                'чате.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.outlineVariant),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SmoothCaretField(
                    controller: _smoothCaretController,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _plainCaretController,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
              ],
            ),
          ),
          _section(
            context,
            title: 'Видео-скраббер (RlinkVideoScrubber)',
            subtitle:
                'Наведите/зажмите на полосе — она растёт и сверху всплывает '
                'таймер перемотки, следующий за курсором/пальцем.',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(10),
              ),
              child: RlinkVideoScrubber(
                positionMs: _scrubberPosMs,
                durationMs: _scrubberDurationMs,
                bufferedMs: (_scrubberPosMs + 30000).clamp(0, _scrubberDurationMs),
                formatTime: (d) =>
                    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}',
                onChanged: (v) => setState(() => _scrubberPosMs = v),
              ),
            ),
          ),
          _section(
            context,
            title: 'Цель темы (GoalMessageCard)',
            subtitle:
                'Реальная карточка на реальном сообщении в локальной БД — '
                '"Присоединиться" и чек-лист действительно пишут через '
                'GroupService.applyGoalAction, как в настоящем чате.',
            child: ValueListenableBuilder<int>(
              valueListenable: GroupService.instance.version,
              builder: (context, _, __) {
                return FutureBuilder(
                  future:
                      GroupService.instance.getMessage(_demoGoalMessageId),
                  builder: (context, snap) {
                    final goal = GroupGoal.tryDecode(snap.data?.goalJson);
                    if (goal == null) {
                      return const SizedBox(
                        height: 40,
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return GoalMessageCard(
                      messageId: _demoGoalMessageId,
                      goal: goal,
                      cs: cs,
                    );
                  },
                );
              },
            ),
          ),
          _section(
            context,
            title: 'RlinkDesign.frosted() — настоящий iOS Liquid Glass',
            subtitle: Platform.isIOS
                ? 'Это уже реальный путь, которым теперь рендерится нижняя '
                    'навигация и другой "стеклянный" хром — не отдельный '
                    'спайк. На iOS 26+ RlinkDesign.frosted() сам подставляет '
                    'нативную UIGlassEffect-вьюху вместо BackdropFilter '
                    '(на более старых iOS — системный блюр); контент внутри '
                    'остаётся обычным Flutter-виджетом.'
                : 'Нативное стекло — только iOS; здесь используется обычный '
                    'BackdropFilter-фолбэк.',
            child: SizedBox(
              height: 260,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    ListView(
                      padding: const EdgeInsets.all(12),
                      children: List.generate(10, (i) {
                        final hue = (i * 36).toDouble();
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          height: 48,
                          decoration: BoxDecoration(
                            color: HSVColor.fromAHSV(1, hue, 0.6, 0.9)
                                .toColor(),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Text(
                            'Контент за стеклом #$i',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        );
                      }),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 16,
                      child: RlinkDesign.frosted(
                        context: context,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25)),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 20, vertical: 14),
                          child: Text(
                            'RlinkDesign.frosted()',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
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
