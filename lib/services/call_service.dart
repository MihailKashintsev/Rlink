import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'block_service.dart';
import 'call_history_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'chat_storage_service.dart';
import 'notification_service.dart';
import 'relay_service.dart';
import 'sound_effects_service.dart';
import '../utils/web_file_store.dart';
import '../utils/web_object_url.dart';

enum CallPhase { idle, ringing, connecting, connected, ended, failed }

class CallSessionInfo {
  final String callId;
  final String peerId;
  final bool incoming;
  final bool videoEnabled;
  final bool audioEnabled;

  const CallSessionInfo({
    required this.callId,
    required this.peerId,
    required this.incoming,
    required this.videoEnabled,
    required this.audioEnabled,
  });
}

class CallService {
  CallService._();
  static final CallService instance = CallService._();
  static const Duration _ringingTimeoutDuration = Duration(seconds: 60);
  static const Duration _connectingTimeoutDuration = Duration(seconds: 50);

  static const _turnHost =
      String.fromEnvironment('TURN_HOST', defaultValue: '');
  static const _turnUser =
      String.fromEnvironment('TURN_USER', defaultValue: '');
  static const _turnPassword =
      String.fromEnvironment('TURN_PASSWORD', defaultValue: '');

  static const _callUiChannel = MethodChannel('com.rendergames.rlink/call_ui');

