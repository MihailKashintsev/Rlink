import 'package:flutter/services.dart';

/// Native tick: a haptic bump plus the OS click. On web this file isn't used.
void playTick() {
  HapticFeedback.selectionClick();
  SystemSound.play(SystemSoundType.click);
}
