import 'package:flutter/services.dart';

import '../../services/sound_effects_service.dart';

/// Native tick: haptic (always, so it's felt even with sound off) + a short
/// click via the audio service. SystemSound.play was inaudible on Android and
/// the haptic needs the VIBRATE permission (added to the manifest).
void playTick() {
  HapticFeedback.selectionClick();
  SoundEffectsService.instance.playTick();
}
