import 'package:flutter/material.dart';

import '../../services/in_app_notification_service.dart';
import 'avatar_widget.dart';

/// Telegram-style banner that slides in from the top when a message/call
/// arrives while the app is open elsewhere. Motion per emil-design-eng:
/// translateY from above + opacity, strong ease-out, ~280ms; swipe up or tap
/// the X to dismiss; tap the body to open the chat.
class InAppNotificationOverlay extends StatelessWidget {
  const InAppNotificationOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<InAppNotif?>(
      valueListenable: InAppNotificationService.instance.current,
      builder: (_, notif, __) {
        return Align(
          alignment: Alignment.topCenter,
          child: notif == null
              ? const SizedBox.shrink()
              : _Banner(
                  // Key on seq so a new notif re-runs the entrance animation.
                  key: ValueKey(notif.seq),
                  notif: notif,
                ),
        );
      },
    );
  }
}

class _Banner extends StatefulWidget {
  final InAppNotif notif;
  const _Banner({super.key, required this.notif});

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 190),
  )..forward();
  double _dragDy = 0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (!mounted) return;
    try {
      await _c.reverse();
    } catch (_) {}
    InAppNotificationService.instance.dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = widget.notif;
    final curve = CurvedAnimation(parent: _c, curve: const Cubic(0.23, 1, 0.32, 1));
    return SafeArea(
      child: AnimatedBuilder(
        animation: curve,
        builder: (context, child) {
          final t = curve.value;
          final dy = (-90.0 * (1 - t)) + _dragDy;
          return Transform.translate(
            offset: Offset(0, dy),
            child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: GestureDetector(
            onTap: () {
              InAppNotificationService.instance.onOpen?.call(n.payload);
              _dismiss();
            },
            onVerticalDragUpdate: (d) {
              if (d.primaryDelta != null && d.primaryDelta! < 0) {
                setState(() => _dragDy += d.primaryDelta!);
              }
            },
            onVerticalDragEnd: (d) {
              if (_dragDy < -28 ||
                  (d.primaryVelocity != null && d.primaryVelocity! < -300)) {
                _dismiss();
              } else {
                setState(() => _dragDy = 0);
              }
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Material(
                elevation: 8,
                shadowColor: Colors.black.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(18),
                color: cs.surfaceContainerHigh,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      n.isCall
                          ? CircleAvatar(
                              radius: 22,
                              backgroundColor: Colors.green.withValues(alpha: 0.2),
                              child: const Icon(Icons.call, color: Colors.green),
                            )
                          : AvatarWidget(
                              initials: n.title.isNotEmpty
                                  ? n.title[0].toUpperCase()
                                  : '?',
                              color: n.color,
                              emoji: n.emoji,
                              imagePath: n.imagePath,
                              size: 44,
                            ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              n.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              n.body,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.close_rounded,
                            size: 20, color: cs.onSurfaceVariant),
                        onPressed: _dismiss,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
