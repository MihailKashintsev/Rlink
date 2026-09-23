import 'dart:async';

import 'package:flutter/foundation.dart';

/// Max people in one call room — mesh (everyone <-> everyone) stops being
/// comfortable beyond this.
const int kMaxCallParticipants = 5;

/// A call room. Group rooms are deterministic per (group, topic) so every
/// member maps the same chat/topic to the same room and two people starting at
/// once merge instead of forking; ad-hoc rooms (started from a DM) get a
/// random id and are invite-only.
class GroupCallRoomInfo {
  final String roomId;
  final String? groupId;
  final String? topicId;
  final String creatorId;

  /// Full 64-hex ids when we know them, 8-char prefixes when the info came
  /// from a group broadcast (resolved against the group's member list on join).
  final List<String> participants;
  final bool video;
  final int updatedAtMs;

  const GroupCallRoomInfo({
    required this.roomId,
    this.groupId,
    this.topicId,
    required this.creatorId,
    required this.participants,
    required this.video,
    required this.updatedAtMs,
  });

  bool get isGroupRoom => groupId != null;

  static String groupRoomId(String groupId, String? topicId) =>
      'g|$groupId|${topicId ?? ''}';

  GroupCallRoomInfo copyWith({
    List<String>? participants,
    bool? video,
    String? creatorId,
  }) =>
      GroupCallRoomInfo(
        roomId: roomId,
        groupId: groupId,
        topicId: topicId,
        creatorId: creatorId ?? this.creatorId,
        participants: participants ?? this.participants,
        video: video ?? this.video,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
}

/// Active group-call rooms we've heard about, for the "join the call" banner.
/// Entries expire unless refreshed by the room's periodic announcements.
class GroupCallDirectory {
  GroupCallDirectory._();
  static final GroupCallDirectory instance = GroupCallDirectory._();

  static const Duration ttl = Duration(seconds: 90);

  final Map<String, GroupCallRoomInfo> _rooms = {};
  final ValueNotifier<int> version = ValueNotifier<int>(0);
  Timer? _pruneTimer;

  void _bump() => version.value++;

  GroupCallRoomInfo? byId(String roomId) {
    _prune();
    return _rooms[roomId];
  }

  GroupCallRoomInfo? forGroup(String groupId, String? topicId) =>
      byId(GroupCallRoomInfo.groupRoomId(groupId, topicId));

  /// Returns true if this room wasn't known before. The creator of an
  /// existing entry is kept: first announcement wins, so a later participant
  /// can't claim the starter's role by announcing itself as creator.
  bool upsert(GroupCallRoomInfo info) {
    final prev = _rooms[info.roomId];
    _rooms[info.roomId] =
        prev == null ? info : info.copyWith(creatorId: prev.creatorId);
    _pruneTimer ??=
        Timer.periodic(const Duration(seconds: 20), (_) => _prune());
    _bump();
    return prev == null;
  }

  void remove(String roomId) {
    if (_rooms.remove(roomId) != null) _bump();
  }

  void _prune() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final before = _rooms.length;
    _rooms.removeWhere((_, r) => now - r.updatedAtMs > ttl.inMilliseconds);
    if (_rooms.length != before) _bump();
    if (_rooms.isEmpty) {
      _pruneTimer?.cancel();
      _pruneTimer = null;
    }
  }
}
