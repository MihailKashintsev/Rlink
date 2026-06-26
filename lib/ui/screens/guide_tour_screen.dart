import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../services/app_settings.dart';

/// A guided "where is what" tour: an illustrated, theme-aware replica of the
/// Rlink home screen with an animated arrow + caption pointing at each area
/// (tabs, search, stories). Programmatic, so it works on any theme/language.
class GuideTourScreen extends StatefulWidget {
  /// First-launch flow marks the intro/guide as seen when finished.
  final bool markSeenOnFinish;
  const GuideTourScreen({super.key, this.markSeenOnFinish = false});

  @override
  State<GuideTourScreen> createState() => _GuideTourScreenState();
}

class _Target {
  // Center + size as fractions of the mock rect.
  final double cx, cy, w, h;
  final String titleKey, subKey;
  const _Target(this.cx, this.cy, this.w, this.h, this.titleKey, this.subKey);
}

const _targets = <_Target>[
  _Target(0.125, 0.952, 0.22, 0.085, 'guide_chats_t', 'guide_chats_s'),
  _Target(0.375, 0.952, 0.22, 0.085, 'guide_nearby_t', 'guide_nearby_s'),
  _Target(0.625, 0.952, 0.22, 0.085, 'guide_ether_t', 'guide_ether_s'),
  _Target(0.875, 0.952, 0.22, 0.085, 'guide_me_t', 'guide_me_s'),
  _Target(0.875, 0.046, 0.18, 0.05, 'guide_search_t', 'guide_search_s'),
  _Target(0.5, 0.15, 0.86, 0.12, 'guide_stories_t', 'guide_stories_s'),
];

