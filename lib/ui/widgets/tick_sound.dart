// Tiny "click" for the spinning picker. WebAudio on web (SystemSound is a
// no-op there), haptic + system click on native.
import 'tick_sound_io.dart' if (dart.library.js_interop) 'tick_sound_web.dart'
    as impl;

void playTick() => impl.playTick();
