import 'package:flutter/material.dart';

/// Animates each character of [value] independently whenever it changes —
/// an unread badge ticking up, a participant count, a price. Port of the
/// per-character swap from skiper-ui's Aave demo: each character slot is
/// keyed by `index-char`, so a digit that didn't actually change (same
/// value at the same position) never re-animates, only the ones that did.
///
/// Built on [AnimatedSwitcher] (one instance per character) rather than
/// Framer Motion's `AnimatePresence`, which Flutter has no equivalent for.
class SpringValueText extends StatelessWidget {
  final String value;
  final TextStyle? style;
  final Duration duration;

  const SpringValueText({
    super.key,
    required this.value,
    this.style,
    this.duration = const Duration(milliseconds: 260),
  });

  static const _easeOut = Cubic(0.23, 1, 0.32, 1);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < value.length; i++)
          AnimatedSwitcher(
            duration: duration,
            switchInCurve: _easeOut,
            switchOutCurve: _easeOut,
            transitionBuilder: (child, anim) => Opacity(
              opacity: anim.value,
              child: Transform.translate(
                offset: Offset(0, (1 - anim.value) * 10),
                child: child,
              ),
            ),
            child: Text(
              value[i],
              key: ValueKey('$i-${value[i]}'),
              style: style,
            ),
          ),
      ],
    );
  }
}
