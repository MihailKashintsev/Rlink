import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'app_settings.dart';
import 'runtime_platform.dart';
import '../utils/web_file_store.dart';

enum ActionSound {
  messageSent,
  messageReceived,
  callConnected,
}

/// In-call reaction sounds (Google Meet-style). Synthesized, not sampled —
/// same reasoning as the rest of this file (no bundled audio assets, works
/// identically on every platform). A synthesizer can't reproduce a real fart,
/// laugh or crowd honestly; these are cartoon approximations built from noise
/// and oscillators, good enough to read as the intended joke, not as audio
/// realism.
enum CallFxSound {
  fart('💨', 'Пук'),
  laugh('😂', 'Смех'),
  applause('👏', 'Аплодисменты'),
  bee('🐝', 'Пчела');

  final String emoji;
  final String label;
  const CallFxSound(this.emoji, this.label);
}

enum AppSoundSlot {
  incomingCall('incoming_call', 'Входящий звонок'),
  outgoingCall('outgoing_call', 'Исходящий вызов'),
  callConnected('call_connected', 'Соединение установлено'),
  messageSent('message_sent', 'Сообщение отправлено'),
  messageReceived('message_received', 'Сообщение получено'),
  notification('notification', 'Уведомление');

  final String id;
  final String label;
  const AppSoundSlot(this.id, this.label);
}

class SoundEffectsService {
  SoundEffectsService._();
  static final SoundEffectsService instance = SoundEffectsService._();

  final AudioPlayer _effectsPlayer = AudioPlayer(playerId: 'rlink_fx');
  final AudioPlayer _ringtonePlayer = AudioPlayer(playerId: 'rlink_ringtone');
  final AudioPlayer _outgoingCallPlayer =
      AudioPlayer(playerId: 'rlink_outgoing_call');
  // Dedicated low-latency player for the picker "tick" — it fires many times a
  // second on a fast spin, so it must not fight the effect player.
  final AudioPlayer _tickPlayer = AudioPlayer(playerId: 'rlink_tick');
  final AudioPlayer _callFxPlayer = AudioPlayer(playerId: 'rlink_call_fx');
  Uint8List? _tickBytes;
  int _lastTickMs = 0;
  final Map<CallFxSound, Uint8List> _callFxCache = {};

  bool get _enabled => AppSettings.instance.notifSound;
  bool get _supportedPlatform =>
      RuntimePlatform.isAndroid ||
      RuntimePlatform.isIos ||
      RuntimePlatform.isDesktop ||
      RuntimePlatform.isWeb;

