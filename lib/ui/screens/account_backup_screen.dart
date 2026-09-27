import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_l10n.dart';
import '../../main.dart' show navigatorKey;
import '../../services/account_transfer_service.dart';
import '../../services/app_settings.dart';
import '../../services/ble_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/profile_service.dart';
import '../../services/relay_service.dart';
import '../../services/rlink_deep_link_service.dart';
import '../../services/runtime_platform.dart';
import '../../services/web_identity_portable.dart';
import '../../utils/web_file_store.dart';
import 'chat_list_screen.dart';

/// Файловый перенос аккаунта — офлайн-сосед живого переноса
/// ([AccountTransferService.requestTransfer]): человек сам решает, куда
/// положить зашифрованный файл (телефон/облако), и загружает его на новом
/// устройстве самостоятельно, без одновременного онлайна старого устройства.
String _backupFileName() {
  final now = DateTime.now();
  String p2(int n) => n.toString().padLeft(2, '0');
  return 'rlink_backup_${now.year}${p2(now.month)}${p2(now.day)}_'
      '${p2(now.hour)}${p2(now.minute)}.rlinkbackup';
}

/// Экспорт: задать пароль и получить файл (сохранить/поделиться).
class AccountBackupExportScreen extends StatefulWidget {
  const AccountBackupExportScreen({super.key});

  @override
  State<AccountBackupExportScreen> createState() => _AccountBackupExportScreenState();
}

class _AccountBackupExportScreenState extends State<AccountBackupExportScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final pass = _password.text;
    if (pass.length < 6) {
      setState(() => _error = AppL10n.t('Пароль должен быть не короче 6 символов'));
      return;
    }
    if (pass != _confirm.text) {
      setState(() => _error = AppL10n.t('Пароли не совпадают'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await AccountTransferService.instance.exportAccountToFile(password: pass);
      await _saveOrShare(bytes);
    } catch (e) {
      if (mounted) setState(() => _error = AppL10n.f('Не удалось создать файл: {0}', [e]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveOrShare(Uint8List bytes) async {
    final fileName = _backupFileName();
    if (RuntimePlatform.isWeb) {
      final stored = await writeWebStoredFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/octet-stream',
      );
      if (stored != null) {
        await downloadWebFile(stored, fileName: fileName, mimeType: 'application/octet-stream');
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    // The share sheet is the cross-platform way to offer BOTH "save to
    // Files/Downloads" and "save to a cloud drive" without this app needing
    // its own upload integration for every provider.
    await Share.shareXFiles([XFile(file.path, name: fileName)],
        subject: AppL10n.t('Резервная копия аккаунта Rlink'));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.t('Перенос по файлу'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  AppL10n.t('Файл содержит ключ вашего аккаунта — тот, кто получит файл '
                      'И пароль, сможет войти как вы. Придумайте пароль, который не '
                      'использовали больше нигде, и храните файл отдельно от него '
                      '(например, файл — в облаке, пароль — в голове).'),
                  style: TextStyle(fontSize: 13, color: cs.onSurface),
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _password,
                obscureText: _obscure,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: AppL10n.t('Пароль для файла'),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirm,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: AppL10n.t('Повторите пароль'),
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _busy ? null : _export(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
              ],
              const SizedBox(height: 20),
              Text(
                AppL10n.t('Забытый пароль восстановить нельзя — файл станет бесполезен.'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _busy ? null : _export,
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(AppL10n.t('Создать файл переноса')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Импорт: выбрать файл, ввести пароль, восстановить личность и данные.
class AccountBackupImportScreen extends StatefulWidget {
  const AccountBackupImportScreen({super.key});

  @override
  State<AccountBackupImportScreen> createState() => _AccountBackupImportScreenState();
}

class _AccountBackupImportScreenState extends State<AccountBackupImportScreen> {
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  String? _fileName;
  Uint8List? _fileBytes;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['rlinkbackup'],
      allowMultiple: false,
      withData: true,
    );
    final f = picked?.files.firstOrNull;
    if (f?.bytes == null) return;
    setState(() {
      _fileName = f!.name;
      _fileBytes = f.bytes;
      _error = null;
    });
  }

  Future<void> _restore() async {
    final bytes = _fileBytes;
    if (bytes == null) {
      setState(() => _error = AppL10n.t('Сначала выберите файл'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await AccountTransferService.instance
          .importAccountFromFile(fileBytes: bytes, password: _password.text);
      if (!mounted) return;
      if (!result.ok) {
        setState(() => _error = result.error == AccountFileRestoreError.badFile
            ? AppL10n.t('Это не похоже на файл переноса Rlink')
            : AppL10n.t('Неверный пароль, либо файл повреждён'));
        return;
      }
      if (result.alreadyUsedBefore) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(AppL10n.t('Этот файл уже открывали раньше')),
            content: Text(AppL10n.f(
                'Файл переноса уже был использован ({0}). Если это точно были вы — '
                'всё в порядке. Если нет — кто-то ещё мог увидеть этот файл; '
                'смените пароль от него и никому больше не давайте.',
                [result.alreadyUsedAt ?? '?'])),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(AppL10n.t('Понятно')),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
      await _afterRestore();
    } catch (e) {
      if (mounted) setState(() => _error = AppL10n.f('Не удалось восстановить: {0}', [e]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Same post-adopt sequence as the live transfer's `_onIdentityAdopted` in
  /// onboarding_screen.dart (network transports don't know about the new key
  /// until told) — duplicated rather than shared, since that method is
  /// private state tied to the OTHER screen's restore-request flow.
  Future<void> _afterRestore() async {
    final profile = ProfileService.instance.profile;
    if (profile == null || !mounted) return;
    unawaited(WebIdentityPortable.syncIdentitySnapshotToOpfs());
    if (AppSettings.instance.connectionMode != 1) {
      try {
        await BleService.instance.start();
      } catch (_) {}
    }
    if (AppSettings.instance.connectionMode >= 1) {
      try {
        RelayService.instance.reconnect();
      } catch (_) {}
    }
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
    } catch (_) {}
    unawaited(RlinkDeepLinkService.instance.start(navigatorKey));
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ChatListScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.t('Восстановление из файла'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.upload_file_rounded),
                label: Text(_fileName ?? AppL10n.t('Выбрать файл переноса')),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: AppL10n.t('Пароль от файла'),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onSubmitted: (_) => _busy ? null : _restore(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  AppL10n.t('Текущий аккаунт на этом устройстве (если есть) будет заменён.'),
                  style: TextStyle(color: Colors.red.shade300, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _busy ? null : _restore,
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(AppL10n.t('Восстановить')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
