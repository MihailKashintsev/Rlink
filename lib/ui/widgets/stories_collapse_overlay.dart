import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../models/contact.dart';
import '../../services/chat_inbox_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/gossip_router.dart';
import '../../services/profile_service.dart';
import '../../services/story_service.dart';
import '../rlink_nav_routes.dart';
import '../screens/story_creator_screen.dart';
import '../screens/story_viewer_screen.dart';
import 'avatar_widget.dart';

/// Height reserved at the top of the chat list for the story row. The avatars
/// themselves are NOT in the list — [StoriesCollapseOverlay] paints them above
/// the whole screen so they can fly into the app bar.
const double kStoriesRowHeight = 92;

/// True when the chat list must reserve [kStoriesRowHeight] for the row.
bool storiesRowPresent() =>
    ProfileService.instance.profileNotifier.value != null ||
    StoryService.instance.activeAuthors.isNotEmpty;

/// Telegram-style story row: avatars sit at the top of the chat list and, as
/// the list scrolls, shrink and slide into a small overlapping cluster inside
/// the app bar. Everything is driven by the list's scroll offset and done with
/// paint-time transforms — no layout, no re-decoding, so it stays smooth.
class StoriesCollapseOverlay extends StatefulWidget {
  /// Scroll offset (px) of the chat list; negative while overscrolling.
  final ValueListenable<double> scroll;

  /// Key on the box whose top-left corner is where the story row starts.
  final GlobalKey areaKey;

  /// Hidden (and inert) outside the chats tab / during search.
  final bool visible;

  /// Tapping a collapsed avatar scrolls the list back to the top so the row
  /// opens up again (instead of opening that story).
  final VoidCallback onExpand;

  const StoriesCollapseOverlay({
    super.key,
    required this.scroll,
    required this.areaKey,
    required this.visible,
    required this.onExpand,
  });

  @override
  State<StoriesCollapseOverlay> createState() => _StoriesCollapseOverlayState();
}

class _Story {
  final String id;
  final String label;
  final Widget avatar;
  final VoidCallback onTap;
  final bool create;
  const _Story({
    required this.id,
    required this.label,
    required this.avatar,
    required this.onTap,
    this.create = false,
  });
}

class _StoriesCollapseOverlayState extends State<StoriesCollapseOverlay> {
  static const double _avatar = 56;
  static const double _collapsedAvatar = 28;
  static const double _restStep = 68; // 56 + 2 * 6 spacing
  // Touch/label box is wider than the avatar; the avatar sits centred in it.
  static const double _box = 64;
  static const double _boxPad = (_box - _avatar) / 2;
  static const double _clusterStep = 18; // overlap in the app bar
  static const int _maxCluster = 4;
  static const double _toolbar = kToolbarHeight;
  // App bar chrome that the collapsed cluster must fit between.
  static const double _titleEnd = 100;
  static const double _actionsW = 152;

  late final Listenable _data = Listenable.merge([
    ProfileService.instance.profileNotifier,
    ChatStorageService.instance.contactsNotifier,
    StoryService.instance.version,
    ChatInboxService.instance,
  ]);

  @override
  void initState() {
    super.initState();
    _pokeAfterLayout();
  }

  @override
  void didUpdateWidget(covariant StoriesCollapseOverlay old) {
    super.didUpdateWidget(old);
    _pokeAfterLayout();
  }

