import 'dart:async';

import 'package:flutter/material.dart';

import 'spring_value_text.dart';

/// A destructive button that, on first tap, arms a countdown instead of
/// firing immediately — tapping again during the countdown cancels it.
/// Port of skiper-ui's `TimedUndoAction`, for delete-style actions worth a
/// beat to reconsider (per-message "delete for everyone", leaving a group,
/// deleting a channel/chat) rather than every confirmation in the app.
class TimedUndoButton extends StatefulWidget {
  final String actionLabel;
  final String undoLabel;
  final VoidCallback onConfirmed;
  final int seconds;
  final IconData undoIcon;

  const TimedUndoButton({
    super.key,
    required this.actionLabel,
    required this.onConfirmed,
    this.undoLabel = 'Отмена',
    this.seconds = 4,
    this.undoIcon = Icons.undo_rounded,
  });

  @override
  State<TimedUndoButton> createState() => _TimedUndoButtonState();
}

class _TimedUndoButtonState extends State<TimedUndoButton> {
  static const _easeOut = Cubic(0.23, 1, 0.32, 1);

  bool _arming = false;
  late int _left = widget.seconds;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    if (_arming) {
      _timer?.cancel();
      setState(() {
        _arming = false;
        _left = widget.seconds;
      });
      return;
    }
    setState(() {
      _arming = true;
      _left = widget.seconds;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _left--);
      if (_left <= 0) {
        t.cancel();
        widget.onConfirmed();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _toggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: _easeOut,
        padding: EdgeInsets.symmetric(
            horizontal: _arming ? 10 : 16, vertical: 10),
        decoration: BoxDecoration(
          color: _arming ? cs.errorContainer : cs.error,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_arming) ...[
              Icon(widget.undoIcon, size: 18, color: cs.onErrorContainer),
              const SizedBox(width: 8),
            ],
            SpringValueText(
              value: _arming ? widget.undoLabel : widget.actionLabel,
              staggerStep: 0.05,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _arming ? cs.onErrorContainer : cs.onError,
              ),
            ),
            if (_arming) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.error,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SpringValueText(
                  value: '$_left',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.onError,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
