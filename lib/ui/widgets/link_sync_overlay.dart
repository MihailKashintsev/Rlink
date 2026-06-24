import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/device_link_sync_service.dart';

/// Full-screen animation shown on a child device while it receives the linked
/// account snapshot (contacts, channels, chats). Progress bar + a rotating
/// carousel of avatars of the items as they arrive.
class LinkSyncOverlay extends StatelessWidget {
  const LinkSyncOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LinkSyncProgress?>(
      valueListenable: DeviceLinkSyncService.instance.progress,
      builder: (_, p, __) {
        if (p == null) return const SizedBox.shrink();
        return _LinkSyncScrim(progress: p);
      },
    );
  }
}

class _LinkSyncScrim extends StatefulWidget {
  final LinkSyncProgress progress;
  const _LinkSyncScrim({required this.progress});

  @override
  State<_LinkSyncScrim> createState() => _LinkSyncScrimState();
}

class _LinkSyncScrimState extends State<_LinkSyncScrim>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = widget.progress;
    final avatars = p.avatars.isEmpty
        ? List.generate(
            6, (i) => (emoji: '🙂', color: 0xFF42A5F5 + i * 0x001020))
        : p.avatars;

    return Positioned.fill(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          color: Colors.black.withValues(alpha: 0.55),
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 220,
                  height: 220,
                  child: AnimatedBuilder(
                    animation: _spin,
                    builder: (_, __) => CustomPaint(
                      painter: _RingPainter(
                        avatars: avatars,
                        angle: _spin.value * 2 * math.pi,
                        ringColor: cs.primary,
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.devices_rounded,
                                color: cs.primary, size: 30),
                            const SizedBox(height: 4),
                            Text(
                              p.total > 0
                                  ? '${(p.fraction * 100).round()}%'
                                  : '…',
                              style: TextStyle(
                                color: cs.onSurface,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  'Перенос профиля',
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  p.total > 0 ? '${p.phase} · ${p.done}/${p.total}' : p.phase,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 240,
                    child: LinearProgressIndicator(
                      value: p.total > 0 ? p.fraction : null,
                      minHeight: 6,
                      backgroundColor: cs.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation(cs.primary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final List<({String emoji, int color})> avatars;
  final double angle;
  final Color ringColor;
  _RingPainter(
      {required this.avatars, required this.angle, required this.ringColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 26;

    // Faint guide ring.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = ringColor.withValues(alpha: 0.18),
    );

    final n = avatars.length.clamp(1, 24);
    for (var i = 0; i < n; i++) {
      final a = angle + (i / n) * 2 * math.pi;
      final pos =
          center + Offset(math.cos(a) * radius, math.sin(a) * radius);
      final av = avatars[i % avatars.length];
      canvas.drawCircle(pos, 19, Paint()..color = Color(av.color));
      canvas.drawCircle(
        pos,
        19,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white.withValues(alpha: 0.85),
      );
      final tp = TextPainter(
        text: TextSpan(text: av.emoji, style: const TextStyle(fontSize: 18)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.angle != angle || old.avatars != avatars;
}
