import 'package:flutter/material.dart';

/// Custom page route with smooth slide + fade transition.
class SmoothPageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  SmoothPageRoute({required this.page})
      : super(
          pageBuilder: (_, __, ___) => page,
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 250),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curvedAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              // easeIn always delays the exit right as it starts (improve-
              // animations audit, 2026-09-23) — ease-out both ways.
              reverseCurve: Curves.easeOutCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.15, 0),
                end: Offset.zero,
              ).animate(curvedAnimation),
              child: FadeTransition(
                opacity: Tween<double>(begin: 0.0, end: 1.0)
                    .animate(curvedAnimation),
                child: child,
              ),
            );
          },
        );
}

/// Scale + fade transition for dialogs and overlays.
class ScaleFadeRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  ScaleFadeRoute({required this.page})
      : super(
          opaque: false,
          pageBuilder: (_, __, ___) => page,
          transitionDuration: const Duration(milliseconds: 250),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curvedAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutBack,
              // easeIn always delays the exit right as it starts (improve-
              // animations audit, 2026-09-23) — plain ease-out closes fast
              // without the entrance's overshoot looking odd in reverse.
              reverseCurve: Curves.easeOutCubic,
            );
            return ScaleTransition(
              scale:
                  Tween<double>(begin: 0.85, end: 1.0).animate(curvedAnimation),
              child: FadeTransition(
                opacity: curvedAnimation,
                child: child,
              ),
            );
          },
        );
}

/// Slide-up transition (for bottom sheets / full-screen overlays).
class SlideUpRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  SlideUpRoute({required this.page})
      : super(
          pageBuilder: (_, __, ___) => page,
          transitionDuration: const Duration(milliseconds: 350),
          reverseTransitionDuration: const Duration(milliseconds: 250),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curvedAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              // easeIn always delays the exit right as it starts (improve-
              // animations audit, 2026-09-23) — ease-out both ways.
              reverseCurve: Curves.easeOutCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.3),
                end: Offset.zero,
              ).animate(curvedAnimation),
              child: FadeTransition(
                opacity: curvedAnimation,
                child: child,
              ),
            );
          },
        );
}

/// Staggered list item animation wrapper.
/// Wraps a child widget with slide + fade animation, delayed by index.
class StaggeredListItem extends StatelessWidget {
  final int index;
  final Widget child;
  final Duration duration;
  final Duration maxDelay;

  const StaggeredListItem({
    super.key,
    required this.index,
    required this.child,
    this.duration = const Duration(milliseconds: 350),
    this.maxDelay = const Duration(milliseconds: 400),
  });

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    final delay = Duration(
      milliseconds: (index * 60).clamp(0, maxDelay.inMilliseconds),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (_, value, child) {
        final delayFrac = delay.inMilliseconds /
            (duration.inMilliseconds + maxDelay.inMilliseconds);
        final adjusted =
            ((value - delayFrac) / (1.0 - delayFrac)).clamp(0.0, 1.0);
        return Transform.translate(
          offset: Offset(0, 20 * (1.0 - adjusted)),
          child: Opacity(opacity: adjusted, child: child),
        );
      },
      child: child,
    );
  }
}

/// One-shot slide + fade animation for list rows.
///
/// Keeps expensive child subtrees static after the first entrance animation.
class OneShotSlideFade extends StatefulWidget {
  final Widget child;
  final Offset beginOffset;
  final Duration duration;
  final Duration delay;
  final Curve curve;
  /// Skip the animation and render [child] immediately — for a caller that
  /// already knows this exact instance shouldn't animate (e.g. a
  /// ListView.builder row whose id already played its entrance once; without
  /// this, a row disposed/recreated by scrolling outside cacheExtent would
  /// replay its "one-shot" animation every time it scrolls back into view —
  /// see improve-animations audit, 2026-09-23).
  final bool skip;

  const OneShotSlideFade({
    super.key,
    required this.child,
    this.beginOffset = const Offset(0, 0.08),
    this.duration = const Duration(milliseconds: 260),
    this.delay = Duration.zero,
    this.curve = Curves.easeOutCubic,
    this.skip = false,
  });

  @override
  State<OneShotSlideFade> createState() => _OneShotSlideFadeState();
}

class _OneShotSlideFadeState extends State<OneShotSlideFade>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.skip) return;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration + widget.delay,
    )..forward();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (widget.skip ||
        controller == null ||
        MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }

    final totalMs = controller.duration?.inMilliseconds ?? 1;
    final start = (widget.delay.inMilliseconds / totalMs).clamp(0.0, 0.95);
    final animation = CurvedAnimation(
      parent: controller,
      curve: Interval(start, 1, curve: widget.curve),
    );

    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: widget.beginOffset,
          end: Offset.zero,
        ).animate(animation),
        child: widget.child,
      ),
    );
  }
}

/// Animated scale-in wrapper (used for buttons, icons, etc.)
class ScaleIn extends StatelessWidget {
  final Widget child;
  final Duration duration;
  final Duration delay;

  const ScaleIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 300),
    this.delay = Duration.zero,
  });

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: duration + delay,
      curve: Curves.elasticOut,
      builder: (_, value, child) {
        final delayFrac =
            delay.inMilliseconds / (duration + delay).inMilliseconds;
        final adjusted =
            ((value - delayFrac) / (1.0 - delayFrac)).clamp(0.0, 1.0);
        return Transform.scale(
          scale: adjusted,
          child: Opacity(opacity: adjusted.clamp(0.0, 1.0), child: child),
        );
      },
      child: child,
    );
  }
}
