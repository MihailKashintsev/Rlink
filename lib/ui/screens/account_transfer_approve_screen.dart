import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/account_transfer_service.dart';
import '../../services/rlink_account_transfer_reset.dart';

/// Full-screen "someone wants to transfer your account" approval flow —
/// structurally the same pattern as `showPairRequestScreen` in
/// chat_list_screen.dart (opaque:true full-screen slide-in; the "new
/// design" theme's transparent scaffoldBackgroundColor means anything less
/// than opaque:true here lets the previous screen bleed through, the same
/// bug fixed there earlier this session).
void showAccountTransferApprovalScreen(
    BuildContext context, IncomingTransferRequest request) {
  Navigator.of(context).push(PageRouteBuilder(
    opaque: true,
    pageBuilder: (_, __, ___) => AccountTransferApproveScreen(request: request),
    transitionsBuilder: (_, anim, __, child) {
      return SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      );
    },
    transitionDuration: const Duration(milliseconds: 350),
  ));
}

enum _Step { confirm, categories, sending, readyToWipe, wiping }

class AccountTransferApproveScreen extends StatefulWidget {
  final IncomingTransferRequest request;
  const AccountTransferApproveScreen({super.key, required this.request});

  @override
  State<AccountTransferApproveScreen> createState() =>
      _AccountTransferApproveScreenState();
}

class _AccountTransferApproveScreenState
    extends State<AccountTransferApproveScreen> {
  _Step _step = _Step.confirm;
  bool _contacts = true;
  bool _channels = true;
  bool _groups = true;
  bool _emojiPacks = true;
  bool _dmHistory = true;
  bool _settings = true;
  bool _stickers = true;

  TransferCategories get _categories => TransferCategories(
        contacts: _contacts,
        channels: _channels,
        groups: _groups,
        emojiPacks: _emojiPacks,
        dmHistory: _dmHistory,
        settings: _settings,
        stickers: _stickers,
      );

  void _onNo() {
    unawaited(AccountTransferService.instance.deny());
    Navigator.of(context).pop();
  }

  void _onYes() => setState(() => _step = _Step.categories);

  Future<void> _startTransfer() async {
    setState(() => _step = _Step.sending);
    AccountTransferService.instance.readyToWipe.addListener(_onAckReady);
    await AccountTransferService.instance.approveAndSend(_categories);
  }

  void _onAckReady() {
    if (!mounted) return;
    if (AccountTransferService.instance.readyToWipe.value) {
      setState(() => _step = _Step.readyToWipe);
    }
  }

  Future<void> _wipe({required bool forced}) async {
    if (!forced && !AccountTransferService.instance.hasVerifiedAck) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Стереть это устройство?'),
        content: Text(
          forced
              ? 'Подтверждение с нового устройства не получено. Стирайте только '
                  'если вы точно убедились, что перенос завершился успешно на '
                  'новом устройстве — отменить это действие нельзя.'
              : 'Аккаунт перенесён. Сейчас с этого устройства будут удалены ключи, '
                  'вся переписка и профиль. Отменить нельзя.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Стереть'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _step = _Step.wiping);
    await AccountTransferService.instance.notifyWiping();
    if (!mounted) return;
    await rlinkPerformAccountTransferWipe(context);
  }

  @override
  void dispose() {
    AccountTransferService.instance.readyToWipe.removeListener(_onAckReady);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: switch (_step) {
          _Step.confirm => _confirmView(theme),
          _Step.categories => _categoriesView(theme),
          _Step.sending => _progressView(theme, 'Отправка…', showForcedWipeFallback: true),
          _Step.readyToWipe => _readyToWipeView(theme),
          _Step.wiping => _progressView(theme, 'Стирание этого устройства…'),
        },
      ),
    );
  }

  Widget _confirmView(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(icon: const Icon(Icons.close), onPressed: _onNo),
              const Spacer(),
              Text('Перенос аккаунта',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              const SizedBox(width: 48),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: theme.colorScheme.primary.withValues(alpha: 0.4), width: 3),
                    ),
                    child: Icon(Icons.swap_horiz_rounded, color: theme.colorScheme.primary, size: 40),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    widget.request.label.isEmpty ? 'Новое устройство' : widget.request.label,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Пытается перенести ваш аккаунт на себя. Это вы?',
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'После подтверждения аккаунт полностью переедет на новое '
                            'устройство, а это устройство будет очищено. Отменить нельзя — '
                            'придётся переносить всё заново.',
                            style: theme.textTheme.bodySmall?.copyWith(color: Colors.red.shade300),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _onYes,
                  child: const Text('Да, это я', style: TextStyle(fontSize: 16)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: _onNo,
                  child: const Text('Нет, это не я', style: TextStyle(fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _categoryTile(String title, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        title: Text(title),
        value: value,
        onChanged: onChanged,
      );

  Widget _categoriesView(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _step = _Step.confirm)),
              const Spacer(),
              Text('Что перенести',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              const SizedBox(width: 48),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              _categoryTile('Контакты', _contacts, (v) => setState(() => _contacts = v)),
              _categoryTile('Каналы', _channels, (v) => setState(() => _channels = v)),
              _categoryTile('Группы', _groups, (v) => setState(() => _groups = v)),
              _categoryTile('Эмодзи-наборы', _emojiPacks, (v) => setState(() => _emojiPacks = v)),
              _categoryTile('Переписка', _dmHistory, (v) => setState(() => _dmHistory = v)),
              _categoryTile('Настройки', _settings, (v) => setState(() => _settings = v)),
              _categoryTile('Стикеры', _stickers, (v) => setState(() => _stickers = v)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'История группы (сообщения) не переносится — только состав и настройки '
                  'группы. Это уже действующее ограничение синхронизации, не новое для '
                  'переноса аккаунта.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Начиная перенос, вы соглашаетесь, что это устройство будет очищено. '
                  'Отменить нельзя.',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.red.shade300),
                  textAlign: TextAlign.center,
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _startTransfer,
                  child: const Text('Начать перенос', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _progressView(ThemeData theme, String label, {bool showForcedWipeFallback = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<TransferProgress?>(
              valueListenable: AccountTransferService.instance.progress,
              builder: (_, p, __) {
                final fraction = (p != null && p.total > 0) ? p.done / p.total : null;
                return SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(value: fraction, strokeWidth: 4),
                );
              },
            ),
            const SizedBox(height: 20),
            Text(label, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            ValueListenableBuilder<TransferProgress?>(
              valueListenable: AccountTransferService.instance.progress,
              builder: (_, p, __) => Text(
                p?.phase ?? '',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            if (showForcedWipeFallback) ...[
              const SizedBox(height: 28),
              TextButton(
                onPressed: () => _wipe(forced: true),
                child: Text(
                  'Уже перенеслось, но подтверждение не приходит?',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _readyToWipeView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: Colors.green.shade400, size: 56),
            const SizedBox(height: 16),
            Text('Перенос подтверждён новым устройством',
                style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: () => _wipe(forced: false),
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Стереть это устройство', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
