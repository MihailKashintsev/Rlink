import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-field profile visibility. Each field can be shown to peers or kept
/// private. Enforcement happens at every outgoing chokepoint (profile gossip,
/// direct profile packets, avatar/banner/music blobs, stories) so a hidden
/// field simply never leaves the device.
///
/// Note on the mesh: the profile packet floods to whoever is reachable, so the
/// only meaningful control is show/hide (not "contacts only"). Status emoji and
/// birthday additionally retract on the next broadcast (they're sent as an
/// explicit empty), which the receiver honours; avatar/banner/music/stories
/// stop being shared going forward but a copy already delivered isn't pulled
/// back.
enum ProfileField { avatar, banner, statusEmoji, tags, birthday, music, stories }

class ProfilePrivacyService extends ChangeNotifier {
  ProfilePrivacyService._();
  static final ProfilePrivacyService instance = ProfilePrivacyService._();

  static const _prefix = 'profile_priv_';

  final Map<ProfileField, bool> _visible = {
    for (final f in ProfileField.values) f: true,
  };

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final f in ProfileField.values) {
        _visible[f] = p.getBool('$_prefix${f.name}') ?? true;
      }
    } catch (_) {}
    notifyListeners();
  }

  bool isVisible(ProfileField f) => _visible[f] ?? true;

  bool get showAvatar => isVisible(ProfileField.avatar);
  bool get showBanner => isVisible(ProfileField.banner);
  bool get showStatusEmoji => isVisible(ProfileField.statusEmoji);
  bool get showTags => isVisible(ProfileField.tags);
  bool get showBirthday => isVisible(ProfileField.birthday);
  bool get showMusic => isVisible(ProfileField.music);
  bool get showStories => isVisible(ProfileField.stories);

  Future<void> setVisible(ProfileField f, bool value) async {
    if (_visible[f] == value) return;
    _visible[f] = value;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('$_prefix${f.name}', value);
    } catch (_) {}
  }
}
