import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'group_call_directory.dart';
import 'group_service.dart';
import 'notification_service.dart';
import 'relay_service.dart';
import 'screen_share_helper.dart';
import 'webrtc_ice_config.dart';
import '../l10n/app_l10n.dart';

enum GroupCallPhase { idle, active }

class GroupCallInvite {
  final GroupCallRoomInfo room;
  final String fromId;

  const GroupCallInvite({required this.room, required this.fromId});
}

class CallParticipant {
  final String id;
  final bool muted;
  final bool cameraOn;

  /// When this participant started sharing their screen (ms), 0 = not sharing.
  /// A number rather than a flag so the stage can prefer the newest sharer.
  final int screenSince;
  final bool speaking;
  final bool connected;

  const CallParticipant({
    required this.id,
    this.muted = false,
    this.cameraOn = false,
    this.screenSince = 0,
    this.speaking = false,
    this.connected = false,
  });

  bool get screenSharing => screenSince > 0;
  bool get hasVideo => cameraOn || screenSharing;

  CallParticipant copyWith({
    bool? muted,
    bool? cameraOn,
    int? screenSince,
    bool? speaking,
    bool? connected,
  }) =>
      CallParticipant(
        id: id,
        muted: muted ?? this.muted,
        cameraOn: cameraOn ?? this.cameraOn,
        screenSince: screenSince ?? this.screenSince,
        speaking: speaking ?? this.speaking,
        connected: connected ?? this.connected,
      );
}

class CallReaction {
  final String from;
  final String emoji;
  final int at;
  const CallReaction(this.from, this.emoji, this.at);
}

/// Mesh group calls: every participant holds a direct [RTCPeerConnection] to
/// every other participant (no media server), up to [kMaxCallParticipants].
/// A separate, simpler service from [CallService] — it shares no state with
/// 1:1 calls, so it can't regress them.
///
/// Rooms. A group room is deterministic per (group, topic): each topic of a
/// group is its own call, and everybody derives the same id. Ad-hoc rooms
/// (started from a DM) are invite-only. Members of a group find a live room
/// through a periodic `group_call_state` broadcast (see [GroupCallDirectory])
/// and join by tapping the banner in the chat.
///
/// Joining is coordinator-free: the joiner sends `join` to everyone it knows
/// is there; each of them adds it, connects, and replies with `roster` (who
/// else it knows). The joiner then `join`s anyone new from those rosters. Who
/// sends the SDP offer for a pair is decided by comparing public keys (lower
/// one offers) — identical on both ends, so there's no glare and no extra
/// round trip. Video always uses a pre-negotiated transceiver, so camera and
/// screen share start/stop via `replaceTrack` with no renegotiation.
///
/// Admin (kick / force-mute / force-video-off): the room's starter, or a
/// moderator/creator of the group for group rooms. Enforced by the *target*,
/// which re-checks the sender. The "starter" is whoever's announcement
/// reached you first, so it's a convenience, not a hard guarantee — group
/// moderator rights, which are verified against the group itself, are.
class GroupCallService {
  GroupCallService._();
  static final GroupCallService instance = GroupCallService._();
  final _uuid = const Uuid();

  final ValueNotifier<GroupCallPhase> phase =
      ValueNotifier(GroupCallPhase.idle);
  final ValueNotifier<GroupCallRoomInfo?> room = ValueNotifier(null);
  final ValueNotifier<GroupCallInvite?> incomingInvite = ValueNotifier(null);
  final ValueNotifier<Map<String, CallParticipant>> participants =
      ValueNotifier(const {});
  final ValueNotifier<Map<String, MediaStream>> remoteStreams =
      ValueNotifier(const {});
  final ValueNotifier<MediaStream?> localStreamNotifier = ValueNotifier(null);
  final ValueNotifier<MediaStream?> screenStreamNotifier = ValueNotifier(null);
  final ValueNotifier<bool> micEnabled = ValueNotifier(true);
  final ValueNotifier<bool> cameraEnabled = ValueNotifier(false);
  final ValueNotifier<bool> screenSharing = ValueNotifier(false);
  final ValueNotifier<String?> activeSpeaker = ValueNotifier(null);
  final ValueNotifier<bool> canAdminister = ValueNotifier(false);

  /// Header for the call screen / return pill (group name for group rooms).
  final ValueNotifier<String> roomTitle = ValueNotifier(AppL10n.t('Звонок'));

