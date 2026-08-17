import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'app_settings.dart';
import 'runtime_platform.dart';
import '../utils/web_file_store.dart';

enum ActionSound {
  messageSent,
  messageReceived,
  callConnected,
}

/// In-call reaction sounds (Google Meet-style) — real bundled recordings
/// under assets/sounds/call_fx/, played via [SoundEffectsService.playCallFx].
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
  SoundEffectsService._() {
    // Fire-and-forget: by the time a user actually reaches a bayan-themed
    // sound (toggle a setting, get a call/message), this ~550KB asset has
    // almost always finished decoding. _waveAt falls back to synthesis for
    // the rare case it hasn't (or never does).
    unawaited(_loadAccordionSample());
  }
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

  static const _callFxAssetPath = {
    CallFxSound.fart: 'sounds/call_fx/fart.wav',
    CallFxSound.laugh: 'sounds/call_fx/laugh.wav',
    CallFxSound.applause: 'sounds/call_fx/applause.wav',
    CallFxSound.bee: 'sounds/call_fx/bee.wav',
  };

  @visibleForTesting
  static Map<CallFxSound, String> get callFxAssetPathsForTest =>
      _callFxAssetPath;

  /// Plays a call reaction sound locally. [CallService] is responsible for
  /// also signalling the peer so both sides hear it — this only handles the
  /// audio, same split as [playAction]/[startIncomingRingtone]. Real bundled
  /// recordings, not synthesized — a sine-wave synth can't sound like a
  /// laugh or a crowd no matter how it's shaped.
  Future<void> playCallFx(CallFxSound fx) async {
    if (!_enabled || !_supportedPlatform) return;
    try {
      await _callFxPlayer.stop();
      await _callFxPlayer.setReleaseMode(ReleaseMode.stop);
      await _callFxPlayer.play(AssetSource(_callFxAssetPath[fx]!), volume: 1);
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

  /// Shifts every bayan note down an octave from what the melody nominally
  /// asks for — the user's own call after hearing the first pass. Applied to
  /// both rendering paths (real sample and the harmonic fallback) so they
  /// stay pitch-consistent with each other. 0.5 = one octave down exactly;
  /// for a smaller drop use e.g. math.pow(2, -7/12) for a fifth.
  static const double _bayanPitchMultiplier = 0.5;

  static double _waveAt(double t, int freq, {required bool bayan}) {
    if (!bayan) return math.sin(2 * math.pi * freq * t);
    final target = freq * _bayanPitchMultiplier;
    final loop = _accordionLoop;
    if (loop != null && loop.isNotEmpty) {
      // Play the real note back faster/slower than it was recorded — the
      // standard cheap pitch-shift (changes both pitch and effective
      // playback rate together, which is why we loop rather than play once).
      final ratio = target / _accordionBaseFreq;
      final pos = (t * ratio * _accordionSampleRate) % loop.length;
      final i0 = pos.floor();
      final frac = pos - i0;
      final i1 = (i0 + 1) % loop.length;
      return loop[i0] * (1 - frac) + loop[i1] * frac;
    }
    // Fallback additive-harmonic approximation — used only until the real
    // sample finishes loading, or if it never does.
    var v = 0.0;
    for (final h in _bayanHarmonics) {
      v += math.sin(2 * math.pi * target * h.mul * t) * h.amp;
    }
    // Musette tremolo: real accordions detune two reed banks a few cents
    // apart, which beats into a slow amplitude wobble — the single most
    // recognizable trait of the timbre. ~5.5 Hz, shallow enough not to sound
    // like vibrato-effect processing.
    final tremolo = 1.0 + 0.16 * math.sin(2 * math.pi * 5.5 * t);
    return v * tremolo / 1.89; // 1.89 = sum of harmonic amps, keeps peak ~1
  }

  // ── Real accordion sample (assets/sounds/accordion_note.wav) ───────────
  // Decoded once, cached as a seamlessly-loopable middle segment (skips the
  // bellows attack/tail) plus its detected fundamental frequency, so _waveAt
  // above can pitch-shift it to any note by resampling.
  static List<double>? _accordionLoop;
  static double _accordionSampleRate = 44100;
  static double _accordionBaseFreq = 220;

  static Future<void> _loadAccordionSample() async {
    try {
      final data = await rootBundle.load('assets/sounds/accordion_note.wav');
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final parsed = _decodeWavPcm16(bytes);
      if (parsed == null || parsed.samples.length < 2048) return;
      final s = parsed.samples;
      // Middle 50% — skips attack chiff and any release, leaving just the
      // sustained tone to loop and to measure pitch from.
      final start = (s.length * 0.25).round();
      final end = (s.length * 0.75).round();
      final loop = _seamlessLoop(
          s.sublist(start, end), (parsed.sampleRate * 0.01).round());
      _accordionSampleRate = parsed.sampleRate.toDouble();
      _accordionBaseFreq = _detectFundamentalHz(loop, parsed.sampleRate);
      _accordionLoop = loop;
      debugPrint('[RLINK][Sound] accordion sample ready: '
          '${loop.length} samples @ ${parsed.sampleRate}Hz, '
          'pitch ${_accordionBaseFreq.toStringAsFixed(1)}Hz');
    } catch (e) {
      debugPrint('[RLINK][Sound] accordion sample load failed: $e');
    }
  }

  /// Crossfades the segment's tail into its head over [fadeSamples] so
  /// wrapping it in a modulo loop doesn't produce an audible click at the seam.
  static List<double> _seamlessLoop(List<double> src, int fadeSamples) {
    final n = src.length;
    final fade = fadeSamples.clamp(1, n ~/ 4);
    final out = List<double>.of(src);
    for (var i = 0; i < fade; i++) {
      final k = i / fade;
      out[n - fade + i] = out[n - fade + i] * (1 - k) + out[i] * k;
    }
    return out;
  }

  /// Autocorrelation pitch detection, searching only the musically-plausible
  /// 70-1000 Hz range — simple, well-understood, and accurate enough for a
  /// single sustained note (no polyphony/noise to confuse it).
  static double _detectFundamentalHz(List<double> window, int sampleRate) {
    if (window.length < 512) return 220;
    final minLag = (sampleRate / 1000).floor().clamp(1, window.length - 1);
    final maxLag = (sampleRate / 70).ceil().clamp(minLag + 1, window.length - 1);
    var bestLag = minLag;
    var bestScore = double.negativeInfinity;
    for (var lag = minLag; lag <= maxLag; lag++) {
      var sum = 0.0;
      for (var i = 0; i < window.length - lag; i++) {
        sum += window[i] * window[i + lag];
      }
      if (sum > bestScore) {
        bestScore = sum;
        bestLag = lag;
      }
    }
    return sampleRate / bestLag;
  }

  /// Minimal PCM16 WAV decoder (mono or stereo, downmixed to mono) — walks
  /// chunks rather than assuming fixed offsets, robust to whatever extra
  /// metadata chunks a given encoder adds.
  static ({List<double> samples, int sampleRate})? _decodeWavPcm16(
      Uint8List bytes) {
    if (bytes.length < 44) return null;
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    final header = ByteData.sublistView(bytes);
    var offset = 12;
    int? sampleRate;
    int? channels;
    int? bitsPerSample;
    Uint8List? pcmBytes;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = header.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        channels = header.getUint16(body + 2, Endian.little);
        sampleRate = header.getUint32(body + 4, Endian.little);
        bitsPerSample = header.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        pcmBytes = bytes.sublist(body, (body + size).clamp(0, bytes.length));
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    if (sampleRate == null ||
        channels == null ||
        bitsPerSample != 16 ||
        pcmBytes == null ||
        channels < 1) {
      return null;
    }
    final pcm = ByteData.sublistView(pcmBytes);
    final frameCount = pcmBytes.length ~/ (2 * channels);
    final samples = List<double>.filled(frameCount, 0);
    for (var i = 0; i < frameCount; i++) {
      var sum = 0;
      for (var c = 0; c < channels; c++) {
        sum += pcm.getInt16((i * channels + c) * 2, Endian.little);
      }
      samples[i] = (sum / channels) / 32768.0;
    }
    return (samples: samples, sampleRate: sampleRate);
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

  @visibleForTesting
  static Uint8List toneBytesForTest({
    required List<int> notes,
    required int stepMs,
    bool bayan = false,
  }) =>
      _buildToneBytes(notes: notes, stepMs: stepMs, bayan: bayan);

  @visibleForTesting
  static Future<void> loadAccordionSampleForTest() => _loadAccordionSample();

  @visibleForTesting
  static bool get accordionSampleLoadedForTest => _accordionLoop != null;

  @visibleForTesting
  static double get accordionBaseFreqForTest => _accordionBaseFreq;

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
