import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../design/rlink_design.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app_version.dart';
import '../../l10n/app_l10n.dart';
import '../../services/update_service.dart';
import '../../services/app_lock_service.dart' show LockMethod;
import '../../main.dart' show isUpdateSupported, pendingUpdateNotifier;
import '../../models/contact.dart';
import '../../models/user_profile.dart';
import '../../services/app_settings.dart';
import '../../services/app_lock_service.dart';
import 'device_security_screen.dart';
import 'delivery_health_screen.dart';
import 'emoji_bindings_screen.dart';
import 'profile_privacy_screen.dart';
import '../../services/app_icon_service.dart';
import '../../services/google_drive_channel_backup.dart';
import '../../services/dropbox_backup.dart';
import '../../services/relay_oauth_link.dart';
import '../../services/transcription_engine.dart';
import '../../services/model_download_service.dart';
import '../app_palettes.dart';
import '../widgets/message_cache_clear_dialog.dart';
import '../../services/ble_service.dart';
import '../../services/connection_transport.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/profile_service.dart';
import '../../services/relay_service.dart';
import '../../services/runtime_platform.dart';
import '../../services/sound_effects_service.dart';
import '../../services/notification_service.dart';
import '../../services/web_notification_bridge.dart';
import '../../utils/web_file_store.dart';
import '../../utils/chat_background_picker.dart';
import '../widgets/channel_feed_image.dart' show storedImage;
import '../screens/rid_screen.dart';
import '../screens/stickers_hub_screen.dart';
import '../screens/emoji_hub_screen.dart';
import '../screens/music_screen.dart';
import '../screens/premium_status_screen.dart';
import '../../services/premium_service.dart';
import '../screens/chat_screen.dart';
import '../screens/diagnostics_screen.dart';
import '../screens/mesh_radar_screen.dart';
import '../screens/mesh_status_screen.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/update_restart_dialog.dart';
import '../widgets/status_emoji_view.dart';
import '../widgets/security_visuals.dart';
import '../widgets/google_sign_in_button.dart';
import '../screens/about_screen.dart';
import '../screens/documentation_screen.dart';
import '../screens/settings_data_page.dart';
import '../screens/input_bar_button_order_settings.dart';
import '../../main.dart' show sendProfileToAllContacts;
import '../widgets/reactions.dart';
import '../rlink_nav_routes.dart';
import 'qr_contact_screen.dart' show QrScanScreen;
import 'help_center_screen.dart';
import 'quick_video_settings_screen.dart';
import '../../models/quick_video.dart';

// ─────────────────────────────────────────────────────────────────────
// Shared top-level helpers
// ─────────────────────────────────────────────────────────────────────

/// Returns a consistently styled Scaffold for settings sub-screens.
Scaffold _subScaffold({
  required BuildContext context,
  required String title,
  required Widget body,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final nd = AppSettings.instance.newDesign;
  final bg = nd
      ? Theme.of(context).colorScheme.surface
      : (RlinkDesign.screenBg(context, isDark));
  return Scaffold(
    backgroundColor: bg,
    appBar: AppBar(
      title: Text(title),
      elevation: 0,
      scrolledUnderElevation: 0.5,
      backgroundColor: nd
          ? Theme.of(context).colorScheme.surface
          : (RlinkDesign.barBg(context, isDark)),
    ),
    body: body,
  );
}

/// Unlink linked device — used from both NetworkPage and child-device mode.
Future<void> doUnlinkDevice(BuildContext context) async {
  final settings = AppSettings.instance;
  final linkedKey = settings.linkedDevicePublicKey;
  final myProfile = ProfileService.instance.profile;
  if (linkedKey.isNotEmpty &&
      myProfile != null &&
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(linkedKey)) {
    await RelayService.instance.connect();
    await GossipRouter.instance.sendDeviceUnlink(
      publicKey: myProfile.publicKeyHex,
      recipientId: linkedKey,
    );
  }
  await settings.unlinkDevice();
  await applyConnectionTransport();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(AppL10n.t('cm_link_removed'))),
  );
}

/// Pick a contact, send them a companion-device link request — used from
/// both NetworkPage and the RID screen.
Future<void> requestDeviceLink(BuildContext context) async {
  final myProfile = ProfileService.instance.profile;
  if (myProfile == null) return;
  final useQr = await _pickLinkMethod(context);
  if (useQr == null) return;
  if (useQr) {
    // The scanned device doesn't need to be an existing contact — the new
    // device's own onboarding screen shows a QR of just its pubkey before
    // it has any profile at all (see onboarding_screen.dart's
    // "Это дополнительное устройство"). QrScanScreen sends the link
    // request itself once a code resolves.
    if (context.mounted) {
      await Navigator.of(context).push(rlinkPushRoute(
        const QrScanScreen(linkDeviceMode: true),
      ));
    }
    return;
  }
  if (!context.mounted) return;
  final contact = await _pickContactForLink(context);
  if (contact == null) return;

  final settings = AppSettings.instance;
  await settings.setConnectionMode(1);
  await applyConnectionTransport();
  await RelayService.instance.connect();
  if (!RelayService.instance.isConnected) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                AppL10n.t('Не удалось подключиться к интернет-ретранслятору'))),
      );
    }
    return;
  }
  await GossipRouter.instance.sendDeviceLinkRequest(
    publicKey: myProfile.publicKeyHex,
    nick: myProfile.nickname,
    username: myProfile.username,
    recipientId: contact.publicKeyHex,
  );
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
        content: Text(
            AppL10n.f('Запрос на связку отправлен: {0}', [contact.nickname]))),
  );
}