  // The row's origin comes from the list's render box, which only exists after
  // the frame that (re)built it — repaint once it has been laid out.
  void _pokeAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  List<_Story> _stories(BuildContext context) {
    final my = ProfileService.instance.profileNotifier.value;
    final contacts = ChatStorageService.instance.contactsNotifier.value;
    final byKey = {for (final c in contacts) c.publicKeyHex: c};
    final inbox = ChatInboxService.instance;
    final ownKey = my?.publicKeyHex;
    final authors = StoryService.instance.activeAuthors
        .where((id) => id == ownKey || byKey.containsKey(id))
        .toList();
    if (authors.isEmpty && my == null) return const [];

    final out = <_Story>[];
    if (my != null) {
      out.add(_Story(
        id: 'create',
        label: AppL10n.t('Создать'),
        create: true,
        avatar: _withBadge(
          context,
          AvatarWidget(
            initials: my.initials,
            color: my.avatarColor,
            emoji: my.avatarEmoji,
            imagePath: my.avatarImagePath,
            size: _avatar,
          ),
        ),
        onTap: () => _createStory(context, my.publicKeyHex),
      ));
      if (StoryService.instance.hasActiveStory(my.publicKeyHex)) {
        out.add(_Story(
          id: 'me',
          label: AppL10n.t('Моя история'),
          avatar: AvatarWidget(
            initials: my.initials,
            color: my.avatarColor,
            emoji: my.avatarEmoji,
            imagePath: my.avatarImagePath,
            size: _avatar,
            hasStory: true,
          ),
          onTap: () {
            final existing = StoryService.instance.storiesFor(my.publicKeyHex);
            if (existing.isEmpty) return;
            Navigator.push(
              context,
              rlinkPushRoute(StoryViewerScreen(
                authorId: my.publicKeyHex,
                authorName: AppL10n.t('Я'),
                stories: existing,
              )),
            );
          },
        ));
      }
    }
    for (final id in authors) {
      if (id == ownKey) continue;
      final c = byKey[id];
      if (c != null &&
          inbox.isArchived(
              chatInboxKey(kind: ChatInboxItemKind.dm, id: c.publicKeyHex))) {
        continue;
      }
      final name = _name(c, id);
      out.add(_Story(
        id: id,
        label: name,
        avatar: AvatarWidget(
          initials: name.isNotEmpty ? name[0].toUpperCase() : '?',
          color: c?.avatarColor ?? 0xFF607D8B,
          emoji: c?.avatarEmoji ?? '',
          imagePath: c?.avatarImagePath,
          size: _avatar,
          hasStory: true,
          hasUnviewedStory: StoryService.instance.hasUnviewedStory(id),
        ),
        onTap: () => Navigator.push(
          context,
          rlinkPushRoute(StoryViewerScreen(
            authorId: id,
            authorName: name,
            stories: StoryService.instance.storiesFor(id),
          )),
        ),
      ));
    }
    return out;
  }

  String _name(Contact? c, String id) {
    final n = c?.nickname ?? '';
    return n.isNotEmpty ? n : id.substring(0, id.length.clamp(0, 8));
  }

