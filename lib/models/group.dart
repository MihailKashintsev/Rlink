import 'dart:convert';

/// Модель группового чата.
class Group {
  final String id; // UUID группы
  final String name;
  final String creatorId; // publicKeyHex создателя
  final List<String> memberIds; // publicKeyHex всех участников
  final List<String>
      moderatorIds; // publicKeyHex модераторов (могут всё, кроме удаления группы)
  // publicKeyHex участников без права писать — присутствуют и читают, но их
  // сообщения остальные клиенты молча игнорируют при приёме. Для ботов,
  // которым нужен доступ на чтение без права постить самостоятельно.
  final List<String> readOnlyIds;
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath;
  final int createdAt; // ms since epoch
  // История в Google Drive (как у каналов): публикуется создателем/модератором,
  // новые участники подтягивают её по публичным ссылкам.
  final bool driveBackupEnabled;
  final int driveBackupRev;
  final String? driveHistoryUrl;
  final String? driveKeysUrl;
  // Куда публикуется резерв: 'google' | 'onedrive' | 'dropbox'. Выбирает
  // модератор среди аккаунтов, привязанных лично у него — остальным
  // участникам достаточно публичной ссылки, от них ничего не требуется.
  final String backupProvider;

  const Group({
    required this.id,
    required this.name,
    required this.creatorId,
    required this.memberIds,
    this.moderatorIds = const [],
    this.readOnlyIds = const [],
    this.avatarColor = 0xFF5C6BC0,
    this.avatarEmoji = '👥',
    this.avatarImagePath,
    required this.createdAt,
    this.driveBackupEnabled = false,
    this.driveBackupRev = 0,
    this.driveHistoryUrl,
    this.driveKeysUrl,
    this.backupProvider = 'google',
  });

  /// Returns true if [userId] is an admin (creator) or moderator.
  bool canModerate(String userId) =>
      userId == creatorId || moderatorIds.contains(userId);

