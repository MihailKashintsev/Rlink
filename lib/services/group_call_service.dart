import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'relay_service.dart';
import 'webrtc_ice_config.dart';

enum GroupCallPhase { idle, ringing, active }

class GroupCallInvite {
  final String groupCallId;
  final String groupId;
  final String fromId;
  final bool video;

  const GroupCallInvite({
    required this.groupCallId,
    required this.groupId,
    required this.fromId,
    required this.video,
  });
}

/// Mesh group calls: every participant holds a direct [RTCPeerConnection] to
/// every other participant (no media server). Deliberately a separate,
/// simpler service from [CallService] — it does not share state with 1:1
/// calls and doesn't inherit their elaborate reconnect/ICE-diagnostic logic,
/// so it can't regress a working call. That logic can be ported over later
/// if group calls turn out to need it in practice.
///
/// Membership bootstrap: the call's initiator is a lightweight roster
/// coordinator (never a media relay — media stays fully P2P). Whenever the
/// initiator's known-participant set changes (someone accepts or leaves), it
/// broadcasts the current id list to everyone it knows via a `roster` signal.
/// Each participant that sees a new id in a roster connects to it directly;
/// which side sends the SDP offer is decided the same deterministic way on
/// both ends (lower public key wins), so there's no glare and no need for a
/// central signaling server for the media itself.
///
/// Known v1 limitations: no mid-call invites (only the initiator's starting
/// member list), no reconnect-on-ICE-failure beyond what WebRTC retries on
/// its own, mesh only — practical up to ~5 participants before each client's
/// upload bandwidth/CPU (N-1 simultaneous encodes) becomes the bottleneck.
class GroupCallService {
  GroupCallService._();
  static final GroupCallService instance = GroupCallService._();
  final _uuid = const Uuid();

  final ValueNotifier<GroupCallPhase> phase =
      ValueNotifier(GroupCallPhase.idle);
  final ValueNotifier<GroupCallInvite?> incomingInvite = ValueNotifier(null);
  final ValueNotifier<List<String>> participantIds = ValueNotifier(const []);
  final ValueNotifier<Map<String, MediaStream>> remoteStreams =
      ValueNotifier(const {});
  final ValueNotifier<MediaStream?> localStreamNotifier = ValueNotifier(null);
  final ValueNotifier<bool> micEnabled = ValueNotifier(true);
  final ValueNotifier<bool> cameraEnabled = ValueNotifier(true);

  String? _groupCallId;
  String? _groupId;
  bool _videoEnabled = true;
  MediaStream? _localStream;
  final Map<String, RTCPeerConnection> _pcs = {};
  final Map<String, MediaStream> _remote = {};
  final Set<String> _known = {};
  final Map<String, List<Map<String, dynamic>>> _pendingIce = {};

  String get _myId => CryptoService.instance.publicKeyHex;
  String? get groupId => _groupId;
  bool get isActive => phase.value != GroupCallPhase.idle;
  bool get isVideoEnabled => _videoEnabled;

  void bindSignaling() {
    GossipRouter.instance.onGroupCallSignal = _onSignal;
  }

  Map<String, dynamic> _offerAnswerConstraints() => <String, dynamic>{
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': _videoEnabled,
      };

  Future<String?> _x25519For(String peerId) async {
    final relayKey = RelayService.instance.getPeerX25519Key(peerId);
    if (relayKey != null && relayKey.isNotEmpty) return relayKey;
    final contact = await ChatStorageService.instance.getContact(peerId);
    final stored = contact?.x25519Key?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return null;
  }

  Future<void> _send(
    String to,
    String signalType, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final gcid = _groupCallId;
    if (gcid == null) return;
    final x = await _x25519For(to);
    if (x == null || x.isEmpty) {
      debugPrint('[RLINK][GroupCall] no x25519 for $to, dropping $signalType');
      return;
    }
    await GossipRouter.instance.sendGroupCallSignal(
      fromId: _myId,
      recipientId: to,
      groupCallId: gcid,
      signalType: signalType,
      recipientX25519KeyBase64: x,
      payload: payload,
    );
  }