  Widget _withBadge(BuildContext context, Widget avatar) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: cs.primary,
              shape: BoxShape.circle,
              border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor, width: 2),
            ),
            child: const Icon(Icons.add, size: 12, color: Colors.white),
          ),
        ),
      ],
    );
  }

  void _createStory(BuildContext context, String authorId) {
    Navigator.push(
      context,
      rlinkPushRoute(StoryCreatorScreen(authorId: authorId)),
    ).then((story) {
      if (story is StoryItem) {
        GossipRouter.instance.sendStory(
          storyId: story.id,
          authorId: story.authorId,
          text: story.text,
          bgColor: story.bgColor,
          textX: story.textX,
          textY: story.textY,
          textSize: story.textSize,
          textColor: story.textColor,
          textBold: story.textBold,
          textItalic: story.textItalic,
          textBgOpacity: story.textBgOpacity,
          overlays: story.overlays.map((e) => e.toJson()).toList(),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Lives above the Scaffold, so it needs its own text-style/ink ancestor.
    return Material(
      type: MaterialType.transparency,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: AnimatedOpacity(
          opacity: widget.visible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: ListenableBuilder(
            listenable: _data,
            builder: (context, _) {
              final stories = _stories(context);
              if (stories.isEmpty) return const SizedBox.shrink();
              return ValueListenableBuilder<double>(
                valueListenable: widget.scroll,
                builder: (context, offset, _) =>
                    _layer(context, stories, offset),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _layer(BuildContext context, List<_Story> stories, double offset) {
    final area = widget.areaKey.currentContext?.findRenderObject();
    final me = context.findRenderObject();
    if (area is! RenderBox ||
        !area.attached ||
        !area.hasSize ||
        me is! RenderBox ||
        !me.hasSize) {
      return const SizedBox.shrink();
    }
    final origin = me.globalToLocal(area.localToGlobal(Offset.zero));
    final width = me.size.width;
    final cs = Theme.of(context).colorScheme;
    final topInset = MediaQuery.paddingOf(context).top;

    // p: 0 = row fully expanded, 1 = cluster in the app bar.
    final p = (offset / kStoriesRowHeight).clamp(0.0, 1.0);
    // Horizontal gather + shrink lead (the row squeezes together first), the
    // vertical flight into the bar trails — so the avatars don't sweep across
    // the toolbar icons while still spread out.
    final e = Curves.easeOutCubic.transform(p);
    final ey = Curves.easeInOutCubic.transform(p);
    final scale = 1 - (1 - _collapsedAvatar / _avatar) * e;
    final labelAlpha = (1 - p / 0.4).clamp(0.0, 1.0);
    final collapsed = p >= 0.5;

    final hasCreate = stories.first.create;
    final nStory = stories.length - (hasCreate ? 1 : 0);
    final availW = width - _actionsW - _titleEnd;
    final byWidth =
        math.max(1, ((availW - _collapsedAvatar) / _clusterStep).floor() + 1);
    final vis = math.min(nStory, math.min(_maxCluster, byWidth));
    final clusterW =
        vis == 0 ? 0.0 : _collapsedAvatar + (vis - 1) * _clusterStep;
    final clusterLeft = _titleEnd + (availW - clusterW) / 2;
    final targetY = topInset + (_toolbar - _collapsedAvatar) / 2;
    // The anchor is the (stationary) list viewport, so the row rides the scroll.
    final restY = origin.dy + 6 - offset;

    final children = <Widget>[];
    // Paint back-to-front so the first avatar ends up on top of the cluster.
    for (var i = stories.length - 1; i >= 0; i--) {
      final s = stories[i];
      final si = i - (hasCreate ? 1 : 0);
      var alpha = 1.0;
      double toX;
      if (s.create) {
        alpha = 1 - (p / 0.45).clamp(0.0, 1.0);
        toX = clusterLeft - 8;
      } else {
        // Beyond the first few: drift right of the cluster and fade away.
        if (si >= vis) alpha = 1 - ((p - 0.1) / 0.5).clamp(0.0, 1.0);
        toX = clusterLeft + math.min(si, vis) * _clusterStep;
      }
      if (alpha <= 0.01) continue;
      final restX = origin.dx + 14 + i * _restStep;
      final x = restX + (toX - restX) * e - _boxPad * scale;
      final y = restY + (targetY - restY) * ey;

      Widget entry = _entry(context, s, cs, e, labelAlpha,
          collapsed ? widget.onExpand : s.onTap);
      if (alpha < 1) entry = Opacity(opacity: alpha, child: entry);
      children.add(Positioned(
        left: 0,
        top: 0,
        child: Transform(
          alignment: Alignment.topLeft,
          transform: Matrix4.identity()
            ..setEntry(0, 0, scale)
            ..setEntry(1, 1, scale)
            ..setEntry(0, 3, x)
            ..setEntry(1, 3, y),
          child: entry,
        ),
      ));
    }
    return Stack(clipBehavior: Clip.none, children: children);
  }

  Widget _entry(BuildContext context, _Story s, ColorScheme cs, double e,
      double labelAlpha, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: _box,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _avatar,
              height: _avatar,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Halo: separates overlapping avatars in the collapsed cluster.
                  if (e > 0.02)
                    Positioned(
                      left: -3,
                      top: -3,
                      right: -3,
                      bottom: -3,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: cs.surface.withValues(alpha: e),
                        ),
                      ),
                    ),
                  RepaintBoundary(child: s.avatar),
                ],
              ),
            ),
            if (labelAlpha > 0.01) ...[
              const SizedBox(height: 4),
              Text(
                s.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: labelAlpha),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
