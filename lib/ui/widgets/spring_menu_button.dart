import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// One row in a [SpringMenuButton]'s panel.
class SpringMenuAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const SpringMenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

/// A "+" trigger that opens a small glass panel of actions with a spring
/// entrance (staggered fade + rise per row, blur-to-sharp on the panel
/// itself) instead of the platform's plain [PopupMenuButton] fade.
///
/// Built on Flutter's own [SpringSimulation] (no extra package needed) and
/// an [Overlay] anchored to the button via [CompositedTransformTarget], so
/// it can be dropped in wherever a `PopupMenuButton` used to live.
class SpringMenuButton extends StatefulWidget {
  final List<SpringMenuAction> actions;
  final String? tooltip;

  const SpringMenuButton({super.key, required this.actions, this.tooltip});

  @override
  State<SpringMenuButton> createState() => _SpringMenuButtonState();
}

class _SpringMenuButtonState extends State<SpringMenuButton>
    with SingleTickerProviderStateMixin {
  static const _easeOut = Cubic(0.23, 1, 0.32, 1);

  final LayerLink _link = LayerLink();
  late final AnimationController _c = AnimationController(vsync: this);
  OverlayEntry? _entry;
  bool _open = false;

  @override
  void dispose() {
    _entry?.remove();
    _c.dispose();
    super.dispose();
  }

  void _runSpring(double target) {
    final sim = SpringSimulation(
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 340),
        bounce: 0.14,
      ),
      _c.value,
      target,
      0,
    );
    _c.animateWith(sim);
  }

  void _toggle() => _open ? _close() : _openMenu();

  void _openMenu() {
    _entry = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    setState(() => _open = true);
    _runSpring(1);
  }

  void _close() {
    if (!_open) return;
    setState(() => _open = false);
    _runSpring(0);
    Future.delayed(const Duration(milliseconds: 260), () {
      _entry?.remove();
      _entry = null;
    });
  }

  Widget _buildOverlay(BuildContext overlayCtx) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, 10),
          child: AnimatedBuilder(
            animation: _c,
            builder: (ctx, _) {
              final t = _easeOut.transform(_c.value.clamp(0.0, 1.0));
              return Align(
                alignment: Alignment.topRight,
                child: Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.85 + 0.15 * t,
                    alignment: Alignment.topRight,
                    child: ImageFiltered(
                      imageFilter:
                          ImageFilter.blur(sigmaX: (1 - t) * 6, sigmaY: (1 - t) * 6),
                      child: Material(
                        // The overlay sits on the root Overlay, outside this
                        // screen's Scaffold/Material — without one here,
                        // Flutter flags every Text below with its "no
                        // Material ancestor" debug marker (double yellow
                        // underline).
                        color: Colors.transparent,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                            child: Container(
                              width: 232,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHigh
                                    .withValues(alpha: 0.82),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color:
                                        cs.outlineVariant.withValues(alpha: 0.3)),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (var i = 0; i < widget.actions.length; i++)
                                    _rowFor(i, t, cs),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _rowFor(int i, double panelT, ColorScheme cs) {
    final a = widget.actions[i];
    final delay = i * 0.07;
    final local = ((_c.value - delay) / (1 - delay)).clamp(0.0, 1.0);
    final e = _easeOut.transform(local);
    return Transform.translate(
      offset: Offset(0, (1 - e) * 12),
      child: Opacity(
        opacity: e,
        child: InkWell(
          onTap: () {
            _close();
            a.onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(a.icon, size: 20, color: cs.primary),
                const SizedBox(width: 12),
                Text(a.label,
                    style: TextStyle(fontSize: 15, color: cs.onSurface)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: IconButton(
        tooltip: widget.tooltip,
        onPressed: _toggle,
        icon: AnimatedBuilder(
          animation: _c,
          builder: (ctx, _) => Transform.rotate(
            angle: _c.value * math.pi / 4,
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );
  }
}