  /// True while the call screen is on top; the app-wide "return to call"
  /// pill hides itself then.
  final ValueNotifier<bool> screenOpen = ValueNotifier(false);

  final StreamController<CallReaction> _reactions =
      StreamController<CallReaction>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  Stream<CallReaction> get reactions => _reactions.stream;

  /// One-line user-facing events ("you were removed", "room is full", ...).
  Stream<String> get notices => _notices.stream;

  bool _videoWanted = false;
  MediaStream? _localStream;
  MediaStream? _screenStream;
  final Set<String> _known = {};
  final Set<String> _kicked = {};
  final Map<String, Future<RTCPeerConnection>> _pcFutures = {};
  final Map<String, RTCPeerConnection> _pcs = {};
  final Map<String, RTCRtpSender> _videoSenders = {};
  final Map<String, MediaStream> _remote = {};
  final Map<String, List<Map<String, dynamic>>> _pendingIce = {};
  Timer? _statsTimer;
  Timer? _announceTimer;
  String? _speakerCandidate;
  int _speakerCandidateSince = 0;
  int _speakerLastSpokeAt = 0;
  int _lastReactionSentAt = 0;

  String get _myId => CryptoService.instance.publicKeyHex;
  bool get isActive => phase.value != GroupCallPhase.idle;
  bool get isVideoRoom => room.value?.video ?? false;
  String? get _roomId => room.value?.roomId;

  void bindSignaling() {
    GossipRouter.instance.onGroupCallSignal = _onSignal;
    GossipRouter.instance.onGroupCallState = (p) => unawaited(_onState(p));
  }

  // ── entry points ────────────────────────────────────────────────────────

  /// Starts the call for a group topic, or joins it if one is already live.
  Future<void> startOrJoinGroupRoom({
    required String groupId,
    String? topicId,
    required bool video,
  }) async {
    final tid = (topicId == null || topicId.isEmpty) ? null : topicId;
    final existing = GroupCallDirectory.instance.forGroup(groupId, tid);
    if (existing != null) {
      await joinRoom(existing, video: video);
      return;
    }
    await _enter(
      GroupCallRoomInfo(
        roomId: GroupCallRoomInfo.groupRoomId(groupId, tid),
        groupId: groupId,
        topicId: tid,
        creatorId: _myId,
        participants: [_myId],
        video: video,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
      video: video,
    );
  }

  /// Starts an invite-only room from a regular chat and rings [peerId];
  /// more people can be invited from inside the call.
  Future<void> startAdHocRoom({
    required String peerId,
    required bool video,
  }) async {
    await _enter(
      GroupCallRoomInfo(
        roomId: 'a|${_uuid.v4()}',
        creatorId: _myId,
        participants: [_myId],
        video: video,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
      video: video,
    );
    await inviteMember(peerId);
  }

  Future<void> joinRoom(GroupCallRoomInfo info, {bool? video}) async {
    final ids = await _resolveParticipants(info);
    if (ids.length >= kMaxCallParticipants) {
      _notices.add(AppL10n.f('Комната заполнена (до {0} человек)', [kMaxCallParticipants]));
      throw StateError('full');
    }
    await _enter(info, video: video ?? info.video, connectTo: ids);
  }

  Future<void> acceptInvite() async {
    final invite = incomingInvite.value;
    if (invite == null || isActive) return;
    incomingInvite.value = null;
    try {
      await joinRoom(invite.room);
    } catch (_) {}
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
      groupCallId: invite.room.roomId,
      signalType: 'decline',
      recipientX25519KeyBase64: x,
    );
  }

  Future<void> _enter(
    GroupCallRoomInfo info, {
    required bool video,
    List<String> connectTo = const [],
  }) async {
    if (isActive) throw StateError('busy');
    final me = _myId;
    if (me.isEmpty) throw StateError('no_identity');
    _videoWanted = video;
    _kicked.clear();
    _known
      ..clear()
      ..add(me);
    micEnabled.value = true;
    cameraEnabled.value = video;
    screenSharing.value = false;
    room.value = info;
    roomTitle.value = info.isGroupRoom ? AppL10n.t('Групповой звонок') : AppL10n.t('Звонок');
    if (info.groupId != null) {
      unawaited(GroupService.instance.getGroup(info.groupId!).then((g) {
        if (g != null && room.value?.roomId == info.roomId) {
          roomTitle.value = g.name;
        }
      }));
    }
    participants.value = {
      me: CallParticipant(id: me, cameraOn: video, connected: true),
    };
    try {
      await _ensureLocalStream();
    } catch (e) {
      room.value = null;
      participants.value = const {};
      rethrow;
    }
    phase.value = GroupCallPhase.active;
    unawaited(_computeAdmin());
    _statsTimer =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _pollLevels());
    _announceTimer =
        Timer.periodic(const Duration(seconds: 25), (_) => _announce());
    for (final id in connectTo.where((i) => i != me)) {
      unawaited(_send(id, 'join', {'s': _myStatus()}));
    }
    _announce();
  }

