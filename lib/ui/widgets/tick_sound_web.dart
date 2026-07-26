
import 'package:web/web.dart' as web;

web.AudioContext? _ctx;

/// Web tick: a very short WebAudio blip. SystemSound.play is a no-op on web,
/// so the drum would be silent otherwise. Cheap enough to fire per detent.
void playTick() {
  try {
    final ctx = _ctx ??= web.AudioContext();
    final now = ctx.currentTime;
    final osc = ctx.createOscillator();
    final gain = ctx.createGain();
    osc.type = 'square';
    osc.frequency.value = 1500;
    gain.gain.value = 0.0001;
    gain.gain.setValueAtTime(0.05, now);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.025);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start();
    osc.stop(now + 0.03);
  } catch (_) {}
}
