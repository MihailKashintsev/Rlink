/// A named sub-thread within a group — splits one group's messages into
/// separate streams (e.g. "General", "🎨 Design", "🐛 Bugs") while sharing
/// the parent group's membership and moderation. `null` topicId on a
/// [GroupMessage] means the (always-present, unlisted) General thread, so
/// existing groups and messages need no migration.
class GroupTopic {
  final String id;
  final String groupId;
  final String name;
  final String emoji;
  final String creatorId;
  final int createdAt;

  const GroupTopic({
    required this.id,
    required this.groupId,
    required this.name,
    this.emoji = '💬',
    required this.creatorId,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'group_id': groupId,
        'name': name,
        'emoji': emoji,
        'creator_id': creatorId,
        'created_at': createdAt,
      };

  factory GroupTopic.fromMap(Map<String, dynamic> m) => GroupTopic(
        id: m['id'] as String,
        groupId: m['group_id'] as String,
        name: m['name'] as String,
        emoji: m['emoji'] as String? ?? '💬',
        creatorId: m['creator_id'] as String,
        createdAt: m['created_at'] as int,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'groupId': groupId,
        'name': name,
        'emoji': emoji,
        'creatorId': creatorId,
        'createdAt': createdAt,
      };

  factory GroupTopic.fromJson(Map<String, dynamic> j) => GroupTopic(
        id: j['id'] as String,
        groupId: j['groupId'] as String,
        name: j['name'] as String,
        emoji: j['emoji'] as String? ?? '💬',
        creatorId: j['creatorId'] as String,
        createdAt: (j['createdAt'] as num).toInt(),
      );
}