  /// Show-over-lock-screen for the duration of the ring, so the full-screen
  /// incoming-call banner is actually visible if the phone is locked instead
  /// of the OS just showing the keyguard underneath. No-op off Android.
  Future<void> _ringLockScreen() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _callUiChannel.invokeMethod('ring');
    } catch (_) {}
  }

  Future<void> _stopRingLockScreen() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _callUiChannel.invokeMethod('stopRinging');
    } catch (_) {}
  }

  final _uuid = const Uuid();
  final ValueNotifier<CallSessionInfo?> incomingCall = ValueNotifier(null);
  final ValueNotifier<CallPhase> phase = ValueNotifier(CallPhase.idle);

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  final Map<String, dynamic> _pendingOffers = <String, dynamic>{};
  final Map<String, List<Map<String, dynamic>>> _pendingIce =
      <String, List<Map<String, dynamic>>>{};
  Map<String, dynamic>? _lastLocalOffer;
  String? _activeCallId;
  String? _activePeerId;

  /// Для записи в [CallHistoryService] при [_cleanup].
  bool _historyWasIncoming = false;
  bool _videoEnabled = true;
  bool _acceptedAwaitingOffer = false;
  Timer? _connectTimeout;
  Timer? _acceptResendTimer;
  int _acceptResendAttempts = 0;
  Timer? _offerResendTimer;
  Timer? _iceDiagTimer;

  /// Grace window for a transient `disconnected`. WebRTC uses that state for
  /// "connectivity checks are failing right now", and it recovers on its own
  /// routinely — a mobile network blip, a Wi-Fi/LTE handover, a NAT rebind.
  /// Tearing the call down on the first one is why long calls died after
  /// 20-30 minutes. We wait, ask ICE to re-negotiate a path, and only give up
  /// if it hasn't come back.
  Timer? _reconnectGrace;
  static const Duration _reconnectGraceDuration = Duration(seconds: 12);
  int _localRelayCount = 0;
  int _localSrflxCount = 0;
  int _localHostCount = 0;
  int _remoteRelayCount = 0;
  int _remoteSrflxCount = 0;
  int _remoteHostCount = 0;
  DateTime _phaseSince = DateTime.now();
  final Map<String, DateTime> _recentlyHandledCallIds = {};
  // A call can be torn down by both the local hangup and the remote's hangup
  // signal; record its history/chat-message only once.
  final Set<String> _recordedCallIds = {};
  final Map<String, DateTime> _recentInviteNotifiedAt = {};
  static const _recentCallTtl = Duration(seconds: 30);
  static final RegExp _pubKeyHex64 = RegExp(r'^[0-9a-f]{64}$');

  MediaStream? remoteStream;
  final ValueNotifier<MediaStream?> remoteStreamNotifier = ValueNotifier(null);

  /// Инкремент при каждом [onTrack]: иначе [ValueNotifier] не уведомляет слушателей,
  /// если объект [MediaStream] тот же — у инициатора не появлялось удалённое видео.
  final ValueNotifier<int> remoteStreamGeneration = ValueNotifier(0);

  /// Собеседник включил запись звонка — показываем красный индикатор.
  final ValueNotifier<bool> peerIsRecording = ValueNotifier(false);

  /// Мы сами пишем разговор (локальная кнопка записи).
  final ValueNotifier<bool> localRecording = ValueNotifier(false);

  /// Длительность с момента соединения (обновляется раз в секунду).
  final ValueNotifier<Duration> callElapsed = ValueNotifier(Duration.zero);

  /// Длительность записи (обновляется раз в секунду, пока localRecording == true).
  final ValueNotifier<Duration> recordingElapsed = ValueNotifier(Duration.zero);

  /// Громкая связь для аудиозвонка. При включении proximity-blanking не нужен.
  final ValueNotifier<bool> speakerOn = ValueNotifier(false);

  /// Живой уровень звука собеседника (0..1) — питает «живую» звуковую волну на
  /// экране звонка. Берётся из getStats() входящего аудио, пока идёт разговор.
  final ValueNotifier<double> audioLevel = ValueNotifier(0.0);
  Timer? _audioLevelTimer;

  MediaRecorder? _mediaRecorder;
  String? _recordingPath;
  String _recordingMimeType = 'video/webm';
  Stopwatch? _callDurationSw;
  Timer? _callDurationTimer;
  Stopwatch? _recordingSw;
  Timer? _recordingTimer;

  bool get isBusy =>
      phase.value == CallPhase.ringing ||
      phase.value == CallPhase.connecting ||
      phase.value == CallPhase.connected;

  void _setPhase(CallPhase next) {
    final prev = phase.value;
    phase.value = next;
    _phaseSince = DateTime.now();
    if (next == CallPhase.connected && prev != CallPhase.connected) {
      _armCallDurationTimer();
    }
    // Leaving the ringing state (accepted, declined, timed out, caller
    // cancelled) — clear whatever the incoming-call UI armed, regardless of
    // which call site triggered the transition.
    if (prev == CallPhase.ringing && next != CallPhase.ringing) {
      unawaited(_stopRingLockScreen());
      final peerId = _activePeerId;
      if (peerId != null) {
        unawaited(NotificationService.instance.cancelIncomingCallNotification(
          peerId,
        ));
      }
    }
  }

  void _armCallDurationTimer() {
    if (_callDurationSw != null) return;
    _callDurationSw = Stopwatch()..start();
    callElapsed.value = Duration.zero;
    _callDurationTimer?.cancel();
    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final sw = _callDurationSw;
      if (sw != null) {
        callElapsed.value = sw.elapsed;
      }
    });
    _startAudioLevelPoll();
  }

  void _stopCallDurationTimer() {
    _callDurationTimer?.cancel();
    _callDurationTimer = null;
    _callDurationSw?.stop();
    _callDurationSw = null;
    callElapsed.value = Duration.zero;
    _audioLevelTimer?.cancel();
    _audioLevelTimer = null;
    audioLevel.value = 0.0;
  }

  void _startAudioLevelPoll() {
    _audioLevelTimer?.cancel();
    _audioLevelTimer =
        Timer.periodic(const Duration(milliseconds: 120), (_) {
      unawaited(_pollAudioLevel());
    });
  }

  /// Read the live incoming audio level via WebRTC getStats().
  Future<void> _pollAudioLevel() async {
    final pc = _pc;
    if (pc == null || phase.value != CallPhase.connected) return;
    try {
      final reports = await pc.getStats();
      double best = -1;
      for (final r in reports) {
        final v = r.values;
        final lvl = v['audioLevel'];
        if (lvl is! num) continue;
        final d = lvl.toDouble();
        final inbound = r.type == 'inbound-rtp' ||
            (r.type == 'track' && v['remoteSource'] == true);
        if (inbound) {
          best = math.max(best, d);
        } else if (best < 0) {
          best = d; // fallback to any audioLevel if no inbound found
        }
      }
      if (best >= 0) {
        // Emphasise speech and smooth so the wave glides instead of flickering.
        final target = (best * 1.8).clamp(0.0, 1.0);
        audioLevel.value = audioLevel.value * 0.45 + target * 0.55;
      }
    } catch (_) {
      // getStats not available / transient — leave the last value to decay.
    }
  }

  /// Запись разговора (локально в Documents). Собеседнику уходит сигнал [recording].
  Future<void> setCallRecording(bool on) async {
    final peerId = _activePeerId;
    final callId = _activeCallId;
    if (peerId == null || callId == null) return;
    if (on) {
      if (_mediaRecorder != null) return;
      if (phase.value != CallPhase.connected) return;
      try {
        if (kIsWeb) {
          final source = remoteStream ?? _localStream;
          if (source == null) return;
          final hasVideo =
              _videoEnabled && source.getVideoTracks().isNotEmpty == true;
          await _startWebRecording(source, hasVideo: hasVideo);
        } else {
          final dir = await getApplicationDocumentsDirectory();
          final ext = (_videoEnabled &&
                  remoteStream?.getVideoTracks().isNotEmpty == true)
              ? 'mp4'
              : 'm4a';
          _recordingPath = p.join(
            dir.path,
            'call_${callId.substring(0, 8)}_${DateTime.now().millisecondsSinceEpoch}.$ext',
          );
          final rec = MediaRecorder();
          final remote = remoteStream;
          final vTracks =
              remote?.getVideoTracks() ?? const <MediaStreamTrack>[];
          final aTracks =
              remote?.getAudioTracks() ?? const <MediaStreamTrack>[];
          if (vTracks.isNotEmpty) {
            await rec.start(
              _recordingPath!,
              videoTrack: vTracks.first,
              audioChannel: RecorderAudioChannel.OUTPUT,
            );
          } else if (aTracks.isNotEmpty) {
            await rec.start(
              _recordingPath!,
              audioChannel: RecorderAudioChannel.OUTPUT,
            );
          } else {
            await rec.start(
              _recordingPath!,
              audioChannel: RecorderAudioChannel.INPUT,
            );
          }
          _mediaRecorder = rec;
          _recordingMimeType = ext == 'mp4' ? 'video/mp4' : 'audio/mp4';
        }
        localRecording.value = true;
        _recordingSw = Stopwatch()..start();
        recordingElapsed.value = Duration.zero;
        _recordingTimer?.cancel();
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_recordingSw != null) {
            recordingElapsed.value = _recordingSw!.elapsed;
          }
        });
        await _sendSignal(peerId, callId, 'recording', {'on': true});
        debugPrint('[RLINK][Call] Recording started');
      } catch (e) {
        debugPrint('[RLINK][Call] Recording start failed: $e');
        _mediaRecorder = null;
        _recordingPath = null;
      }
    } else {
      if (_mediaRecorder == null) {
        return;
      }
      try {
        await _sendSignal(peerId, callId, 'recording', {'on': false});
      } catch (_) {}
      try {
        await _stopActiveRecording();
      } catch (_) {}
    }
  }

  Future<void> _startWebRecording(
    MediaStream source, {
    required bool hasVideo,
  }) async {
    final candidates = hasVideo
        ? const <String>[
            'video/webm;codecs=vp8,opus',
            'video/webm',
            'video/mp4',
          ]
        : const <String>[
            'audio/webm;codecs=opus',
            'audio/webm',
            'audio/mp4',
            'video/webm',
          ];
    Object? lastError;
    for (final mime in candidates) {
      try {
        final rec = MediaRecorder();
        rec.startWeb(source, mimeType: mime, timeSlice: 1000);
        _mediaRecorder = rec;
        _recordingMimeType = mime.split(';').first;
        _recordingPath = null;
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('Web MediaRecorder start failed: $lastError');
  }

  Future<String?> _stopActiveRecording() async {
    final recorder = _mediaRecorder;
    if (recorder == null) return _recordingPath;
    try {
      final out = await recorder.stop();
      if (kIsWeb) {
        final objectUrl = out?.toString();
        final bytes = objectUrl == null || objectUrl.isEmpty
            ? null
            : await readWebObjectUrlBytes(objectUrl);
        if (bytes != null && bytes.isNotEmpty) {
          final callId = _activeCallId ?? 'call';
          final shortLen = callId.length < 8 ? callId.length : 8;
          final shortCallId = callId.substring(0, shortLen);
          final ts = DateTime.now().millisecondsSinceEpoch;
          final ext = _recordingMimeType.contains('mp4')
              ? (_recordingMimeType.startsWith('audio/') ? 'm4a' : 'mp4')
              : 'webm';
          final stored = await writeWebStoredFile(
            fileName: 'call_${shortCallId}_$ts.$ext',
            bytes: bytes,
            mimeType: _recordingMimeType,
          );
          _recordingPath = stored ?? objectUrl;
        } else {
          _recordingPath = objectUrl;
        }
      }
      debugPrint('[RLINK][Call] Recording stopped');
    } catch (e) {
      debugPrint('[RLINK][Call] Recording stop failed: $e');
    }
    _mediaRecorder = null;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingSw?.stop();
    _recordingSw = null;
    recordingElapsed.value = Duration.zero;
    localRecording.value = false;
    return _recordingPath;
  }

  void _cancelReconnectGrace() {
    _reconnectGrace?.cancel();
    _reconnectGrace = null;
  }

  /// Best-effort ICE restart. Only the side that made the offer may renegotiate,
  /// and the plugin can throw on platforms that don't implement it — a failure
  /// here just means we fall back to waiting out the grace window.
  Future<void> _tryRestartIce(RTCPeerConnection pc) async {
    try {
      await pc.restartIce();
    } catch (e) {
      debugPrint('[RLINK][Call] restartIce failed: $e');
    }
  }

  Map<String, dynamic> _iceConfig() {
    final servers = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
      {'urls': 'stun:stun.nextcloud.com:443'},
    ];
    final host = _turnHost.trim();
    final user = _turnUser.trim();
    final pass = _turnPassword.trim();
    if (host.isNotEmpty && user.isNotEmpty && pass.isNotEmpty) {
      // TURN UDP и TCP — основной транспорт; TLS не добавляем (нет сертификата).
      servers.add(<String, dynamic>{
        'urls': <String>[
          'turn:$host:3478?transport=udp',
          'turn:$host:3478?transport=tcp',
        ],
        'username': user,
        'credential': pass,
      });
      debugPrint('[RLINK][Call] TURN configured: $host user=$user');
    } else {
      debugPrint('[RLINK][Call] TURN NOT configured (no dart-define). '
          'Calls may fail between NAT devices. Run with:\n'
          '  --dart-define=TURN_HOST=<host>\n'
          '  --dart-define=TURN_USER=<user>\n'
          '  --dart-define=TURN_PASSWORD=<pass>');
    }
    // iceCandidatePoolSize: пул кандидатов начинает собираться сразу при
    //   createPeerConnection, а не после setLocalDescription — заметно
    //   ускоряет старт звонка (особенно для TURN allocate).
    // bundlePolicy/rtcpMuxPolicy: один транспортный канал для всего —
    //   меньше работы NAT-у, быстрее ICE checks.
    return <String, dynamic>{
      'iceServers': servers,
      'iceCandidatePoolSize': 4,
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };
  }

  Map<String, dynamic> _offerAnswerConstraints() => <String, dynamic>{
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': _videoEnabled,
      };

  /// Сбор статистики типов ICE-кандидатов; вызывается через несколько секунд
  /// после старта «connecting» — помогает отлавливать «нет relay-кандидатов»
  /// (TURN не работает) и symmetric NAT-проблемы.
  void _logIceCandidateSummary(int localRelay, int localSrflx, int localHost,
      int remoteRelay, int remoteSrflx, int remoteHost) {
    debugPrint('[RLINK][Call] ICE candidates: '
        'local relay=$localRelay srflx=$localSrflx host=$localHost / '
        'remote relay=$remoteRelay srflx=$remoteSrflx host=$remoteHost');
    if (localRelay == 0 && _turnHost.trim().isNotEmpty) {
      debugPrint(
          '[RLINK][Call][WARN] no local relay candidates — TURN allocate '
          'не прошёл (host=$_turnHost). Проверь UDP 3478 и порты 49160-49200.');
    }
    if (remoteRelay == 0 && remoteSrflx == 0) {
      debugPrint(
          '[RLINK][Call][WARN] нет ни одного публичного кандидата от пира — '
          'возможно его STUN не работает или ICE-сигнализация не доходит.');
    }
  }

  void bindSignaling() {
    GossipRouter.instance.onCallSignal = _onSignal;
  }

  Future<CallSessionInfo> startOutgoing({
    required String peerId,
    required bool video,
  }) async {
    if (isBusy) {
      throw StateError('busy');
    }
    final recipientKey = _resolveRecipientKey(peerId);
    if (recipientKey == null) {
      throw StateError('invalid_recipient');
    }
    if (!RelayService.instance.isConnected) {
      throw StateError('peer_offline');
    }
    final recipientX25519 = await _x25519ForRecipient(recipientKey);
    if (recipientX25519 == null || recipientX25519.isEmpty) {
      throw StateError('missing_peer_encryption_key');
    }
    _historyWasIncoming = false;
    final callId = _uuid.v4();
    _activeCallId = callId;
    _activePeerId = recipientKey;
    _videoEnabled = video;
    await SoundEffectsService.instance.stopIncomingRingtone();
    unawaited(SoundEffectsService.instance.startOutgoingCallTone());
    // Show "ringing" while waiting for callee to accept.
    // Transitions to connecting when 'accept' signal arrives.
    _setPhase(CallPhase.ringing);
    try {
      await _ensurePeerConnection();
      await _ensureLocalStream();

      await _sendSignal(recipientKey, callId, 'invite', {
        'video': _videoEnabled,
        'audio': true,
      });
      await _createAndSendOffer();
      _armRingingTimeout();
      _startOfferResendLoop(recipientKey, callId);
    } catch (e) {
      debugPrint('[RLINK][Call] startOutgoing failed: $e');
      await _cleanup(CallPhase.failed);
      throw StateError('media_init_failed');
    }

    return CallSessionInfo(
      callId: callId,
      peerId: peerId,
      incoming: false,
      videoEnabled: _videoEnabled,
      audioEnabled: true,
    );
  }

  Future<void> acceptIncoming(CallSessionInfo session) async {
    final isIncomingRinging = phase.value == CallPhase.ringing &&
        incomingCall.value?.callId == session.callId;
    if (isBusy && !isIncomingRinging && _activeCallId != session.callId) {
      throw StateError('busy');
    }
    _activeCallId = session.callId;
    _activePeerId = session.peerId;
    _videoEnabled = session.videoEnabled;
    _historyWasIncoming = true;
    await SoundEffectsService.instance.stopIncomingRingtone();
    await SoundEffectsService.instance.stopOutgoingCallTone();
    _setPhase(CallPhase.connecting);

    try {
      await _ensurePeerConnection();
      await _ensureLocalStream();
    } catch (e) {
      debugPrint('[RLINK][Call] acceptIncoming media failed: $e');
      try {
        await _sendSignal(session.peerId, session.callId, 'reject');
      } catch (_) {}
      await _cleanup(CallPhase.failed);
      throw StateError('media_init_failed');
    }
    await _sendSignal(session.peerId, session.callId, 'accept');
    _armConnectTimeout();

    final offer = _pendingOffers.remove(session.callId);
    if (offer is! Map<String, dynamic>) {
      // Offer can arrive after user taps "accept"; keep session pending.
      _acceptedAwaitingOffer = true;
      _startAcceptResendLoop(session.peerId, session.callId);
      incomingCall.value = null;
      return;
    }
    _stopAcceptResendLoop();
    await _applyOfferAndAnswer(session.callId, session.peerId, offer);
    incomingCall.value = null;
  }

  Future<void> _applyOfferAndAnswer(
    String callId,
    String peerId,
    Map<String, dynamic> offer,
  ) async {
    final sdp = offer['sdp'] as String?;
    final type = offer['type'] as String?;
    if (sdp != null && type != null) {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
      await _refreshRemoteTracksFromReceivers();
      await _flushPendingIce(callId);
    }
    final answer = await _pc!.createAnswer(_offerAnswerConstraints());
    await _pc!.setLocalDescription(answer);
    final local = await _pc!.getLocalDescription();
    await _sendSignal(peerId, callId, 'answer', {
      'sdp': local?.sdp ?? answer.sdp,
      'type': local?.type ?? answer.type,
    });
  }

  Future<void> rejectIncoming(CallSessionInfo session) async {
    await _sendSignal(session.peerId, session.callId, 'reject');
    _recentlyHandledCallIds[session.callId] = DateTime.now();
    incomingCall.value = null;
    await SoundEffectsService.instance.stopIncomingRingtone();
    if (_activeCallId == session.callId || phase.value == CallPhase.ringing) {
      _pendingOffers.remove(session.callId);
      _pendingIce.remove(session.callId);
      _activeCallId = null;
      _activePeerId = null;
      _acceptedAwaitingOffer = false;
      _setPhase(CallPhase.idle);
    }
    unawaited(
      CallHistoryService.instance.recordRejectedIncoming(
        peerId: session.peerId,
        video: session.videoEnabled,
      ),
    );
  }

  Future<void> endCall() async {
    final peer = _activePeerId;
    final callId = _activeCallId;
    if (peer != null && callId != null) {
      await _sendSignal(peer, callId, 'end');
    }
    await _cleanup(CallPhase.ended);
  }

  Future<void> toggleMic(bool enabled) async {
    for (final t
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  Future<void> toggleCamera(bool enabled) async {
    _videoEnabled = enabled;
    for (final t
        in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
  }

  Future<void> setSpeakerphone(bool enabled) async {
    try {
      await Helper.setSpeakerphoneOn(enabled);
    } catch (e) {
      debugPrint('[RLINK][Call] setSpeakerphone failed: $e');
    }
    speakerOn.value = enabled;
  }

  Future<MediaStream?> getLocalStream() async {
    await _ensureLocalStream();
    return _localStream;
  }

  Future<void> _createAndSendOffer() async {
    final pc = _pc;
    final peerId = _activePeerId;
    final callId = _activeCallId;
    if (pc == null || peerId == null || callId == null) return;
    final offer = await pc.createOffer(_offerAnswerConstraints());
    await pc.setLocalDescription(offer);
    final local = await pc.getLocalDescription();
    final payload = <String, dynamic>{
      'sdp': local?.sdp ?? offer.sdp,
      'type': local?.type ?? offer.type,
    };
    _lastLocalOffer = payload;
    await _sendSignal(peerId, callId, 'offer', payload);
  }

  Future<void> _ensurePeerConnection() async {
    if (_pc != null) return;
    final pc = await createPeerConnection(_iceConfig());
    _pc = pc;
    pc.onIceCandidate = (candidate) async {
      final peerId = _activePeerId;
      final callId = _activeCallId;
      if (peerId == null || callId == null || candidate.candidate == null) {
        return;
      }
      // Логируем тип кандидата для диагностики (host/srflx/relay)
      final c = candidate.candidate ?? '';
      final typ = RegExp(r'typ\s+(\S+)').firstMatch(c)?.group(1) ?? '?';
      switch (typ) {
        case 'relay':
          _localRelayCount++;
          break;
        case 'srflx':
        case 'prflx':
          _localSrflxCount++;
          break;
        case 'host':
          _localHostCount++;
          break;
      }
      debugPrint(
          '[RLINK][Call] ICE candidate typ=$typ mid=${candidate.sdpMid}');
      await _sendSignal(peerId, callId, 'ice', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onTrack = (event) {
      unawaited(_attachRemoteTrack(event));
    };

    pc.onAddStream = (stream) {
      _attachRemoteStream(stream);
    };

    pc.onIceConnectionState = (state) {
      debugPrint('[RLINK][Call] ICE state: $state');
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _connectTimeout?.cancel();
          if (phase.value != CallPhase.connected) {
            _setPhase(CallPhase.connected);
            unawaited(SoundEffectsService.instance.stopOutgoingCallTone());
            unawaited(SoundEffectsService.instance
                .playAction(ActionSound.callConnected));
          }
          unawaited(_refreshRemoteTracksFromReceivers());
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          if (phase.value != CallPhase.ended &&
              phase.value != CallPhase.failed) {
            unawaited(_cleanup(CallPhase.failed));
          }
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          // Transient — give it a few seconds before cleaning up.
          // onConnectionState handles the definitive closure.
          break;
        default:
          break;
      }
    };

    pc.onConnectionState = (state) {
      debugPrint('[RLINK][Call] PC state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _cancelReconnectGrace();
        unawaited(_cleanup(CallPhase.failed));
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // Transient by definition — don't hang up on it. Ask ICE for a fresh
        // path and give it a moment; `connected` below cancels the timer.
        if (phase.value != CallPhase.ended &&
            phase.value != CallPhase.failed &&
            _reconnectGrace == null) {
          debugPrint('[RLINK][Call] disconnected — trying to recover');
          unawaited(_tryRestartIce(pc));
          _reconnectGrace = Timer(_reconnectGraceDuration, () {
            _reconnectGrace = null;
            if (phase.value != CallPhase.ended &&
                phase.value != CallPhase.failed) {
              debugPrint('[RLINK][Call] recovery window expired — ending');
              unawaited(_cleanup(CallPhase.ended));
            }
          });
        }
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _cancelReconnectGrace();
        if (phase.value != CallPhase.ended && phase.value != CallPhase.failed) {
          unawaited(_cleanup(CallPhase.ended));
        }
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _cancelReconnectGrace();
        _connectTimeout?.cancel();
        if (phase.value != CallPhase.connected) {
          _setPhase(CallPhase.connected);
          unawaited(SoundEffectsService.instance.stopOutgoingCallTone());
          unawaited(SoundEffectsService.instance
              .playAction(ActionSound.callConnected));
        }
        unawaited(_refreshRemoteTracksFromReceivers());
      }
    };
  }

  Future<void> _refreshRemoteTracksFromReceivers() async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final receivers = await pc.getReceivers();
      if (receivers.isEmpty) return;
      final stream = remoteStream ?? await createLocalMediaStream('remote');
      var added = false;
      for (final receiver in receivers) {
        final track = receiver.track;
        if (track == null) continue;
        final alreadyAdded = stream.getTracks().any((t) => t.id == track.id);
        if (!alreadyAdded) {
          await stream.addTrack(track);
          added = true;
        }
      }
      if (!added && remoteStream == stream) return;
      remoteStream = stream;
      remoteStreamNotifier.value = stream;
      remoteStreamGeneration.value++;
      debugPrint('[RLINK][Call] remote receivers refresh: '
          'audio=${stream.getAudioTracks().length} '
          'video=${stream.getVideoTracks().length}');
    } catch (e) {
      debugPrint('[RLINK][Call] remote receivers refresh failed: $e');
    }
  }

  Future<void> _attachRemoteTrack(dynamic event) async {
    final track = event.track as MediaStreamTrack;
    final eventStreams = event.streams as List<dynamic>?;
    final eventStream = eventStreams != null && eventStreams.isNotEmpty
        ? eventStreams.first as MediaStream?
        : null;
    final stream =
        eventStream ?? remoteStream ?? await createLocalMediaStream('remote');
    final alreadyAdded = stream.getTracks().any((t) => t.id == track.id);
    if (!alreadyAdded && eventStream == null) {
      await stream.addTrack(track);
    }
    remoteStream = stream;
    remoteStreamNotifier.value = stream;
    remoteStreamGeneration.value++;
    debugPrint('[RLINK][Call] remote track: kind=${track.kind} '
        'audio=${stream.getAudioTracks().length} '
        'video=${stream.getVideoTracks().length}');
    _connectTimeout?.cancel();
    if (phase.value != CallPhase.connected) {
      _setPhase(CallPhase.connected);
      unawaited(SoundEffectsService.instance.stopOutgoingCallTone());
      unawaited(
          SoundEffectsService.instance.playAction(ActionSound.callConnected));
    }
  }

  void _attachRemoteStream(MediaStream stream) {
    remoteStream = stream;
    remoteStreamNotifier.value = stream;
    remoteStreamGeneration.value++;
    debugPrint('[RLINK][Call] remote stream: '
        'audio=${stream.getAudioTracks().length} '
        'video=${stream.getVideoTracks().length}');
    _connectTimeout?.cancel();
    if (phase.value != CallPhase.connected) {
      _setPhase(CallPhase.connected);
      unawaited(SoundEffectsService.instance.stopOutgoingCallTone());
      unawaited(
          SoundEffectsService.instance.playAction(ActionSound.callConnected));
    }
  }

  Future<void> _ensureLocalStream() async {
    if (_localStream != null) return;
    try {
      final media = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': _videoEnabled,
      });
      _localStream = media;
      final pc = _pc;
      if (pc != null) {
        for (final track in media.getTracks()) {
          await pc.addTrack(track, media);
        }
      }
      return;
    } catch (e) {
      debugPrint('[RLINK][Call] getUserMedia primary failed: $e');
    }

    if (_videoEnabled) {
      // iOS devices can fail or crash during camera bootstrap on some plugin/device
      // combinations. Fallback to audio-only instead of aborting the call flow.
      try {
        final media = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
        _videoEnabled = false;
        _localStream = media;
        final pc = _pc;
        if (pc != null) {
          for (final track in media.getTracks()) {
            await pc.addTrack(track, media);
          }
        }
        debugPrint('[RLINK][Call] Fallback to audio-only stream.');
        return;
      } catch (e) {
        debugPrint('[RLINK][Call] getUserMedia audio fallback failed: $e');
      }
    }

    throw StateError('media_init_failed');
  }

  Future<void> _onSignal(
    String fromId,
    String callId,
    String signalType,
    Map<String, dynamic> payload,
  ) async {
    final f8 = fromId.length >= 8 ? fromId.substring(0, 8) : fromId;
    // Drop every call signal from a blocked peer — including 'invite', so a
    // blocked contact's call never rings, never notifies, never touches
    // phase/activeCallId at all. The block-contact dialog already promises
    // "you won't receive calls from them"; nothing here previously enforced
    // that promise.
    if (BlockService.instance.isBlocked(fromId)) {
      debugPrint('[RLINK][Call] Dropped $signalType from blocked $f8');
      return;
    }
    debugPrint('[RLINK][Call][RX] $signalType from=$f8');
    switch (signalType) {
      case 'invite':
        final now = DateTime.now();
        // Dedup: ignore re-invites for calls we've already handled.
        final recentTs = _recentlyHandledCallIds[callId];
        if (recentTs != null && now.difference(recentTs) < _recentCallTtl) {
          debugPrint('[RLINK][Call] ignoring re-invite for handled call');
          break;
        }
        // De-duplicate: if we're already ringing for this exact call, ignore
        // re-invites (sent by caller's offer resend loop).
        if (_activeCallId == callId && phase.value == CallPhase.ringing) {
          final lastNotify = _recentInviteNotifiedAt[callId];
          if (lastNotify == null ||
              now.difference(lastNotify) > const Duration(seconds: 20)) {
            _recentInviteNotifiedAt[callId] = now;
          }
          break;
        }
        if (isBusy && _activeCallId != callId) {
          final staleBusy = (phase.value == CallPhase.ringing ||
                  phase.value == CallPhase.connecting) &&
              DateTime.now().difference(_phaseSince) >
                  const Duration(seconds: 45);
          if (staleBusy) {
            debugPrint(
              '[RLINK][Call] dropping stale busy state: call=${_activeCallId ?? '-'} phase=${phase.value}',
            );
            await _cleanup(CallPhase.idle);
          }
        }
        if (isBusy && _activeCallId != callId) {
          await _sendSignal(fromId, callId, 'busy');
          break;
        }
        final contact = await ChatStorageService.instance.getContact(fromId);
        final displayName = (contact?.nickname.trim().isNotEmpty ?? false)
            ? contact!.nickname.trim()
            : (fromId.length >= 8 ? '${fromId.substring(0, 8)}...' : fromId);
        final isVideo = payload['video'] == true;
        _recentInviteNotifiedAt[callId] = now;
        final info = CallSessionInfo(
          callId: callId,
          peerId: fromId,
          incoming: true,
          videoEnabled: isVideo,
          audioEnabled: payload['audio'] != false,
        );
        _activeCallId = callId;
        _activePeerId = fromId;
        _videoEnabled = isVideo;
        incomingCall.value = info;
        _setPhase(CallPhase.ringing);
        // Only when backgrounded — while the app is open, the dedicated
        // incoming-call overlay/banner already covers this; also firing the
        // generic in-app message banner would double up on the same call.
        if (NotificationService.instance.isInBackground.value) {
          unawaited(
            NotificationService.instance.showPersonalMessage(
              peerId: fromId,
              title: displayName,
              body: isVideo ? 'Видеозвонок' : 'Аудиозвонок',
            ),
          );
        }
        // Android: arm show-over-lock-screen first, then the full-screen
        // notification — order matters if the phone is currently locked.
        unawaited(_ringLockScreen());
        unawaited(NotificationService.instance.showIncomingCallNotification(
          peerId: fromId,
          title: displayName,
          isVideo: isVideo,
        ));
        unawaited(SoundEffectsService.instance.startIncomingRingtone());
        break;
      case 'offer':
        _pendingOffers[callId] = payload;
        if (_acceptedAwaitingOffer &&
            _activeCallId == callId &&
            _activePeerId == fromId &&
            _pc != null) {
          _acceptedAwaitingOffer = false;
          _stopAcceptResendLoop();
          await _applyOfferAndAnswer(callId, fromId, payload);
        }
        break;
      case 'accept':
        // Callee accepted — move to connecting phase, then resend offer.
        final callMatch = _activeCallId == callId;
        final peerMatch = _activePeerId == fromId;
        debugPrint(
            '[RLINK][Call] accept gate: callMatch=$callMatch peerMatch=$peerMatch '
            'myPeer=${_activePeerId?.substring(0, 8) ?? '-'} rxPeer=${fromId.substring(0, 8)}');
        if (callMatch && peerMatch) {
          _setPhase(CallPhase
              .connecting); // Set phase BEFORE stopping loop to prevent race
          _stopOfferResendLoop(); // stop ringing resend, caller now sends offer on-demand
          _armConnectTimeout();
          if (_lastLocalOffer != null) {
            await _sendSignal(fromId, callId, 'offer', _lastLocalOffer!);
          }
        }
        break;
      case 'answer':
        if (_pc != null) {
          final sdp = payload['sdp'] as String?;
          final type = payload['type'] as String?;
          if (sdp != null && type != null) {
            await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
            await _refreshRemoteTracksFromReceivers();
            await _flushPendingIce(callId);
            if (phase.value == CallPhase.connecting) {
              _armConnectTimeout();
            }
          }
        }
        break;
      case 'recording':
        if (_activeCallId != callId || _activePeerId != fromId) {
          break;
        }
        peerIsRecording.value = payload['on'] == true;
        break;
      case 'ice':
        final candidate = payload['candidate'] as String?;
        final sdpMid = payload['sdpMid'] as String?;
        final sdpMLineIndex = (payload['sdpMLineIndex'] as num?)?.toInt();
        final icePayload = <String, dynamic>{
          'candidate': candidate,
          'sdpMid': sdpMid,
          'sdpMLineIndex': sdpMLineIndex,
        };
        final pc = _pc;
        if (pc == null) {
          _pendingIce
              .putIfAbsent(callId, () => <Map<String, dynamic>>[])
              .add(icePayload);
          break;
        }
        try {
          await _addIceCandidate(icePayload);
          if (phase.value == CallPhase.connecting) {
            _armConnectTimeout();
          }
        } catch (_) {
          _pendingIce
              .putIfAbsent(callId, () => <Map<String, dynamic>>[])
              .add(icePayload);
        }
        break;
      case 'reject':
      case 'busy':
      case 'end':
        _recentlyHandledCallIds[callId] = DateTime.now();
        await _cleanup(CallPhase.ended);
        break;
      case 'fx':
        if (_activeCallId != callId || _activePeerId != fromId) break;
        final name = payload['fx'] as String?;
        CallFxSound? fx;
        try {
          fx = name == null ? null : CallFxSound.values.byName(name);
        } catch (_) {
          fx = null;
        }
        if (fx != null) _fireFx(fx);
        break;
    }
  }

  /// Last reaction sound played (self-triggered or received from the peer)
  /// and a counter that bumps on every trigger — CallScreen listens to the
  /// counter to know when to (re)play the falling-emoji overlay, since a
  /// ValueNotifier only notifies on a value *change* and the same emoji can
  /// legitimately fire twice in a row.
  CallFxSound? lastFx;
  final ValueNotifier<int> fxSignal = ValueNotifier(0);

  void _fireFx(CallFxSound fx) {
    lastFx = fx;
    fxSignal.value++;
    unawaited(SoundEffectsService.instance.playCallFx(fx));
  }

  /// Triggers an in-call reaction sound (Meet-style) — plays it locally right
  /// away and tells the peer to play the same one, so both sides hear it.
  Future<void> sendCallFx(CallFxSound fx) async {
    _fireFx(fx);
    final peerId = _activePeerId;
    final callId = _activeCallId;
    if (peerId == null || callId == null) return;
    await _sendSignal(peerId, callId, 'fx', {'fx': fx.name});
  }

  Future<void> _sendSignal(
    String recipientId,
    String callId,
    String signalType, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    final r8 =
        recipientId.length >= 8 ? recipientId.substring(0, 8) : recipientId;
    final x25519 = await _x25519ForRecipient(recipientId);
    if (x25519 == null || x25519.isEmpty) {
      debugPrint(
          '[RLINK][Call][DROP] $signalType reason=missing_peer_key to=$r8');
      return;
    }
    debugPrint('[RLINK][Call][TX] $signalType to=$r8');
    await GossipRouter.instance.sendCallSignal(
      fromId: myId,
      recipientId: recipientId,
      callId: callId,
      signalType: signalType,
      recipientX25519KeyBase64: x25519,
      payload: payload,
    );
  }

  Future<String?> _x25519ForRecipient(String recipientId) async {
    final relayKey = RelayService.instance.getPeerX25519Key(recipientId);
    if (relayKey != null && relayKey.isNotEmpty) return relayKey;
    final contact = await ChatStorageService.instance.getContact(recipientId);
    final stored = contact?.x25519Key?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return null;
  }

  String? _resolveRecipientKey(String peerId) {
    final trimmed = peerId.trim().toLowerCase();
    if (_pubKeyHex64.hasMatch(trimmed)) return trimmed;
    if (trimmed.length >= 8) {
      final byPrefix = RelayService.instance.findPeerByPrefix(trimmed);
      if (byPrefix != null) {
        final key = byPrefix.trim().toLowerCase();
        if (_pubKeyHex64.hasMatch(key)) return key;
      }
    }
    return null;
  }

  Future<void> _cleanup(CallPhase endPhase) async {
    _cancelReconnectGrace();
    await SoundEffectsService.instance.stopIncomingRingtone();
    await SoundEffectsService.instance.stopOutgoingCallTone();
    unawaited(setSpeakerphone(false));
    final callIdForRecent = _activeCallId;
    final peerForHistory = _activePeerId;
    final durationSnapshot =
        _callDurationSw != null ? _callDurationSw!.elapsed : Duration.zero;
    final incomingSnapshot = _historyWasIncoming;
    final videoSnapshot = _videoEnabled;
    _stopCallDurationTimer();
    peerIsRecording.value = false;
    if (localRecording.value &&
        _activePeerId != null &&
        _activeCallId != null) {
      try {
        await _sendSignal(
            _activePeerId!, _activeCallId!, 'recording', {'on': false});
      } catch (_) {}
    }
    if (_mediaRecorder != null) {
      await _stopActiveRecording();
    } else {
      localRecording.value = false;
    }
    final recordingPathSnapshot = _recordingPath;
    _connectTimeout?.cancel();
    _connectTimeout = null;
    _iceDiagTimer?.cancel();
    _iceDiagTimer = null;
    _stopAcceptResendLoop();
    _stopOfferResendLoop();
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    final local = _localStream;
    if (local != null) {
      for (final track in local.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await local.dispose();
      } catch (_) {}
    }
    _localStream = null;
    final remote = remoteStream;
    if (remote != null) {
      for (final track in remote.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await remote.dispose();
      } catch (_) {}
    }
    remoteStream = null;
    remoteStreamNotifier.value = null;
    _activeCallId = null;
    _activePeerId = null;
    _lastLocalOffer = null;
    _acceptedAwaitingOffer = false;
    _pendingOffers.clear();
    _pendingIce.clear();
    _localRelayCount = 0;
    _localSrflxCount = 0;
    _localHostCount = 0;
    _remoteRelayCount = 0;
    _remoteSrflxCount = 0;
    _remoteHostCount = 0;
    _setPhase(endPhase);
    if (peerForHistory != null &&
        endPhase != CallPhase.idle &&
        (callIdForRecent == null || _recordedCallIds.add(callIdForRecent))) {
      if (_recordedCallIds.length > 100) _recordedCallIds.clear();
      unawaited(
        CallHistoryService.instance.recordCallEnded(
          peerId: peerForHistory,
          duration: durationSnapshot,
          incoming: incomingSnapshot,
          video: videoSnapshot,
          recordingPath: recordingPathSnapshot,
        ),
      );
    }
    _recordingPath = null;
    _historyWasIncoming = false;
    // Track handled call to prevent duplicate incoming from caller resend loop.
    if (callIdForRecent != null) {
      _recentlyHandledCallIds[callIdForRecent] = DateTime.now();
    }
    // Purge old entries
    _recentlyHandledCallIds
        .removeWhere((k, v) => DateTime.now().difference(v) > _recentCallTtl);
    _recentInviteNotifiedAt
        .removeWhere((k, v) => DateTime.now().difference(v) > _recentCallTtl);
  }

  void _startAcceptResendLoop(String peerId, String callId) {
    _stopAcceptResendLoop();
    _acceptResendAttempts = 0;
    _acceptResendTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!_acceptedAwaitingOffer ||
          _activeCallId != callId ||
          _activePeerId != peerId) {
        _stopAcceptResendLoop();
        return;
      }
      _acceptResendAttempts++;
      if (_acceptResendAttempts > 6) {
        debugPrint('[RLINK][Call] offer did not arrive after repeated accept.');
        _stopAcceptResendLoop();
        return;
      }
      debugPrint('[RLINK][Call] resend accept #$_acceptResendAttempts');
      await _sendSignal(peerId, callId, 'accept');
    });
  }

  void _stopAcceptResendLoop() {
    _acceptResendTimer?.cancel();
    _acceptResendTimer = null;
    _acceptResendAttempts = 0;
  }

  /// Caller-side loop: refresh offer while still ringing. The invite itself is
  /// sent once; repeatedly sending it can surface as duplicate incoming banners
  /// on web when notifications and overlays race.
  void _startOfferResendLoop(String peerId, String callId) {
    _stopOfferResendLoop();
    _offerResendTimer = Timer.periodic(const Duration(seconds: 5), (t) async {
      if (phase.value != CallPhase.ringing || _activeCallId != callId) {
        _stopOfferResendLoop();
        return;
      }
      debugPrint('[RLINK][Call] resend offer (ringing retry)');
      if (_lastLocalOffer != null) {
        await _sendSignal(peerId, callId, 'offer', _lastLocalOffer!);
      }
    });
  }

  void _stopOfferResendLoop() {
    _offerResendTimer?.cancel();
    _offerResendTimer = null;
  }

  void _armConnectTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(_connectingTimeoutDuration, () {
      if (phase.value == CallPhase.connected ||
          phase.value == CallPhase.ended) {
        return;
      }
      debugPrint(
        '[RLINK][Call] connect timeout: phase=${phase.value}',
      );
      _logIceCandidateSummary(
          _localRelayCount,
          _localSrflxCount,
          _localHostCount,
          _remoteRelayCount,
          _remoteSrflxCount,
          _remoteHostCount);
      unawaited(_cleanup(CallPhase.failed));
    });
    // Промежуточный диаг через 8 сек — если до сих пор не connected,
    // покажем сводку кандидатов: проще понять, виноват ли TURN.
    _iceDiagTimer?.cancel();
    _iceDiagTimer = Timer(const Duration(seconds: 8), () {
      if (phase.value != CallPhase.connecting) return;
      _logIceCandidateSummary(
          _localRelayCount,
          _localSrflxCount,
          _localHostCount,
          _remoteRelayCount,
          _remoteSrflxCount,
          _remoteHostCount);
    });
  }

  void _armRingingTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(_ringingTimeoutDuration, () {
      if (phase.value != CallPhase.ringing) return;
      debugPrint(
        '[RLINK][Call] ringing timeout: phase=${phase.value}',
      );
      unawaited(_cleanup(CallPhase.failed));
    });
  }

  Future<void> _flushPendingIce(String callId) async {
    final list = _pendingIce.remove(callId);
    if (list == null || list.isEmpty) return;
    for (final c in list) {
      await _addIceCandidate(c);
    }
  }

  Future<void> _addIceCandidate(Map<String, dynamic> payload) async {
    final pc = _pc;
    if (pc == null) return;
    final cstr = payload['candidate'] as String? ?? '';
    final typ = RegExp(r'typ\s+(\S+)').firstMatch(cstr)?.group(1) ?? '?';
    switch (typ) {
      case 'relay':
        _remoteRelayCount++;
        break;
      case 'srflx':
      case 'prflx':
        _remoteSrflxCount++;
        break;
      case 'host':
        _remoteHostCount++;
        break;
    }
    await pc.addCandidate(
      RTCIceCandidate(
        payload['candidate'] as String?,
        payload['sdpMid'] as String?,
        payload['sdpMLineIndex'] as int?,
      ),
    );
  }
}
