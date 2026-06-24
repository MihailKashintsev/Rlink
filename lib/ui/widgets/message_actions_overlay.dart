import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// One row in the compact message action menu.
class MessageMenuAction {
  final IconData icon;
  final String label;
  final bool destructive;
  final VoidCallback onTap;
  const MessageMenuAction({
    required this.icon,
    required this.label,
    this.destructive = false,
    required this.onTap,
  });
}

/// Telegram-style long-press menu: blur the whole screen, lift the selected
/// message (a captured snapshot) above the blur, and show a reaction bar +
/// compact action menu next to it. Tapping the backdrop dismisses.
Future<void> showMessageActionsOverlay({
  required BuildContext context,
  required Rect bubbleRect,
  ui.Image? snapshot,
  required List<MessageMenuAction> actions,
  List<String> quickReactions = const ['👍', '❤️', '😂', '😮', '😢', '🔥'],
  void Function(String emoji)? onReact,
  VoidCallback? onMoreReactions,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (ctx, anim, __) => _MessageActionsLayer(
        anim: anim,
        bubbleRect: bubbleRect,
        snapshot: snapshot,
        actions: actions,
        quickReactions: quickReactions,
        onReact: onReact,
        onMoreReactions: onMoreReactions,
      ),
    ),
  );
}

class _MessageActionsLayer extends StatelessWidget {
  final Animation<double> anim;
  final Rect bubbleRect;
  final ui.Image? snapshot;
  final List<MessageMenuAction> actions;
  final List<String> quickReactions;
  final void Function(String emoji)? onReact;
  final VoidCallback? onMoreReactions;

  const _MessageActionsLayer({
    required this.anim,
    required this.bubbleRect,
    this.snapshot,
    required this.actions,
    required this.quickReactions,
    required this.onReact,
    required this.onMoreReactions,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final size = media.size;
    final rect = bubbleRect;
    final alignRight = rect.center.dx > size.width / 2;

    const menuWidth = 240.0;
    final menuEst = 60.0 + actions.length * 46.0;
    final spaceBelow = size.height - rect.bottom - media.padding.bottom - 16;
    final placeBelow = spaceBelow > menuEst || spaceBelow > size.height * 0.4;

    void dismiss() => Navigator.of(context).maybePop();

    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        final t = Curves.easeOut.transform(anim.value.clamp(0.0, 1.0));
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Ignore the tap that's part of the opening long-press release;
                // only dismiss once the open animation has settled.
                onTap: () {
                  if (anim.value >= 0.95) dismiss();
                },
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 9 * t, sigmaY: 9 * t),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.22 * t),
                  ),
                ),
              ),
            ),
            // Reaction bar above the bubble.
            if (onReact != null)
              Positioned(
                top: (rect.top - 60)
                    .clamp(media.padding.top + 8, size.height - 60),
                left: alignRight ? null : rect.left.clamp(8.0, size.width),
                right: alignRight
                    ? (size.width - rect.right).clamp(8.0, size.width)
                    : null,
                child: Opacity(
                  opacity: t,
                  child: _ReactionBar(
                    emojis: quickReactions,
                    cs: cs,
                    onReact: (e) {
                      dismiss();
                      onReact!(e);
                    },
                    onMore: onMoreReactions == null
                        ? null
                        : () {
                            dismiss();
                            onMoreReactions!();
                          },
                  ),
                ),
              ),
            // The lifted bubble snapshot (best-effort; absent on web HTML renderer).
            if (snapshot != null)
              Positioned(
                top: rect.top,
                left: rect.left,
                width: rect.width,
                height: rect.height,
                child: Transform.scale(
                  scale: 1.0 - 0.04 * (1 - t),
                  alignment:
                      alignRight ? Alignment.centerRight : Alignment.centerLeft,
                  child: RawImage(
                    image: snapshot,
                    width: rect.width,
                    height: rect.height,
                    fit: BoxFit.fill,
                  ),
                ),
              ),
            // Compact action menu. When placed above the bubble, clear the
            // reaction bar (which sits just above the bubble) so they don't overlap.
            Positioned(
              top: placeBelow ? rect.bottom + 10 : null,
              bottom: placeBelow
                  ? null
                  : (size.height - rect.top + (onReact != null ? 74 : 12)),
              left: alignRight ? null : rect.left.clamp(8.0, size.width),
              right: alignRight
                  ? (size.width - rect.right).clamp(8.0, size.width)
                  : null,
              child: Opacity(
                opacity: t,
                child: _ActionMenu(
                  width: menuWidth,
                  actions: actions,
                  cs: cs,
                  onPick: dismiss,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ReactionBar extends StatelessWidget {
  final List<String> emojis;
  final ColorScheme cs;
  final void Function(String emoji) onReact;
  final VoidCallback? onMore;
  const _ReactionBar({
    required this.emojis,
    required this.cs,
    required this.onReact,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(30),
      elevation: 6,
      shadowColor: Colors.black54,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in emojis)
              InkWell(
                onTap: () => onReact(e),
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(e, style: const TextStyle(fontSize: 26)),
                ),
              ),
            if (onMore != null)
              InkWell(
                onTap: onMore,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.add_rounded,
                      size: 22, color: cs.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionMenu extends StatelessWidget {
  final double width;
  final List<MessageMenuAction> actions;
  final ColorScheme cs;
  final VoidCallback onPick;
  const _ActionMenu({
    required this.width,
    required this.actions,
    required this.cs,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      elevation: 8,
      shadowColor: Colors.black54,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: 380, maxWidth: width),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final a in actions)
                InkWell(
                  onTap: () {
                    onPick();
                    a.onTap();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 11),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            a.label,
                            style: TextStyle(
                              fontSize: 15,
                              color: a.destructive ? cs.error : cs.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(a.icon,
                            size: 20,
                            color: a.destructive
                                ? cs.error
                                : cs.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
