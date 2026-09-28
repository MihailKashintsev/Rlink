import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

/// A search trigger that morphs into a floating, blurred command-palette
/// panel instead of the platform's inline AppBar text field — port of
/// skiper-ui's CommandSearch. Controlled by [open] rather than owning its
/// own open/close state, so it can be driven from more than one place (an
/// AppBar icon and a bottom-nav button, say) without the two disagreeing.
///
/// The "F" hotkey and Escape-to-close from the original are kept (useful on
/// desktop builds); arrow-key result navigation is not — the results body
/// is supplied via [resultsBuilder] and is whatever list/sections the host
/// screen already renders, which isn't a flat indexable list here.
class SpringSearchPalette extends StatefulWidget {
  final bool open;
  final VoidCallback onToggle;
  final TextEditingController controller;
  final ValueChanged<String> onQueryChanged;
  final WidgetBuilder resultsBuilder;
  final String hintText;
  final String tooltip;

  const SpringSearchPalette({
    super.key,
    required this.open,
    required this.onToggle,
    required this.controller,
    required this.onQueryChanged,
    required this.resultsBuilder,
    this.hintText = '',
    this.tooltip = '',
  });

  @override
  State<SpringSearchPalette> createState() => SpringSearchPaletteState();
}

class SpringSearchPaletteState extends State<SpringSearchPalette>
    with SingleTickerProviderStateMixin {
  static const _easeOut = Cubic(0.23, 1, 0.32, 1);

  final LayerLink _link = LayerLink();
  final FocusNode _fieldFocus = FocusNode();
  late final AnimationController _c = AnimationController(vsync: this);
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
    if (widget.open) {
      _insertOverlay();
      _runSpring(1);
    }
  }

  @override
  void didUpdateWidget(SpringSearchPalette old) {
    super.didUpdateWidget(old);
    if (widget.open == old.open) return;
    if (widget.open) {
      _insertOverlay();
      _runSpring(1);
      Future.delayed(const Duration(milliseconds: 90), () {
        if (mounted && widget.open) _fieldFocus.requestFocus();
      });
    } else {
      _runSpring(0);
      Future.delayed(const Duration(milliseconds: 240), () {
        _entry?.remove();
        _entry = null;
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _entry?.remove();
    _c.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!widget.open && event.logicalKey == LogicalKeyboardKey.keyF) {
      final focusCtx = FocusManager.instance.primaryFocus?.context;
      if (focusCtx != null && focusCtx.widget is EditableText) return false;
      widget.onToggle();
      return true;
    }
    if (widget.open && event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onToggle();
      return true;
    }
    return false;
  }

  void _insertOverlay() {
    _entry = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void _runSpring(double target) {
    final sim = SpringSimulation(
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 320),
        bounce: 0.08,
      ),
      _c.value,
      target,
      0,
    );
    _c.animateWith(sim);
  }

  Widget _buildOverlay(BuildContext overlayCtx) {
    final cs = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (ctx, _) {
        final t = _easeOut.transform(_c.value.clamp(0.0, 1.0));
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onToggle,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 2 * t, sigmaY: 2 * t),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.28 * t),
                  ),
                ),
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 10),
              child: Align(
                alignment: Alignment.topRight,
                child: Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.9 + 0.1 * t,
                    alignment: Alignment.topRight,
                    child: GestureDetector(
                      // Swallow taps so they don't fall through to the
                      // backdrop's dismiss handler.
                      onTap: () {},
                      child: Material(
                        color: Colors.transparent,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                            child: Container(
                              width: math.min(400, media.size.width - 24),
                              height: math.min(460, media.size.height * 0.64),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHigh
                                    .withValues(alpha: 0.92),
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color:
                                      cs.outlineVariant.withValues(alpha: 0.3),
                                ),
                              ),
                              child: Column(
                                children: [
                                  Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(16, 14, 10, 14),
                                    child: Row(
                                      children: [
                                        Icon(Icons.search,
                                            size: 20,
                                            color: cs.onSurfaceVariant),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: TextField(
                                            controller: widget.controller,
                                            focusNode: _fieldFocus,
                                            style: TextStyle(
                                                fontSize: 16,
                                                color: cs.onSurface),
                                            decoration: InputDecoration(
                                              isCollapsed: true,
                                              border: InputBorder.none,
                                              hintText: widget.hintText,
                                            ),
                                            onChanged: widget.onQueryChanged,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        GestureDetector(
                                          onTap: widget.onToggle,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 3),
                                            decoration: BoxDecoration(
                                              border: Border.all(
                                                color: cs.outlineVariant
                                                    .withValues(alpha: 0.5),
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              'Esc',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                color: cs.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Divider(
                                      height: 1,
                                      color:
                                          cs.outlineVariant.withValues(alpha: 0.25)),
                                  Expanded(
                                    child: ListenableBuilder(
                                      listenable: widget.controller,
                                      builder: (ctx2, _) =>
                                          widget.resultsBuilder(ctx2),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: IconButton(
        tooltip: widget.tooltip,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: _easeOut,
          switchOutCurve: _easeOut,
          transitionBuilder: (child, anim) => RotationTransition(
            turns: Tween<double>(begin: 0.75, end: 1).animate(anim),
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: Icon(
            widget.open ? Icons.close : Icons.search,
            key: ValueKey<bool>(widget.open),
          ),
        ),
        onPressed: widget.onToggle,
      ),
    );
  }
}
