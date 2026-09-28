import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// A single-line text field whose caret glides (spring physics) to each new
/// position instead of jumping — port of skiper-ui's "Smooth caret input".
///
/// The native caret is hidden (`cursorColor: transparent`); a [TextPainter]
/// built with the same text/style measures the real caret's x offset, and an
/// overlay bar springs to it on every selection change. Deliberately not
/// wired into the app's real (multi-line, internally-scrolling) composer —
/// the reference component's own docs call this "a playful experiment,
/// designed primarily for creative or unconventional interfaces... not
/// intended for production or accessibility-critical scenarios", and
/// replicating exact caret alignment once a field scrolls its content
/// needs real device testing this sandbox can't do. Safe and correct for a
/// single line of left-aligned, non-wrapping text — use it there deliberately
/// (behind AppSettings.smoothCaretEnabled), not as a drop-in TextField swap.
class SmoothCaretField extends StatefulWidget {
  final TextEditingController controller;
  final String? hintText;
  final TextStyle? style;
  final EdgeInsets padding;

  const SmoothCaretField({
    super.key,
    required this.controller,
    this.hintText,
    this.style,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  });

  @override
  State<SmoothCaretField> createState() => _SmoothCaretFieldState();
}

class _SmoothCaretFieldState extends State<SmoothCaretField>
    with SingleTickerProviderStateMixin {
  final _focusNode = FocusNode();
  late final AnimationController _spring =
      AnimationController(vsync: this, duration: const Duration(seconds: 1));
  double _caretX = 0;
  double _animFrom = 0;
  double _animTo = 0;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scheduleUpdate);
    _focusNode.addListener(_scheduleUpdate);
    _spring.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scheduleUpdate);
    _spring.removeListener(_onTick);
    _focusNode.dispose();
    _spring.dispose();
    super.dispose();
  }

  void _scheduleUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  double _measure(String upToCursor) {
    final tp = TextPainter(
      text: TextSpan(text: upToCursor, style: widget.style ?? const TextStyle(fontSize: 16)),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  void _update() {
    if (!mounted) return;
    final sel = widget.controller.selection;
    final shouldShow = _focusNode.hasFocus && sel.isValid && sel.isCollapsed;
    if (!shouldShow) {
      if (_visible) setState(() => _visible = false);
      return;
    }
    final offset = sel.baseOffset.clamp(0, widget.controller.text.length);
    final x = _measure(widget.controller.text.substring(0, offset));
    if (!_visible) {
      setState(() {
        _visible = true;
        _caretX = x;
        _animFrom = x;
        _animTo = x;
      });
      return;
    }
    if ((x - _animTo).abs() < 0.5) return;
    _animFrom = _caretX;
    _animTo = x;
    final sim = SpringSimulation(
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 320),
        bounce: 0.18,
      ),
      0,
      1,
      0,
    );
    _spring.animateWith(sim);
  }

  void _onTick() {
    setState(() => _caretX = ui.lerpDouble(_animFrom, _animTo, _spring.value)!);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = widget.style ?? const TextStyle(fontSize: 16);
    return Padding(
      padding: widget.padding,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          TextField(
            controller: widget.controller,
            focusNode: _focusNode,
            style: style,
            cursorColor: Colors.transparent,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              hintText: widget.hintText,
              hintStyle: style.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
            ),
          ),
          if (_visible)
            Positioned(
              left: _caretX,
              top: -1,
              bottom: -1,
              child: IgnorePointer(
                child: Container(
                  width: 2,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