  Future<List<String>> _resolveParticipants(GroupCallRoomInfo info) async {
    final me = _myId;
    final out = <String>{};
    List<String> members = const [];
    if (info.groupId != null) {
      members =
          (await GroupService.instance.getGroup(info.groupId!))?.memberIds ??
              const [];
    }
    for (final p in info.participants) {
      if (p == me) continue;
      if (p.length >= 64) {
        out.add(p);
      } else {
        final m = members.where((id) => id.startsWith(p)).firstOrNull;
        if (m != null) out.add(m);
      }
    }
    return out.toList();
  }

  // ── signaling ───────────────────────────────────────────────────────────

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
    final rid = _roomId;
    if (rid == null) return;
    final x = await _x25519For(to);
    if (x == null || x.isEmpty) {
      debugPrint('[RLINK][GroupCall] no x25519 for $to, dropping $signalType');
      return;
    }
    await GossipRouter.instance.sendGroupCallSignal(
      fromId: _myId,
      recipientId: to,
      groupCallId: rid,
      signalType: signalType,
      recipientX25519KeyBase64: x,
      payload: payload,
    );
  }

  Future<void> _sendToAll(String signalType,
      [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    for (final id in _known.where((i) => i != _myId).toList()) {
      unawaited(_send(id, signalType, payload));
    }
  }

  Map<String, dynamic> _myStatus() {
    final p = participants.value[_myId];
    return {
      'm': (p?.muted ?? false) ? 1 : 0,
      'c': (p?.cameraOn ?? false) ? 1 : 0,
      's': p?.screenSince ?? 0,
    };
  }

  void _pushStatus() => unawaited(_sendToAll('status', _myStatus()));

  Future<void> inviteMember(String peerId) async {
    final r = room.value;
    if (r == null || peerId == _myId) return;
    await _send(peerId, 'invite', {
      if (r.groupId != null) 'g': r.groupId,
      if (r.topicId != null) 't': r.topicId,
      'cr': r.creatorId,
      'v': r.video,
      'ps': _known.toList(),
    });
  }

  Future<void> _onSignal(
    String fromId,
    String roomId,
    String signalType,
    Map<String, dynamic> data,
  ) async {
    try {
      await _handleSignal(fromId, roomId, signalType, data);
    } catch (e, st) {
      debugPrint('[RLINK][GroupCall] $signalType from $fromId failed: $e\n$st');
    }
  }

  Future<void> _handleSignal(
    String fromId,
    String roomId,
    String signalType,
    Map<String, dynamic> data,
  ) async {
    if (signalType == 'invite') {
      if (roomId == _roomId) return;
      if (isActive) {
        await _declineTo(fromId, roomId);
        return;
      }
      final info = GroupCallRoomInfo(
        roomId: roomId,
        groupId: data['g'] as String?,
        topicId: data['t'] as String?,
        creatorId: (data['cr'] as String?) ?? fromId,
        participants: (data['ps'] as List?)?.cast<String>() ?? [fromId],
        video: data['v'] as bool? ?? false,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      incomingInvite.value = GroupCallInvite(room: info, fromId: fromId);
      return;
    }

    if (roomId != _roomId) return;

    switch (signalType) {
      case 'join':
        if (_kicked.contains(fromId)) return;
        if (!_known.contains(fromId) && _known.length >= kMaxCallParticipants) {
          unawaited(_send(fromId, 'full'));
          return;
        }
        _addPeer(fromId, data['s']);
        unawaited(_maybeConnectTo(fromId));
        unawaited(_send(fromId, 'roster', {
          'ids': _known.toList(),
          's': _myStatus(),
        }));
        _announce();
        break;
      case 'roster':
        if (_kicked.contains(fromId)) return;
        _addPeer(fromId, data['s']);
        unawaited(_maybeConnectTo(fromId));
        final ids = (data['ids'] as List?)?.cast<String>() ?? const [];
        for (final id in ids) {
          if (id == _myId || _known.contains(id) || _kicked.contains(id)) {
            continue;
          }
          if (_known.length >= kMaxCallParticipants) break;
          unawaited(_send(id, 'join', {'s': _myStatus()}));
        }
        break;
      case 'full':
        if (_known.length <= 1) {
          _notices.add(AppL10n.f('Комната заполнена (до {0} человек)', [kMaxCallParticipants]));
          await leaveCall();
        }
        break;
      case 'decline':
        break;
      case 'offer':
        if (_kicked.contains(fromId)) return;
        await _handleRemoteOffer(fromId, data);
        break;
      case 'answer':
        final pc = _pcs[fromId];
        final sdp = data['sdp'] as String?;
        final type = data['type'] as String?;
        if (pc != null && sdp != null && type != null) {
          await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
          await _flushPendingIce(fromId);
        }
        break;
      case 'ice':
        await _handleRemoteIce(fromId, data);
        break;
      case 'status':
        if (_known.contains(fromId)) _applyStatus(fromId, data);
        break;
      case 'reaction':
        final emoji = data['e'] as String?;
        if (emoji != null && _known.contains(fromId)) {
          _reactions.add(CallReaction(
              fromId, emoji, DateTime.now().millisecondsSinceEpoch));
        }
        break;
      case 'leave':
        _dropPeer(fromId);
        _announce();
        break;
      case 'kick':
        await _onKick(fromId, data['t'] as String?);
        break;
      case 'forcemute':
        if (await _isAdmin(fromId)) {
          await toggleMic(false);
          _notices.add(AppL10n.t('Администратор выключил ваш микрофон'));
        }
        break;
      case 'forcevideo':
        if (await _isAdmin(fromId)) {
          if (screenSharing.value) await stopScreenShare();
          await toggleCamera(false);
          _notices.add(AppL10n.t('Администратор выключил вашу камеру'));
        }
        break;
    }
  }

  Future<void> _declineTo(String toId, String roomId) async {
    final x = await _x25519For(toId);
    if (x == null || x.isEmpty) return;
    unawaited(GossipRouter.instance.sendGroupCallSignal(
      fromId: _myId,
      recipientId: toId,
      groupCallId: roomId,
      signalType: 'decline',
      recipientX25519KeyBase64: x,
    ));
  }

  // ── room presence broadcast (group rooms only) ──────────────────────────

  Future<void> _onState(Map<String, dynamic> p) async {
    final gid = p['g'] as String?;
    final by = p['by'] as String?;
    final creator = p['cr'] as String?;
    if (gid == null || by == null || creator == null) return;
    final me = _myId;
    if (me.isEmpty || by == me) return;
    final group = await GroupService.instance.getGroup(gid);
    if (group == null ||
        !group.memberIds.contains(me) ||
        !group.memberIds.contains(by)) {
      return;
    }
    final tid = (p['t'] as String?)?.isEmpty ?? true ? null : p['t'] as String;
    final rid = GroupCallRoomInfo.groupRoomId(gid, tid);
    final dir = GroupCallDirectory.instance;

    if (p['e'] == true) {
      dir.remove(rid);
      return;
    }
    final prefixes = (p['p'] as List?)?.cast<String>() ?? const <String>[];
    if (prefixes.isEmpty) {
      dir.remove(rid);
      return;
    }
    final info = GroupCallRoomInfo(
      roomId: rid,
      groupId: gid,
      topicId: tid,
      creatorId: creator,
      participants: prefixes,
      video: p['v'] == true,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    if (rid == _roomId) {
      // Two people started the same room at once, or someone joined that we
      // haven't heard from — connect to anyone new so the halves merge.
      final ids = await _resolveParticipants(info);
      for (final id in ids) {
        if (!_known.contains(id) &&
            !_kicked.contains(id) &&
            _known.length < kMaxCallParticipants) {
          unawaited(_send(id, 'join', {'s': _myStatus()}));
        }
      }
      return;
    }

    final isNew = dir.upsert(info);
    if (isNew && !isActive) {
      unawaited(NotificationService.instance.showGroupMessage(
        groupId: gid,
        title: group.name,
        body: AppL10n.t('📞 Идёт групповой звонок'),
        color: group.avatarColor,
        imagePath: group.avatarImagePath,
        emoji: group.avatarEmoji.isNotEmpty ? group.avatarEmoji : '👥',
      ));
    }
  }

  /// The participant with the smallest key announces, so exactly one does and
  /// it hands over automatically when they leave.
  void _announce({bool ended = false, List<String>? remaining}) {
    final r = room.value;
    if (r == null || r.groupId == null) return;
    final me = _myId;
    final ids = remaining ?? (_known.toList()..sort());
    if (ids.isEmpty && !ended) return;
    if (!ended && remaining == null && ids.first != me) {
      // Not the announcer — still keep our own directory entry fresh so the
      // banner in our chat shows the live count.
      GroupCallDirectory.instance
          .upsert(r.copyWith(participants: _known.toList()));
      return;
    }
    GroupCallDirectory.instance.upsert(r.copyWith(participants: ids));
    unawaited(GossipRouter.instance.sendGroupCallState(
      groupId: r.groupId!,
      topicId: r.topicId,
      creatorId: r.creatorId,
      announcerId: me,
      participantPrefixes:
          ids.map((e) => e.substring(0, e.length.clamp(0, 8))).toList(),
      video: r.video,
      ended: ended,
    ));
  }

  // ── peers & media ───────────────────────────────────────────────────────

  void _addPeer(String id, Object? status) {
    if (id == _myId) return;
    _known.add(id);
    final map = Map<String, CallParticipant>.of(participants.value);
    map.putIfAbsent(id, () => CallParticipant(id: id));
    participants.value = map;
    if (status is Map) _applyStatus(id, status.cast<String, dynamic>());
  }

  void _applyStatus(String id, Map<String, dynamic> s) {
    _setPart(id, (p) => p.copyWith(
          muted: (s['m'] as num?) == 1 ? true : ((s['m'] as num?) == 0 ? false : null),
          cameraOn: (s['c'] as num?) == 1 ? true : ((s['c'] as num?) == 0 ? false : null),
          screenSince: (s['s'] as num?)?.toInt(),
        ));
  }

  void _setPart(String id, CallParticipant Function(CallParticipant) f) {
    final cur = participants.value[id];
    if (cur == null) return;
    final next = f(cur);
    if (next.muted == cur.muted &&
        next.cameraOn == cur.cameraOn &&
        next.screenSince == cur.screenSince &&
        next.speaking == cur.speaking &&
        next.connected == cur.connected) {
      return;
    }
    participants.value = {...participants.value, id: next};
  }

  Future<void> _ensureLocalStream() async {
    if (_localStream != null) return;
    try {
      final media = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': _videoWanted,
      });
      _localStream = media;
      localStreamNotifier.value = media;
      return;
    } catch (e) {
      debugPrint('[RLINK][GroupCall] getUserMedia failed: $e');
    }
    if (_videoWanted) {
      try {
        final media = await navigator.mediaDevices
            .getUserMedia({'audio': true, 'video': false});
        _videoWanted = false;
        cameraEnabled.value = false;
        _setPart(_myId, (p) => p.copyWith(cameraOn: false));
        _localStream = media;
        localStreamNotifier.value = media;
        return;
      } catch (e) {
        debugPrint('[RLINK][GroupCall] audio-only fallback failed: $e');
      }
    }
    throw StateError('media_init_failed');
  }

  MediaStreamTrack? get _cameraTrack =>
      _localStream?.getVideoTracks().firstOrNull;

  Future<RTCPeerConnection> _pcFor(String peerId) {
    final existing = _pcFutures[peerId];
    if (existing != null) return existing;
    final f = _createPeerConnectionFor(peerId).then((pc) {
      _pcs[peerId] = pc;
      return pc;
    });
    _pcFutures[peerId] = f;
    return f;
  }

  Future<RTCPeerConnection> _createPeerConnectionFor(String peerId) async {
    final pc = await createPeerConnection(webrtcIceConfig());
    final local = _localStream;
    if (local != null) {
      for (final t in local.getAudioTracks()) {
        await pc.addTrack(t, local);
      }
    }
    // Video is always negotiated (even in an audio room) so camera / screen
    // share can start later with replaceTrack and no renegotiation.
    final vtrack = _screenStream?.getVideoTracks().firstOrNull ?? _cameraTrack;
    final init = RTCRtpTransceiverInit(
      direction: TransceiverDirection.SendRecv,
      streams: local != null ? [local] : null,
    );
    final tr = vtrack != null
        ? await pc.addTransceiver(track: vtrack, init: init)
        : await pc.addTransceiver(
            kind: RTCRtpMediaType.RTCRtpMediaTypeVideo, init: init);
    _videoSenders[peerId] = tr.sender;
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      unawaited(_send(peerId, 'ice', {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      }));
    };
    pc.onTrack = (event) {
      unawaited(_attachRemoteTrack(peerId, event));
    };
    pc.onConnectionState = (state) {
      debugPrint('[RLINK][GroupCall] $peerId pc state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setPart(peerId, (p) => p.copyWith(connected: true));
        // Late joiner may have missed our status — tell them now.
        unawaited(_send(peerId, 'status', _myStatus()));
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _setPart(peerId, (p) => p.copyWith(connected: false));
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _dropPeer(peerId);
        _announce();
      }
    };
    return pc;
  }

  Future<void> _attachRemoteTrack(String peerId, RTCTrackEvent event) async {
    MediaStream? stream =
        event.streams.isNotEmpty ? event.streams.first : _remote[peerId];
    stream ??= await createLocalMediaStream('remote_$peerId');
    if (event.streams.isEmpty &&
        !stream.getTracks().any((t) => t.id == event.track.id)) {
      await stream.addTrack(event.track);
    }
    _remote[peerId] = stream;
    remoteStreams.value = Map.of(_remote);
  }

  /// Connects to [peerId] if we don't already have a link. Only the first
  /// caller creates the connection, and only the lower key sends the offer.
  Future<void> _maybeConnectTo(String peerId) async {
    if (peerId == _myId || _roomId == null) return;
    final fresh = !_pcFutures.containsKey(peerId);
    try {
      final pc = await _pcFor(peerId);
      if (!fresh) return;
      if (_myId.compareTo(peerId) < 0) {
        final offer = await pc.createOffer(<String, dynamic>{});
        await pc.setLocalDescription(offer);
        final local = await pc.getLocalDescription();
        await _send(peerId, 'offer', {
          'sdp': local?.sdp ?? offer.sdp,
          'type': local?.type ?? offer.type,
        });
      }
    } catch (e) {
      debugPrint('[RLINK][GroupCall] connect to $peerId failed: $e');
      _dropPeer(peerId);
    }
  }

  Future<void> _handleRemoteOffer(
      String fromId, Map<String, dynamic> data) async {
    if (!_known.contains(fromId)) {
      if (_known.length >= kMaxCallParticipants) {
        unawaited(_send(fromId, 'full'));
        return;
      }
      _addPeer(fromId, null);
    }
    final pc = await _pcFor(fromId);
    final sdp = data['sdp'] as String?;
    final type = data['type'] as String?;
    if (sdp == null || type == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    await _flushPendingIce(fromId);
    final answer = await pc.createAnswer(<String, dynamic>{});
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
    await _addCandidate(pc, data);
  }

  Future<void> _flushPendingIce(String peerId) async {
    final list = _pendingIce.remove(peerId);
    final pc = _pcs[peerId];
    if (list == null || pc == null) return;
    for (final d in list) {
      await _addCandidate(pc, d);
    }
  }

  Future<void> _addCandidate(
      RTCPeerConnection pc, Map<String, dynamic> d) async {
    final candidate = d['candidate'] as String?;
    if (candidate == null) return;
    try {
      await pc.addCandidate(RTCIceCandidate(
        candidate,
        d['sdpMid'] as String?,
        (d['sdpMLineIndex'] as num?)?.toInt(),
      ));
    } catch (_) {}
  }

  void _dropPeer(String peerId) {
    final pc = _pcs.remove(peerId);
    _pcFutures.remove(peerId);
    _videoSenders.remove(peerId);
    if (pc != null) unawaited(pc.close());
    _remote.remove(peerId);
    _pendingIce.remove(peerId);
    _known.remove(peerId);
    remoteStreams.value = Map.of(_remote);
    final map = Map<String, CallParticipant>.of(participants.value)
      ..remove(peerId);
    participants.value = map;
    if (activeSpeaker.value == peerId) activeSpeaker.value = null;
  }

  // ── speaking detection ──────────────────────────────────────────────────

  static double _level(Object? v) {
    final d = double.tryParse('$v') ?? 0;
    return d > 1 ? d / 32768 : d;
  }

  bool _polling = false;

  Future<void> _pollLevels() async {
    if (_polling || !isActive || _pcs.isEmpty) return;
    _polling = true;
    try {
      final levels = <String, double>{};
      double local = 0;
      for (final e in _pcs.entries.toList()) {
        List<StatsReport> stats;
        try {
          stats = await e.value.getStats();
        } catch (_) {
          continue;
        }
        for (final r in stats) {
          final kind = '${r.values['kind'] ?? r.values['mediaType']}';
          if (kind != 'audio') continue;
          if (r.type == 'inbound-rtp') {
            final l = _level(r.values['audioLevel']);
            if (l > (levels[e.key] ?? 0)) levels[e.key] = l;
          } else if (r.type == 'media-source') {
            final l = _level(r.values['audioLevel']);
            if (l > local) local = l;
          }
        }
      }
      if (!isActive) return;
      levels[_myId] = micEnabled.value ? local : 0;
      const threshold = 0.02;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final id in participants.value.keys.toList()) {
        final speaking = (levels[id] ?? 0) > threshold &&
            !(participants.value[id]?.muted ?? false);
        _setPart(id, (p) => p.copyWith(speaking: speaking));
      }
      _updateActiveSpeaker(levels, now, threshold);
    } finally {
      _polling = false;
    }
  }

  /// Sticky: a new speaker has to be loudest for ~0.8s to take over, and the
  /// current one keeps the spot for 2s of silence — the stage doesn't flicker
  /// on every cough.
  void _updateActiveSpeaker(
      Map<String, double> levels, int now, double threshold) {
    String? top;
    var best = threshold;
    levels.forEach((id, l) {
      if (id == _myId) return; // the stage shows others, not yourself
      if (l > best) {
        best = l;
        top = id;
      }
    });
    final current = activeSpeaker.value;
    if (current != null && (levels[current] ?? 0) > threshold) {
      _speakerLastSpokeAt = now;
    }
    if (top == null) {
      if (current != null && now - _speakerLastSpokeAt > 2000) {
        activeSpeaker.value = null;
      }
      _speakerCandidate = null;
      return;
    }
    if (top == current) {
      _speakerCandidate = null;
      return;
    }
    if (_speakerCandidate != top) {
      _speakerCandidate = top;
      _speakerCandidateSince = now;
    }
    if (current == null || now - _speakerCandidateSince > 800) {
      activeSpeaker.value = top;
      _speakerLastSpokeAt = now;
      _speakerCandidate = null;
    }
  }

  // ── controls ────────────────────────────────────────────────────────────

  Future<void> toggleMic(bool enabled) async {
    micEnabled.value = enabled;
    for (final t
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
    _setPart(_myId, (p) => p.copyWith(muted: !enabled));
    _pushStatus();
  }

  Future<void> toggleCamera(bool enabled) async {
    if (enabled && _cameraTrack == null) {
      try {
        final media =
            await navigator.mediaDevices.getUserMedia({'video': true});
        final track = media.getVideoTracks().first;
        final local = _localStream ??= await createLocalMediaStream('local');
        await local.addTrack(track);
        localStreamNotifier.value = null;
        localStreamNotifier.value = local;
        if (!screenSharing.value) {
          for (final s in _videoSenders.values) {
            await s.replaceTrack(track);
          }
        }
      } catch (e) {
        debugPrint('[RLINK][GroupCall] camera start failed: $e');
        _notices.add(AppL10n.t('Не удалось включить камеру'));
        return;
      }
    }
    for (final t
        in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
    cameraEnabled.value = enabled;
    _setPart(_myId, (p) => p.copyWith(cameraOn: enabled));
    _pushStatus();
  }

  Future<void> switchCamera() async {
    final t = _cameraTrack;
    if (t == null) return;
    await Helper.switchCamera(t);
  }

  Future<void> startScreenShare() async {
    if (!isActive || screenSharing.value) return;
    MediaStream? stream;
    try {
      stream = await ScreenShareHelper.start();
    } catch (e) {
      debugPrint('[RLINK][GroupCall] screen share failed: $e');
    }
    final track = stream?.getVideoTracks().firstOrNull;
    if (stream == null || track == null) {
      if (stream != null) await ScreenShareHelper.stop(stream);
      _notices.add(AppL10n.t('Не удалось начать демонстрацию экрана'));
      return;
    }
    track.onEnded = () => unawaited(stopScreenShare());
    _screenStream = stream;
    screenStreamNotifier.value = stream;
    for (final s in _videoSenders.values) {
      await s.replaceTrack(track);
    }
    screenSharing.value = true;
    _setPart(_myId,
        (p) => p.copyWith(screenSince: DateTime.now().millisecondsSinceEpoch));
    _pushStatus();
  }

  Future<void> stopScreenShare() async {
    if (!screenSharing.value) return;
    screenSharing.value = false;
    final cam = _cameraTrack;
    for (final s in _videoSenders.values) {
      try {
        await s.replaceTrack(cam);
      } catch (_) {}
    }
    final stream = _screenStream;
    _screenStream = null;
    screenStreamNotifier.value = null;
    await ScreenShareHelper.stop(stream);
    _setPart(_myId, (p) => p.copyWith(screenSince: 0));
    _pushStatus();
  }

  void sendReaction(String emoji) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastReactionSentAt < 700) return;
    _lastReactionSentAt = now;
    _reactions.add(CallReaction(_myId, emoji, now));
    unawaited(_sendToAll('reaction', {'e': emoji}));
  }

  // ── admin ───────────────────────────────────────────────────────────────

  Future<bool> _isAdmin(String id) async {
    final r = room.value;
    if (r == null) return false;
    if (id == r.creatorId) return true;
    final gid = r.groupId;
    if (gid == null) return false;
    final g = await GroupService.instance.getGroup(gid);
    return g != null && g.canModerate(id);
  }

  Future<void> _computeAdmin() async {
    canAdminister.value = await _isAdmin(_myId);
  }

  Future<void> kick(String targetId) async {
    if (!canAdminister.value || targetId == _myId) return;
    // Everyone learns it (so nobody re-adds them); the target leaves.
    await _sendToAll('kick', {'t': targetId});
    _kicked.add(targetId);
    _dropPeer(targetId);
    _announce();
  }

  Future<void> forceMute(String targetId) async {
    if (!canAdminister.value) return;
    await _send(targetId, 'forcemute');
  }

  Future<void> forceVideoOff(String targetId) async {
    if (!canAdminister.value) return;
    await _send(targetId, 'forcevideo');
  }

  Future<void> _onKick(String fromId, String? target) async {
    if (target == null || !await _isAdmin(fromId)) return;
    if (target == _myId) {
      _notices.add(AppL10n.t('Вас исключили из звонка'));
      await leaveCall(notifyPeers: false);
      return;
    }
    _kicked.add(target);
    _dropPeer(target);
    _announce();
  }

  // ── leaving ─────────────────────────────────────────────────────────────

  Future<void> leaveCall({bool notifyPeers = true}) async {
    if (!isActive) return;
    final others = _known.where((id) => id != _myId).toList()..sort();
    final r = room.value;
    if (notifyPeers) {
      for (final id in others) {
        unawaited(_send(id, 'leave'));
      }
    }
    // Hand the announcement over / close the banner before state is wiped.
    if (r != null && r.groupId != null) {
      final wasAnnouncer = (_known.toList()..sort()).first == _myId;
      if (others.isEmpty) {
        _announce(ended: true, remaining: const []);
        GroupCallDirectory.instance.remove(r.roomId);
      } else if (wasAnnouncer) {
        _announce(remaining: others);
      }
    }
    _statsTimer?.cancel();
    _announceTimer?.cancel();
    _statsTimer = null;
    _announceTimer = null;
    if (screenSharing.value) {
      screenSharing.value = false;
      final stream = _screenStream;
      _screenStream = null;
      screenStreamNotifier.value = null;
      await ScreenShareHelper.stop(stream);
    }
    for (final pc in _pcs.values) {
      unawaited(pc.close());
    }
    _pcs.clear();
    _pcFutures.clear();
    _videoSenders.clear();
    _pendingIce.clear();
    _remote.clear();
    _known.clear();
    _kicked.clear();
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
    participants.value = const {};
    activeSpeaker.value = null;
    canAdminister.value = false;
    room.value = null;
    phase.value = GroupCallPhase.idle;
  }
}
