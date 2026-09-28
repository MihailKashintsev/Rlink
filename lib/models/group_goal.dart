import 'dart:convert';

/// One checklist item within a [GroupGoal].
class GoalItem {
  final String title;
  final bool completed;
  final String? completedBy;

  const GoalItem({
    required this.title,
    this.completed = false,
    this.completedBy,
  });

  Map<String, dynamic> toJson() => {
        't': title,
        if (completed) 'c': true,
        if (completedBy != null) 'b': completedBy,
      };

  factory GoalItem.fromJson(Map<String, dynamic> j) => GoalItem(
        title: j['t']?.toString() ?? '',
        completed: j['c'] == true,
        completedBy: j['b']?.toString(),
      );

  GoalItem withCompleted(bool value, String? by) =>
      GoalItem(title: title, completed: value, completedBy: value ? by : null);
}

/// Цель темы группы (JSON в group_messages.goal_json / gossip 'goal_action').
/// Port of skiper-ui's TaskWidget, adapted to Rlink: a deadline, a shared
/// checklist anyone who joined can tick off, and join/leave tracking for
/// "статистика цели" (who's in, how much is done).
class GroupGoal {
  final String title;
  final int deadlineMs; // 0 = без срока
  final String creatorId;
  final List<GoalItem> items;
  final List<String> joinedIds;

  const GroupGoal({
    required this.title,
    this.deadlineMs = 0,
    required this.creatorId,
    this.items = const [],
    this.joinedIds = const [],
  });

  int get completedCount => items.where((i) => i.completed).length;
  int get totalCount => items.length;
  double get progress => totalCount == 0 ? 0 : completedCount / totalCount;
  bool get isOverdue =>
      deadlineMs > 0 && DateTime.now().millisecondsSinceEpoch > deadlineMs;

  Map<String, dynamic> toJson() => {
        'title': title,
        if (deadlineMs > 0) 'deadline': deadlineMs,
        'creator': creatorId,
        'items': items.map((i) => i.toJson()).toList(),
        if (joinedIds.isNotEmpty) 'joined': joinedIds,
      };

  factory GroupGoal.fromJson(Map<String, dynamic> j) => GroupGoal(
        title: j['title']?.toString() ?? '',
        deadlineMs: (j['deadline'] as num?)?.toInt() ?? 0,
        creatorId: j['creator']?.toString() ?? '',
        items: (j['items'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => GoalItem.fromJson(m.cast<String, dynamic>()))
            .toList(),
        joinedIds: (j['joined'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  String encode() => jsonEncode(toJson());

  static GroupGoal? tryDecode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return GroupGoal.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  GroupGoal withJoined(String userId, bool joined) {
    final ids = List<String>.from(joinedIds);
    if (joined) {
      if (!ids.contains(userId)) ids.add(userId);
    } else {
      ids.remove(userId);
    }
    return GroupGoal(
      title: title,
      deadlineMs: deadlineMs,
      creatorId: creatorId,
      items: items,
      joinedIds: ids,
    );
  }

  GroupGoal withItemToggled(int index, bool completed, String actorId) {
    if (index < 0 || index >= items.length) return this;
    final list = List<GoalItem>.from(items);
    list[index] = list[index].withCompleted(completed, actorId);
    return GroupGoal(
      title: title,
      deadlineMs: deadlineMs,
      creatorId: creatorId,
      items: list,
      joinedIds: joinedIds,
    );
  }

  /// Applies a single incoming actor's delta — mirrors [MessagePoll.withVote]:
  /// each `goal_action` packet carries one actor's change, so no merge logic
  /// is needed on the live path (that's what [mergeFrom] is for instead).
  GroupGoal applyAction(String actorId, String action,
      {int? itemIndex, bool? completed}) {
    switch (action) {
      case 'join':
        return withJoined(actorId, true);
      case 'leave':
        return withJoined(actorId, false);
      case 'toggle_item':
        if (itemIndex == null || completed == null) return this;
        return withItemToggled(itemIndex, completed, actorId);
      default:
        return this;
    }
  }

  /// Merges a full snapshot from elsewhere (history sync / backup restore) —
  /// unions who's joined, and for each item keeps whichever side has it
  /// completed (a completed item never reverts from a merge).
  GroupGoal mergeFrom(GroupGoal? other) {
    if (other == null) return this;
    final joined = <String>{...joinedIds, ...other.joinedIds}.toList();
    final merged = <GoalItem>[];
    for (var i = 0; i < items.length; i++) {
      final mine = items[i];
      final theirs = i < other.items.length ? other.items[i] : null;
      merged.add(
          (theirs != null && theirs.completed && !mine.completed) ? theirs : mine);
    }
    return GroupGoal(
      title: title,
      deadlineMs: deadlineMs,
      creatorId: creatorId,
      items: merged,
      joinedIds: joined,
    );
  }
}