class _GuideTourScreenState extends State<GuideTourScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _amb = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);
  int _step = 0;

  @override
  void dispose() {
    _amb.dispose();
    super.dispose();
  }

  void _next() {
    if (_step >= _targets.length - 1) {
      _finish();
      return;
    }
    setState(() => _step++);
  }

  void _prev() {
    if (_step > 0) setState(() => _step--);
  }

  Future<void> _finish() async {
    if (widget.markSeenOnFinish) {
      await AppSettings.instance.setHasSeenIntro(true);
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final isLast = _step == _targets.length - 1;

    return Scaffold(
      backgroundColor: cs.surface,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          // Mock phone rect (centered, leaves room for header + caption).
          final topPad = media.padding.top + 64;
          final captionH = 188.0;
          final availH = h - topPad - captionH - 24;
          var mockH = math.min(availH, h * 0.62);
          var mockW = mockH * 9 / 19.5;
          if (mockW > w - 48) {
            mockW = w - 48;
            mockH = mockW * 19.5 / 9;
          }
          final mockLeft = (w - mockW) / 2;
          final mockTop = topPad;
          final t = _targets[_step];
          // Target rect in screen coords.
          final tcx = mockLeft + t.cx * mockW;
          final tcy = mockTop + t.cy * mockH;
          final tw = t.w * mockW;
          final th = t.h * mockH;
          final captionTop = mockTop + mockH + 20;

          return Stack(
            children: [
              // Header
              Positioned(
                top: media.padding.top + 14,
                left: 20,
                right: 20,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      AppL10n.t('guide_intro_title'),
                      style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 22,
                          fontWeight: FontWeight.w700),
                    ),
                    TextButton(
                      onPressed: _finish,
                      child: Text(AppL10n.t('intro_skip'),
                          style: TextStyle(
                              color: cs.onSurfaceVariant, fontSize: 15)),
                    ),
                  ],
                ),
              ),
              // The Rlink mock.
              Positioned(
                left: mockLeft,
                top: mockTop,
                width: mockW,
                height: mockH,
                child: _RlinkMock(cs: cs, highlightStep: _step),
              ),
              // Pulsing highlight ring on the target.
              AnimatedBuilder(
                animation: _amb,
                builder: (context, _) {
                  final pulse = _amb.value;
                  return Positioned(
                    left: tcx - tw / 2 - 6,
                    top: tcy - th / 2 - 6,
                    width: tw + 12,
                    height: th + 12,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: cs.primary
                                .withValues(alpha: 0.6 + 0.4 * pulse),
                            width: 2.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: cs.primary
                                  .withValues(alpha: 0.25 + 0.2 * pulse),
                              blurRadius: 18 + 10 * pulse,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              // Animated arrow from the caption toward the target.
              AnimatedBuilder(
                animation: _amb,
                builder: (context, _) {
                  return IgnorePointer(
                    child: CustomPaint(
                      size: Size(w, h),
                      painter: _ArrowPainter(
                        from: Offset(w / 2, captionTop - 6),
                        to: Offset(tcx, tcy + (tcy < h / 2 ? th / 2 + 8 : -th / 2 - 8)),
                        color: cs.primary,
                        wiggle: _amb.value,
                      ),
                    ),
                  );
                },
              ),
              // Caption card.
              Positioned(
                left: 20,
                right: 20,
                top: captionTop,
                child: _CaptionCard(
                  key: ValueKey(_step),
                  cs: cs,
                  title: AppL10n.t(t.titleKey),
                  sub: AppL10n.t(t.subKey),
                ),
              ),
              // Bottom controls.
              Positioned(
                left: 20,
                right: 20,
                bottom: media.padding.bottom + 22,
                child: Row(
                  children: [
                    _Dots(count: _targets.length, index: _step, cs: cs),
                    const Spacer(),
                    FilledButton(
                      onPressed: _next,
                      child: Text(isLast
                          ? AppL10n.t('guide_done')
                          : AppL10n.t('intro_next')),
                    ),
                  ],
                ),
              ),
              // Tap anywhere (right side) to advance.
              Positioned.fill(
                child: Row(
                  children: [
                    Expanded(
                        child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: _prev)),
                    Expanded(
                        flex: 2,
                        child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: _next)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Caption card (animated entrance) ────────────────────────────────────────
class _CaptionCard extends StatefulWidget {
  final ColorScheme cs;
  final String title, sub;
  const _CaptionCard({
    super.key,
    required this.cs,
    required this.title,
    required this.sub,
  });

  @override
  State<_CaptionCard> createState() => _CaptionCardState();
}

class _CaptionCardState extends State<_CaptionCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.cs;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_c.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - t)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 24),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    style: TextStyle(
                        color: cs.primary,
                        fontSize: 20,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.sub,
                    style: TextStyle(
                        color: cs.onSurface, fontSize: 15.5, height: 1.35),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Dots extends StatelessWidget {
  final int count, index;
  final ColorScheme cs;
  const _Dots({required this.count, required this.index, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(count, (i) {
        final on = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(right: 6),
          width: on ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: on ? cs.primary : cs.onSurface.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

// ── Curved animated arrow ───────────────────────────────────────────────────
class _ArrowPainter extends CustomPainter {
  final Offset from;
  final Offset to;
  final Color color;
  final double wiggle;
  _ArrowPainter({
    required this.from,
    required this.to,
    required this.color,
    required this.wiggle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Control point bulges to one side for a nice curve; small wiggle animates.
    final mid = Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2);
    final dir = to - from;
    final norm = Offset(-dir.dy, dir.dx);
    final double len = norm.distance == 0 ? 1.0 : norm.distance;
    final bulge = 60.0 + 8 * math.sin(wiggle * math.pi * 2);
    final ctrl = mid + norm / len * bulge;

    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(ctrl.dx, ctrl.dy, to.dx, to.dy);
    canvas.drawPath(path, paint);

    // Arrowhead at the target end (tangent ≈ to - ctrl).
    final tan = (to - ctrl);
    final ang = math.atan2(tan.dy, tan.dx);
    const ah = 18.0;
    final p1 = to - Offset(math.cos(ang - 0.5) * ah, math.sin(ang - 0.5) * ah);
    final p2 = to - Offset(math.cos(ang + 0.5) * ah, math.sin(ang + 0.5) * ah);
    final head = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(head, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.from != from ||
      old.to != to ||
      old.color != color ||
      old.wiggle != wiggle;
}

// ── Stylised Rlink home replica ─────────────────────────────────────────────
class _RlinkMock extends StatelessWidget {
  final ColorScheme cs;
  final int highlightStep;
  const _RlinkMock({required this.cs, required this.highlightStep});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(34),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 30),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(34),
        child: Column(
          children: [
            // app bar
            Expanded(
              flex: 85,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 4),
                child: Row(
                  children: [
                    Text('Rlink',
                        style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 22,
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Icon(Icons.search, color: cs.onSurface, size: 24),
                  ],
                ),
              ),
            ),
            // stories
            Expanded(
              flex: 115,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: List.generate(5, (i) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [
                            cs.primary,
                            Color.lerp(cs.primary, cs.tertiary, 0.6)!,
                          ]),
                          border: Border.all(color: cs.surface, width: 2),
                        ),
                        child:
                            const Center(child: Text('•', style: TextStyle())),
                      ),
                    );
                  }),
                ),
              ),
            ),
            // chat rows
            Expanded(
              flex: 700,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                physics: const NeverScrollableScrollPhysics(),
                children: List.generate(6, (i) {
                  final colors = [
                    const Color(0xFF7C4DFF),
                    cs.primary,
                    const Color(0xFFEC407A),
                    const Color(0xFF26A69A),
                    const Color(0xFFFFA726),
                    const Color(0xFF42A5F5),
                  ];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle, color: colors[i]),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                  height: 9,
                                  width: 90 + (i % 3) * 24,
                                  decoration: BoxDecoration(
                                      color: cs.onSurface
                                          .withValues(alpha: 0.55),
                                      borderRadius: BorderRadius.circular(5))),
                              const SizedBox(height: 7),
                              Container(
                                  height: 8,
                                  width: 140 - (i % 3) * 20,
                                  decoration: BoxDecoration(
                                      color: cs.onSurfaceVariant
                                          .withValues(alpha: 0.4),
                                      borderRadius: BorderRadius.circular(5))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),
            // bottom nav
            Expanded(
              flex: 100,
              child: Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  border: Border(
                      top: BorderSide(
                          color: cs.outlineVariant.withValues(alpha: 0.3))),
                ),
                child: Row(
                  children: [
                    _navItem(Icons.chat_bubble_outline, 'Чаты', 0),
                    _navItem(Icons.radar, 'Рядом', 1),
                    _navItem(Icons.cell_tower, 'Эфир', 2),
                    _navItem(Icons.person_outline, 'Я', 3),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int idx) {
    final active = highlightStep == idx;
    final c = active ? cs.primary : cs.onSurfaceVariant;
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: c, size: 22),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(color: c, fontSize: 11)),
        ],
      ),
    );
  }
}
