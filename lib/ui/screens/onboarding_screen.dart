import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/user_profile.dart';
import '../../services/account_transfer_service.dart';
import '../../services/app_settings.dart';
import '../../services/ble_service.dart';
import '../../services/channel_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/device_link_sync_service.dart';
import '../../services/gossip_router.dart';
import '../../services/group_service.dart';
import '../../services/image_service.dart';
import '../../services/profile_service.dart';
import '../../services/relay_service.dart';
import '../../services/runtime_platform.dart';
import '../../services/web_identity_portable.dart';
import '../widgets/avatar_widget.dart';
import '../../main.dart' show navigatorKey;
import '../../services/rlink_deep_link_service.dart';
import 'chat_list_screen.dart';
import '../../l10n/app_l10n.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _nickController     = TextEditingController();
  final _usernameController = TextEditingController();
  final _usernameFocus      = FocusNode();

  int     _selectedColor = UserProfile.avatarColors[0];
  String  _selectedEmoji = UserProfile.avatarEmojis[0];
  String? _selectedImagePath;
  bool    _loading         = false;
  bool    _showEmojiPicker = false;

  final _picker = ImagePicker();

  static const _maxNickLength     = 20;
  static const _maxUsernameLength = 20;

  // ── Restore existing account (account transfer) ──────────────────
  bool _restoreMode = false;
  bool _restoreRequested = false;
  final _restoreIdController = TextEditingController();
  static final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  void _enterRestoreMode() {
    setState(() => _restoreMode = true);
  }

  Future<void> _sendRestoreRequest() async {
    final id = _restoreIdController.text.trim().toLowerCase();
    if (!_hex64.hasMatch(id)) {
      _showSnack(AppL10n.t('ID должен быть 64 hex-символа'));
      return;
    }
    AccountTransferService.instance.adoptedIdentityLive.addListener(_onIdentityAdopted);
    setState(() => _restoreRequested = true);
    await AccountTransferService.instance.requestTransfer(id);
  }

  Future<void> _onIdentityAdopted() async {
    if (!AccountTransferService.instance.adoptedIdentityLive.value) return;
    AccountTransferService.instance.adoptedIdentityLive.removeListener(_onIdentityAdopted);
    final profile = ProfileService.instance.profile;
    if (profile == null || !mounted) return;
    unawaited(WebIdentityPortable.syncIdentitySnapshotToOpfs());
    await _restartTransports(profile);
    unawaited(RlinkDeepLinkService.instance.start(navigatorKey));
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ChatListScreen()),
      );
    }
  }


  // ── Validation ────────────────────────────────────────────────

  String get _initials {
    final text = _nickController.text.trim();
    if (text.isEmpty) return '?';
    final parts = text.split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return text[0].toUpperCase();
  }

  /// null = valid, otherwise error message
  String? get _usernameError {
    final u = _usernameController.text.trim();
    if (u.isEmpty) return null;
    if (u.length < 3) return AppL10n.t('Минимум 3 символа');
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(u)) {
      return AppL10n.t('Только буквы, цифры и _');
    }
    return null;
  }

  Future<void> _pickImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    final path = await ImageService.instance.compressAndSave(
      picked.path,
      isAvatar: true,
    );
    setState(() => _selectedImagePath = path);
  }

  Future<void> _create() async {
    final nick     = _nickController.text.trim();
    var username = _usernameController.text.trim().toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9_.]'), '');

    if (nick.length < 2) {
      _showSnack(AppL10n.t('Имя должно быть не короче 2 символов'));
      return;
    }
    if (nick.length > _maxNickLength) {
      _showSnack(AppL10n.f('Имя не должно превышать {0} символов', [_maxNickLength]));
      return;
    }
    if (_usernameError != null) {
      _showSnack(_usernameError!);
      return;
    }
    if (username.length < 3) {
      final k = CryptoService.instance.publicKeyHex;
      username = 'user_${k.length >= 10 ? k.substring(0, 10) : k}';
    }

    setState(() => _loading = true);
    try {
      if (!RuntimePlatform.isWeb) {
        await _ensureCoreDatabasesInitialized();
      }
      await ProfileService.instance.createProfile(
        publicKeyHex: CryptoService.instance.publicKeyHex,
        nickname: nick,
      );
      await ProfileService.instance.updateProfile(
        nickname: nick,
        username: username,
        avatarColor: _selectedColor,
        avatarEmoji: _selectedEmoji,
        setAvatarImagePath: true,
        avatarImagePath: _selectedImagePath,
      );
      unawaited(WebIdentityPortable.syncIdentitySnapshotToOpfs());
      // Restart transports with new identity.
      // BLE was stopped during reset — start() restores it.
      // Relay needs to reconnect so the server registers the new public key.
      // For first-launch (BLE already running) start() is a no-op;
      // relay reconnect is harmless if already connected.
      unawaited(_restartTransports(ProfileService.instance.profile!));
      unawaited(RlinkDeepLinkService.instance.start(navigatorKey));

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ChatListScreen()),
        );
      }
    } catch (e) {
      if (mounted) _showSnack(AppL10n.f('Ошибка регистрации: {0}', [e]), isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red : null,
    ));
  }


  Future<void> _ensureCoreDatabasesInitialized() async {
    if (RuntimePlatform.isWeb) return;
    await ChatStorageService.instance.init();
    await ChannelService.instance.init();
    await GroupService.instance.init();
  }

  /// Restart BLE + relay after profile creation so both transports use the
  /// new identity immediately — without requiring an app restart.
  Future<void> _restartTransports(UserProfile profile) async {
    // BLE: start() is safe to call even if already running.
    // After a full reset, BLE was stopped — this restores it.
    if (AppSettings.instance.connectionMode != 1) {
      try { await BleService.instance.start(); } catch (e) {
        debugPrint('[Onboarding] BLE start error: $e');
      }
    }
    // Relay: reconnect so the server registers our new public key.
    if (AppSettings.instance.connectionMode >= 1) {
      try { RelayService.instance.reconnect(); } catch (e) {
        debugPrint('[Onboarding] Relay reconnect error: $e');
      }
    }
    // Broadcast our profile over gossip so any already-connected BLE peers
    // learn our new identity without waiting for the next connection cycle.
    try {
      await GossipRouter.instance.broadcastProfile(
        id: profile.publicKeyHex,
        nick: profile.nickname,
        username: profile.username,
        color: profile.avatarColor,
        emoji: profile.avatarEmoji,
        x25519Key: CryptoService.instance.x25519PublicKeyBase64,
        tags: profile.tags,
        statusEmoji: profile.statusEmoji,
      );
    } catch (e) {
      debugPrint('[Onboarding] Profile broadcast error: $e');
    }
  }

  @override
  void dispose() {
    _nickController.dispose();
    _usernameController.dispose();
    _usernameFocus.dispose();
    _restoreIdController.dispose();
    AccountTransferService.instance.adoptedIdentityLive.removeListener(_onIdentityAdopted);
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_restoreMode) return _buildRestoreView(cs);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 40),

              // ── Логотип ──────────────────────────────────────
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFF1DB954),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.bluetooth, color: Colors.white, size: 40),
              ),
              const SizedBox(height: 20),
              Text(
                'Rlink',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                AppL10n.t('Мессенджер без интернета через Bluetooth'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 36),

              // ── Аватар ───────────────────────────────────────
              Stack(
                children: [
                  GestureDetector(
                    onTap: () =>
                        setState(() => _showEmojiPicker = !_showEmojiPicker),
                    child: AnimatedBuilder(
                      animation: _nickController,
                      builder: (_, __) => AvatarWidget(
                        initials: _initials,
                        color: _selectedColor,
                        emoji: _selectedEmoji,
                        imagePath: _selectedImagePath,
                        size: 84,
                      ),
                    ),
                  ),
                  // Редактировать эмодзи
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _showEmojiPicker = !_showEmojiPicker),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1DB954),
                          shape: BoxShape.circle,
                          border: Border.all(color: cs.surface, width: 2),
                        ),
                        child: const Icon(Icons.edit, size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                  // Выбрать фото
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          shape: BoxShape.circle,
                          border: Border.all(color: cs.surface, width: 2),
                        ),
                        child: Icon(Icons.photo_camera,
                            size: 14, color: cs.onSurfaceVariant),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                AppL10n.t('Нажми на аватар чтобы выбрать эмодзи'),
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 16),

              // ── Выбор эмодзи ─────────────────────────────────
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: _showEmojiPicker
                    ? Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: AvatarEmojiPicker(
                          selected: _selectedEmoji,
                          onSelected: (e) => setState(() {
                            _selectedEmoji = e;
                            _showEmojiPicker = false;
                          }),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              if (!_showEmojiPicker) ...[
                const SizedBox(height: 16),

                // ── Цвет аватара ──────────────────────────────
                if (_selectedImagePath == null) ...[
                  AvatarColorPicker(
                    selected: _selectedColor,
                    onSelected: (c) => setState(() => _selectedColor = c),
                  ),
                  const SizedBox(height: 24),
                ],

                // ── Поле имени ────────────────────────────────
                TextField(
                  controller: _nickController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  textAlign: TextAlign.center,
                  maxLength: _maxNickLength,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText: AppL10n.t('Твоё имя'),
                    hintStyle: TextStyle(color: cs.onSurfaceVariant),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: isDark
                        ? const Color(0xFF1A1A1A)
                        : cs.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    counterStyle:
                        TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                  ),
                  onSubmitted: (_) => _usernameFocus.requestFocus(),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),

                // ── Поле юзернейма ────────────────────────────
                TextField(
                  controller: _usernameController,
                  focusNode: _usernameFocus,
                  textAlign: TextAlign.center,
                  maxLength: _maxUsernameLength,
                  // Only letters, digits, underscore
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
                  ],
                  style: TextStyle(
                    fontSize: 16,
                    color: cs.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText:
                        AppL10n.t('Юзернейм (мин. 3 символа; пусто — сгенерируем сами)'),
                    hintStyle: TextStyle(color: cs.onSurfaceVariant),
                    prefixIcon: Icon(Icons.alternate_email,
                        size: 20, color: cs.onSurfaceVariant),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: isDark
                        ? const Color(0xFF1A1A1A)
                        : cs.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    counterStyle:
                        TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                    errorText: _usernameController.text.isEmpty
                        ? null
                        : _usernameError,
                    errorStyle: const TextStyle(fontSize: 11),
                  ),
                  onSubmitted: (_) => _create(),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 20),

                // ── Кнопка ───────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _loading ? null : _create,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1DB954),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text(
                            AppL10n.t('Начать'),
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _loading ? null : _enterRestoreMode,
                  child: Text(
                    AppL10n.t('У меня уже есть аккаунт'),
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
                TextButton(
                  onPressed: _loading
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const _LinkAsChildScreen(),
                            ),
                          ),
                  child: Text(
                    AppL10n.t('Это дополнительное устройство'),
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              ],

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRestoreView(ColorScheme cs) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _restoreRequested
                        ? null
                        : () => setState(() => _restoreMode = false),
                  ),
                ],
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: _restoreRequested ? _restoreWaiting(cs) : _restoreForm(cs),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _restoreForm(ColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.swap_horiz_rounded, color: cs.primary, size: 48),
        const SizedBox(height: 16),
        Text(
          AppL10n.t('Перенос аккаунта'),
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: cs.onSurface),
        ),
        const SizedBox(height: 8),
        Text(
          AppL10n.t('Введите уникальный ID (64 hex-символа) своего аккаунта — его можно скопировать в Настройках на старом устройстве. Там нужно будет подтвердить перенос.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _restoreIdController,
          autofocus: true,
          maxLines: 2,
          style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: AppL10n.t('64-символьный ID'),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            filled: true,
            fillColor: cs.surfaceContainerHighest,
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            AppL10n.t('После подтверждения на старом устройстве оно будет очищено. Отменить перенос нельзя.'),
            style: TextStyle(color: Colors.red.shade300, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            onPressed: _sendRestoreRequest,
            child: Text(AppL10n.t('Отправить запрос'), style: TextStyle(fontSize: 16)),
          ),
        ),
      ],
    );
  }

  Widget _restoreWaiting(ColorScheme cs) {
    return ValueListenableBuilder<bool>(
      valueListenable: AccountTransferService.instance.wasDenied,
      builder: (_, denied, __) {
        if (denied) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.block, color: cs.error, size: 48),
              const SizedBox(height: 16),
              Text(AppL10n.t('Запрос отклонён'), style: TextStyle(fontSize: 18, color: cs.onSurface)),
              const SizedBox(height: 8),
              Text(
                AppL10n.t('Старое устройство не подтвердило перенос.'),
                style: TextStyle(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: () => setState(() {
                  _restoreRequested = false;
                  AccountTransferService.instance.wasDenied.value = false;
                }),
                child: Text(AppL10n.t('Попробовать снова')),
              ),
            ],
          );
        }
        return Column(
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
            Text(AppL10n.t('Ожидание подтверждения на старом устройстве…'),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            ValueListenableBuilder<TransferProgress?>(
              valueListenable: AccountTransferService.instance.progress,
              builder: (_, p, __) => Text(
                p?.phase ?? '',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Fresh, profile-less device's side of "link as a child device without
/// creating an account first": shows this device's own pubkey as a QR.
/// The primary device scans it (Настройки → RID → «Привязать дочернее
/// устройство» → «Сканировать QR») and sends a device_link request — which
/// this screen auto-accepts (see main.dart's onDeviceLinkRequest handler:
/// showing this QR at all is the consent) instead of going through the
/// normal in-chat approval card, which a profile-less device could never
/// reach anyway.
class _LinkAsChildScreen extends StatefulWidget {
  const _LinkAsChildScreen();

  @override
  State<_LinkAsChildScreen> createState() => _LinkAsChildScreenState();
}

class _LinkAsChildScreenState extends State<_LinkAsChildScreen> {
  bool _linked = false;

  @override
  void initState() {
    super.initState();
    DeviceLinkSyncService.instance.awaitingLinkAsChild.value = true;
    AppSettings.instance.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (!mounted || _linked) return;
    if (!AppSettings.instance.isLinkedChildDevice) return;
    setState(() => _linked = true);
    Future.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ChatListScreen()),
        (route) => false,
      );
    });
  }

  @override
  void dispose() {
    DeviceLinkSyncService.instance.awaitingLinkAsChild.value = false;
    AppSettings.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pubkey = CryptoService.instance.publicKeyHex;
    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.t('Дополнительное устройство'))),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _linked
                ? [
                    Icon(Icons.check_circle,
                        color: Colors.green.shade400, size: 64),
                    const SizedBox(height: 16),
                    Text(AppL10n.t('Привязано!'), textAlign: TextAlign.center),
                  ]
                : [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: QrImageView(
                        data: 'rlink://user/$pubkey',
                        size: 220,
                        padding: EdgeInsets.zero,
                        errorCorrectionLevel: QrErrorCorrectLevel.H,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      AppL10n.t('Отсканируйте этот код на основном устройстве:\nНастройки → RID → «Привязать дочернее устройство»'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    const CircularProgressIndicator(),
                  ],
          ),
        ),
      ),
    );
  }
}
