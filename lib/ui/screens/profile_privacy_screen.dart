import 'package:flutter/material.dart';

import '../../main.dart'
    show
        broadcastMyAvatar,
        broadcastMyBanner,
        broadcastMyProfileMusic,
        sendProfileToAllContacts;
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/profile_privacy_service.dart';
import '../../services/profile_service.dart';

/// Per-field profile privacy: choose what leaves your device.
class ProfilePrivacyScreen extends StatefulWidget {
  const ProfilePrivacyScreen({super.key});

  @override
  State<ProfilePrivacyScreen> createState() => _ProfilePrivacyScreenState();
}

class _ProfilePrivacyScreenState extends State<ProfilePrivacyScreen> {
  final _priv = ProfilePrivacyService.instance;

  Future<void> _toggle(ProfileField f, bool value) async {
    await _priv.setVisible(f, value);
    if (mounted) setState(() {});
    // Re-share so peers pick up the change. Status emoji + birthday retract on
    // this broadcast; turning an asset back on re-sends it.
    final p = ProfileService.instance.profile;
    if (p != null) {
      GossipRouter.instance.broadcastProfile(
        id: p.publicKeyHex,
        nick: p.nickname,
        username: p.username,
        color: p.avatarColor,
        emoji: p.avatarEmoji,
        x25519Key: CryptoService.instance.x25519PublicKeyBase64,
        tags: p.tags,
        statusEmoji: p.statusEmoji,
        nickColor: p.nickColor,
        birthday: p.birthday,
      );
      sendProfileToAllContacts();
    }
    if (value) {
      switch (f) {
        case ProfileField.avatar:
          broadcastMyAvatar();
          break;
        case ProfileField.banner:
          broadcastMyBanner();
          break;
        case ProfileField.music:
          broadcastMyProfileMusic();
          break;
        default:
          break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Приватность профиля')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Выберите, что видят другие. Скрытое поле не покидает устройство. '
              'Статус и день рождения убираются у контактов при следующей '
              'синхронизации; уже полученные аватар/баннер остаются у них.',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
          _tile(ProfileField.avatar, 'Аватар', Icons.account_circle_outlined,
              _priv.showAvatar),
          _tile(ProfileField.banner, 'Баннер', Icons.panorama_outlined,
              _priv.showBanner),
          _tile(ProfileField.statusEmoji, 'Эмодзи статуса',
              Icons.emoji_emotions_outlined, _priv.showStatusEmoji),
          _tile(ProfileField.tags, 'Теги / интересы', Icons.tag_outlined,
              _priv.showTags),
          _tile(ProfileField.birthday, 'День рождения', Icons.cake_outlined,
              _priv.showBirthday),
          _tile(ProfileField.music, 'Музыка профиля', Icons.music_note_outlined,
              _priv.showMusic),
          _tile(ProfileField.stories, 'Истории', Icons.auto_stories_outlined,
              _priv.showStories),
        ],
      ),
    );
  }

  Widget _tile(ProfileField f, String label, IconData icon, bool value) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(label),
      subtitle: Text(value ? 'Видно' : 'Скрыто'),
      value: value,
      onChanged: (v) => _toggle(f, v),
    );
  }
}