  /// False for a member explicitly muted via [readOnlyIds] — their own
  /// outgoing messages should be sent locally but ignored by everyone else
  /// on receipt (see main.dart's onGroupMessage).
  bool canPost(String userId) => !readOnlyIds.contains(userId);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'creator': creatorId,
        'members': memberIds,
        if (moderatorIds.isNotEmpty) 'mods': moderatorIds,
        if (readOnlyIds.isNotEmpty) 'ro': readOnlyIds,
        'color': avatarColor,
        'emoji': avatarEmoji,
        if (avatarImagePath != null) 'img': avatarImagePath,
        'ts': createdAt,
        if (driveBackupEnabled) 'drv': true,
        if (driveBackupRev > 0) 'drvRev': driveBackupRev,
        if (driveHistoryUrl != null) 'drvUrl': driveHistoryUrl,
        if (driveKeysUrl != null) 'drvKeys': driveKeysUrl,
        if (backupProvider != 'google') 'bp': backupProvider,
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: j['id'] as String,
        name: j['name'] as String,
        creatorId: j['creator'] as String,
        memberIds: (j['members'] as List).cast<String>(),
        moderatorIds:
            j['mods'] != null ? (j['mods'] as List).cast<String>() : const [],
        readOnlyIds:
            j['ro'] != null ? (j['ro'] as List).cast<String>() : const [],
        avatarColor: j['color'] as int? ?? 0xFF5C6BC0,
        avatarEmoji: j['emoji'] as String? ?? '👥',
        avatarImagePath: j['img'] as String?,
        createdAt: j['ts'] as int? ?? 0,
        driveBackupEnabled: j['drv'] == true,
        driveBackupRev: (j['drvRev'] as num?)?.toInt() ?? 0,
        driveHistoryUrl: j['drvUrl'] as String?,
        driveKeysUrl: j['drvKeys'] as String?,
        backupProvider: j['bp'] as String? ?? 'google',
      );

  String encode() => jsonEncode(toJson());

  static Group? tryDecode(String s) {
    try {
      return Group.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Group copyWith({
    String? name,
    List<String>? memberIds,
    List<String>? moderatorIds,
    List<String>? readOnlyIds,
    int? avatarColor,
    String? avatarEmoji,
    String? avatarImagePath,
    bool? driveBackupEnabled,
    int? driveBackupRev,
    String? driveHistoryUrl,
    String? driveKeysUrl,
    String? backupProvider,
  }) =>
      Group(
        id: id,
        name: name ?? this.name,
        creatorId: creatorId,
        memberIds: memberIds ?? this.memberIds,
        moderatorIds: moderatorIds ?? this.moderatorIds,
        readOnlyIds: readOnlyIds ?? this.readOnlyIds,
        avatarColor: avatarColor ?? this.avatarColor,
        avatarEmoji: avatarEmoji ?? this.avatarEmoji,
        avatarImagePath: avatarImagePath ?? this.avatarImagePath,
        createdAt: createdAt,
        driveBackupEnabled: driveBackupEnabled ?? this.driveBackupEnabled,
        driveBackupRev: driveBackupRev ?? this.driveBackupRev,
        driveHistoryUrl: driveHistoryUrl ?? this.driveHistoryUrl,
        driveKeysUrl: driveKeysUrl ?? this.driveKeysUrl,
        backupProvider: backupProvider ?? this.backupProvider,
      );
}

/// Сообщение в групповом чате.
class GroupMessage {
  final String id;
  final String groupId;
  final String senderId;
  final String text;
  final String? imagePath;
  final String? videoPath;
  final String? voicePath;
  final double? latitude;
  final double? longitude;
  final bool isOutgoing;
  final int timestamp;
  final Map<String, List<String>> reactions;
  final String? pollJson;
  final String? forwardFromId;
  final String? forwardFromNick;
  /// null = the (always-present) General thread — see [GroupTopic].
  final String? topicId;

  const GroupMessage({
    required this.id,
    required this.groupId,
    required this.senderId,
    this.text = '',
    this.imagePath,
    this.videoPath,
    this.voicePath,
    this.latitude,
    this.longitude,
    required this.isOutgoing,
    required this.timestamp,
    this.reactions = const {},
    this.pollJson,
    this.forwardFromId,
    this.forwardFromNick,
    this.topicId,
  });

  int get totalReactions {
    var n = 0;
    for (final list in reactions.values) {
      n += list.length;
    }
    return n;
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'group_id': groupId,
        'sender_id': senderId,
        'text': text,
        'image_path': imagePath,
        'video_path': videoPath,
        'voice_path': voicePath,
        'latitude': latitude,
        'longitude': longitude,
        'is_outgoing': isOutgoing ? 1 : 0,
        'timestamp': timestamp,
        'reactions': reactions.isEmpty ? null : jsonEncode(reactions),
        'poll_json': pollJson,
        'forward_from_id': forwardFromId,
        'forward_from_nick': forwardFromNick,
        'topic_id': topicId,
      };

  factory GroupMessage.fromMap(Map<String, dynamic> m) {
    Map<String, List<String>> reactions = const {};
    final raw = m['reactions'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        reactions =
            decoded.map((k, v) => MapEntry(k, (v as List).cast<String>()));
      } catch (_) {}
    }
    return GroupMessage(
      id: m['id'] as String,
      groupId: m['group_id'] as String,
      senderId: m['sender_id'] as String,
      text: m['text'] as String? ?? '',
      imagePath: m['image_path'] as String?,
      videoPath: m['video_path'] as String?,
      voicePath: m['voice_path'] as String?,
      latitude: (m['latitude'] as num?)?.toDouble(),
      longitude: (m['longitude'] as num?)?.toDouble(),
      isOutgoing: (m['is_outgoing'] as int) == 1,
      timestamp: m['timestamp'] as int,
      reactions: reactions,
      pollJson: m['poll_json'] as String?,
      forwardFromId: m['forward_from_id'] as String?,
      forwardFromNick: m['forward_from_nick'] as String?,
      topicId: m['topic_id'] as String?,
    );
  }
}