/// null = cancelled, true = "scan a QR", false = "pick an existing contact".
Future<bool?> _pickLinkMethod(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(AppL10n.t('Привязать дочернее устройство'),
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_scanner_rounded),
            title: Text(AppL10n.t('Сканировать QR')),
            subtitle: Text(
                AppL10n.t(
                    'На новом устройстве: «Это дополнительное устройство»'),
                style: TextStyle(fontSize: 12)),
            onTap: () => Navigator.pop(ctx, true),
          ),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: Text(AppL10n.t('Выбрать из контактов')),
            subtitle: Text(AppL10n.t('Устройство уже пользуется Rlink'),
                style: TextStyle(fontSize: 12)),
            onTap: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Future<Contact?> _pickContactForLink(BuildContext context) async {
  final contacts = await ChatStorageService.instance.getContacts();
  if (!context.mounted) return null;
  if (contacts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.t('Нет контактов для связки устройств'))),
    );
    return null;
  }
  return showModalBottomSheet<Contact>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(AppL10n.t('Выберите устройство')),
            subtitle: Text(
              AppL10n.t(
                  'Выбранный контакт получит запрос на привязку как дочернего устройства.'),
              style: TextStyle(fontSize: 12),
            ),
          ),
          for (final c in contacts)
            ListTile(
              leading: AvatarWidget(
                initials: c.initials,
                color: c.avatarColor,
                emoji: c.avatarEmoji,
                imagePath: c.avatarImagePath,
                size: 40,
              ),
              title: Text(c.nickname),
              subtitle: Text(
                c.username.isNotEmpty ? '#${c.username}' : c.shortId,
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.pop(ctx, c),
            ),
        ],
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────
// Main Settings Screen — category tiles
// ─────────────────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final webPushLabel = AppVersion.webPushLabel;

    if (settings.isLinkedChildDevice && !RuntimePlatform.isWeb) {
      return _buildChildLinkedScreen(context, settings, isDark);
    }

    return Scaffold(
      backgroundColor: AppSettings.instance.newDesign
          ? Theme.of(context).colorScheme.surface
          : (RlinkDesign.screenBg(context, isDark)),
      appBar: AppBar(
        title: Text(AppL10n.t('settings')),
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: AppSettings.instance.newDesign
            ? Theme.of(context).colorScheme.surface
            : (RlinkDesign.barBg(context, isDark)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          // ── Profile mini-card ────────────────────────────────────
          _ProfileMiniCard(
            onTap: () => _push(context, const _ProfilePage()),
          ),
          const SizedBox(height: 12),

          const SettingsCategoryCards(),

          const SizedBox(height: 32),

          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
              child: Text(
                [
                  'Rlink v${AppVersion.label}',
                  if (webPushLabel.isNotEmpty) webPushLabel,
                  AppL10n.t('footer_ble_mesh'),
                ].join(' • '),
                style:
                    TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.push(context, rlinkOpaquePushRoute(page));
  }

  // ── Child linked-device restricted settings ────────────────────────

  Widget _buildChildLinkedScreen(
    BuildContext context,
    AppSettings settings,
    bool isDark,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppSettings.instance.newDesign
          ? Theme.of(context).colorScheme.surface
          : (RlinkDesign.screenBg(context, isDark)),
      appBar: AppBar(
        title: Text(AppL10n.t('settings')),
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: AppSettings.instance.newDesign
            ? Theme.of(context).colorScheme.surface
            : (RlinkDesign.barBg(context, isDark)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('Режим дочернего устройства')),
          ListTile(
            leading: Icon(Icons.lock_person_outlined, color: cs.primary),
            title: Text(AppL10n.t('Доступ ограничен')),
            subtitle: Text(
              AppL10n.t(
                  'В этом режиме доступны только переписка и отвязка устройства.'),
              style: TextStyle(fontSize: 12),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.link_rounded),
            title: Text(AppL10n.t('Связано с')),
            subtitle: Text(
              settings.linkedDeviceNickname.isNotEmpty
                  ? settings.linkedDeviceNickname
                  : settings.linkedDevicePublicKey,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.link_off_rounded, color: Colors.red),
            title: Text(
              AppL10n.t('Отвязаться от главного устройства'),
              style: TextStyle(color: Colors.red),
            ),
            onTap: () => doUnlinkDevice(context),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Profile mini-card shown at the top of Settings
// ─────────────────────────────────────────────────────────────────────

class _ProfileMiniCard extends StatelessWidget {
  final VoidCallback onTap;
  const _ProfileMiniCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.profile;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            if (profile != null)
              AvatarWidget(
                initials: profile.initials,
                color: profile.avatarColor,
                emoji: profile.avatarEmoji,
                imagePath: profile.avatarImagePath,
                size: 52,
              )
            else
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.person, color: cs.primary, size: 28),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile?.nickname.isNotEmpty == true
                        ? profile!.nickname
                        : AppL10n.t('Без имени'),
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    profile != null
                        ? (profile.username.isNotEmpty
                            ? '@${profile.username}'
                            : '${profile.publicKeyHex.substring(0, 12)}...')
                        : AppL10n.t('Настройте профиль'),
                    style: TextStyle(
                      fontSize: 12,
                      color: profile?.username.isNotEmpty == true
                          ? cs.primary
                          : cs.onSurfaceVariant,
                      fontFamily: profile?.username.isNotEmpty == true
                          ? null
                          : 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Category group / item widgets
// ─────────────────────────────────────────────────────────────────────

class _CategoryItem {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? badge;

  const _CategoryItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });
}

class _CategoryGroup extends StatelessWidget {
  final bool isDark;
  final List<_CategoryItem> items;

  const _CategoryGroup({
    required this.isDark,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 58,
                color: cs.outlineVariant.withValues(alpha: 0.4),
              ),
            _buildTile(context, items[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildTile(BuildContext context, _CategoryItem item) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: item.color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(item.icon, size: 19, color: item.color),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(item.title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w400)),
          if (item.badge != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                item.badge!,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        item.subtitle,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      trailing: Icon(Icons.chevron_right,
          color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
      onTap: item.onTap,
    );
  }
}

/// Те же карточки категорий, что на корне [SettingsScreen] — для вкладки «Я» и единообразия.
class SettingsCategoryCards extends StatefulWidget {
  const SettingsCategoryCards({super.key});

  @override
  State<SettingsCategoryCards> createState() => _SettingsCategoryCardsState();
}

class _SettingsCategoryCardsState extends State<SettingsCategoryCards> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _checkingUpdate = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _open(BuildContext context, Widget page) {
    Navigator.push(context, rlinkOpaquePushRoute(page));
  }

  Future<void> _manualCheckUpdate(BuildContext context) async {
    if (_checkingUpdate || !isUpdateSupported) return;
    setState(() => _checkingUpdate = true);
    try {
      final update = await UpdateService.instance.checkForUpdate();
      if (!mounted) return;
      if (update != null) {
        pendingUpdateNotifier.value = update;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(AppL10n.f('Доступно обновление {0}', [update.version])),
            action: SnackBarAction(
              label: AppL10n.t('Скачать'),
              onPressed: () => UpdateService.instance.startDownload(update),
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.t('У вас последняя версия'))),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  List<List<_CategoryItem>> _groups(BuildContext context) => [
        [
          _CategoryItem(
            icon: Icons.key_outlined,
            color: const Color(0xFF1DB954),
            title: 'RID',
            subtitle: AppL10n.t('Ваш RlinkID — перенос, привязка, удаление'),
            onTap: () => _open(context, const RidScreen()),
          ),
        ],
        [
          _CategoryItem(
            icon: Icons.palette_outlined,
            color: const Color(0xFF9C27B0),
            title: AppL10n.t('settings_appearance'),
            subtitle: AppL10n.t('Тема, цвета, шрифт, фон'),
            onTap: () => _open(context, const _AppearancePage()),
          ),
          _CategoryItem(
            icon: Icons.notifications_outlined,
            color: const Color(0xFFF44336),
            title: AppL10n.t('settings_notifications'),
            subtitle: AppL10n.t('Звуки, рингтон, вибрация'),
            onTap: () => _open(context, const _NotificationsPage()),
          ),
          if (kIsWeb)
            _CategoryItem(
              icon: Icons.verified_user_outlined,
              color: const Color(0xFF00BCD4),
              title: AppL10n.t('Разрешения'),
              subtitle:
                  AppL10n.t('Микрофон, камера, уведомления, фоновые пуши'),
              onTap: () => _open(context, const _PermissionsPage()),
            ),
        ],
        [
          _CategoryItem(
            icon: Icons.chat_bubble_outline,
            color: const Color(0xFF2196F3),
            title: AppL10n.t('settings_messaging'),
            subtitle: AppL10n.t('Отправка, медиа, память'),
            onTap: () => _open(context, const _MessagingPage()),
          ),
          _CategoryItem(
            icon: Icons.tune,
            color: const Color(0xFF9C27B0),
            title: AppL10n.t('Панель ввода'),
            subtitle: AppL10n.t('Порядок кнопок'),
            onTap: () => _open(context, const InputBarButtonOrderSettings()),
          ),
          _CategoryItem(
            icon: Icons.workspace_premium_outlined,
            color: const Color(0xFFFFB300),
            title: 'Rlink Premium',
            subtitle: PremiumService.instance.isActive
                ? AppL10n.t('Подписка активна')
                : AppL10n.t('Цвет ника, каналы, конструктор ботов'),
            onTap: () => _open(context, const PremiumStatusPage()),
          ),
          _CategoryItem(
            icon: Icons.library_music_outlined,
            color: const Color(0xFF00BCD4),
            title: AppL10n.t('Музыка'),
            subtitle: AppL10n.t('Плеер, поиск, «Нравится», текст (бета)'),
            onTap: () => _open(context, const MusicScreen()),
          ),
          _CategoryItem(
            icon: Icons.emoji_emotions_outlined,
            color: const Color(0xFFEC407A),
            title: AppL10n.t('emoji_my_packs'),
            subtitle: AppL10n.t('Свои :код: и анимированные эмодзи'),
            onTap: () => _open(context, const EmojiHubScreen()),
          ),
          _CategoryItem(
            icon: Icons.auto_awesome_motion_outlined,
            color: const Color(0xFF7E57C2),
            title: AppL10n.t('Стикеры и наборы'),
            subtitle:
                AppL10n.t('Свои наборы и редактор анимированных стикеров'),
            onTap: () => _open(context, const StickersHubScreen()),
          ),
          _CategoryItem(
            icon: Icons.lock_outline,
            color: const Color(0xFF4CAF50),
            title: AppL10n.t('settings_privacy'),
            subtitle: AppL10n.t('Прочтение, статус онлайн'),
            onTap: () => _open(context, const _PrivacyPage()),
          ),
          _CategoryItem(
            icon: Icons.menu_book_rounded,
            color: const Color(0xFF1DB954),
            title: AppL10n.t('help_center_title'),
            subtitle: AppL10n.t('help_center_sub'),
            onTap: () => Navigator.of(context).push(
              rlinkOpaquePushRoute(const HelpCenterScreen()),
            ),
          ),
          _CategoryItem(
            icon: Icons.record_voice_over_outlined,
            color: const Color(0xFFFF7043),
            title: AppL10n.t('Расшифровка'),
            subtitle: AppL10n.t('Движок и модель'),
            onTap: () => _open(context, const _TranscriptionPage()),
          ),
        ],
        [
          _CategoryItem(
            icon: Icons.wifi_tethering_rounded,
            color: const Color(0xFF009688),
            title: AppL10n.t('settings_section_network'),
            subtitle: AppL10n.t('BLE, интернет, ретранслятор'),
            onTap: () => _open(context, const _NetworkPage()),
          ),
          _CategoryItem(
            icon: Icons.add_to_drive_outlined,
            color: const Color(0xFF1A73E8),
            title: 'Google Drive',
            subtitle: AppL10n.t('Привязка аккаунта, резерв и место'),
            onTap: () => _open(context, const _GoogleDrivePage()),
          ),
          _CategoryItem(
            icon: Icons.cloud_outlined,
            color: const Color(0xFF0078D4),
            title: 'OneDrive',
            subtitle: AppL10n.t('Пока недоступно'),
            badge: AppL10n.t('Скоро'),
            onTap: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(AppL10n.t('OneDrive — скоро')),
                content: Text(
                  AppL10n.t(
                      'Привязка OneDrive ещё не готова — ждём регистрацию приложения в Microsoft. Резервные копии пока доступны через Google Drive и Dropbox.'),
                  style: TextStyle(fontSize: 13),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(AppL10n.t('ОК')),
                  ),
                ],
              ),
            ),
          ),
          _CategoryItem(
            icon: Icons.inventory_2_outlined,
            color: const Color(0xFF0061FF),
            title: 'Dropbox',
            subtitle: AppL10n.t('Привязка аккаунта для резервных копий'),
            onTap: () => _open(
              context,
              _CloudProviderPage(
                title: 'Dropbox',
                link: DropboxBackup.instance.link,
              ),
            ),
          ),
          if (RuntimePlatform.isWeb)
            _CategoryItem(
              icon: Icons.ios_share_rounded,
              color: const Color(0xFF4CAF50),
              title: AppL10n.t('Установка на iPhone'),
              subtitle: AppL10n.t('Добавить Rlink на главный экран'),
              onTap: () => _open(context, const _WebInstallPage()),
            ),
        ],
        [
          _CategoryItem(
            icon: Icons.storage_outlined,
            color: const Color(0xFF795548),
            title: AppL10n.t('settings_data'),
            subtitle: AppL10n.t('История, контакты, сброс'),
            onTap: () => _open(context, const SettingsDataPage()),
          ),
          _CategoryItem(
            icon: Icons.menu_book_outlined,
            color: const Color(0xFF3949AB),
            title: AppL10n.t('Документация'),
            subtitle: AppL10n.t(
                'Rlink, боты Lib, python -m rlink_bot onboard — RU / EN'),
            onTap: () => DocumentationScreen.open(context),
          ),
          if (isUpdateSupported)
            _CategoryItem(
              icon: _checkingUpdate
                  ? Icons.sync_rounded
                  : Icons.system_update_alt_rounded,
              color: const Color(0xFF43A047),
              title: AppL10n.t('Проверить обновление'),
              subtitle: _checkingUpdate
                  ? AppL10n.t('Проверяем…')
                  : AppL10n.f(
                      'Rlink v{0} — проверить сейчас', [AppVersion.label]),
              onTap: () => _manualCheckUpdate(context),
            ),
          _CategoryItem(
            icon: Icons.info_outline_rounded,
            color: const Color(0xFF607D8B),
            title: AppL10n.t('about_title'),
            subtitle: [
              'Rlink v${AppVersion.label}',
              if (AppVersion.webPushLabel.isNotEmpty) AppVersion.webPushLabel,
            ].join(' • '),
            onTap: () => _open(context, const AboutScreen()),
          ),
        ],
      ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final groups = _groups(context);
    final q = _query.trim().toLowerCase();

    final searchField = Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: AppL10n.t('Поиск в настройках'),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: q.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
          isDense: true,
          filled: true,
          fillColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );

    if (q.isNotEmpty) {
      final matches = <_CategoryItem>[
        for (final g in groups)
          for (final it in g)
            if (it.title.toLowerCase().contains(q) ||
                it.subtitle.toLowerCase().contains(q))
              it,
      ];
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          searchField,
          if (matches.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(AppL10n.t('Ничего не найдено'),
                    style: TextStyle(color: cs.onSurfaceVariant)),
              ),
            )
          else
            _CategoryGroup(isDark: isDark, items: matches),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        searchField,
        // Прогресс фоновой загрузки обновления / кнопка установки (сам скрыт,
        // когда обновления нет).
        const UpdateProgressTile(),
        for (var i = 0; i < groups.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _CategoryGroup(isDark: isDark, items: groups[i]),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Google Drive (account linking, status, free space)
// ─────────────────────────────────────────────────────────────────────

class _GoogleDrivePage extends StatefulWidget {
  const _GoogleDrivePage();

  @override
  State<_GoogleDrivePage> createState() => _GoogleDrivePageState();
}

class _GoogleDrivePageState extends State<_GoogleDrivePage> {
  GoogleDriveSyncStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load(interactive: false);
  }

  String? get _email {
    final e = _status?.email;
    return (e != null && e.isNotEmpty) ? e : null;
  }

  String _fmtBytes(int? b) {
    if (b == null || b < 0) return '—';
    final units = [
      AppL10n.t('Б'),
      AppL10n.t('КБ'),
      AppL10n.t('МБ'),
      AppL10n.t('ГБ'),
      AppL10n.t('ТБ')
    ];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  Future<void> _load({required bool interactive}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final st = await GoogleDriveChannelBackup.getSyncStatus(
          interactive: interactive);
      if (mounted) setState(() => _status = st);
    } catch (_) {
      if (mounted) setState(() => _status = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Durable server-side linking: the relay holds the refresh token, so the
  /// account survives re-login (unlike the ~1h implicit token). Works on web
  /// and native alike once the relay OAuth backend is deployed.
  Future<void> _linkRelay() async {
    final uri = Uri.tryParse(GoogleDriveChannelBackup.startRelayLink());
    if (uri == null) return;
    if (kIsWeb) {
      await launchUrl(uri, webOnlyWindowName: '_blank');
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (!mounted) return;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.t('Привязка через сервер')),
        content: Text(
          AppL10n.t(
              'В открывшемся окне войдите в Google и разрешите доступ к Drive, затем вернитесь сюда и нажмите «Готово».\n\nТокен хранится на сервере — привязка не слетит после перезахода.'),
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.t('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.t('Готово')),
          ),
        ],
      ),
    );
    if (done != true || !mounted) return;
    setState(() => _busy = true);
    final ok = await GoogleDriveChannelBackup.finishRelayLink();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? AppL10n.t('Google Drive привязан (постоянно)')
            : AppL10n.t('Не удалось завершить привязку — попробуйте ещё раз')),
      ),
    );
    if (ok) await _load(interactive: false);
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.t('Отвязать Google-аккаунт?')),
        content: Text(AppL10n.t('Привязка будет удалена на этом устройстве.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.t('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.t('cm_unlink')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await GoogleDriveChannelBackup.disconnectCurrentUser();
    if (!mounted) return;
    setState(() => _status = const GoogleDriveSyncStatus());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.t('Аккаунт отвязан'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final linked = _email != null;
    return _subScaffold(
      context: context,
      title: 'Google Drive',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('Аккаунт')),
          ListTile(
            leading: Icon(
              linked ? Icons.account_circle : Icons.account_circle_outlined,
              color: linked ? cs.primary : null,
            ),
            title: Text(linked ? _email! : AppL10n.t('Аккаунт не привязан')),
            subtitle: _busy
                ? Text(AppL10n.t('Обновление…'), style: TextStyle(fontSize: 12))
                : (linked && _status?.limitBytes != null
                    ? Text(
                        AppL10n.f('Свободно {0} из {1}', [
                          _fmtBytes(_status!.freeBytes),
                          _fmtBytes(_status!.limitBytes)
                        ]),
                        style: const TextStyle(fontSize: 12),
                      )
                    : null),
            trailing: linked
                ? IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _busy ? null : () => _load(interactive: true),
                  )
                : null,
          ),
          Builder(builder: (_) {
            final accounts = GoogleDriveChannelBackup.relayAccounts;
            if (accounts.length < 2) return const SizedBox.shrink();
            final active = GoogleDriveChannelBackup.activeRelayPairing;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SectionHeader(AppL10n.t('Аккаунты')),
                for (final a in accounts)
                  Builder(builder: (_) {
                    final pairing = a['pairing'] ?? '';
                    final email = (a['email'] ?? '').isNotEmpty
                        ? a['email']!
                        : AppL10n.t('Аккаунт');
                    final isActive = pairing == active;
                    return ListTile(
                      leading: Icon(
                        isActive
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: isActive ? cs.primary : null,
                      ),
                      title: Text(email),
                      subtitle: isActive
                          ? Text(
                              AppL10n.t('Активный — для каналов и скачиваний'),
                              style: TextStyle(fontSize: 11))
                          : null,
                      onTap: _busy
                          ? null
                          : () async {
                              await GoogleDriveChannelBackup
                                  .setActiveRelayAccount(pairing);
                              if (!mounted) return;
                              setState(() {});
                              await _load(interactive: false);
                            },
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _busy
                            ? null
                            : () async {
                                await GoogleDriveChannelBackup
                                    .removeRelayAccount(pairing);
                                if (!mounted) return;
                                setState(() {});
                                await _load(interactive: false);
                              },
                      ),
                    );
                  }),
              ],
            );
          }),
          const SizedBox(height: 8),
          if (!linked) ...[
            _SectionHeader(AppL10n.t('Привязка')),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: GoogleSignInButton(
                busy: _busy,
                // Only the server (relay) OAuth flow — the direct in-app
                // Google sign-in loops/forgets on web and isn't durable.
                onPressed: _busy ? null : _linkRelay,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                AppL10n.t(
                    'Вход через сервер — привязка не слетает после перезахода.'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          ],
          if (linked)
            ListTile(
              leading: const Icon(Icons.link_off, color: Colors.red),
              title: Text(AppL10n.t('Отвязать аккаунт'),
                  style: TextStyle(color: Colors.red)),
              onTap: _busy ? null : _disconnect,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              kIsWeb
                  ? AppL10n.t(
                      'Аккаунт используется для резервного копирования каналов. В веб-версии токен доступа живёт около часа — затем потребуется войти заново.')
                  : AppL10n.t(
                      'Аккаунт используется для резервного копирования каналов (если в настройках канала включён резерв).'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: generic cloud provider (OneDrive, Dropbox — same relay-linked
// OAuth flow as Google Drive, but without a driver here for a signed-in SDK,
// so no quota display; just link/switch/unlink accounts).
// ─────────────────────────────────────────────────────────────────────

class _CloudProviderPage extends StatefulWidget {
  const _CloudProviderPage({required this.title, required this.link});
  final String title;
  final RelayOauthLink link;

  @override
  State<_CloudProviderPage> createState() => _CloudProviderPageState();
}

class _CloudProviderPageState extends State<_CloudProviderPage> {
  bool _busy = false;

  Future<void> _linkRelay() async {
    final uri = Uri.tryParse(widget.link.startLink());
    if (uri == null) return;
    if (kIsWeb) {
      await launchUrl(uri, webOnlyWindowName: '_blank');
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (!mounted) return;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.t('Привязка через сервер')),
        content: Text(
          AppL10n.f(
              'В открывшемся окне войдите в {0} и разрешите доступ, затем вернитесь сюда и нажмите «Готово».\n\nТокен хранится на сервере — привязка не слетит после перезахода.',
              [widget.title]),
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.t('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.t('Готово')),
          ),
        ],
      ),
    );
    if (done != true || !mounted) return;
    setState(() => _busy = true);
    final ok = await widget.link.finishLink();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? AppL10n.f('{0} привязан (постоянно)', [widget.title])
            : AppL10n.t('Не удалось завершить привязку — попробуйте ещё раз')),
      ),
    );
  }

  Future<void> _disconnect(String pairing) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.f('Отвязать аккаунт {0}?', [widget.title])),
        content: Text(AppL10n.t('Привязка будет удалена на этом устройстве.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.t('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.t('cm_unlink')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.link.removeAccount(pairing);
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accounts = widget.link.accounts;
    final active = widget.link.activePairing;
    return _subScaffold(
      context: context,
      title: widget.title,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('Аккаунты')),
          if (accounts.isEmpty)
            ListTile(
              leading: Icon(Icons.account_circle_outlined),
              title: Text(AppL10n.t('Аккаунт не привязан')),
            )
          else
            for (final a in accounts)
              Builder(builder: (_) {
                final pairing = a['pairing'] ?? '';
                final email = (a['email'] ?? '').isNotEmpty
                    ? a['email']!
                    : AppL10n.t('Аккаунт');
                final isActive = pairing == active;
                return ListTile(
                  leading: Icon(
                    isActive
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: isActive ? cs.primary : null,
                  ),
                  title: Text(email),
                  subtitle: isActive
                      ? Text(AppL10n.t('Активный — для резервных копий'),
                          style: TextStyle(fontSize: 11))
                      : null,
                  onTap: _busy || isActive
                      ? null
                      : () async {
                          await widget.link.setActiveAccount(pairing);
                          if (!mounted) return;
                          setState(() {});
                        },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy ? null : () => _disconnect(pairing),
                  ),
                );
              }),
          const SizedBox(height: 8),
          _SectionHeader(AppL10n.t('Привязка')),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: FilledButton.icon(
              onPressed: _busy ? null : _linkRelay,
              icon: const Icon(Icons.add_link),
              label: Text(AppL10n.f('Привязать {0}', [widget.title])),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              AppL10n.f(
                  'Аккаунт используется для резервного копирования каналов и групп (если в настройках канала/группы выбран {0} как место хранения).',
                  [widget.title]),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Appearance
// ─────────────────────────────────────────────────────────────────────

class _AppearancePage extends StatefulWidget {
  const _AppearancePage();

  @override
  State<_AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<_AppearancePage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_appearance'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          // ── Язык ─────────────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_language')),
          ListTile(
            leading: Icon(Icons.translate_rounded, color: cs.primary),
            title: Text(AppL10n.t('settings_language')),
            subtitle: Text(
              AppL10n.supportedLocales
                  .firstWhere((l) => l.code == settings.locale,
                      orElse: () => AppL10n.supportedLocales.first)
                  .nativeName,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showLanguagePicker(context, settings),
          ),

          // ── Тема ─────────────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_appearance')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppL10n.t('settings_theme'),
                    style: TextStyle(
                        fontSize: 13, color: Theme.of(context).hintColor)),
                const SizedBox(height: 8),
                Row(children: [
                  _ThemeChip(
                    label: AppL10n.t('settings_theme_system'),
                    icon: Icons.brightness_auto,
                    selected: settings.themeMode == ThemeMode.system,
                    onTap: () => settings.setThemeMode(ThemeMode.system),
                  ),
                  const SizedBox(width: 8),
                  _ThemeChip(
                    label: AppL10n.t('settings_theme_light'),
                    icon: Icons.light_mode,
                    selected: settings.themeMode == ThemeMode.light,
                    onTap: () => settings.setThemeMode(ThemeMode.light),
                  ),
                  const SizedBox(width: 8),
                  _ThemeChip(
                    label: AppL10n.t('settings_theme_dark'),
                    icon: Icons.dark_mode,
                    selected: settings.themeMode == ThemeMode.dark,
                    onTap: () => settings.setThemeMode(ThemeMode.dark),
                  ),
                ]),
                const SizedBox(height: 20),
                Text(AppL10n.t('Цветовая схема'),
                    style: TextStyle(
                        fontSize: 13, color: Theme.of(context).hintColor)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: List.generate(kAppPalettes.length, (i) {
                    final p = kAppPalettes[i];
                    final selected = settings.appPalette == i;
                    return GestureDetector(
                      onTap: () => settings.setAppPalette(i),
                      child: Tooltip(
                        message: AppL10n.t(p.name),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: p.gradient,
                            ),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color:
                                  selected ? cs.onSurface : cs.outlineVariant,
                              width: selected ? 3 : 1,
                            ),
                            boxShadow: selected
                                ? [
                                    BoxShadow(
                                        color: p.seed.withValues(alpha: 0.5),
                                        blurRadius: 10)
                                  ]
                                : null,
                          ),
                          child: selected
                              ? const Icon(Icons.check,
                                  color: Colors.white, size: 22)
                              : null,
                        ),
                      ),
                    );
                  }),
                ),
                if (RuntimePlatform.isIos || RuntimePlatform.isAndroid) ...[
                  const SizedBox(height: 20),
                  Text(AppL10n.t('settings_app_icon'),
                      style: TextStyle(
                          fontSize: 13, color: Theme.of(context).hintColor)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _AppIconChoiceChip(
                        label: AppL10n.t('settings_app_icon_variant_classic'),
                        selected: settings.appIconVariant == 0,
                        onTap: () async {
                          await settings.setAppIconVariant(0);
                          await AppIconService.setVariant(0);
                        },
                      ),
                      _AppIconChoiceChip(
                        label: 'Mono',
                        selected: settings.appIconVariant == 1,
                        onTap: () async {
                          await settings.setAppIconVariant(1);
                          await AppIconService.setVariant(1);
                        },
                      ),
                      _AppIconChoiceChip(
                        label: AppL10n.t('settings_app_icon_variant_ai'),
                        selected: settings.appIconVariant == 2,
                        onTap: () async {
                          await settings.setAppIconVariant(2);
                          await AppIconService.setVariant(2);
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // ── Оформление ───────────────────────────────────────────
          _SectionHeader(AppL10n.t('Оформление')),
          SwitchListTile(
            secondary: Icon(Icons.crop_square_rounded, color: cs.primary),
            title: Text(AppL10n.t('Минимализм')),
            subtitle: Text(
                AppL10n.t(
                    'Две краски — фон и акцент. Плоские поверхности, тонкие линии, без свечения, градиентов и размытия. Акцент берётся из выбранной палитры.'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.minimalist,
            onChanged: (v) => settings.setMinimalist(v),
          ),
          SwitchListTile(
            secondary: Icon(Icons.wallpaper_rounded, color: cs.primary),
            title: Text(AppL10n.t('Фон в чатах')),
            subtitle: Text(AppL10n.t('Показывать фоновую картинку в переписке'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.chatBackground,
            onChanged: (v) => settings.setChatBackground(v),
          ),
          // ── Движение и анимации ──────────────────────────────────
          _SectionHeader(AppL10n.t('Движение и анимации')),
          SwitchListTile(
            secondary: Icon(Icons.blur_on_rounded, color: cs.primary),
            title: Text(AppL10n.t('Жидкое стекло (размытие)')),
            subtitle: Text(
                RuntimePlatform.isAndroid
                    ? AppL10n.t(
                        'Размытые «стеклянные» панели. Красиво, но снижает плавность — выключите, если подтормаживает')
                    : AppL10n.t('Полупрозрачные панели с размытием фона'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.liquidGlassPref,
            onChanged:
                settings.minimalist ? null : (v) => settings.setLiquidGlass(v),
          ),
          SwitchListTile(
            secondary: Icon(Icons.gradient_rounded, color: cs.primary),
            title: Text(AppL10n.t('Анимированный фон')),
            subtitle: Text(
                AppL10n.t(
                    'Плавно переливающийся градиент. Выключен по умолчанию ради скорости'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.animatedGradientPref,
            onChanged: settings.minimalist
                ? null
                : (v) => settings.setAnimatedGradient(v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.auto_awesome_rounded, color: cs.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(AppL10n.t('Интенсивность анимаций')),
                  const Spacer(),
                  Text('${(settings.animationLevel * 100).round()}%',
                      style:
                          TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                ]),
                Slider(
                  value: settings.animationLevel,
                  onChanged: (v) => settings.setAnimationLevel(v),
                ),
              ],
            ),
          ),
          SwitchListTile(
            secondary: Icon(Icons.battery_saver_rounded, color: cs.primary),
            title: Text(AppL10n.t('Экономия энергии')),
            subtitle: Text(
              AppL10n.f('Снижать анимации при {0}%, выключать при {1}%',
                  [settings.batteryAnimReduceAt, settings.batteryAnimOffAt]),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            value: settings.batterySaverAnimations,
            onChanged: (v) => settings.setBatterySaverAnimations(v),
          ),
          if (settings.batterySaverAnimations) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(children: [
                SizedBox(
                    width: 110,
                    child: Text(AppL10n.t('Снижать при'),
                        style: TextStyle(fontSize: 13))),
                Expanded(
                  child: Slider(
                    value: settings.batteryAnimReduceAt.toDouble().clamp(5, 50),
                    min: 5,
                    max: 50,
                    divisions: 9,
                    label: '${settings.batteryAnimReduceAt}%',
                    onChanged: (v) =>
                        settings.setBatteryAnimReduceAt(v.round()),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text('${settings.batteryAnimReduceAt}%',
                      textAlign: TextAlign.end,
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [
                SizedBox(
                    width: 110,
                    child: Text(AppL10n.t('Выключать при'),
                        style: TextStyle(fontSize: 13))),
                Expanded(
                  child: Slider(
                    value: settings.batteryAnimOffAt.toDouble().clamp(0, 20),
                    min: 0,
                    max: 20,
                    divisions: 20,
                    label: '${settings.batteryAnimOffAt}%',
                    onChanged: (v) => settings.setBatteryAnimOffAt(v.round()),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text('${settings.batteryAnimOffAt}%',
                      textAlign: TextAlign.end,
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ),
              ]),
            ),
          ],

          // Font size
          ListTile(
            leading: Icon(Icons.format_size, color: cs.primary),
            title: Text(AppL10n.t('settings_font_size')),
            subtitle: Text(
              [
                AppL10n.t('settings_font_small'),
                AppL10n.t('settings_font_medium'),
                AppL10n.t('settings_font_large')
              ][settings.fontSize],
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              _SizeChip(
                label: 'A',
                style:
                    const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                selected: settings.fontSize == 0,
                onTap: () => settings.setFontSize(0),
              ),
              const SizedBox(width: 6),
              _SizeChip(
                label: 'A',
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                selected: settings.fontSize == 1,
                onTap: () => settings.setFontSize(1),
              ),
              const SizedBox(width: 6),
              _SizeChip(
                label: 'A',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                selected: settings.fontSize == 2,
                onTap: () => settings.setFontSize(2),
              ),
            ]),
          ),

          if (RuntimePlatform.isAndroid)
            SwitchListTile(
              secondary: Icon(Icons.emoji_emotions_outlined, color: cs.primary),
              title: Text(AppL10n.t('settings_ios_emoji')),
              subtitle: Text(AppL10n.t('settings_ios_emoji_sub'),
                  style: const TextStyle(fontSize: 12)),
              value: settings.useIosStyleEmoji,
              onChanged: (v) => settings.setUseIosStyleEmoji(v),
            ),

          SwitchListTile(
            secondary: Icon(Icons.compress_outlined, color: cs.primary),
            title: Text(AppL10n.t('settings_compact_mode')),
            subtitle: Text(AppL10n.t('settings_compact_mode_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.compactMode,
            onChanged: (v) => settings.setCompactMode(v),
          ),

          // Bubble style
          ListTile(
            leading: Icon(Icons.chat_bubble_outline, color: cs.primary),
            title: Text(AppL10n.t('settings_message_style')),
            subtitle: Text(
              [
                AppL10n.t('settings_bubble_rounded'),
                AppL10n.t('settings_bubble_square'),
                AppL10n.t('settings_bubble_minimal'),
              ][settings.bubbleStyle],
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < 3; i++) ...[
                GestureDetector(
                  onTap: () => settings.setBubbleStyle(i),
                  child: Container(
                    width: 28,
                    height: 20,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(
                          alpha: settings.bubbleStyle == i ? 0.85 : 0.25),
                      borderRadius: i == 0
                          ? BorderRadius.circular(10)
                          : i == 1
                              ? BorderRadius.circular(3)
                              : BorderRadius.circular(6),
                    ),
                  ),
                ),
              ],
            ]),
          ),

          // Message density
          ListTile(
            leading: Icon(Icons.density_medium, color: cs.primary),
            title: Text(AppL10n.t('settings_message_density')),
            subtitle: Text(
              [
                AppL10n.t('settings_density_relaxed'),
                AppL10n.t('settings_density_normal'),
                AppL10n.t('settings_density_compact'),
              ][settings.messageDensity],
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < 3; i++) ...[
                _SizeChip(
                  label: ['≋', '≡', '-'][i],
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                  selected: settings.messageDensity == i,
                  onTap: () => settings.setMessageDensity(i),
                ),
                const SizedBox(width: 4),
              ],
            ]),
          ),

          // Clock format
          ListTile(
            leading: Icon(Icons.schedule, color: cs.primary),
            title: Text(AppL10n.t('settings_time_format')),
            subtitle: Text(
              settings.clockFormat == 0
                  ? AppL10n.t('settings_clock_24h')
                  : AppL10n.t('settings_clock_12h'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              _SizeChip(
                label: '24',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                selected: settings.clockFormat == 0,
                onTap: () => settings.setClockFormat(0),
              ),
              const SizedBox(width: 6),
              _SizeChip(
                label: '12',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                selected: settings.clockFormat == 1,
                onTap: () => settings.setClockFormat(1),
              ),
            ]),
          ),

          // Reactions
          SwitchListTile(
            secondary: Icon(Icons.emoji_emotions_outlined, color: cs.primary),
            title: Text(AppL10n.t('settings_reaction_quick_bar')),
            subtitle: Text(AppL10n.t('settings_reaction_quick_bar_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.showReactionsQuickBar,
            onChanged: (v) => settings.setShowReactionsQuickBar(v),
          ),

          ListTile(
            leading: Icon(Icons.touch_app_outlined, color: cs.primary),
            title: Text(AppL10n.t('settings_quick_reaction_double_tap')),
            subtitle: Row(
              children: [
                Text(
                  AppL10n.t('settings_quick_reaction_now'),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 4),
                StatusEmojiView(
                  statusEmoji: settings.quickReactionEmoji,
                  fontSize: 16,
                  emptyPlaceholder: '😀',
                  style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
                ),
              ],
            ),
            trailing: StatusEmojiView(
              statusEmoji: settings.quickReactionEmoji,
              fontSize: 22,
              emptyPlaceholder: '😀',
              style: const TextStyle(fontSize: 22),
            ),
            onTap: () async {
              final picked = await showReactionPickerSheet(context);
              final e = (picked ?? '').trim();
              if (e.isNotEmpty) {
                await settings.setQuickReactionEmoji(e);
              }
            },
          ),

          // ── Фон чата ─────────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_chat_bg')),
          _ChatBgTile(settings: settings),
        ],
      ),
    );
  }

  void _showLanguagePicker(BuildContext context, AppSettings settings) {
    showModalBottomSheet(
      context: context,
      // Tall lists must be able to scroll: let the sheet grow to 90% of the
      // screen and put the locales in a ListView (they were in a plain Column,
      // so nothing below the fold was reachable).
      isScrollControlled: true,
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Text(AppL10n.t('settings_language'),
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Flexible(
                child: ListView(
              shrinkWrap: true,
              children: [
                ...AppL10n.supportedLocales.map((locale) {
                  final selected = settings.locale == locale.code;
                  final cs = Theme.of(context).colorScheme;
                  final Widget? subtitle;
                  if (locale.showPartialUiHint) {
                    subtitle = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(AppL10n.t('locale_ui_partial_note'),
                            style: TextStyle(
                                fontSize: 11,
                                height: 1.25,
                                color: cs.tertiary)),
                        const SizedBox(height: 2),
                        Text(locale.name,
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).hintColor)),
                      ],
                    );
                  } else if (locale.code != 'system') {
                    subtitle = Text(locale.name,
                        style: TextStyle(
                            fontSize: 12, color: Theme.of(context).hintColor));
                  } else {
                    subtitle = null;
                  }
                  return ListTile(
                    title: Text(locale.nativeName),
                    subtitle: subtitle,
                    isThreeLine: locale.showPartialUiHint,
                    trailing: selected
                        ? Icon(Icons.check_rounded,
                            color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () {
                      settings.setLocale(locale.code);
                      Navigator.pop(ctx);
                    },
                  );
                }),
                const SizedBox(height: 8),
              ],
            )),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Notifications
// ─────────────────────────────────────────────────────────────────────

class _NotificationsPage extends StatefulWidget {
  const _NotificationsPage();

  @override
  State<_NotificationsPage> createState() => _NotificationsPageState();
}

Future<void> _syncCurrentWebPushSubscription() async {
  if (!RuntimePlatform.isWeb) return;
  if (!RelayService.instance.isConnected) return;
  final publicKey = CryptoService.instance.publicKeyHex;
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(publicKey.trim())) return;
  final profile = ProfileService.instance.profile;
  await syncWebPushSubscription(
    relayServerUrl:
        RelayService.instance.serverUrl ?? RelayService.defaultServerUrl,
    publicKey: publicKey,
    nick: profile?.nickname ?? '',
  );
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Permissions (web) — request mic/camera/notifications once.
// ─────────────────────────────────────────────────────────────────────

class _PermissionsPage extends StatefulWidget {
  const _PermissionsPage();

  @override
  State<_PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<_PermissionsPage> {
  String _mic = 'unknown';
  String _cam = 'unknown';
  String _notif = 'default';
  bool _busy = false;
  String _pushStatus = ''; // '', 'on', 'off'
  bool _pushBusy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final mic = await webMediaPermissionStatus('microphone');
    final cam = await webMediaPermissionStatus('camera');
    final cap = await webNotificationCapability();
    if (!mounted) return;
    setState(() {
      _mic = mic;
      _cam = cam;
      _notif = (cap['permission'] as String?) ?? 'default';
    });
  }

  Future<void> _requestMedia({required bool audio, required bool video}) async {
    setState(() => _busy = true);
    final r = await requestWebMediaPermission(audio: audio, video: video);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (audio)
        _mic = r == 'granted' ? 'granted' : (r == 'denied' ? 'denied' : _mic);
      if (video)
        _cam = r == 'granted' ? 'granted' : (r == 'denied' ? 'denied' : _cam);
    });
    if (r == 'denied') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppL10n.t(
              'Доступ запрещён. Разрешите его для сайта в настройках браузера.'))));
    }
    await _refresh();
  }

  Future<void> _requestNotifications() async {
    setState(() => _busy = true);
    final res = await _enableBackgroundPush();
    if (!mounted) return;
    setState(() => _busy = false);
    await _refresh();
    _showPushResult(res);
  }

  /// Reads current identity/relay and force-enables background push. Returns the
  /// bridge result map `{ok, reason, detail?}`.
  Future<Map<String, Object?>> _enableBackgroundPush() async {
    if (!RuntimePlatform.isWeb) {
      await requestWebNotificationPermission();
      return {'ok': true, 'reason': 'native'};
    }
    if (!RelayService.instance.isConnected) {
      try {
        await RelayService.instance.connect();
      } catch (_) {}
    }
    final publicKey = CryptoService.instance.publicKeyHex;
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(publicKey.trim())) {
      return {'ok': false, 'reason': 'no_keys'};
    }
    final res = await enableWebPush(
      relayServerUrl:
          RelayService.instance.serverUrl ?? RelayService.defaultServerUrl,
      publicKey: publicKey,
      nick: ProfileService.instance.profile?.nickname ?? '',
    );
    if (mounted) {
      setState(() => _pushStatus = res['ok'] == true ? 'on' : 'off');
    }
    return res;
  }

  Future<void> _testPush() async {
    setState(() => _pushBusy = true);
    final publicKey = CryptoService.instance.publicKeyHex;
    final res = await testWebPush(
      relayServerUrl:
          RelayService.instance.serverUrl ?? RelayService.defaultServerUrl,
      publicKey: publicKey,
    );
    if (!mounted) return;
    setState(() => _pushBusy = false);
    final ok = res['ok'] == true;
    final sent = (res['sent'] as num?)?.toInt() ?? 0;
    _snack(ok
        ? AppL10n.f(
            'Тестовый пуш отправлен ({0}). Сверните приложение — должно прийти уведомление.',
            [
                sent
              ])
        : AppL10n.f('Не удалось отправить тест: {0}',
            [_pushReasonText(res['reason']?.toString())]));
  }

  void _showPushResult(Map<String, Object?> res) {
    if (res['ok'] == true) {
      _snack(AppL10n.t('Фоновые уведомления включены ✓'));
    } else {
      _snack(AppL10n.f(
          'Не включилось: {0}', [_pushReasonText(res['reason']?.toString())]));
    }
  }

  String _pushReasonText(String? reason) {
    switch (reason) {
      case 'denied':
        return AppL10n.t(
            'уведомления запрещены — разрешите их для сайта в настройках браузера');
      case 'not_granted':
        return AppL10n.t(
            'разрешение не выдано — нажмите «Разрешить» в запросе браузера');
      case 'no_push_api':
      case 'no_service_worker':
        return AppL10n.t('этот браузер не поддерживает фоновые пуши');
      case 'no_subscription':
      case 'no_keys':
        return AppL10n.t(
            'не удалось создать подписку (на iPhone добавьте Rlink на экран «Домой»)');
      case 'no_vapid':
        return AppL10n.t('relay не отдал ключ пушей');
      case 'no_subscription_on_relay':
        return AppL10n.t('сначала включите фоновые уведомления');
      case 'bad_args':
        return AppL10n.t('нет связи с relay или профиля');
      default:
        if (reason != null && reason.startsWith('relay_')) {
          return AppL10n.f(
              'relay отклонил подписку ({0})', [reason.substring(6)]);
        }
        if (reason != null && reason.startsWith('http_')) {
          return AppL10n.f('relay недоступен ({0})', [reason.substring(5)]);
        }
        return reason ?? AppL10n.t('неизвестная ошибка');
    }
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  Widget _statusChip(String status) {
    final granted = status == 'granted';
    final denied = status == 'denied';
    final label = granted
        ? AppL10n.t('Разрешено')
        : (denied ? AppL10n.t('Запрещено') : AppL10n.t('Не задано'));
    final color =
        granted ? Colors.green : (denied ? Colors.red : Colors.orange);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required String status,
    required VoidCallback onRequest,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(icon, size: 30, color: cs.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                        child: Text(title,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 16))),
                    const SizedBox(width: 8),
                    _statusChip(status),
                  ]),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style:
                          TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: (_busy || status == 'granted') ? null : onRequest,
              child: Text(status == 'granted'
                  ? AppL10n.t('Готово')
                  : AppL10n.t('Разрешить')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _backgroundPushCard(ColorScheme cs) {
    if (!RuntimePlatform.isWeb) return const SizedBox.shrink();
    final on = _pushStatus == 'on';
    final off = _pushStatus == 'off';
    final (statusText, statusColor) = on
        ? (AppL10n.t('включены'), Colors.green)
        : (off
            ? (AppL10n.t('выключены'), Colors.orange)
            : (AppL10n.t('не проверено'), cs.onSurfaceVariant));
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.podcasts_rounded, size: 22, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(AppL10n.t('Фоновые пуши'),
                      style:
                          TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                Text(statusText,
                    style: TextStyle(
                        color: statusColor, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              AppL10n.t(
                  'Уведомления приходят, даже когда Rlink закрыт. Включите, затем нажмите «Проверить».'),
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _requestNotifications,
                  icon:
                      const Icon(Icons.notifications_active_outlined, size: 18),
                  label: Text(AppL10n.t('Включить')),
                ),
                OutlinedButton.icon(
                  onPressed: _pushBusy ? null : _testPush,
                  icon: _pushBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_outlined, size: 18),
                  label: Text(AppL10n.t('Проверить')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _subScaffold(
      context: context,
      title: AppL10n.t('Разрешения'),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              AppL10n.t(
                  'Разрешите доступ один раз — браузер запомнит выбор для этого сайта и больше спрашивать не будет.'),
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
          _tile(
            icon: Icons.mic_rounded,
            title: AppL10n.t('Микрофон'),
            subtitle: AppL10n.t('Голосовые сообщения и звонки'),
            status: _mic,
            onRequest: () => _requestMedia(audio: true, video: false),
          ),
          _tile(
            icon: Icons.videocam_rounded,
            title: AppL10n.t('Камера'),
            subtitle: AppL10n.t('Видеозвонки'),
            status: _cam,
            onRequest: () => _requestMedia(audio: false, video: true),
          ),
          _tile(
            icon: Icons.notifications_active_rounded,
            title: AppL10n.t('Уведомления'),
            subtitle: AppL10n.t('Пуши, даже когда приложение закрыто'),
            status: _notif,
            onRequest: _requestNotifications,
          ),
          _backgroundPushCard(cs),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              AppL10n.t(
                  'На iPhone уведомления в фоне работают только если добавить Rlink на экран «Домой» (как приложение) и один раз нажать «Разрешить». После включения нажмите «Проверить» и сверните приложение — должно прийти тестовое уведомление.'),
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationsPageState extends State<_NotificationsPage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_notifications'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('settings_notifications')),
          if (RuntimePlatform.isAndroid)
            ListTile(
              leading: Icon(Icons.mark_chat_unread_outlined, color: cs.primary),
              title: Text(AppL10n.t('Доставка сообщений в фоне')),
              subtitle: Text(
                AppL10n.t(
                    'Почему сообщение могло не прийти, пока Rlink закрыт'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context)
                  .push(rlinkOpaquePushRoute(const DeliveryHealthScreen())),
            ),
          SwitchListTile(
            secondary: Icon(Icons.notifications_outlined,
                color: settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_messages')),
            subtitle: Text(AppL10n.t('settings_notif_messages_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.notificationsEnabled,
            onChanged: (v) async {
              await settings.setNotificationsEnabled(v);
              if (v) {
                await NotificationService.instance.requestPermissions();
                await _syncCurrentWebPushSubscription();
                if (mounted) setState(() {});
              }
            },
          ),
          SwitchListTile(
            secondary: Icon(Icons.volume_up_outlined,
                color: settings.notifSound && settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_sound')),
            value: settings.notifSound,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifSound(v)
                : null,
          ),
          ListTile(
            leading: Icon(
              Icons.ring_volume_rounded,
              color: settings.notificationsEnabled
                  ? cs.primary
                  : Theme.of(context).hintColor,
            ),
            title: Text(AppL10n.t('Рингтон звонка')),
            subtitle: Text(
              _ringtoneLabel(settings.callRingtone),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: settings.notificationsEnabled,
            onTap: settings.notificationsEnabled
                ? () => _pickRingtone(context, settings)
                : null,
          ),
          SwitchListTile(
            secondary: Icon(
              Icons.piano_outlined,
              color: settings.notifSound && settings.notificationsEnabled
                  ? cs.primary
                  : Theme.of(context).hintColor,
            ),
            title: Text(AppL10n.t('Тема «Баян»')),
            subtitle: Text(
              AppL10n.t(
                  'Те же мелодии, но в тембре аккордеона вместо чистого тона'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            value: settings.soundTheme == 1,
            onChanged: settings.notificationsEnabled
                ? (v) => unawaited(settings.setSoundTheme(v ? 1 : 0))
                : null,
          ),
          _SectionHeader(AppL10n.t('Звуки приложения')),
          for (final slot in AppSoundSlot.values)
            ListTile(
              leading: Icon(Icons.music_note_outlined, color: cs.primary),
              title: Text(slot.label),
              subtitle: Text(
                _soundSubtitle(settings, slot),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              trailing: Wrap(
                spacing: 2,
                children: [
                  IconButton(
                    tooltip: AppL10n.t('Прослушать'),
                    onPressed: settings.notifSound
                        ? () => unawaited(
                              SoundEffectsService.instance.previewSlot(slot),
                            )
                        : null,
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                  IconButton(
                    tooltip: AppL10n.t('Выбрать файл'),
                    onPressed: settings.notifSound
                        ? () => unawaited(_pickCustomSound(slot))
                        : null,
                    icon: const Icon(Icons.folder_open_outlined),
                  ),
                  if (settings.customSoundPath(slot.id) != null)
                    IconButton(
                      tooltip: AppL10n.t('Сбросить'),
                      onPressed: () => unawaited(_resetCustomSound(slot)),
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
            ),
          if (RuntimePlatform.isWeb)
            FutureBuilder<Map<String, Object?>>(
              future: webNotificationCapability(),
              builder: (context, snapshot) {
                final capability = snapshot.data;
                final permission =
                    (capability?['permission'] as String?) ?? 'default';
                final label = (capability?['label'] as String?) ??
                    AppL10n.t('Проверяем поддержку браузера');
                final canRequest =
                    (capability?['canRequest'] as bool?) ?? false;
                return ListTile(
                  leading: Icon(Icons.public_rounded, color: cs.primary),
                  title: Text(AppL10n.t('Web-уведомления')),
                  subtitle: Text(label,
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  trailing: FilledButton.tonal(
                    onPressed: canRequest
                        ? () async {
                            await NotificationService.instance
                                .requestPermissions();
                            await _syncCurrentWebPushSubscription();
                            if (mounted) setState(() {});
                          }
                        : null,
                    child: Text(permission == 'granted'
                        ? AppL10n.t('Обновить')
                        : AppL10n.t('Разрешить')),
                  ),
                );
              },
            ),
          SwitchListTile(
            secondary: Icon(Icons.vibration,
                color: settings.notifVibration && settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_vibration')),
            value: settings.notifVibration,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifVibration(v)
                : null,
          ),
          SwitchListTile(
            secondary: Icon(Icons.chat_bubble_outline,
                color: settings.notifyPersonal && settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_personal')),
            value: settings.notifyPersonal,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifyPersonal(v)
                : null,
          ),
          SwitchListTile(
            secondary: Icon(Icons.groups_2_outlined,
                color: settings.notifyGroups && settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_groups')),
            value: settings.notifyGroups,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifyGroups(v)
                : null,
          ),
          SwitchListTile(
            secondary: Icon(Icons.campaign_outlined,
                color: settings.notifyChannels && settings.notificationsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_notif_channels')),
            value: settings.notifyChannels,
            onChanged: settings.notificationsEnabled
                ? (v) => settings.setNotifyChannels(v)
                : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.45)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 20, color: cs.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        AppL10n.t('settings_notif_background_warning'),
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: cs.onSurfaceVariant,
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

  String _ringtoneLabel(int ringtone) {
    switch (ringtone.clamp(0, 2)) {
      case 1:
        return 'Digital Pulse';
      case 2:
        return 'Soft Bell';
      case 0:
      default:
        return 'Classic Ring';
    }
  }

  String _soundSubtitle(AppSettings settings, AppSoundSlot slot) {
    final custom = settings.customSoundPath(slot.id);
    if (custom != null)
      return AppL10n.f('Свой файл: {0}', [p.basename(custom)]);
    if (slot == AppSoundSlot.incomingCall) {
      return AppL10n.f(
          'Стандартный: {0}', [_ringtoneLabel(settings.callRingtone)]);
    }
    return AppL10n.t('Стандартный звук');
  }

  String _soundMimeForName(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
      case '.mp4':
        return 'audio/mp4';
      case '.ogg':
      case '.opus':
        return 'audio/ogg';
      case '.wav':
        return 'audio/wav';
      case '.aac':
        return 'audio/aac';
      case '.webm':
        return 'audio/webm';
      default:
        return 'audio/mpeg';
    }
  }

  Future<void> _pickCustomSound(AppSoundSlot slot) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'mp3',
        'm4a',
        'mp4',
        'aac',
        'wav',
        'ogg',
        'opus',
        'webm'
      ],
      allowMultiple: false,
      withData: RuntimePlatform.isWeb,
    );
    final file = picked?.files.firstOrNull;
    if (file == null) return;
    String? storedPath;
    if (RuntimePlatform.isWeb) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) return;
      storedPath = await writeWebStoredFile(
        fileName:
            'sound_${slot.id}_${DateTime.now().millisecondsSinceEpoch}_${file.name}',
        bytes: bytes,
        mimeType: _soundMimeForName(file.name),
      );
      storedPath ??= 'data:${_soundMimeForName(file.name)};base64,'
          '${base64Encode(bytes)}';
    } else {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'sounds'))
        ..createSync(recursive: true);
      final safeName = file.name
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      final out = p.join(
        dir.path,
        '${slot.id}_${DateTime.now().millisecondsSinceEpoch}_$safeName',
      );
      if (file.path != null) {
        await File(file.path!).copy(out);
      } else if (file.bytes != null) {
        await File(out).writeAsBytes(file.bytes!);
      }
      storedPath = out;
    }
    if (storedPath == null || storedPath.isEmpty) return;
    await AppSettings.instance.setCustomSoundPath(slot.id, storedPath);
    if (!mounted) return;
    setState(() {});
    await SoundEffectsService.instance.previewSlot(slot);
  }

  Future<void> _resetCustomSound(AppSoundSlot slot) async {
    await AppSettings.instance.setCustomSoundPath(slot.id, null);
    if (mounted) setState(() {});
  }

  Future<void> _pickRingtone(BuildContext context, AppSettings settings) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(AppL10n.t('Выберите рингтон')),
              subtitle: Text(
                  AppL10n.t('Будет проигрываться при входящем звонке'),
                  style: TextStyle(fontSize: 12)),
            ),
            for (final idx in const [0, 1, 2])
              RadioListTile<int>(
                value: idx,
                groupValue: settings.callRingtone,
                title: Text(_ringtoneLabel(idx)),
                onChanged: (v) => Navigator.pop(ctx, v),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await settings.setCallRingtone(picked);
    // Short preview of selected ringtone
    await SoundEffectsService.instance.startIncomingRingtone();
    await Future.delayed(const Duration(milliseconds: 1200));
    await SoundEffectsService.instance.stopIncomingRingtone();
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Privacy
// ─────────────────────────────────────────────────────────────────────

class _PrivacyPage extends StatefulWidget {
  const _PrivacyPage();

  @override
  State<_PrivacyPage> createState() => _PrivacyPageState();
}

class _PrivacyPageState extends State<_PrivacyPage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_privacy'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('settings_privacy')),
          ListTile(
            leading: Icon(Icons.shield_outlined, color: cs.primary),
            title: Text(AppL10n.t('Безопасность устройства')),
            subtitle: Text(AppL10n.t('Как защищены данные на этом устройстве'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(rlinkOpaquePushRoute(const DeviceSecurityScreen())),
          ),
          ListTile(
            leading: Icon(Icons.visibility_off_outlined, color: cs.primary),
            title: Text(AppL10n.t('Приватность профиля')),
            subtitle: Text(
                AppL10n.t('Что видят другие: аватар, баннер, теги, др…'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(rlinkOpaquePushRoute(const ProfilePrivacyScreen())),
          ),
          SwitchListTile(
            secondary: Icon(Icons.done_all_rounded,
                color: settings.showReadReceipts
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_read_receipts')),
            subtitle: Text(AppL10n.t('settings_read_receipts_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.showReadReceipts,
            onChanged: (v) => settings.setShowReadReceipts(v),
          ),
          SwitchListTile(
            secondary: Icon(Icons.circle,
                color: settings.showOnlineStatus
                    ? const Color(0xFF4CAF50)
                    : Theme.of(context).hintColor,
                size: 14),
            title: Text(AppL10n.t('settings_online_status')),
            subtitle: Text(AppL10n.t('settings_online_status_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.showOnlineStatus,
            onChanged: (v) => settings.setShowOnlineStatus(v),
          ),
          SwitchListTile(
            secondary: Icon(Icons.access_time_rounded,
                color: settings.hideLastSeen
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('Скрыть время последнего визита')),
            subtitle: Text(
              AppL10n.t('Другие не увидят, когда вы были в сети'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            value: settings.hideLastSeen,
            onChanged: (v) => settings.setHideLastSeen(v),
          ),
          _SectionHeader(AppL10n.t('settings_section_presence')),
          _OnlineStatusSelector(
            current: settings.onlineStatusMode,
            onChanged: (mode) => settings.setOnlineStatusMode(mode),
          ),
          _SectionHeader(AppL10n.t('Блокировка')),
          SwitchListTile(
            secondary: Icon(Icons.lock_outline,
                color: AppLockService.instance.isEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('Блокировка приложения')),
            subtitle: Text(
              AppLockService.instance.isEnabled
                  ? _lockMethodLabel(AppLockService.instance.method)
                  : AppL10n.t('PIN, графический ключ или пароль при запуске'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            value: AppLockService.instance.isEnabled,
            onChanged: (v) async {
              if (v) {
                await _enableOrSetPasscode();
              } else {
                await AppLockService.instance.disable();
                if (mounted) setState(() {});
              }
            },
          ),
          if (AppLockService.instance.isEnabled) ...[
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text(AppL10n.t('Автоблокировка')),
              subtitle: Text(
                  _lockTimeoutLabel(AppLockService.instance.timeoutSeconds)),
              onTap: _pickLockTimeout,
            ),
            ListTile(
              leading: const Icon(Icons.password_outlined),
              title: Text(AppL10n.t('Изменить защиту')),
              subtitle: Text(_lockMethodLabel(AppLockService.instance.method),
                  style: const TextStyle(fontSize: 12)),
              onTap: _enableOrSetPasscode,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _enableOrSetPasscode() async {
    // Step 1: choose method
    final method = await showModalBottomSheet<LockMethod>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(AppL10n.t('Выберите способ защиты'),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.grid_4x4_rounded, color: Colors.blue),
              ),
              title: Text(AppL10n.t('Графический ключ')),
              subtitle: Text(AppL10n.t('9 точек — соедините пальцем'),
                  style: TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, LockMethod.pattern),
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.pin_rounded, color: Colors.green),
              ),
              title: Text(AppL10n.t('PIN-код')),
              subtitle:
                  Text(AppL10n.t('4 цифры'), style: TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, LockMethod.pin4),
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.password_rounded, color: Colors.orange),
              ),
              title: Text(AppL10n.t('Пароль')),
              subtitle: Text(AppL10n.t('Буквы, цифры, символы'),
                  style: TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, LockMethod.text),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (method == null || !mounted) return;

    String? code;
    switch (method) {
      case LockMethod.pin4:
        code = await _setupPin4();
      case LockMethod.pattern:
        code = await _setupPattern();
      case LockMethod.text:
        code = await _setupTextPassword();
    }

    if (code == null || !mounted) return;
    await AppLockService.instance.setPasscode(
      code,
      timeoutSeconds: AppLockService.instance.timeoutSeconds,
      method: method,
    );
    if (mounted) setState(() {});
  }

  Future<String?> _setupPin4() async {
    String? first;
    String? err;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          return AlertDialog(
            title: Text(first == null
                ? AppL10n.t('Введите PIN')
                : AppL10n.t('Повторите PIN')),
            content: _PinSetupWidget(
              key: ValueKey(first),
              onComplete: (pin) async {
                if (first == null) {
                  setS(() {
                    first = pin;
                    err = null;
                  });
                } else if (pin == first) {
                  Navigator.pop(ctx, pin);
                } else {
                  setS(() {
                    first = null;
                    err = AppL10n.t('PIN не совпадает — введите снова');
                  });
                }
              },
              error: err,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppL10n.t('Отмена')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<String?> _setupPattern() async {
    List<int>? first;
    String? err;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(first == null
              ? AppL10n.t('Нарисуйте графический ключ')
              : AppL10n.t('Повторите ключ')),
          content: SizedBox(
            width: 240,
            height: 260,
            child: Column(
              children: [
                if (err != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(err!,
                        style: TextStyle(
                            color: Theme.of(ctx).colorScheme.error,
                            fontSize: 13)),
                  ),
                Expanded(
                  child: _PatternSetupWidget(
                    key: ValueKey(first?.join(',')),
                    onComplete: (pattern) {
                      if (pattern.length < 4) {
                        setS(() =>
                            err = AppL10n.t('Соедините не менее 4 точек'));
                        return;
                      }
                      if (first == null) {
                        setS(() {
                          first = pattern;
                          err = null;
                        });
                      } else if (pattern.join(',') == first!.join(',')) {
                        Navigator.pop(ctx, pattern.join(','));
                      } else {
                        setS(() {
                          first = null;
                          err =
                              AppL10n.t('Ключи не совпадают — начните заново');
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppL10n.t('Отмена')),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _setupTextPassword() async {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    String? err;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(AppL10n.t('Установить пароль')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PasswordStrengthField(
                  controller: c1,
                  label: AppL10n.t('Новый пароль'),
                  onChanged: (_) {
                    if (err != null) setS(() => err = null);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: c2,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: AppL10n.t('Повторите пароль'),
                    border: const OutlineInputBorder(),
                    errorText: err,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppL10n.t('Отмена'))),
            FilledButton(
              onPressed: () {
                final a = c1.text;
                final b = c2.text;
                if (a.length < 4) {
                  setS(() => err = AppL10n.t('Минимум 4 символа'));
                  return;
                }
                if (a != b) {
                  setS(() => err = AppL10n.t('Пароли не совпадают'));
                  return;
                }
                Navigator.pop(ctx, a);
              },
              child: Text(AppL10n.t('Готово')),
            ),
          ],
        ),
      ),
    );
  }

  String _lockMethodLabel(LockMethod m) => switch (m) {
        LockMethod.pin4 => AppL10n.t('PIN-код (4 цифры)'),
        LockMethod.pattern => AppL10n.t('Графический ключ'),
        LockMethod.text => AppL10n.t('Текстовый пароль'),
      };

  Future<void> _pickLockTimeout() async {
    final opts = [
      (0, AppL10n.t('Сразу')),
      (60, AppL10n.t('Через 1 минуту')),
      (300, AppL10n.t('Через 5 минут')),
      (900, AppL10n.t('Через 15 минут')),
    ];
    final chosen = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in opts)
              ListTile(
                title: Text(o.$2),
                trailing: AppLockService.instance.timeoutSeconds == o.$1
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(ctx, o.$1),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) {
      await AppLockService.instance.setTimeout(chosen);
      if (mounted) setState(() {});
    }
  }

  String _lockTimeoutLabel(int s) => s == 0
      ? AppL10n.t('Сразу')
      : s < 3600
          ? AppL10n.f('Через {0} мин', [s ~/ 60])
          : AppL10n.f('Через {0} ч', [s ~/ 3600]);
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Messaging
// ─────────────────────────────────────────────────────────────────────

class _MessagingPage extends StatefulWidget {
  const _MessagingPage();

  @override
  State<_MessagingPage> createState() => _MessagingPageState();
}

class _MessagingPageState extends State<_MessagingPage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_messaging'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('settings_messaging')),
          SwitchListTile(
            secondary: Icon(Icons.keyboard_return_rounded,
                color: settings.sendOnEnter
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_send_on_enter')),
            subtitle: Text(AppL10n.t('settings_send_on_enter_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.sendOnEnter,
            onChanged: (v) => settings.setSendOnEnter(v),
          ),
          SwitchListTile(
            secondary: Icon(Icons.auto_awesome_outlined,
                color: settings.emojiSuggestionsEnabled
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('Подсказки эмодзи')),
            subtitle: Text(
              AppL10n.t('Стикер или кастомный эмодзи по набранному эмодзи'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            value: settings.emojiSuggestionsEnabled,
            onChanged: (v) => settings.setEmojiSuggestionsEnabled(v),
          ),
          ListTile(
            leading: Icon(Icons.motion_photos_on_rounded, color: cs.primary),
            title: Text(AppL10n.t('Быстрое видео')),
            subtitle: Text(
              '${settings.quickVideoShape.label} · ${settings.quickVideoQuality.label}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const QuickVideoSettingsScreen())),
          ),
          if (settings.emojiSuggestionsEnabled) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'both', label: Text(AppL10n.t('Оба'))),
                  ButtonSegment(
                      value: 'stickers', label: Text(AppL10n.t('Стикеры'))),
                  ButtonSegment(
                      value: 'emoji', label: Text(AppL10n.t('Эмодзи'))),
                ],
                selected: {settings.emojiSuggestionsMode},
                onSelectionChanged: (s) =>
                    settings.setEmojiSuggestionsMode(s.first),
              ),
            ),
            ListTile(
              leading: Icon(Icons.link_rounded, color: cs.primary),
              title: Text(AppL10n.t('Управление привязками')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context)
                  .push(rlinkOpaquePushRoute(const EmojiBindingsScreen())),
            ),
          ],
          if (!kIsWeb)
            SwitchListTile(
              secondary: Icon(Icons.photo_library_outlined,
                  color: settings.useSystemGallery
                      ? cs.primary
                      : Theme.of(context).hintColor),
              title: Text(AppL10n.t('Системная галерея')),
              subtitle: Text(
                settings.useSystemGallery
                    ? AppL10n.t('Выбор фото через галерею системы')
                    : AppL10n.t('Выбор фото во встроенной галерее Rlink'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              value: settings.useSystemGallery,
              onChanged: (v) => settings.setUseSystemGallery(v),
            ),
          SwitchListTile(
            secondary: Icon(Icons.download_for_offline_outlined,
                color: settings.autoDownloadMedia
                    ? cs.primary
                    : Theme.of(context).hintColor),
            title: Text(AppL10n.t('settings_auto_download')),
            subtitle: Text(AppL10n.t('settings_auto_download_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.autoDownloadMedia,
            onChanged: (v) => settings.setAutoDownloadMedia(v),
          ),
          _SectionHeader(AppL10n.t('settings_section_memory')),
          ListTile(
            leading: Icon(Icons.delete_sweep_outlined, color: cs.error),
            title: Text(AppL10n.t('settings_clear_convo_cache')),
            subtitle: Text(
              AppL10n.t('settings_clear_convo_cache_sub'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            onTap: () => showMessageCacheClearDialog(context),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Profile
// ─────────────────────────────────────────────────────────────────────

class _ProfilePage extends StatefulWidget {
  const _ProfilePage();

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<_ProfilePage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.profile;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_profile'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('settings_profile')),
          if (profile != null)
            ListTile(
              leading: Icon(Icons.emoji_emotions_outlined, color: cs.primary),
              title: Text(AppL10n.t('Эмодзи-статус')),
              subtitle: profile.statusEmoji.isEmpty
                  ? Text(
                      AppL10n.t(
                          'Рядом с именем в меню; виден контактам в сети'),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    )
                  : StatusEmojiView(
                      statusEmoji: profile.statusEmoji,
                      fontSize: 20,
                      style: TextStyle(fontSize: 20, color: cs.onSurface),
                    ),
              trailing: profile.statusEmoji.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: AppL10n.t('Убрать'),
                      onPressed: () => _clearEmojiStatus(),
                    )
                  : null,
              onTap: () => _pickEmojiStatus(context),
            ),
          ListTile(
            leading:
                Icon(Icons.auto_awesome_motion_outlined, color: cs.primary),
            title: Text(AppL10n.t('Стикеры и наборы')),
            subtitle: Text(
              AppL10n.t('Свои наборы и добавление стикеров из переписки'),
              style: TextStyle(fontSize: 12),
            ),
            onTap: () => Navigator.push<void>(
              context,
              rlinkOpaquePushRoute(const StickersHubScreen()),
            ),
          ),
          ListTile(
            leading: Icon(Icons.emoji_emotions, color: cs.primary),
            title: Text(AppL10n.t('cm_emoji')),
            subtitle: Text(
              AppL10n.t('Свои :shortcode: и бот Emoji'),
              style: TextStyle(fontSize: 12),
            ),
            onTap: () => Navigator.push<void>(
              context,
              rlinkOpaquePushRoute(const EmojiHubScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('RID'),
            subtitle: Text(
              profile?.publicKeyHex ?? '—',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push<void>(
              context,
              rlinkOpaquePushRoute(const RidScreen()),
            ),
          ),
          _SectionHeader(AppL10n.t('settings_find_user')),
          ListTile(
            leading: const Icon(Icons.search),
            title: Text(AppL10n.t('settings_search_by_id')),
            subtitle: Text(AppL10n.t('settings_search_by_id_sub'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            onTap: () => _showSearchById(context),
          ),
        ],
      ),
    );
  }

  Future<void> _pickEmojiStatus(BuildContext context) async {
    final prof = ProfileService.instance.profile;
    if (prof == null) return;
    final manualCtrl = TextEditingController(text: prof.statusEmoji);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(AppL10n.t('Эмодзи-статус'),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              SizedBox(
                height: 300,
                child: SingleChildScrollView(
                  child: AvatarEmojiPicker(
                    selected: prof.statusEmoji.isNotEmpty
                        ? prof.statusEmoji
                        : UserProfile.avatarEmojis.first,
                    onSelected: (e) async {
                      Navigator.pop(ctx);
                      await ProfileService.instance.updateProfile(
                        statusEmoji: UserProfile.normalizeStatusEmoji(e),
                      );
                      if (!context.mounted) return;
                      setState(() {});
                      await sendProfileToAllContacts();
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: manualCtrl,
                decoration: InputDecoration(
                  labelText: AppL10n.t('Свой статус'),
                  hintText: AppL10n.t('😀 или :my_emoji:'),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () async {
                  final normalized =
                      UserProfile.normalizeStatusEmoji(manualCtrl.text);
                  Navigator.pop(ctx);
                  await ProfileService.instance.updateProfile(
                    statusEmoji: normalized,
                  );
                  if (!context.mounted) return;
                  setState(() {});
                  await sendProfileToAllContacts();
                },
                child: Text(AppL10n.t('Сохранить статус')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _clearEmojiStatus() async {
    await ProfileService.instance.updateProfile(statusEmoji: '');
    if (mounted) setState(() {});
    await sendProfileToAllContacts();
  }

  void _showSearchById(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _PeerSearchSheet(
        onOpenChat: (publicKey, nickname, color, emoji,
            {String? relayX25519Key, String? relayUsername}) async {
          Navigator.pop(ctx);
          if (relayX25519Key != null && relayX25519Key.isNotEmpty) {
            BleService.instance
                .registerPeerX25519Key(publicKey, relayX25519Key);
            unawaited(ChatStorageService.instance
                .updateContactX25519Key(publicKey, relayX25519Key));
          }
          var contact = await ChatStorageService.instance.getContact(publicKey);
          final finalNick = contact?.nickname ?? nickname;
          final finalColor = contact?.avatarColor ?? color;
          final finalEmoji = contact?.avatarEmoji ?? emoji;
          final imagePath = contact?.avatarImagePath;
          final mergedUsername =
              (relayUsername != null && relayUsername.isNotEmpty)
                  ? relayUsername
                  : (contact?.username ?? '');
          final mergedX25519 =
              (relayX25519Key != null && relayX25519Key.isNotEmpty)
                  ? relayX25519Key
                  : contact?.x25519Key;
          if (contact == null) {
            await ChatStorageService.instance.saveContact(Contact(
              publicKeyHex: publicKey,
              nickname: finalNick,
              username: mergedUsername,
              avatarColor: finalColor,
              avatarEmoji: finalEmoji,
              x25519Key: mergedX25519,
              addedAt: DateTime.now(),
            ));
          } else if (mergedUsername != contact.username ||
              mergedX25519 != contact.x25519Key ||
              finalNick != contact.nickname) {
            await ChatStorageService.instance.saveContact(contact.copyWith(
              nickname: finalNick,
              username: mergedUsername,
              x25519Key: mergedX25519,
            ));
          }
          contact = await ChatStorageService.instance.getContact(publicKey);
          final openNick = contact?.nickname ?? finalNick;
          final openColor = contact?.avatarColor ?? finalColor;
          final openEmoji = contact?.avatarEmoji ?? finalEmoji;
          final openImage = contact?.avatarImagePath ?? imagePath;
          if (context.mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatScreen(
                  peerId: publicKey,
                  peerNickname: openNick,
                  peerAvatarColor: openColor,
                  peerAvatarEmoji: openEmoji,
                  peerAvatarImagePath: openImage,
                ),
              ),
            );
          }
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-screen: Network
// ─────────────────────────────────────────────────────────────────────

class _WebInstallPage extends StatelessWidget {
  const _WebInstallPage();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _subScaffold(
      context: context,
      title: AppL10n.t('Установка на iPhone'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('Safari на iPhone')),
          _InstallStepTile(
            index: 1,
            icon: Icons.open_in_browser_rounded,
            title: AppL10n.t('Откройте Rlink в Safari'),
            subtitle: AppL10n.t(
                'На iPhone установка на главный экран работает именно из Safari.'),
          ),
          _InstallStepTile(
            index: 2,
            icon: Icons.ios_share_rounded,
            title: AppL10n.t('Нажмите кнопку «Поделиться»'),
            subtitle: AppL10n.t('Она находится в нижней панели Safari.'),
          ),
          _InstallStepTile(
            index: 3,
            icon: Icons.add_box_outlined,
            title: AppL10n.t('Выберите «На экран Домой»'),
            subtitle: AppL10n.t(
                'Если пункта не видно, прокрутите список действий ниже.'),
          ),
          _InstallStepTile(
            index: 4,
            icon: Icons.check_circle_outline_rounded,
            title: AppL10n.t('Нажмите «Добавить»'),
            subtitle: AppL10n.t(
                'После этого Rlink будет запускаться с главного экрана как приложение.'),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(Icons.info_outline_rounded, color: cs.primary),
            title: Text(AppL10n.t('После установки')),
            subtitle: Text(
              AppL10n.t(
                  'Откройте Rlink с иконки на главном экране и разрешите уведомления, микрофон и камеру при первом запросе.'),
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _InstallStepTile extends StatelessWidget {
  final int index;
  final IconData icon;
  final String title;
  final String subtitle;

  const _InstallStepTile({
    required this.index,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: cs.primaryContainer,
        child: Text(
          '$index',
          style: TextStyle(
            color: cs.onPrimaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Row(
        children: [
          Icon(icon, size: 19, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(title)),
        ],
      ),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _NetworkPage extends StatefulWidget {
  const _NetworkPage();

  @override
  State<_NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends State<_NetworkPage> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;

    return _subScaffold(
      context: context,
      title: AppL10n.t('settings_section_network'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          // ── Связка устройств ──────────────────────────────────────
          _SectionHeader(AppL10n.t('Связка устройств')),
          if (settings.isDeviceLinked) ...[
            ListTile(
              leading: Icon(
                settings.isPrimaryDevice
                    ? Icons.admin_panel_settings_outlined
                    : Icons.phone_iphone_rounded,
                color: cs.primary,
              ),
              title: Text(settings.isPrimaryDevice
                  ? AppL10n.t('Главное устройство')
                  : AppL10n.t('Дочернее устройство')),
              subtitle: Text(
                settings.linkedDeviceNickname.isNotEmpty
                    ? AppL10n.f('Связано: {0}', [settings.linkedDeviceNickname])
                    : settings.linkedDevicePublicKey,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.link_off_rounded, color: Colors.red),
              title: Text(AppL10n.t('Отвязать устройство'),
                  style: TextStyle(color: Colors.red)),
              subtitle: Text(
                  AppL10n.t('Связка будет снята на обоих устройствах'),
                  style: TextStyle(fontSize: 12)),
              onTap: () => doUnlinkDevice(context),
            ),
          ] else ...[
            ListTile(
              leading: Icon(Icons.link_rounded, color: cs.primary),
              title: Text(AppL10n.t('Привязать дочернее устройство')),
              subtitle: Text(
                  AppL10n.t('Выберите контакт и отправьте запрос на связку'),
                  style: TextStyle(fontSize: 12)),
              onTap: () => requestDeviceLink(context),
            ),
          ],

          // ── Тип связи ──────────────────────────────────────────────
          _SectionHeader(AppL10n.t('settings_connection_type')),
          ListTile(
            leading: Icon(Icons.swap_horiz_rounded, color: cs.primary),
            title: Text(AppL10n.t('settings_connection_type')),
            subtitle: Text(
              [
                AppL10n.t('conn_mode_ble_only'),
                AppL10n.t('conn_mode_internet_only'),
                AppL10n.t('conn_mode_all'),
              ][settings.connectionMode],
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: RuntimePlatform.isWeb
                ? Row(children: [
                    _NetChip(
                      icon: Icons.wifi,
                      label: AppL10n.t('net_label_internet'),
                      selected: true,
                      onTap: () => _setConnectionMode(1),
                    ),
                  ])
                : Row(children: [
                    _NetChip(
                      icon: Icons.bluetooth,
                      label: 'BLE',
                      selected: settings.connectionMode == 0,
                      onTap: () => _setConnectionMode(0),
                    ),
                    const SizedBox(width: 8),
                    _NetChip(
                      icon: Icons.wifi,
                      label: AppL10n.t('net_label_internet'),
                      selected: settings.connectionMode == 1,
                      onTap: () => _setConnectionMode(1),
                    ),
                    const SizedBox(width: 8),
                    _NetChip(
                      icon: Icons.sync_alt_rounded,
                      label: AppL10n.t('net_label_both'),
                      selected: settings.connectionMode == 2,
                      onTap: () => _setConnectionMode(2),
                    ),
                  ]),
          ),
          if (RuntimePlatform.isWeb)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                  AppL10n.t('В web-версии доступен только интернет-режим.'),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ),
          if (settings.isDeviceLinked)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                AppL10n.t(
                    'В режиме связки Bluetooth автоматически выключен, используется только интернет.'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          if (RuntimePlatform.isAndroid && settings.connectionMode == 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                AppL10n.t('wifi_direct_note_android'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 12),

          // Media priority
          if (settings.connectionMode == 2) ...[
            ListTile(
              leading: Icon(Icons.perm_media_outlined, color: cs.primary),
              title: Text(AppL10n.t('settings_media_priority')),
              subtitle: Text(
                settings.mediaPriority == 0
                    ? AppL10n.t('media_send_via_bt')
                    : AppL10n.t('media_send_via_internet'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                _NetChip(
                  icon: Icons.bluetooth,
                  label: 'BLE',
                  selected: settings.mediaPriority == 0,
                  onTap: () => settings.setMediaPriority(0),
                ),
                const SizedBox(width: 8),
                _NetChip(
                  icon: Icons.wifi,
                  label: AppL10n.t('net_label_internet'),
                  selected: settings.mediaPriority == 1,
                  onTap: () => settings.setMediaPriority(1),
                ),
              ]),
            ),
            const SizedBox(height: 12),
          ],

          // ── Ретранслятор ───────────────────────────────────────────
          if (settings.connectionMode >= 1) ...[
            _SectionHeader(AppL10n.t('Ретранслятор')),
            ValueListenableBuilder<RelayState>(
              valueListenable: RelayService.instance.state,
              builder: (_, relayState, __) {
                final connected = relayState == RelayState.connected;
                final connecting = relayState == RelayState.connecting;
                return ValueListenableBuilder<int>(
                  valueListenable: RelayService.instance.onlineCount,
                  builder: (_, count, __) => ValueListenableBuilder<String?>(
                    valueListenable: RelayService.instance.lastError,
                    builder: (_, lastErr, __) => ListTile(
                      leading: Icon(
                        connected
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
                        color: connected
                            ? const Color(0xFF4CAF50)
                            : connecting
                                ? Colors.amber
                                : Colors.red,
                      ),
                      title: Text(connected
                          ? AppL10n.t('relay_server_connected')
                          : connecting
                              ? AppL10n.t('relay_server_connecting')
                              : AppL10n.t('relay_server_unavailable')),
                      subtitle: Text(
                        connected
                            ? AppL10n.t('relay_online')
                                .replaceAll('{n}', '$count')
                            : ((lastErr != null && lastErr.isNotEmpty)
                                ? '${AppL10n.t('relay_no_connection')}\n$lastErr'
                                : AppL10n.t('relay_no_connection')),
                        style:
                            TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                      trailing: SizedBox(
                        width: 60,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (connecting)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            IconButton(
                              icon: const Icon(Icons.refresh, size: 20),
                              tooltip: connected
                                  ? AppL10n.t('tool_reconnect')
                                  : AppL10n.t('tool_connect'),
                              onPressed: () async {
                                // Keep a healthy connection (new ones can be
                                // dropped by the network); reconnect only if
                                // the server does not answer.
                                final messenger = ScaffoldMessenger.of(context);
                                final alive = connected &&
                                    await RelayService.instance.refreshIfDead();
                                if (alive) {
                                  messenger.showSnackBar(SnackBar(
                                      content: Text(AppL10n.t(
                                          'Соединение с сервером в порядке'))));
                                } else if (!connected) {
                                  await RelayService.instance.reconnect();
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.bug_report_outlined, color: cs.primary),
              title: Text(AppL10n.t('Диагностика связи')),
              subtitle: ValueListenableBuilder<String?>(
                valueListenable: RelayService.instance.lastError,
                builder: (_, lastErr, __) {
                  final pk = CryptoService.instance.publicKeyHex;
                  final shortPk =
                      pk.isEmpty ? 'empty' : '${pk.substring(0, 8)}...';
                  final relayState = RelayService.instance.state.value.name;
                  final online = RelayService.instance.onlineCount.value;
                  final err = (lastErr == null || lastErr.isEmpty)
                      ? '-'
                      : lastErr.replaceAll('\n', ' ');
                  return Text(
                    'pk=$shortPk, relay=$relayState, online=$online, err=$err',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  );
                },
              ),
              trailing: const Icon(Icons.copy_rounded, size: 18),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final pk = CryptoService.instance.publicKeyHex;
                final relayState = RelayService.instance.state.value.name;
                final online = RelayService.instance.onlineCount.value;
                final err = RelayService.instance.lastError.value ?? '-';
                final diag = [
                  'pk=${pk.isEmpty ? 'empty' : pk}',
                  'relay=$relayState',
                  'online=$online',
                  'err=$err',
                  'url=${RelayService.instance.activeGossipRelayUrl ?? RelayService.instance.serverUrl ?? '-'}',
                  'secondary=${RelayService.instance.hasSecondaryLink}',
                ].join('\n');
                await Clipboard.setData(ClipboardData(text: diag));
                if (!context.mounted) return;
                messenger.showSnackBar(
                  SnackBar(content: Text(AppL10n.t('Диагностика скопирована'))),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.list_alt_rounded, color: cs.primary),
              title: Text(AppL10n.t('Живой лог доставки')),
              subtitle: Text(
                AppL10n.t('TX/RX/DROP трассировка сообщений и запросов'),
                style: TextStyle(fontSize: 12),
              ),
              onTap: () => Navigator.push(
                context,
                rlinkOpaquePushRoute(const DiagnosticsScreen()),
              ),
            ),
            ListTile(
              leading: Icon(Icons.hub_outlined, color: cs.primary),
              title: Text(AppL10n.t('Статус mesh')),
              subtitle: Text(
                AppL10n.t('Кто рядом по Bluetooth, что ещё не доставлено'),
                style: TextStyle(fontSize: 12),
              ),
              onTap: () => Navigator.push(
                context,
                rlinkOpaquePushRoute(const MeshStatusScreen()),
              ),
            ),
            ListTile(
              leading: Icon(Icons.radar, color: cs.primary),
              title: Text(AppL10n.t('Радар mesh-сети')),
              subtitle: Text(
                AppL10n.t('Кто рядом визуально: напрямую и через сеть'),
                style: TextStyle(fontSize: 12),
              ),
              onTap: () => Navigator.push(
                context,
                rlinkOpaquePushRoute(const MeshRadarScreen()),
              ),
            ),
            ListTile(
              leading: Icon(Icons.dns_outlined, color: cs.primary),
              title: Text(AppL10n.t('Свой relay-сервер')),
              subtitle: Text(
                settings.relayServerUrl.trim().isEmpty
                    ? AppL10n.f(
                        'По умолчанию ({0})', [RelayService.defaultServerUrl])
                    : settings.relayServerUrl,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              onTap: () => _editCustomRelayUrl(context),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _editCustomRelayUrl(BuildContext context) async {
    final settings = AppSettings.instance;
    final controller = TextEditingController(text: settings.relayServerUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.t('Свой relay-сервер')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppL10n.t(
                  'Сюда впиши адрес своего relay (например wss://my-server.example). Официальный сервер при этом не отключается — приложение держит лёгкое соединение и с ним тоже, чтобы достучаться до тех, кто свой relay не настраивал. Платежи и другие сервисы всё равно остаются только на официальном сервере.'),
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'wss://my-relay.example',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text(AppL10n.t('Сбросить')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppL10n.t('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(AppL10n.t('Сохранить')),
          ),
        ],
      ),
    );
    if (result == null) return; // cancelled
    if (result.isNotEmpty &&
        !result.startsWith('ws://') &&
        !result.startsWith('wss://')) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(AppL10n.t('Адрес должен начинаться с ws:// или wss://'))),
      );
      return;
    }
    await settings.setRelayServerUrl(result);
    RelayService.instance.disconnect();
    unawaited(RelayService.instance.connect());
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.isEmpty
            ? AppL10n.t('Сброшено на сервер по умолчанию')
            : AppL10n.t('Сохранено, переподключаюсь...')),
      ),
    );
  }

  Future<void> _setConnectionMode(int mode) async {
    final settings = AppSettings.instance;
    if (RuntimePlatform.isWeb && mode != 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(AppL10n.t('В web-версии доступен только интернет-режим'))),
      );
      return;
    }
    if (settings.isDeviceLinked) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppL10n.t(
                'В режиме связки устройств доступен только интернет-режим'))),
      );
      return;
    }
    await settings.setConnectionMode(mode);
    await applyConnectionTransport();
  }
}

// ─────────────────────────────────────────────────────────────────────
// Helper widgets (unchanged)
// ─────────────────────────────────────────────────────────────────────

class _SizeChip extends StatelessWidget {
  final String label;
  final TextStyle style;
  final bool selected;
  final VoidCallback onTap;

  const _SizeChip({
    required this.label,
    required this.style,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: selected ? cs.primary : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          border: selected ? null : Border.all(color: cs.outlineVariant),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: style.copyWith(
                color: selected ? cs.onPrimary : cs.onSurfaceVariant)),
      ),
    );
  }
}

class _ThemeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? cs.primary : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: selected ? null : Border.all(color: cs.outlineVariant),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 16, color: selected ? cs.onPrimary : cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: selected ? cs.onPrimary : cs.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ]),
      ),
    );
  }
}

class _AppIconChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Future<void> Function() onTap;

  const _AppIconChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => onTap(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? cs.primary : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: selected ? null : Border.all(color: cs.outlineVariant),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? cs.onPrimary : cs.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _NetChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NetChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? cs.primary : cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: selected ? null : Border.all(color: cs.outlineVariant),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 20, color: selected ? cs.onPrimary : cs.onSurfaceVariant),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: selected ? cs.onPrimary : cs.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Фон чата ──────────────────────────────────────────────────────────

class _ChatBgTile extends StatelessWidget {
  final AppSettings settings;
  const _ChatBgTile({required this.settings});

  Future<void> _pickBg(BuildContext context) async {
    final path = await pickAndStoreChatBackground();
    if (path == null || !context.mounted) return;
    await settings.setChatBgForPeer('__global__', path);
  }

  /// Убирает глобальный фон чата: очищает настройку и удаляет сам файл.
  Future<void> _removeBg() async {
    final path = settings.chatBgForPeer('__global__');
    await settings.setChatBgForPeer('__global__', null);
    if (path != null && !RuntimePlatform.isWeb) {
      try {
        final f = File(path);
        if (f.existsSync()) await f.delete();
      } catch (_) {/* файл мог быть уже удалён — не критично */}
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bgPath = settings.chatBgForPeer('__global__');
    final hasBg = bgPath != null &&
        (RuntimePlatform.isWeb ? isWebStoredFile(bgPath) : File(bgPath).existsSync());

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: hasBg
                ? storedImage(bgPath, fit: BoxFit.cover, width: 44, height: 44)
                : Container(
                    width: 44,
                    height: 44,
                    color: cs.surfaceContainerHigh,
                    child: Icon(Icons.wallpaper_outlined,
                        color: cs.onSurfaceVariant),
                  ),
          ),
          title: Text(AppL10n.t('settings_chat_bg')),
          subtitle: Text(
            bgPath != null
                ? AppL10n.t('settings_chat_bg_custom')
                : AppL10n.t('settings_chat_bg_none'),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: AppL10n.t('settings_chat_bg_pick_tooltip'),
            onPressed: () => _pickBg(context),
          ),
        ),
        // Явная кнопка удаления фона — видна, только когда фон установлен.
        if (bgPath != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _removeBg,
                icon: Icon(Icons.delete_outline, color: cs.error, size: 20),
                label: Text(
                  AppL10n.t('settings_chat_bg_remove'),
                  style:
                      TextStyle(color: cs.error, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Заголовок секции ───────────────────────────────────────────────────

// ── Расшифровка (движок + модель) ─────────────────────────────────────

class _TranscriptionPage extends StatefulWidget {
  const _TranscriptionPage();

  @override
  State<_TranscriptionPage> createState() => _TranscriptionPageState();
}

class _TranscriptionPageState extends State<_TranscriptionPage> {
  final Map<WhisperModelSize, bool> _installed = {};

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onChanged);
    _refreshInstalled();
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  bool get _isWeb => RuntimePlatform.isWeb;
  bool get _isApple => RuntimePlatform.isIos || RuntimePlatform.isDesktopMacos;

  static String _fmtMb(int bytes) =>
      AppL10n.f('{0} МБ', [(bytes / (1024 * 1024)).round()]);

  String _onDeviceSubtitle() {
    if (_isWeb) return AppL10n.t('whisper.cpp в браузере (WASM)');
    if (_isApple) return AppL10n.t('WhisperKit — встроенный движок Apple');
    return AppL10n.t('whisper.cpp на устройстве');
  }

  Future<void> _refreshInstalled() async {
    if (_isWeb || _isApple) return;
    for (final s in WhisperModelSize.values) {
      if (s.isBundled) continue;
      _installed[s] = await ModelDownloadService.instance.isDownloaded(s);
    }
    if (mounted) setState(() {});
  }

  Future<void> _downloadModel(WhisperModelSize size) async {
    try {
      await ModelDownloadService.instance.ensureDownloaded(size);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                AppL10n.f('Модель «{0}» установлена', [size.displayName]))),
      );
      await _refreshInstalled();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _deleteModel(WhisperModelSize size) async {
    await ModelDownloadService.instance.delete(size);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(AppL10n.f('Модель «{0}» удалена', [size.displayName]))),
    );
    await _refreshInstalled();
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;
    final engine = settings.transcriptionEngine;
    final size = settings.transcriptionModelSize;

    return _subScaffold(
      context: context,
      title: AppL10n.t('Расшифровка'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _SectionHeader(AppL10n.t('Движок расшифровки')),
          RadioListTile<TranscriptionEngine>(
            value: TranscriptionEngine.onDevice,
            groupValue: engine,
            title: Text(AppL10n.t('На устройстве (локально)')),
            subtitle: Text(_onDeviceSubtitle(),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            onChanged: (v) {
              if (v != null) settings.setTranscriptionEngine(v);
            },
          ),
          RadioListTile<TranscriptionEngine>(
            value: TranscriptionEngine.cloud,
            groupValue: engine,
            title: Text(AppL10n.t('Облако (Hugging Face)')),
            subtitle: Text(AppL10n.t('Аудио отправляется на сервер'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            onChanged: (v) {
              if (v != null) settings.setTranscriptionEngine(v);
            },
          ),
          if (engine == TranscriptionEngine.onDevice) ...[
            _SectionHeader(AppL10n.t('Модель')),
            for (final s in WhisperModelSize.values)
              _modelTile(context, s, size),
            if (_isWeb)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  AppL10n.t(
                      'В браузере используется встроенная модель (tiny); загрузка дополнительных моделей недоступна.'),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              )
            else if (_isApple)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  AppL10n.t(
                      'WhisperKit скачивает выбранную модель автоматически при первом запуске.'),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _modelTile(
      BuildContext context, WhisperModelSize s, WhisperModelSize selected) {
    final cs = Theme.of(context).colorScheme;
    // На вебе доступна только встроенная tiny.
    final disabled = _isWeb && !s.isBundled;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RadioListTile<WhisperModelSize>(
          value: s,
          groupValue: selected,
          title: Text(s.displayName),
          subtitle: Text(
            '≈ ${_fmtMb(s.approxBytes)}${s.isBundled ? AppL10n.t(' · встроена') : ''}',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          onChanged: disabled
              ? null
              : (v) {
                  if (v != null) {
                    AppSettings.instance.setTranscriptionModelSize(v);
                  }
                },
        ),
        if (!_isWeb && !_isApple && !s.isBundled) _modelDownloadRow(context, s),
      ],
    );
  }

  Widget _modelDownloadRow(BuildContext context, WhisperModelSize s) {
    return ValueListenableBuilder<WhisperModelSize?>(
      valueListenable: ModelDownloadService.instance.downloading,
      builder: (_, downloadingSize, __) {
        if (downloadingSize == s) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 10),
            child: ValueListenableBuilder<double?>(
              valueListenable: ModelDownloadService.instance.progress,
              builder: (_, prog, __) {
                return Row(
                  children: [
                    Expanded(child: LinearProgressIndicator(value: prog)),
                    const SizedBox(width: 12),
                    Text(prog == null ? '…' : '${(prog * 100).round()}%',
                        style: const TextStyle(fontSize: 12)),
                  ],
                );
              },
            ),
          );
        }
        final installed = _installed[s] ?? false;
        final busy = downloadingSize != null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 8, 6),
          child: Row(
            children: [
              if (installed) ...[
                const Icon(Icons.check_circle,
                    color: Color(0xFF4CAF50), size: 18),
                const SizedBox(width: 6),
                Text(AppL10n.t('Установлена'), style: TextStyle(fontSize: 12)),
                const Spacer(),
                TextButton.icon(
                  onPressed: busy ? null : () => _deleteModel(s),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(AppL10n.t('common_delete')),
                ),
              ] else ...[
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : () => _downloadModel(s),
                  icon: const Icon(Icons.download, size: 18),
                  label: Text(AppL10n.t('Скачать')),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).hintColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

// ── Статус в сети ─────────────────────────────────────────────────────

class _OnlineStatusSelector extends StatelessWidget {
  final int current;
  final ValueChanged<int> onChanged;

  const _OnlineStatusSelector({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final statuses = [
      (
        icon: Icons.circle,
        color: const Color(0xFF4CAF50),
        label: AppL10n.t('online_status_green'),
        sub: AppL10n.t('online_status_green_sub'),
      ),
      (
        icon: Icons.circle,
        color: const Color(0xFFFFC107),
        label: AppL10n.t('online_status_yellow'),
        sub: AppL10n.t('online_status_yellow_sub'),
      ),
      (
        icon: Icons.circle,
        color: const Color(0xFFF44336),
        label: AppL10n.t('online_status_red'),
        sub: AppL10n.t('online_status_red_sub'),
      ),
    ];
    return Column(
      children: [
        for (var i = 0; i < statuses.length; i++)
          RadioListTile<int>(
            value: i,
            groupValue: current,
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            secondary:
                Icon(statuses[i].icon, color: statuses[i].color, size: 14),
            title: Text(statuses[i].label),
            subtitle: Text(statuses[i].sub,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            dense: true,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Icon(Icons.circle, color: Colors.grey.shade500, size: 10),
            const SizedBox(width: 8),
            Text(AppL10n.t('online_status_gray_hint'),
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).hintColor)),
          ]),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ── Поиск собеседника (relay + прямой ключ) ────────────────────────────

class _PeerSearchSheet extends StatefulWidget {
  final void Function(
    String publicKey,
    String nickname,
    int color,
    String emoji, {
    String? relayX25519Key,
    String? relayUsername,
  }) onOpenChat;

  const _PeerSearchSheet({required this.onOpenChat});

  @override
  State<_PeerSearchSheet> createState() => _PeerSearchSheetState();
}

class _PeerSearchSheetState extends State<_PeerSearchSheet> {
  final _ctrl = TextEditingController();
  bool _searching = false;
  Timer? _debounce;
  static final RegExp _pubKey64 = RegExp(r'^[0-9a-fA-F]{64}$');

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    RelayService.instance.searchResults.value = [];
    super.dispose();
  }

  void _onTextChanged() {
    _debounce?.cancel();
    final q = _ctrl.text.trim();
    if (q.isEmpty) {
      RelayService.instance.searchResults.value = [];
      setState(() => _searching = false);
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 400), () {
      RelayService.instance.searchUsers(q);
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) setState(() => _searching = false);
      });
    });
  }

  void _openDirect() {
    final raw = _ctrl.text.trim();
    if (raw.isEmpty) return;
    String? id;
    if (_pubKey64.hasMatch(raw)) {
      id = raw.toLowerCase();
    } else if (raw.length >= 8) {
      id = RelayService.instance.findPeerByPrefix(raw.toLowerCase());
    }
    if (id == null || !_pubKey64.hasMatch(id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppL10n.t(
              'Нужен полный ключ (64 hex) или онлайн-пир по короткому коду')),
        ),
      );
      return;
    }
    widget.onOpenChat(id, '${id.substring(0, 8)}...', 0xFF607D8B, '');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final relayConnected = RelayService.instance.isConnected;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Text(AppL10n.t('peer_search_title'),
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              relayConnected
                  ? AppL10n.t('peer_search_sub_connected')
                  : AppL10n.t('peer_search_sub_disconnected'),
              style:
                  TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  hintText: AppL10n.t('peer_search_hint'),
                  hintStyle: TextStyle(
                    color: Theme.of(context).hintColor,
                    fontFamily: 'sans-serif',
                  ),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _ctrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _ctrl.clear();
                            RelayService.instance.searchResults.value = [];
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<List<RelayPeer>>(
              valueListenable: RelayService.instance.searchResults,
              builder: (_, results, __) {
                if (_searching) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                if (results.isEmpty && _ctrl.text.trim().isNotEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Icon(Icons.person_search_rounded,
                            color: Theme.of(context).hintColor, size: 36),
                        const SizedBox(height: 8),
                        Text(
                          relayConnected
                              ? AppL10n.t('peer_not_found_online')
                              : AppL10n.t('peer_relay_off_no_search'),
                          style: TextStyle(
                              color: Theme.of(context).hintColor, fontSize: 13),
                        ),
                        if (_ctrl.text.trim().length >= 8) ...[
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _openDirect,
                            icon:
                                const Icon(Icons.chat_bubble_outline, size: 18),
                            label: Text(AppL10n.t('peer_open_chat_by_key')),
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }
                if (results.isEmpty) {
                  return const SizedBox(height: 16);
                }
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: results.length,
                    itemBuilder: (_, i) {
                      final peer = results[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: cs.primary.withValues(alpha: 0.15),
                          child: Text(
                            peer.nick.isNotEmpty
                                ? peer.nick[0].toUpperCase()
                                : '#',
                            style: TextStyle(
                              color: cs.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          peer.nick.isNotEmpty ? peer.nick : peer.shortId,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(
                          peer.shortId,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 11),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Color(0xFF4CAF50),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(AppL10n.t('peer_online'),
                                style: TextStyle(
                                    fontSize: 11, color: cs.onSurfaceVariant)),
                          ],
                        ),
                        onTap: () => widget.onOpenChat(
                          peer.publicKey,
                          peer.nick.isNotEmpty ? peer.nick : peer.shortId,
                          0xFF607D8B,
                          '',
                          relayX25519Key:
                              peer.x25519Key.isNotEmpty ? peer.x25519Key : null,
                          relayUsername:
                              peer.username.isNotEmpty ? peer.username : null,
                        ),
                      );
                    },
                  ),
                );
              },
            ),
            if (_ctrl.text.trim().length >= 32)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextButton.icon(
                  onPressed: _openDirect,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: Text(AppL10n.t('peer_open_direct_by_key')),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Lock setup helpers
// ─────────────────────────────────────────────────────────────────────

class _PinSetupWidget extends StatefulWidget {
  final void Function(String pin) onComplete;
  final String? error;
  const _PinSetupWidget({super.key, required this.onComplete, this.error});
  @override
  State<_PinSetupWidget> createState() => _PinSetupWidgetState();
}

class _PinSetupWidgetState extends State<_PinSetupWidget> {
  String _pin = '';
  void _onDigit(int d) {
    if (_pin.length >= 4) return;
    setState(() => _pin += '$d');
    if (_pin.length == 4) {
      final p = _pin;
      setState(() => _pin = '');
      widget.onComplete(p);
    }
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(widget.error!,
                style: TextStyle(color: cs.error, fontSize: 13)),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(4, (i) {
            final filled = i < _pin.length;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(horizontal: 8),
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? cs.primary : Colors.transparent,
                border: Border.all(
                  color:
                      filled ? cs.primary : cs.outline.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 16),
        for (final row in [
          [1, 2, 3],
          [4, 5, 6],
          [7, 8, 9],
          [-1, 0, -2]
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: row.map((d) {
              if (d == -1) return const SizedBox(width: 56, height: 44);
              if (d == -2)
                return SizedBox(
                    width: 56,
                    height: 44,
                    child: IconButton(
                        icon: const Icon(Icons.backspace_outlined, size: 18),
                        onPressed: _backspace));
              return SizedBox(
                  width: 56,
                  height: 44,
                  child: TextButton(
                      onPressed: () => _onDigit(d),
                      child: Text('$d',
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w400))));
            }).toList(),
          ),
      ],
    );
  }
}

class _PatternSetupWidget extends StatefulWidget {
  final void Function(List<int>) onComplete;
  const _PatternSetupWidget({super.key, required this.onComplete});
  @override
  State<_PatternSetupWidget> createState() => _PatternSetupWidgetState();
}

class _PatternSetupWidgetState extends State<_PatternSetupWidget> {
  final List<int> _pattern = [];
  Offset? _currentDrag;
  bool _done = false;

  Offset _pos(int i, Size s) {
    final cw = s.width / 3;
    final ch = s.height / 3;
    return Offset(cw * (i % 3) + cw / 2, ch * (i ~/ 3) + ch / 2);
  }

  void _onPanStart(DragStartDetails d, Size s) {
    if (_done) return;
    setState(() {
      _pattern.clear();
      _currentDrag = d.localPosition;
      _done = false;
    });
    _hitTest(d.localPosition, s);
  }

  void _onPanUpdate(DragUpdateDetails d, Size s) {
    if (_done) return;
    setState(() => _currentDrag = d.localPosition);
    _hitTest(d.localPosition, s);
  }

  void _hitTest(Offset pos, Size s) {
    for (var i = 0; i < 9; i++) {
      if (_pattern.contains(i)) continue;
      if ((pos - _pos(i, s)).distance < 26) {
        setState(() => _pattern.add(i));
        break;
      }
    }
  }

  void _onPanEnd(DragEndDetails _) {
    if (_done || _pattern.isEmpty) return;
    setState(() {
      _done = true;
      _currentDrag = null;
    });
    widget.onComplete(List.from(_pattern));
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted)
        setState(() {
          _pattern.clear();
          _done = false;
        });
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (_, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      return GestureDetector(
        onPanStart: (d) => _onPanStart(d, size),
        onPanUpdate: (d) => _onPanUpdate(d, size),
        onPanEnd: _onPanEnd,
        child: CustomPaint(
          painter: _PatternPainterSimple(
              pattern: _pattern,
              currentDrag: _currentDrag,
              color: cs.primary,
              outline: cs.outline),
          size: size,
        ),
      );
    });
  }
}

class _PatternPainterSimple extends CustomPainter {
  final List<int> pattern;
  final Offset? currentDrag;
  final Color color, outline;
  const _PatternPainterSimple(
      {required this.pattern,
      required this.currentDrag,
      required this.color,
      required this.outline});
  Offset _pos(int i, Size s) {
    final cw = s.width / 3;
    final ch = s.height / 3;
    return Offset(cw * (i % 3) + cw / 2, ch * (i ~/ 3) + ch / 2);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final lp = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < pattern.length - 1; i++)
      canvas.drawLine(_pos(pattern[i], size), _pos(pattern[i + 1], size), lp);
    if (pattern.isNotEmpty && currentDrag != null)
      canvas.drawLine(_pos(pattern.last, size), currentDrag!, lp);
    for (var i = 0; i < 9; i++) {
      final pos = _pos(i, size);
      final sel = pattern.contains(i);
      canvas.drawCircle(pos, sel ? 12 : 9,
          Paint()..color = sel ? color : outline.withValues(alpha: 0.3));
      canvas.drawCircle(
          pos,
          19,
          Paint()
            ..color = sel
                ? color.withValues(alpha: 0.2)
                : outline.withValues(alpha: 0.15)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_PatternPainterSimple o) =>
      o.pattern != pattern || o.currentDrag != currentDrag;
}

class _PasswordStrengthField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final void Function(String)? onChanged;
  const _PasswordStrengthField(
      {required this.controller, required this.label, this.onChanged});
  @override
  State<_PasswordStrengthField> createState() => _PasswordStrengthFieldState();
}

class _PasswordStrengthFieldState extends State<_PasswordStrengthField> {
  bool _obscure = true;
  int _strength(String pw) {
    if (pw.isEmpty) return 0;
    var s = 0;
    if (pw.length >= 8) s++;
    if (pw.contains(RegExp(r'[A-Z]'))) s++;
    if (pw.contains(RegExp(r'[0-9]'))) s++;
    if (pw.contains(RegExp(r'[^A-Za-z0-9]'))) s++;
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final s = _strength(widget.controller.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          obscureText: _obscure,
          onChanged: (v) {
            setState(() {});
            widget.onChanged?.call(v);
          },
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: widget.controller.text.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: SecurityStrengthMeter(strength: s),
                ),
        ),
      ],
    );
  }
}

/// A settings page reachable from the global search.
class SettingsSearchEntry {
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget Function() page;
  const SettingsSearchEntry(this.title, this.subtitle, this.icon, this.page);
}

/// Settings pages the global search can jump to. Titles reuse the same
/// localisation keys as the category cards so they can't drift apart.
List<SettingsSearchEntry> settingsSearchEntries() => [
      SettingsSearchEntry(
          AppL10n.t('settings_appearance'),
          AppL10n.t('Тема, цвета, шрифт, фон'),
          Icons.palette_outlined,
          () => const _AppearancePage()),
      SettingsSearchEntry(
          AppL10n.t('settings_notifications'),
          AppL10n.t('Звуки, рингтон, вибрация'),
          Icons.notifications_outlined,
          () => const _NotificationsPage()),
      SettingsSearchEntry(
          AppL10n.t('settings_messaging'),
          AppL10n.t('Отправка, медиа, память, галерея'),
          Icons.chat_bubble_outline,
          () => const _MessagingPage()),
      SettingsSearchEntry(
          AppL10n.t('Панель ввода'),
          AppL10n.t('Порядок кнопок'),
          Icons.tune,
          () => const InputBarButtonOrderSettings()),
      SettingsSearchEntry(
          AppL10n.t('emoji_my_packs'),
          AppL10n.t('Свои :код: и анимированные эмодзи'),
          Icons.emoji_emotions_outlined,
          () => const EmojiHubScreen()),
      SettingsSearchEntry(
          AppL10n.t('settings_privacy'),
          AppL10n.t('Прочтение, статус онлайн'),
          Icons.lock_outline,
          () => const _PrivacyPage()),
      SettingsSearchEntry(
          AppL10n.t('Расшифровка'),
          AppL10n.t('Движок и модель'),
          Icons.record_voice_over_outlined,
          () => const _TranscriptionPage()),
      SettingsSearchEntry(
          AppL10n.t('settings_section_network'),
          AppL10n.t('BLE, интернет, ретранслятор'),
          Icons.wifi_tethering,
          () => const _NetworkPage()),
      SettingsSearchEntry(
          AppL10n.t('settings_data'),
          AppL10n.t('История, контакты, сброс'),
          Icons.storage_outlined,
          () => const SettingsDataPage()),
      SettingsSearchEntry(
          AppL10n.t('Профиль'),
          AppL10n.t('Имя, аватар, теги, музыка'),
          Icons.person_outline,
          () => const _ProfilePage()),
    ];