  Future<void> _ensureLocalStream() async {
    if (_localStream != null) return;
    try {
      final media = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': _videoEnabled,
      });
      _localStream = media;
      localStreamNotifier.value = media;
      return;
    } catch (e) {
      debugPrint('[RLINK][GroupCall] getUserMedia failed: $e');
    }
    if (_videoEnabled) {
      try {
        final media = await navigator.mediaDevices
            .getUserMedia({'audio': true, 'video': false});
        _videoEnabled = false;
        cameraEnabled.value = false;
        _localStream = media;
        localStreamNotifier.value = media;
        return;
      } catch (e) {
        debugPrint('[RLINK][GroupCall] audio-only fallback failed: $e');
      }
    }
    throw StateError('media_init_failed');
  }

  Future<RTCPeerConnection> _createPeerConnectionFor(String peerId) async {
    final pc = await createPeerConnection(webrtcIceConfig());
    final local = _localStream;
    if (local != null) {
      for (final t in local.getTracks()) {
        await pc.addTrack(t, local);
      }
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      unawaited(_send(peerId, 'ice', {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      }));
    };
    pc.onTrack = (event) {
      if (event.streams.isEmpty) return;
      _remote[peerId] = event.streams.first;
      remoteStreams.value = Map.of(_remote);
    };
    pc.onConnectionState = (state) {
      debugPrint('[RLINK][GroupCall] $peerId pc state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _dropPeer(peerId);
      }
    };
    return pc;
  }

  /// Connects to [peerId] if we don't already have a link — the offerer/
  /// answerer role is a pure function of both ids, so both ends agree
  /// without talking first (see class doc).
  Future<void> _maybeConnectTo(String peerId) async {
    if (peerId == _myId || _pcs.containsKey(peerId)) return;
    final pc = await _createPeerConnectionFor(peerId);
    _pcs[peerId] = pc;
    final iOffer = _myId.compareTo(peerId) < 0;
    if (iOffer) {
      final offer = await pc.createOffer(_offerAnswerConstraints());
      await pc.setLocalDescription(offer);
      final local = await pc.getLocalDescription();
      await _send(peerId, 'offer', {
        'sdp': local?.sdp ?? offer.sdp,
        'type': local?.type ?? offer.type,
      });
    }
  }

  Future<void> _flushPendingIce(String peerId) async {
    final list = _pendingIce.remove(peerId);
    if (list == null) return;
    final pc = _pcs[peerId];
    if (pc == null) return;
    for (final d in list) {
      final candidate = d['candidate'] as String?;
      if (candidate == null) continue;
      try {
        await pc.addCandidate(RTCIceCandidate(
          candidate,
          d['sdpMid'] as String?,
          (d['sdpMLineIndex'] as num?)?.toInt(),
        ));
      } catch (_) {}
    }
  }

  Future<void> _broadcastRoster() async {
    final ids = _known.toList();
    for (final id in _known) {
      if (id == _myId) continue;
      unawaited(_send(id, 'roster', {'ids': ids}));
    }
  }

  void _dropPeer(String peerId) {
    final pc = _pcs.remove(peerId);
    unawaited(pc?.close());
    _remote.remove(peerId);
    _known.remove(peerId);
    _pendingIce.remove(peerId);
    remoteStreams.value = Map.of(_remote);
    participantIds.value = _known.toList();
    if (_known.length <= 1 && isActive) {
      // Everyone else left.
      unawaited(leaveCall());
    }
  }

  /// [memberIds] should be the group's other members you want to ring —
  /// typically all of them; the caller decides.
  Future<void> startGroupCall({
    required String groupId,
    required List<String> memberIds,
    required bool video,
  }) async {
    if (isActive) throw StateError('busy');
    final myId = _myId;
    if (myId.isEmpty) throw StateError('no_identity');
    _groupCallId = _uuid.v4();
    _groupId = groupId;
    _videoEnabled = video;
    cameraEnabled.value = video;
    micEnabled.value = true;
    _known
      ..clear()
      ..add(myId);
    participantIds.value = [myId];
    phase.value = GroupCallPhase.ringing;
    try {
      await _ensureLocalStream();
    } catch (e) {
      phase.value = GroupCallPhase.idle;
      _groupCallId = null;
      _groupId = null;
      rethrow;
    }
    phase.value = GroupCallPhase.active;
    for (final m in memberIds.where((m) => m != myId).toSet()) {
      unawaited(_send(m, 'invite', {'groupId': groupId, 'video': video}));
    }
  }

  Future<void> acceptInvite() async {
    final invite = incomingInvite.value;
    if (invite == null || isActive) return;
    incomingInvite.value = null;
    _groupCallId = invite.groupCallId;
    _groupId = invite.groupId;
    _videoEnabled = invite.video;
    cameraEnabled.value = invite.video;
    micEnabled.value = true;
    final myId = _myId;
    _known
      ..clear()
      ..add(myId);
    participantIds.value = [myId];
    try {
      await _ensureLocalStream();
    } catch (e) {
      _groupCallId = null;
      _groupId = null;
      return;
    }
    phase.value = GroupCallPhase.active;
    await _send(invite.fromId, 'accept', {});
  }

  Future<void> declineInvite() async {
    final invite = incomingInvite.value;
    if (invite == null) return;
    incomingInvite.value = null;
    final x = await _x25519For(invite.fromId);
    if (x == null || x.isEmpty) return;
    await GossipRouter.instance.sendGroupCallSignal(
      fromId: _myId,
      recipientId: invite.fromId,
      groupCallId: invite.groupCallId,
      signalType: 'decline',
      recipientX25519KeyBase64: x,
    );
  }

  Future<void> toggleMic(bool enabled) async {
    micEnabled.value = enabled;
    for (final t
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  Future<void> toggleCamera(bool enabled) async {
    cameraEnabled.value = enabled;
    for (final t
        in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  Future<void> leaveCall() async {
    if (!isActive) return;
    final others = _known.where((id) => id != _myId).toList();
    for (final id in others) {
      unawaited(_send(id, 'leave'));
    }
    for (final pc in _pcs.values) {
      unawaited(pc.close());
    }
    _pcs.clear();
    _pendingIce.clear();
    _remote.clear();
    _known.clear();
    final local = _localStream;
    if (local != null) {
      for (final t in local.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await local.dispose();
      } catch (_) {}
    }
    _localStream = null;
    localStreamNotifier.value = null;
    remoteStreams.value = const {};
    participantIds.value = const [];
    _groupCallId = null;
    _groupId = null;
    phase.value = GroupCallPhase.idle;
  }

  Future<void> _onSignal(
    String fromId,
    String groupCallId,
    String signalType,
    Map<String, dynamic> data,
  ) async {
    if (signalType == 'invite') {
      if (isActive) {
        final x = await _x25519For(fromId);
        if (x != null && x.isNotEmpty) {
          unawaited(GossipRouter.instance.sendGroupCallSignal(
            fromId: _myId,
            recipientId: fromId,
            groupCallId: groupCallId,
            signalType: 'decline',
            recipientX25519KeyBase64: x,
          ));
        }
        return;
      }
      final groupId = data['groupId'] as String?;
      if (groupId == null) return;
      incomingInvite.value = GroupCallInvite(
        groupCallId: groupCallId,
        groupId: groupId,
        fromId: fromId,
        video: data['video'] as bool? ?? true,
      );
      return;
    }

    if (_groupCallId != groupCallId) return;

    switch (signalType) {
      case 'accept':
        _known.add(fromId);
        participantIds.value = _known.toList();
        unawaited(_maybeConnectTo(fromId));
        unawaited(_broadcastRoster());
        break;
      case 'decline':
        break;
      case 'roster':
        final ids = (data['ids'] as List?)?.cast<String>() ?? const [];
        for (final id in ids) {
          _known.add(id);
        }
        participantIds.value = _known.toList();
        for (final id in ids) {
          if (id != _myId) unawaited(_maybeConnectTo(id));
        }
        break;
      case 'offer':
        await _handleRemoteOffer(fromId, data);
        break;
      case 'answer':
        final pc = _pcs[fromId];
        if (pc != null) {
          final sdp = data['sdp'] as String?;
          final type = data['type'] as String?;
          if (sdp != null && type != null) {
            await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
            await _flushPendingIce(fromId);
          }
        }
        break;
      case 'ice':
        await _handleRemoteIce(fromId, data);
        break;
      case 'leave':
        _dropPeer(fromId);
        break;
    }
  }

  Future<void> _handleRemoteOffer(
      String fromId, Map<String, dynamic> data) async {
    var pc = _pcs[fromId];
    if (pc == null) {
      pc = await _createPeerConnectionFor(fromId);
      _pcs[fromId] = pc;
      _known.add(fromId);
      participantIds.value = _known.toList();
    }
    final sdp = data['sdp'] as String?;
    final type = data['type'] as String?;
    if (sdp == null || type == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    await _flushPendingIce(fromId);
    final answer = await pc.createAnswer(_offerAnswerConstraints());
    await pc.setLocalDescription(answer);
    final local = await pc.getLocalDescription();
    await _send(fromId, 'answer', {
      'sdp': local?.sdp ?? answer.sdp,
      'type': local?.type ?? answer.type,
    });
  }

  Future<void> _handleRemoteIce(
      String fromId, Map<String, dynamic> data) async {
    final pc = _pcs[fromId];
    if (pc == null || await pc.getRemoteDescription() == null) {
      _pendingIce.putIfAbsent(fromId, () => []).add(data);
      return;
    }
    final candidate = data['candidate'] as String?;
    if (candidate == null) return;
    try {
      await pc.addCandidate(RTCIceCandidate(
        candidate,
        data['sdpMid'] as String?,
        (data['sdpMLineIndex'] as num?)?.toInt(),
      ));
    } catch (_) {}
  }
}