  /// Short click for the spinning date/time picker (native side; web uses
  /// WebAudio). Throttled so a hard flick doesn't queue hundreds of plays.
  Future<void> playTick() async {
    if (!_enabled || !_supportedPlatform) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTickMs < 45) return;
    _lastTickMs = now;
    try {
      _tickBytes ??= _buildToneBytes(
        notes: const [1500],
        stepMs: 12,
        sampleRate: 16000,
        amplitude: 0.28,
      );
      await _tickPlayer.stop();
      await _tickPlayer.play(BytesSource(_tickBytes!), volume: 1);
    } catch (_) {}
  }

  Future<void> playAction(ActionSound sound) async {
    if (!_enabled || !_supportedPlatform) return;
    try {
      final slot = switch (sound) {
        ActionSound.messageSent => AppSoundSlot.messageSent,
        ActionSound.messageReceived => AppSoundSlot.messageReceived,
        ActionSound.callConnected => AppSoundSlot.callConnected,
      };
      final bytes = switch (sound) {
        ActionSound.messageSent => defaultSoundBytes(AppSoundSlot.messageSent),
        ActionSound.messageReceived =>
          defaultSoundBytes(AppSoundSlot.messageReceived),
        ActionSound.callConnected =>
          defaultSoundBytes(AppSoundSlot.callConnected),
      };
      await _playSlotOnce(slot, bytes, _effectsPlayer);
    } catch (e) {
      debugPrint('[RLINK][Sound] playAction failed: $e');
    }
  }

  Future<void> playPushNotificationSound() async {
    if (!_enabled || !_supportedPlatform) return;
    try {
      await _playSlotOnce(
        AppSoundSlot.notification,
        defaultSoundBytes(AppSoundSlot.notification),
        _effectsPlayer,
      );
    } catch (e) {
      debugPrint('[RLINK][Sound] playPushNotificationSound failed: $e');
    }
  }

  Future<void> startIncomingRingtone() async {
    if (!_enabled || !_supportedPlatform) return;
    try {
      await _ringtonePlayer.stop();
      await _ringtonePlayer.setReleaseMode(ReleaseMode.loop);
      await _playSlotLoop(
        AppSoundSlot.incomingCall,
        _buildRingtonePresetBytes(AppSettings.instance.callRingtone),
        _ringtonePlayer,
      );
    } catch (e) {
      debugPrint('[RLINK][Sound] startIncomingRingtone failed: $e');
    }
  }

  Future<void> stopIncomingRingtone() async {
    try {
      await _ringtonePlayer.stop();
    } catch (_) {}
  }

  Future<void> startOutgoingCallTone() async {
    if (!_enabled || !_supportedPlatform) return;
    try {
      await _outgoingCallPlayer.stop();
      await _outgoingCallPlayer.setReleaseMode(ReleaseMode.loop);
      await _playSlotLoop(
        AppSoundSlot.outgoingCall,
        defaultSoundBytes(AppSoundSlot.outgoingCall),
        _outgoingCallPlayer,
      );
    } catch (e) {
      debugPrint('[RLINK][Sound] startOutgoingCallTone failed: $e');
    }
  }

  Future<void> stopOutgoingCallTone() async {
    try {
      await _outgoingCallPlayer.stop();
    } catch (_) {}
  }

  /// Plays a call reaction sound locally. [CallService] is responsible for
  /// also signalling the peer so both sides hear it — this only handles the
  /// audio, same split as [playAction]/[startIncomingRingtone].
  Future<void> playCallFx(CallFxSound fx) async {
    if (!_enabled || !_supportedPlatform) return;
    try {
      final bytes = _callFxCache.putIfAbsent(fx, () => _callFxBytes(fx));
      await _callFxPlayer.stop();
      await _callFxPlayer.setReleaseMode(ReleaseMode.stop);
      await _callFxPlayer.play(BytesSource(bytes), volume: 1);
    } catch (e) {
      debugPrint('[RLINK][Sound] playCallFx failed: $e');
    }
  }

  static Uint8List defaultSoundBytes(AppSoundSlot slot) {
    final bayan = AppSettings.instance.soundTheme == 1;
    switch (slot) {
      case AppSoundSlot.incomingCall:
        return _buildRingtonePresetBytes(AppSettings.instance.callRingtone,
            bayan: bayan);
      case AppSoundSlot.outgoingCall:
        return _buildToneBytes(
          notes: const [440, 0, 440, 0],
          stepMs: 260,
          pauseAfterMs: 720,
          sampleRate: 16000,
          amplitude: 0.22,
          bayan: bayan,
        );
      case AppSoundSlot.callConnected:
        return _buildToneBytes(
          notes: const [660, 880, 660],
          stepMs: 80,
          sampleRate: 16000,
          amplitude: 0.22,
          bayan: bayan,
        );
      case AppSoundSlot.messageSent:
        return _buildToneBytes(
          notes: const [1200],
          stepMs: 70,
          sampleRate: 16000,
          amplitude: 0.20,
          bayan: bayan,
        );
      case AppSoundSlot.messageReceived:
        return _buildToneBytes(
          notes: const [740, 990],
          stepMs: 95,
          sampleRate: 16000,
          amplitude: 0.23,
          bayan: bayan,
        );
      case AppSoundSlot.notification:
        return _buildToneBytes(
          notes: const [820, 1240, 820],
          stepMs: 110,
          sampleRate: 16000,
          amplitude: 0.26,
          bayan: bayan,
        );
    }
  }

  static Uint8List _buildRingtonePresetBytes(int preset, {bool bayan = false}) {
    switch (preset.clamp(0, 2)) {
      case 1:
        return _buildToneBytes(
          notes: const [520, 620, 780, 620],
          stepMs: 170,
          pauseAfterMs: 260,
          sampleRate: 16000,
          amplitude: 0.26,
          bayan: bayan,
        );
      case 2:
        return _buildToneBytes(
          notes: const [420, 420, 560],
          stepMs: 210,
          pauseAfterMs: 300,
          sampleRate: 16000,
          amplitude: 0.22,
          bayan: bayan,
        );
      case 0:
      default:
        return _buildToneBytes(
          notes: const [660, 880],
          stepMs: 230,
          pauseAfterMs: 320,
          sampleRate: 16000,
          amplitude: 0.28,
          bayan: bayan,
        );
    }
  }

  /// Additive-harmonic mix that stands in for a reed timbre — fundamental
  /// plus falling-amplitude overtones, the same principle any reed/brass
  /// physical-modelling synth starts from. A bare sine can only ever sound
  /// like a beep; this is what makes "бая́н" mode sound like an instrument
  /// playing the same melody instead of the same beeps with more steps.
  static const _bayanHarmonics = [
    (mul: 1.0, amp: 1.00),
    (mul: 2.0, amp: 0.48),
    (mul: 3.0, amp: 0.27),
    (mul: 4.0, amp: 0.14),
  ];

  static double _waveAt(double t, int freq, {required bool bayan}) {
    if (!bayan) return math.sin(2 * math.pi * freq * t);
    var v = 0.0;
    for (final h in _bayanHarmonics) {
      v += math.sin(2 * math.pi * freq * h.mul * t) * h.amp;
    }
    // Musette tremolo: real accordions detune two reed banks a few cents
    // apart, which beats into a slow amplitude wobble — the single most
    // recognizable trait of the timbre. ~5.5 Hz, shallow enough not to sound
    // like vibrato-effect processing.
    final tremolo = 1.0 + 0.16 * math.sin(2 * math.pi * 5.5 * t);
    return v * tremolo / 1.89; // 1.89 = sum of harmonic amps, keeps peak ~1
  }

  static Uint8List _buildToneBytes({
    required List<int> notes,
    required int stepMs,
    int pauseAfterMs = 0,
    int sampleRate = 16000,
    double amplitude = 0.25,
    bool bayan = false,
  }) {
    final pcm = BytesBuilder();
    final totalSteps = <int>[...notes];
    final maxAmp = (32767 * amplitude).round().clamp(0, 32767);
    for (final freq in totalSteps) {
      final samples = ((stepMs / 1000) * sampleRate).round();
      for (var i = 0; i < samples; i++) {
        if (freq <= 0) {
          pcm.addByte(0);
          pcm.addByte(0);
          continue;
        }
        final t = i / sampleRate;
        final fadeIn = i < 80 ? i / 80 : 1.0;
        final fadeOut =
            i > samples - 100 ? ((samples - i).clamp(0, 100)) / 100.0 : 1.0;
        final env = fadeIn * fadeOut;
        final val =
            (_waveAt(t, freq, bayan: bayan) * maxAmp * env).round();
        pcm.addByte(val & 0xff);
        pcm.addByte((val >> 8) & 0xff);
      }
    }
    if (pauseAfterMs > 0) {
      final pauseSamples = ((pauseAfterMs / 1000) * sampleRate).round();
      for (var i = 0; i < pauseSamples; i++) {
        pcm.addByte(0);
        pcm.addByte(0);
      }
    }
    return _wrapPcm16MonoWav(
      pcm.toBytes(),
      sampleRate: sampleRate,
    );
  }

  static final _fxRandom = math.Random();

  /// Writes [totalSamples] of mono 16-bit PCM from a per-sample generator
  /// returning roughly -1..1, then wraps it as a WAV — the shared plumbing
  /// under all four call-FX sounds below.
  static Uint8List _pcm16(
      int totalSamples, int sampleRate, double Function(int i) gen) {
    final pcm = BytesBuilder();
    for (var i = 0; i < totalSamples; i++) {
      final val = (gen(i) * 32000).round().clamp(-32768, 32767);
      pcm.addByte(val & 0xff);
      pcm.addByte((val >> 8) & 0xff);
    }
    return _wrapPcm16MonoWav(pcm.toBytes(), sampleRate: sampleRate);
  }

  /// Sawtooth-ish buzz via a falling-harmonic series (amp ~ 1/n, first 5
  /// partials) — a plain sine reads as a whistle, not an insect.
  static double _buzzWave(double t, double freq) {
    var v = 0.0;
    for (var n = 1; n <= 5; n++) {
      v += math.sin(2 * math.pi * freq * n * t) / n;
    }
    return v / 1.79; // normalize (sum of 1/n for n=1..5), peak ~1
  }

  static Uint8List _callFxBytes(CallFxSound fx) {
    const sr = 16000;
    switch (fx) {
      case CallFxSound.bee:
        // Buzzy sawtooth around 210 Hz with a fast ~28 Hz amplitude wobble —
        // the wingbeat-rate wobble is what reads as "insect" rather than
        // "kazoo". A slow pitch drift keeps it from sounding like a pure loop.
        final dur = (0.9 * sr).round();
        return _pcm16(dur, sr, (i) {
          final t = i / sr;
          final env = math.min(1.0, i / 400) * math.min(1.0, (dur - i) / 800);
          final freq = 210 + 12 * math.sin(2 * math.pi * 0.8 * t);
          final wobble = 1.0 + 0.35 * math.sin(2 * math.pi * 28 * t);
          return _buzzWave(t, freq) * wobble * env * 0.5;
        });
      case CallFxSound.fart:
        // Classic "raspberry": a low buzzy tone with a fast downward pitch
        // slide plus a little noise for rasp. Sound design, not physics.
        final dur = (0.55 * sr).round();
        return _pcm16(dur, sr, (i) {
          final t = i / sr;
          final progress = i / dur;
          final freq = 150 - 85 * progress; // 150 Hz -> 65 Hz slide
          final env = math.min(1.0, i / 200) * (1.0 - progress * 0.15);
          final tone = _buzzWave(t, freq);
          final noise = (_fxRandom.nextDouble() * 2 - 1) * 0.18;
          return (tone * 0.85 + noise) * env * 0.55;
        });
      case CallFxSound.applause:
        // Gated white noise: real applause is broadband with no clear pitch,
        // and a crowd is many independent random claps — random-length,
        // random-amplitude noise bursts is the standard cheap approximation
        // (the same trick old arcade sound chips used).
        final dur = (1.4 * sr).round();
        return _pcm16(dur, sr, (i) {
          final t = i / dur;
          // Swells in over the first third, holds, fades over the last third.
          final swell = t < 0.3 ? t / 0.3 : (t > 0.75 ? (1 - t) / 0.25 : 1.0);
          // ~65% duty-cycle gate at ~35 Hz reads as a dense crowd of claps
          // rather than a single hiss.
          final gate =
              (math.sin(2 * math.pi * 35 * (i / sr)) > -0.3) ? 1.0 : 0.0;
          final noise = (_fxRandom.nextDouble() * 2 - 1);
          return noise * gate * swell.clamp(0.0, 1.0) * 0.5;
        });
      case CallFxSound.laugh:
        // 4 short "ha" bursts: fundamental + a strong 3rd partial (vowel-ish),
        // each with a quick pitch rise-then-fall. Reads as a cartoon laugh,
        // not a recording of one — real laughter has formant structure this
        // simple a model can't reach.
        const burstMs = [130, 120, 120, 160];
        const burstBaseHz = [300.0, 330.0, 320.0, 280.0];
        const gapMs = 55;
        final segments = <({int samples, double baseHz})>[
          for (var k = 0; k < burstMs.length; k++)
            (samples: (burstMs[k] / 1000 * sr).round(), baseHz: burstBaseHz[k]),
        ];
        final gapSamples = (gapMs / 1000 * sr).round();
        final total = segments.fold<int>(0, (a, s) => a + s.samples) +
            gapSamples * (segments.length - 1);
        return _pcm16(total, sr, (i) {
          var offset = 0;
          for (var k = 0; k < segments.length; k++) {
            final seg = segments[k];
            if (i < offset + seg.samples) {
              final li = i - offset;
              final t = li / sr;
              final p = li / seg.samples; // 0..1 within this burst
              final pitchArc = 1.0 + 0.12 * math.sin(math.pi * p); // rise/fall
              final freq = seg.baseHz * pitchArc;
              final env = math.sin(math.pi * p).clamp(0.0, 1.0); // smooth in/out
              final wave = math.sin(2 * math.pi * freq * t) +
                  0.4 * math.sin(2 * math.pi * freq * 3 * t);
              return wave * env * 0.4;
            }
            offset += seg.samples;
            if (k < segments.length - 1) {
              if (i < offset + gapSamples) return 0.0;
              offset += gapSamples;
            }
          }
          return 0.0;
        });
    }
  }

  @visibleForTesting
  static Uint8List callFxBytesForTest(CallFxSound fx) => _callFxBytes(fx);

  @visibleForTesting
  static Uint8List toneBytesForTest({
    required List<int> notes,
    required int stepMs,
    bool bayan = false,
  }) =>
      _buildToneBytes(notes: notes, stepMs: stepMs, bayan: bayan);

  Future<void> previewSlot(AppSoundSlot slot) async {
    if (!_supportedPlatform) return;
    try {
      await _playSlotOnce(slot, defaultSoundBytes(slot), _effectsPlayer);
    } catch (e) {
      debugPrint('[RLINK][Sound] previewSlot failed: $e');
    }
  }

  Future<void> _playSlotOnce(
    AppSoundSlot slot,
    Uint8List fallbackBytes,
    AudioPlayer player,
  ) async {
    await player.stop();
    await player.setReleaseMode(ReleaseMode.stop);
    await _playSlot(slot, fallbackBytes, player);
  }

  Future<void> _playSlotLoop(
    AppSoundSlot slot,
    Uint8List fallbackBytes,
    AudioPlayer player,
  ) async {
    await player.setReleaseMode(ReleaseMode.loop);
    await _playSlot(slot, fallbackBytes, player);
  }

  Future<void> _playSlot(
    AppSoundSlot slot,
    Uint8List fallbackBytes,
    AudioPlayer player,
  ) async {
    final custom = AppSettings.instance.customSoundPath(slot.id);
    if (custom != null) {
      if (!kIsWeb && File(custom).existsSync()) {
        await player.play(DeviceFileSource(custom), volume: 1);
        return;
      }
      final customBytes = await _customSoundBytes(custom);
      if (customBytes != null && customBytes.isNotEmpty) {
        await player.play(BytesSource(customBytes), volume: 1);
        return;
      }
    }
    await player.play(BytesSource(fallbackBytes), volume: 1);
  }

  Future<Uint8List?> _customSoundBytes(String ref) async {
    if (ref.startsWith('opfs://rlink/')) {
      return readWebStoredFile(ref);
    }
    if (ref.startsWith('data:')) {
      final comma = ref.indexOf(',');
      if (comma < 0) return null;
      try {
        return base64Decode(ref.substring(comma + 1));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Uint8List _wrapPcm16MonoWav(
    Uint8List pcm, {
    required int sampleRate,
  }) {
    final byteRate = sampleRate * 2;
    const blockAlign = 2;
    final dataSize = pcm.length;
    final fileSize = 36 + dataSize;
    final out = BytesBuilder();
    void addAscii(String s) => out.add(s.codeUnits);
    void addU32(int v) {
      out.addByte(v & 0xff);
      out.addByte((v >> 8) & 0xff);
      out.addByte((v >> 16) & 0xff);
      out.addByte((v >> 24) & 0xff);
    }

    void addU16(int v) {
      out.addByte(v & 0xff);
      out.addByte((v >> 8) & 0xff);
    }

    addAscii('RIFF');
    addU32(fileSize);
    addAscii('WAVE');
    addAscii('fmt ');
    addU32(16);
    addU16(1);
    addU16(1);
    addU32(sampleRate);
    addU32(byteRate);
    addU16(blockAlign);
    addU16(16);
    addAscii('data');
    addU32(dataSize);
    out.add(pcm);
    return out.toBytes();
  }
}
