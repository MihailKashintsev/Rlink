import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/app_l10n.dart';

import '../../models/channel.dart';
import '../../services/backup_provider.dart';
import '../../services/channel_backup_service.dart';
import '../../services/channel_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/google_drive_channel_backup.dart';
import '../../services/gossip_router.dart';
import '../widgets/channel_staff_links_sheet.dart';
import 'channel_profile_edit_dialog.dart';

/// Настройки канала для владельца (пункты бывшего меню «⋯» в ленте).
class ChannelAdminSettingsScreen extends StatefulWidget {
  final String channelId;
  final bool allowModeratorDriveManagement;

  const ChannelAdminSettingsScreen({
    super.key,
    required this.channelId,
    this.allowModeratorDriveManagement = false,
  });

  @override
  State<ChannelAdminSettingsScreen> createState() =>
      _ChannelAdminSettingsScreenState();
}

class _ChannelAdminSettingsScreenState
    extends State<ChannelAdminSettingsScreen> {
  Channel? _channel;
  GoogleDriveSyncStatus? _driveStatus;

  String get _myId => CryptoService.instance.publicKeyHex;

  /// «Свободно X из Y» для привязанного Google-аккаунта (пусто, если квота
  /// недоступна). Только для отображения — управление Drive убрано из настроек
  /// канала, аккаунт привязывается в Настройки → Google Drive.
  String get _driveSpaceLabel {
    final st = _driveStatus;
    final free = st?.freeBytes;
    final limit = st?.limitBytes;
    if (free == null || limit == null || limit <= 0) return '';
    return AppL10n.f('Свободно {0} из {1}', [_fmtGb(free), _fmtGb(limit)]);
  }

  String _fmtGb(int bytes) {
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= gb) return AppL10n.f('{0} ГБ', [(bytes / gb).toStringAsFixed(1)]);
    return AppL10n.f('{0} МБ', [(bytes / mb).toStringAsFixed(0)]);
  }

  @override
  void initState() {
    super.initState();
    _load();
    ChannelService.instance.version.addListener(_load);
  }

  @override
  void dispose() {
    ChannelService.instance.version.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final ch = await ChannelService.instance.getChannel(widget.channelId);
    if (!mounted) return;
    setState(() => _channel = ch);
    if (ch != null) {
      final st =
          await GoogleDriveChannelBackup.getSyncStatus(interactive: false);
      if (mounted) setState(() => _driveStatus = st);
    } else if (mounted) {
      setState(() => _driveStatus = null);
    }
  }

  /// Ownership can only be handed to another administrator of the channel
  /// (moderator or link admin) — not to an arbitrary subscriber.
  List<String> get _transferCandidates {
    final ch = _channel;
    if (ch == null) return const [];
    return {...ch.moderatorIds, ...ch.linkAdminIds}
        .where((id) => id != ch.adminId)
        .toList();
  }

  bool get _canTransferOwnership => _channel?.adminId == _myId;

  Future<void> _toggleComments() async {
    final ch = _channel;
    if (ch == null) return;
    final updated = ch.copyWith(commentsEnabled: !ch.commentsEnabled);
    await ChannelService.instance.updateChannel(updated);
    await updated.broadcastGossipMeta();
    await _load();
  }

  Future<void> _requestVerification() async {
    final ch = _channel;
    if (ch == null || ch.verified) return;
    await GossipRouter.instance.sendVerificationRequest(
      channelId: ch.id,
      channelName: ch.name,
      adminId: ch.adminId,
      subscriberCount: ch.subscriberIds.length,
      avatarEmoji: ch.avatarEmoji,
      description: ch.description,
    );
    // The relay broadcast only reaches OTHER online peers, so a network admin
    // who owns this channel would never see their own request. Persist it
    // locally too, so it shows up in the admin panel on this device.
    await ChannelService.instance.addVerificationRequest(VerificationRequest(
      channelId: ch.id,
      channelName: ch.name,
      adminId: ch.adminId,
      subscriberCount: ch.subscriberIds.length,
      avatarEmoji: ch.avatarEmoji,
      description: ch.description,
      requestedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(AppL10n.t('Заявка на верификацию отправлена администраторам сети')),
        ),
      );
    }
    await _load();
  }

  Future<void> _deleteChannel() async {
    final ch = _channel;
    if (ch == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.t('cm_delete_channel_q')),
        content: Text(AppL10n.t('Канал и все посты будут удалены навсегда.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppL10n.t('common_cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(AppL10n.t('common_delete')),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await ChannelService.instance.deleteChannel(ch.id);
    if (mounted) Navigator.pop(context);
  }

  void _showLeaveHint() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppL10n.t('Чтобы выйти без удаления канала, сначала передайте владение ниже, затем откройте профиль канала и нажмите «Отписаться».'),
        ),
      ),
    );
  }

  Future<void> _openEditDialog() async {
    final ch = _channel;
    if (ch == null) return;
    await showChannelProfileEditDialog(
      context,
      channel: ch,
      showPolicyToggles: true,
      myId: _myId,
      onChannelUpdated: (updated) {
        if (mounted) setState(() => _channel = updated);
      },
    );
    await _load();
  }

  /// Выбор хранилища резервной копии среди привязанных провайдеров (как у групп).
  Future<void> _pickBackupProvider() async {
    final ch = _channel;
    if (ch == null) return;
    final linked = BackupProviders.ids.where(BackupProviders.isLinked).toList();
    if (linked.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              AppL10n.t('Сначала привяжите Google Drive, OneDrive или Dropbox в Настройках'))));
      return;
    }
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppL10n.t('Хранилище резервной копии')),
        children: [
          for (final id in linked)
            RadioListTile<String>(
              value: id,
              groupValue: ch.backupProvider,
              title: Text(BackupProviders.label(id)),
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == ch.backupProvider) return;
    final updated = ch.copyWith(backupProvider: chosen);
    await ChannelService.instance.updateChannel(updated);
    if (mounted) setState(() => _channel = updated);
  }

  void _manageSubscribers() {
    final ch = _channel;
    if (ch == null) return;
    final contacts = ChatStorageService.instance.contactsNotifier.value;

    String nickFor(String id) {
      for (final c in contacts) {
        if (c.publicKeyHex == id) return c.nickname;
      }
      return '${id.substring(0, 8)}…';
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx2, setModal) {
          final current = ch.subscriberIds
              .where((id) => id != ch.adminId && id != _myId)
              .toList();
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(AppL10n.t('Подписчики канала'),
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (current.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(AppL10n.t('Нет подписчиков'),
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(ctx2).size.height * 0.5),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: current.length,
                      itemBuilder: (_, i) {
                        final uid = current[i];
                        final isMod = ch.moderatorIds.contains(uid);
                        return ListTile(
                          title: Text(nickFor(uid)),
                          subtitle: Text(
                            isMod
                                ? AppL10n.f('Модератор · {0}…', [uid.substring(0, 12)])
                                : '${uid.substring(0, 12)}…',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.person_remove_outlined,
                                color: Colors.red),
                            tooltip: AppL10n.t('Исключить'),
                            onPressed: () async {
                              await ChannelService.instance
                                  .removeSubscriber(ch.id, uid);
                              final fresh = await ChannelService.instance
                                  .getChannel(ch.id);
                              if (fresh != null && mounted) {
                                setState(() => _channel = fresh);
                                setModal(() {});
                                unawaited(ChannelBackupService.instance
                                    .publishBackupIfAdminDriveEnabled(ch.id));
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        });
      },
    );
  }

  void _manageModerators() {
    final ch = _channel;
    if (ch == null) return;
    final subscribers =
        ch.subscriberIds.where((id) => id != ch.adminId).toList();
    final contacts = ChatStorageService.instance.contactsNotifier.value;

    String nickFor(String id) {
      if (id == _myId) return AppL10n.t('Вы');
      for (final c in contacts) {
        if (c.publicKeyHex == id) return c.nickname;
      }
      return '${id.substring(0, 8)}…';
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx2, setModal) {
          // Read the LIVE channel, not the captured `ch` — otherwise the switch
          // reads stale moderatorIds after a toggle and snaps back.
          final mods = (_channel ?? ch).moderatorIds;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(AppL10n.t('Модераторы канала'),
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (subscribers.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(AppL10n.t('Нет подписчиков для назначения'),
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx2).size.height * 0.5,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: subscribers.length,
                      itemBuilder: (_, i) {
                        final uid = subscribers[i];
                        final isMod = mods.contains(uid);
                        return SwitchListTile(
                          title: Text(nickFor(uid)),
                          subtitle: Text(
                            '${uid.substring(0, 12)}…',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                          ),
                          value: isMod,
                          onChanged: (val) async {
                            final updated = await ChannelService.instance
                                .setModerator(ch.id, uid, val);
                            if (updated != null && mounted) {
                              setState(() => _channel = updated);
                              setModal(() {});
                              unawaited(updated.broadcastGossipMeta());
                              // Адресная доставка новому модератору — доходит
                              // через relay даже офлайн и для скрытых каналов,
                              // чтобы он реально получил роль (и доступ к меню).
                              if (val) {
                                unawaited(updated.broadcastGossipMeta(
                                    recipientId: uid));
                              }
                              // Re-publish Drive so subscribers see the new
                              // moderator list and moderator gets history access.
                              unawaited(ChannelBackupService.instance
                                  .publishBackupIfAdminDriveEnabled(ch.id));
                            }
                          },
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        });
      },
    );
  }

  void _manageStaffAndLinks() {
    final ch = _channel;
    if (ch == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StaffLinksEditorSheet(
        channel: ch,
        myId: _myId,
        onChannelRefreshed: (fresh) {
          if (mounted) setState(() => _channel = fresh);
        },
      ),
    );
  }

  /// Non-dismissible spinner dialog; returns a function that closes it.
  VoidCallback _showBlockingProgress(String text) {
    var open = true;
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 16),
            Expanded(child: Text(text)),
          ]),
        ),
      ),
    );
    return () {
      if (!open) return;
      open = false;
      if (nav.mounted) nav.pop();
    };
  }

  Future<void> _showTransferOwnershipDialog() async {
    final ch = _channel;
    if (ch == null || !_canTransferOwnership) return;

    final candidates = _transferCandidates;
    if (candidates.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(AppL10n.t('Передать владение')),
          content: Text(AppL10n.t(
              'Владение можно передать только администратору канала. Сначала назначьте администратора в разделе «Команда и подписи».')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppL10n.t('OK')),
            ),
          ],
        ),
      );
      return;
    }

    final contacts = ChatStorageService.instance.contactsNotifier.value;
    String nickFor(String id) {
      for (final c in contacts) {
        if (c.publicKeyHex == id) return c.nickname;
      }
      return '${id.substring(0, 8)}…';
    }

    String? picked = candidates.first;
    var backupFirst = true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(AppL10n.t('Передать владение')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppL10n.t('Новый владелец получит права администратора. Рекомендуется сделать полный резерв истории на ваш Google Диск пока у вас есть доступ админа — затем данные можно импортировать под новым аккаунтом при необходимости.'),
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: picked,
                  decoration: InputDecoration(
                    labelText: AppL10n.t('Новый владелец'),
                    border: OutlineInputBorder(),
                  ),
                  items: candidates
                      .map((id) => DropdownMenuItem(
                            value: id,
                            child: Text(nickFor(id)),
                          ))
                      .toList(),
                  onChanged: (v) => setD(() => picked = v),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: backupFirst,
                  onChanged: (v) => setD(() => backupFirst = v ?? true),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(AppL10n.t('Сделать резерв на мой Google Диск сейчас')),
                  subtitle: Text(
                    AppL10n.t('Перед передачей прав'),
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppL10n.t('common_cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppL10n.t('Передать')),
            ),
          ],
        ),
      ),
    );

    if (ok != true || picked == null || !mounted) return;
    final newAdminId = picked!;

    if (backupFirst) {
      // Visible progress + timeout: a stuck Drive upload used to leave the UI
      // silent after tapping "Передать" (looked like nothing happened).
      final progress = _showBlockingProgress(
          AppL10n.t('Резерв на Google Диск…'));
      try {
        await ChannelBackupService.instance
            .publishBackup(ch)
            .timeout(const Duration(seconds: 60));
        progress();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppL10n.t('Резерв на Google Диск выполнен')),
            ),
          );
        }
      } catch (e) {
        progress();
        if (mounted) {
          final go = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(AppL10n.t('Ошибка резерва')),
              content: Text('$e'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(AppL10n.t('common_cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(AppL10n.t('Всё равно передать')),
                ),
              ],
            ),
          );
          if (go != true) return;
        }
      }
    }

    final updated = await ChannelService.instance.transferOwnership(
      channelId: ch.id,
      newAdminId: newAdminId,
      currentAdminId: _myId,
    );
    if (!mounted) return;
    if (updated == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.t('Не удалось передать владение'))),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppL10n.t('Владение передано. Откройте профиль канала и нажмите «Отписаться», чтобы выйти.'),
        ),
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final ch = _channel;
    if (ch == null) {
      return Scaffold(
        appBar: AppBar(title: Text(AppL10n.t('cm_channel_settings'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final amOwner = ch.adminId == _myId;
    final amMod = !amOwner && ch.moderatorIds.contains(_myId);

    if (!amOwner && !amMod) {
      return Scaffold(
        appBar: AppBar(title: Text(AppL10n.t('cm_channel_settings'))),
        body: Center(child: Text(AppL10n.t('Недостаточно прав для настроек канала'))),
      );
    }

    final theme = Theme.of(context);
    final email = _driveStatus?.email;
    final hasEmail = email != null && email.isNotEmpty;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(title: Text(AppL10n.f('Настройки: {0}', [ch.name]))),
      body: ListView(
        children: [
          // ── Google Drive: только просмотр привязанного аккаунта ───────────
          // Все тумблеры/действия убраны намеренно: аккаунт привязывается в
          // Настройки → Google Drive владельцем устройства. Здесь — только
          // почта и свободное место; модераторы аккаунт менять не могут.
          ListTile(
            leading: Icon(
              Icons.add_to_drive_outlined,
              color: hasEmail ? theme.colorScheme.primary : null,
            ),
            isThreeLine: hasEmail && _driveSpaceLabel.isNotEmpty,
            title: Text(AppL10n.t('Google-аккаунт')),
            subtitle: Text(
              hasEmail
                  ? (_driveSpaceLabel.isEmpty
                      ? email!
                      : '${email!}\n$_driveSpaceLabel')
                  : AppL10n.t('Не привязан — Настройки → Google Drive'),
              style: TextStyle(
                fontSize: 12,
                color: hasEmail
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz_outlined),
            title: Text(AppL10n.t('Хранилище резервной копии')),
            subtitle: Text(AppL10n.f('Сейчас: {0}', [BackupProviders.label(ch.backupProvider)]),
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(_pickBackupProvider()),
          ),
          const Divider(height: 24),

          // ── Профиль ───────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(AppL10n.t('Редактировать профиль')),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openEditDialog,
          ),

          // ── Статистика ────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: Text(AppL10n.t('cm_subscribers')),
            subtitle: Text(AppL10n.f('{0} подписчиков', [ch.subscriberIds.length]),
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('${ch.subscriberIds.length}',
                      style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700)),
                ),
                if (amOwner) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right),
                ],
              ],
            ),
            onTap: amOwner ? _manageSubscribers : null,
          ),
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: Text(AppL10n.t('Модераторы')),
            subtitle: Text(AppL10n.f('{0} модераторов', [ch.moderatorIds.length]),
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color:
                        theme.colorScheme.secondary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('${ch.moderatorIds.length}',
                      style: TextStyle(
                          color: theme.colorScheme.secondary,
                          fontWeight: FontWeight.w700)),
                ),
                if (amOwner) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right),
                ],
              ],
            ),
            onTap: amOwner ? _manageModerators : null,
          ),

          // ── Настройки ─────────────────────────────────────────────────
          ListTile(
            enabled: amOwner,
            leading: Icon(
              ch.commentsEnabled
                  ? Icons.comments_disabled_outlined
                  : Icons.comment_outlined,
            ),
            title: Text(ch.commentsEnabled
                ? AppL10n.t('Выключить комментарии')
                : AppL10n.t('Включить комментарии')),
            onTap: amOwner ? _toggleComments : null,
          ),

          // ── Команда ───────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(AppL10n.t('Команда и подписи')),
            trailing: const Icon(Icons.chevron_right),
            onTap: _manageStaffAndLinks,
          ),

          // ── Только для владельца ──────────────────────────────────────
          if (amOwner) ...[
            if (!ch.verified)
              ListTile(
                leading: const Icon(Icons.verified_outlined),
                title: Text(AppL10n.t('Подать на верификацию')),
                onTap: _requestVerification,
              ),
            if (_canTransferOwnership)
              ListTile(
                leading: const Icon(Icons.swap_horiz_outlined),
                title: Text(AppL10n.t('Передать владение')),
                subtitle: Text(
                  AppL10n.t('Владельцем станет один из администраторов канала'),
                  style: TextStyle(fontSize: 12),
                ),
                onTap: _showTransferOwnershipDialog,
              ),
            ListTile(
              leading: const Icon(Icons.logout_outlined),
              title: Text(AppL10n.t('Покинуть канал')),
              subtitle: Text(
                AppL10n.t('После передачи владения — через «Отписаться» в профиле'),
                style: TextStyle(fontSize: 12),
              ),
              onTap: _showLeaveHint,
            ),
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(AppL10n.t('Удалить канал'),
                  style: TextStyle(color: Colors.red)),
              onTap: _deleteChannel,
            ),
          ],
        ],
      ),
    );
  }
}
