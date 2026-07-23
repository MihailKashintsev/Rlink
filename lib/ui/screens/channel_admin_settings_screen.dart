import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/app_l10n.dart';

import '../../models/channel.dart';
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
    return 'Свободно ${_fmtGb(free)} из ${_fmtGb(limit)}';
  }

  String _fmtGb(int bytes) {
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} ГБ';
    return '${(bytes / mb).toStringAsFixed(0)} МБ';
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

  bool get _canTransferOwnership {
    final ch = _channel;
    if (ch == null) return false;
    return ch.subscriberIds.any((id) => id != ch.adminId);
  }

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
        const SnackBar(
          content:
              Text('Заявка на верификацию отправлена администраторам сети'),
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
        content: const Text('Канал и все посты будут удалены навсегда.'),
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
      const SnackBar(
        content: Text(
          'Чтобы выйти без удаления канала, сначала передайте владение '
          'ниже, затем откройте профиль канала и нажмите «Отписаться».',
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
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Подписчики канала',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (current.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет подписчиков',
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
                                ? 'Модератор · ${uid.substring(0, 12)}…'
                                : '${uid.substring(0, 12)}…',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.person_remove_outlined,
                                color: Colors.red),
                            tooltip: 'Исключить',
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
      if (id == _myId) return 'Вы';
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
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Модераторы канала',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                if (subscribers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет подписчиков для назначения',
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

  Future<void> _showTransferOwnershipDialog() async {
    final ch = _channel;
    if (ch == null || !_canTransferOwnership) return;

    final candidates =
        ch.subscriberIds.where((id) => id != ch.adminId).toList();
    if (candidates.isEmpty) return;

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
          title: const Text('Передать владение'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Новый владелец получит права администратора. '
                  'Рекомендуется сделать полный резерв истории на ваш Google Диск '
                  'пока у вас есть доступ админа — затем данные можно импортировать под новым аккаунтом при необходимости.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: picked,
                  decoration: const InputDecoration(
                    labelText: 'Новый владелец',
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
                  title: const Text('Сделать резерв на мой Google Диск сейчас'),
                  subtitle: const Text(
                    'Перед передачей прав',
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
              child: const Text('Передать'),
            ),
          ],
        ),
      ),
    );

    if (ok != true || picked == null || !mounted) return;
    final newAdminId = picked!;

    if (backupFirst) {
      try {
        await ChannelBackupService.instance.publishBackup(ch);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Резерв на Google Диск выполнен'),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          final go = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Ошибка резерва'),
              content: Text('$e'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(AppL10n.t('common_cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Всё равно передать'),
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
        const SnackBar(content: Text('Не удалось передать владение')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Владение передано. Откройте профиль канала и нажмите «Отписаться», чтобы выйти.',
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
        body: const Center(child: Text('Недостаточно прав для настроек канала')),
      );
    }

    final theme = Theme.of(context);
    final email = _driveStatus?.email;
    final hasEmail = email != null && email.isNotEmpty;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(title: Text('Настройки: ${ch.name}')),
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
            title: const Text('Google-аккаунт'),
            subtitle: Text(
              hasEmail
                  ? (_driveSpaceLabel.isEmpty
                      ? email!
                      : '${email!}\n$_driveSpaceLabel')
                  : 'Не привязан — Настройки → Google Drive',
              style: TextStyle(
                fontSize: 12,
                color: hasEmail
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
              ),
            ),
          ),
          const Divider(height: 24),

          // ── Профиль ───────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Редактировать профиль'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openEditDialog,
          ),

          // ── Статистика ────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: Text(AppL10n.t('cm_subscribers')),
            subtitle: Text('${ch.subscriberIds.length} подписчиков',
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
            title: const Text('Модераторы'),
            subtitle: Text('${ch.moderatorIds.length} модераторов',
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
                ? 'Выключить комментарии'
                : 'Включить комментарии'),
            onTap: amOwner ? _toggleComments : null,
          ),

          // ── Команда ───────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('Команда и подписи'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _manageStaffAndLinks,
          ),

          // ── Только для владельца ──────────────────────────────────────
          if (amOwner) ...[
            if (!ch.verified)
              ListTile(
                leading: const Icon(Icons.verified_outlined),
                title: const Text('Подать на верификацию'),
                onTap: _requestVerification,
              ),
            if (_canTransferOwnership)
              ListTile(
                leading: const Icon(Icons.swap_horiz_outlined),
                title: const Text('Передать владение'),
                subtitle: const Text(
                  'Другой подписчик станет администратором',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: _showTransferOwnershipDialog,
              ),
            ListTile(
              leading: const Icon(Icons.logout_outlined),
              title: const Text('Покинуть канал'),
              subtitle: const Text(
                'После передачи владения — через «Отписаться» в профиле',
                style: TextStyle(fontSize: 12),
              ),
              onTap: _showLeaveHint,
            ),
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Удалить канал',
                  style: TextStyle(color: Colors.red)),
              onTap: _deleteChannel,
            ),
          ],
        ],
      ),
    );
  }
}
