import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_lock_service.dart';
import '../widgets/security_visuals.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Overlay wrapper
// ─────────────────────────────────────────────────────────────────────────────

class AppLockOverlay extends StatelessWidget {
  const AppLockOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppLockService.instance.locked,
      builder: (_, locked, __) =>
          locked ? const AppLockScreen() : const SizedBox.shrink(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Root lock screen — routes to the right method widget
// ─────────────────────────────────────────────────────────────────────────────

class AppLockScreen extends StatelessWidget {
  const AppLockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final method = AppLockService.instance.method;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: switch (method) {
          LockMethod.pin4    => const _Pin4LockScreen(),
          LockMethod.pattern => const _PatternLockScreen(),
          LockMethod.text    => const _TextLockScreen(),
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PIN-4 lock screen with animated feedback
// ─────────────────────────────────────────────────────────────────────────────

class _Pin4LockScreen extends StatefulWidget {
  const _Pin4LockScreen();

  @override
  State<_Pin4LockScreen> createState() => _Pin4LockScreenState();
}

class _Pin4LockScreenState extends State<_Pin4LockScreen>
    with TickerProviderStateMixin {
  String _entered = '';
  bool _busy = false;
  _Pin4State _state = _Pin4State.idle;

  late final AnimationController _shakeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  late final Animation<double> _shake = Tween<double>(begin: 0, end: 1)
      .animate(CurvedAnimation(parent: _shakeCtrl, curve: Curves.elasticOut));

  late final AnimationController _successCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );
  late final Animation<double> _successScale =
      Tween<double>(begin: 0.55, end: 1.0).animate(CurvedAnimation(
          parent: _successCtrl,
          curve: const Interval(0, 0.45, curve: Curves.easeOutBack)));
  // Two full turns of the star carousel before they coalesce.
  late final Animation<double> _starRotation =
      Tween<double>(begin: 0, end: 4 * math.pi)
          .animate(CurvedAnimation(parent: _successCtrl, curve: Curves.easeInOut));
  // Checkmark stroke draws in as the stars pull inward.
  late final Animation<double> _checkT =
      Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
          parent: _successCtrl, curve: const Interval(0.4, 0.82)));
  // Real backdrop blur over the keypad just before the app is revealed.
  late final Animation<double> _blurAnim =
      Tween<double>(begin: 0, end: 22).animate(CurvedAnimation(
          parent: _successCtrl,
          curve: const Interval(0.6, 1.0, curve: Curves.easeInCubic)));

  @override
  void dispose() {
    _shakeCtrl.dispose();
    _successCtrl.dispose();
    super.dispose();
  }

  Future<void> _onDigit(int d) async {
    if (_busy || _entered.length >= 4) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered += '$d';
      _state = _Pin4State.idle;
    });
    if (_entered.length == 4) {
      _busy = true;
      final ok = await AppLockService.instance.verify(_entered);
      if (!mounted) return;
      if (ok) {
        setState(() => _state = _Pin4State.success);
        await _successCtrl.forward();
        // Unlock only now — the success seal has fully played.
        AppLockService.instance.unlock();
      } else {
        HapticFeedback.mediumImpact();
        setState(() {
          _state = _Pin4State.error;
          _entered = '';
        });
        _shakeCtrl.forward(from: 0);
      }
      _busy = false;
    }
  }

  void _backspace() {
    if (_entered.isEmpty || _busy) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _state = _Pin4State.idle;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isError = _state == _Pin4State.error;
    final isSuccess = _state == _Pin4State.success;

    return AnimatedBuilder(
      animation: Listenable.merge([_shake, _successCtrl]),
      builder: (_, __) {
        final dx = isError
            ? math.sin(_shake.value * math.pi * 6) * 10 * (1 - _shake.value)
            : 0.0;
        return Stack(
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                LockGlyph(size: 48, color: cs.primary),
                const SizedBox(height: 16),
                Text('Rlink заблокирован',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(
                    color: isError ? cs.error : cs.onSurfaceVariant,
                    fontSize: 14,
                  ),
                  child: Text(isError ? 'Неверный PIN' : 'Введите PIN-код'),
                ),
                const SizedBox(height: 32),
                // 4 dots
                Transform.translate(
                  offset: Offset(dx, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (i) {
                      final filled = i < _entered.length;
                      final color = isError
                          ? cs.error
                          : isSuccess
                              ? const Color(0xFF30A46C)
                              : cs.primary;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: filled ? color : Colors.transparent,
                          border: Border.all(
                            color: filled
                                ? color
                                : cs.outline.withValues(alpha: 0.5),
                            width: 1.5,
                          ),
                          boxShadow: filled && isSuccess
                              ? [
                                  BoxShadow(
                                    color: color.withValues(alpha: 0.5),
                                    blurRadius: 8,
                                  ),
                                ]
                              : null,
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 44),
                _Keypad(onDigit: _onDigit, onBackspace: _backspace),
              ],
            ),
            // Success: blur the keypad, then the orbiting-stars → checkmark seal.
            if (isSuccess) ...[
              if (_blurAnim.value > 0.1)
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(
                      sigmaX: _blurAnim.value,
                      sigmaY: _blurAnim.value,
                    ),
                    child: ColoredBox(
                      color: const Color(0xFF30A46C)
                          .withValues(alpha: 0.06 * (_blurAnim.value / 22)),
                    ),
                  ),
                ),
              Positioned.fill(
                child: Center(
                  child: SuccessSeal(
                    rotation: _starRotation.value,
                    checkT: _checkT.value,
                    scale: _successScale.value,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

enum _Pin4State { idle, error, success }

// ─────────────────────────────────────────────────────────────────────────────
// Pattern lock (9-dot grid)
// ─────────────────────────────────────────────────────────────────────────────

class _PatternLockScreen extends StatefulWidget {
  const _PatternLockScreen();

  @override
  State<_PatternLockScreen> createState() => _PatternLockScreenState();
}

class _PatternLockScreenState extends State<_PatternLockScreen>
    with SingleTickerProviderStateMixin {
  final List<int> _pattern = [];
  Offset? _currentDrag;
  bool _error = false;
  bool _busy = false;
  bool _success = false;

  late final AnimationController _shakeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void dispose() {
    _shakeCtrl.dispose();
    super.dispose();
  }

  Offset _dotPos(int index, Size size) {
    final col = index % 3;
    final row = index ~/ 3;
    final cellW = size.width / 3;
    final cellH = size.height / 3;
    return Offset(cellW * col + cellW / 2, cellH * row + cellH / 2);
  }

  void _onPanStart(DragStartDetails d, Size size) {
    if (_busy || _success) return;
    setState(() {
      _pattern.clear();
      _error = false;
      _currentDrag = d.localPosition;
    });
    _hitTest(d.localPosition, size);
  }

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    if (_busy || _success) return;
    setState(() => _currentDrag = d.localPosition);
    _hitTest(d.localPosition, size);
  }

  void _hitTest(Offset pos, Size size) {
    for (var i = 0; i < 9; i++) {
      if (_pattern.contains(i)) continue;
      final dot = _dotPos(i, size);
      if ((pos - dot).distance < 28) {
        HapticFeedback.selectionClick();
        setState(() => _pattern.add(i));
        break;
      }
    }
  }

  Future<void> _onPanEnd(DragEndDetails _) async {
    if (_busy || _success) return;
    if (_pattern.length < 4) {
      setState(() {
        _pattern.clear();
        _currentDrag = null;
        _error = _pattern.isNotEmpty;
      });
      return;
    }
    setState(() => _currentDrag = null);
    _busy = true;
    final code = _pattern.join(',');
    final ok = await AppLockService.instance.verify(code);
    if (!mounted) return;
    if (ok) {
      HapticFeedback.lightImpact();
      // Keep the connecting line drawn under the celebration overlay.
      setState(() => _success = true);
    } else {
      HapticFeedback.mediumImpact();
      setState(() => _error = true);
      await _shakeCtrl.forward(from: 0);
      if (mounted) setState(() => _pattern.clear());
    }
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        LockGlyph(size: 46, color: _error ? cs.error : cs.primary),
        const SizedBox(height: 16),
        Text('Rlink заблокирован',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            color: _error ? cs.error : cs.onSurfaceVariant,
            fontSize: 14,
          ),
          child: Text(_error
              ? 'Неверный графический ключ'
              : 'Нарисуйте графический ключ'),
        ),
        const SizedBox(height: 36),
        AnimatedBuilder(
          animation: _shakeCtrl,
          builder: (_, child) {
            final dx =
                math.sin(_shakeCtrl.value * math.pi * 5) * 8 * (1 - _shakeCtrl.value);
            return Transform.translate(
              offset: Offset(dx, 0),
              child: child,
            );
          },
          child: SizedBox(
            width: 280,
            height: 280,
            child: LayoutBuilder(
              builder: (_, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return GestureDetector(
                  onPanStart: (d) => _onPanStart(d, size),
                  onPanUpdate: (d) => _onPanUpdate(d, size),
                  onPanEnd: _onPanEnd,
                  child: CustomPaint(
                    painter: _PatternPainter(
                      pattern: _pattern,
                      currentDrag: _currentDrag,
                      error: _error,
                      primaryColor: cs.primary,
                      errorColor: cs.error,
                      outlineColor: cs.outline,
                    ),
                    size: size,
                  ),
                );
              },
            ),
          ),
        ),
      ],
        ),
        if (_success)
          Positioned.fill(
            child: LockSuccessOverlay(
              onCompleted: () => AppLockService.instance.unlock(),
            ),
          ),
      ],
    );
  }
}

class _PatternPainter extends CustomPainter {
  final List<int> pattern;
  final Offset? currentDrag;
  final bool error;
  final Color primaryColor;
  final Color errorColor;
  final Color outlineColor;

  const _PatternPainter({
    required this.pattern,
    required this.currentDrag,
    required this.error,
    required this.primaryColor,
    required this.errorColor,
    required this.outlineColor,
  });

  Offset _dotPos(int index, Size size) {
    final col = index % 3;
    final row = index ~/ 3;
    final cellW = size.width / 3;
    final cellH = size.height / 3;
    return Offset(cellW * col + cellW / 2, cellH * row + cellH / 2);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final color = error ? errorColor : primaryColor;

    // Glowing trail under the connecting line.
    if (pattern.length > 1 || (pattern.isNotEmpty && currentDrag != null)) {
      final glow = Paint()
        ..color = color.withValues(alpha: 0.28)
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6);
      final trail = Path();
      trail.moveTo(_dotPos(pattern.first, size).dx, _dotPos(pattern.first, size).dy);
      for (var i = 1; i < pattern.length; i++) {
        trail.lineTo(_dotPos(pattern[i], size).dx, _dotPos(pattern[i], size).dy);
      }
      if (currentDrag != null) trail.lineTo(currentDrag!.dx, currentDrag!.dy);
      canvas.drawPath(trail, glow);
    }

    // Solid connecting line with directional arrows between nodes.
    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < pattern.length - 1; i++) {
      final a = _dotPos(pattern[i], size);
      final b = _dotPos(pattern[i + 1], size);
      canvas.drawLine(a, b, linePaint);
      _arrow(canvas, a, b, color);
    }
    if (pattern.isNotEmpty && currentDrag != null) {
      canvas.drawLine(_dotPos(pattern.last, size), currentDrag!,
          linePaint..color = color.withValues(alpha: 0.5));
    }

    // Draw the nine nodes.
    for (var i = 0; i < 9; i++) {
      final pos = _dotPos(i, size);
      final selected = pattern.contains(i);
      if (selected) {
        // Halo around a selected node.
        canvas.drawCircle(
          pos,
          20,
          Paint()
            ..color = color.withValues(alpha: 0.22)
            ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 5),
        );
      }
      canvas.drawCircle(
        pos,
        24,
        Paint()
          ..color = selected
              ? color.withValues(alpha: 0.4)
              : outlineColor.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 2 : 1.4,
      );
      canvas.drawCircle(
        pos,
        selected ? 9 : 6,
        Paint()
          ..color = selected ? color : outlineColor.withValues(alpha: 0.4)
          ..style = PaintingStyle.fill,
      );
    }
  }

  // Little chevron pointing along a→b, drawn at the midpoint.
  void _arrow(Canvas canvas, Offset a, Offset b, Color color) {
    final dir = b - a;
    final len = dir.distance;
    if (len < 1) return;
    final unit = dir / len;
    final mid = a + unit * (len / 2);
    final ang = math.atan2(unit.dy, unit.dx);
    const armLen = 7.0;
    const spread = 2.4; // radians from the shaft
    final p1 = mid +
        Offset(math.cos(ang + math.pi - spread), math.sin(ang + math.pi - spread)) *
            armLen;
    final p2 = mid +
        Offset(math.cos(ang + math.pi + spread), math.sin(ang + math.pi + spread)) *
            armLen;
    final ap = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(mid, p1, ap);
    canvas.drawLine(mid, p2, ap);
  }

  @override
  bool shouldRepaint(_PatternPainter old) =>
      old.pattern != pattern ||
      old.currentDrag != currentDrag ||
      old.error != error;
}

// ─────────────────────────────────────────────────────────────────────────────
// Text password lock screen
// ─────────────────────────────────────────────────────────────────────────────

class _TextLockScreen extends StatefulWidget {
  const _TextLockScreen();

  @override
  State<_TextLockScreen> createState() => _TextLockScreenState();
}

class _TextLockScreenState extends State<_TextLockScreen>
    with SingleTickerProviderStateMixin {
  final _ctrl = TextEditingController();
  bool _error = false;
  bool _busy = false;
  bool _obscure = true;
  bool _success = false;

  late final AnimationController _shakeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void dispose() {
    _ctrl.dispose();
    _shakeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _success || _ctrl.text.isEmpty) return;
    _busy = true;
    final ok = await AppLockService.instance.verify(_ctrl.text);
    if (!mounted) return;
    if (ok) {
      HapticFeedback.lightImpact();
      FocusScope.of(context).unfocus();
      setState(() => _success = true);
    } else {
      HapticFeedback.mediumImpact();
      setState(() {
        _error = true;
        _ctrl.clear();
      });
      _shakeCtrl.forward(from: 0);
    }
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          LockGlyph(size: 46, color: _error ? cs.error : cs.primary),
          const SizedBox(height: 16),
          Text('Rlink заблокирован',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              color: _error ? cs.error : cs.onSurfaceVariant,
              fontSize: 14,
            ),
            child: Text(_error ? 'Неверный пароль' : 'Введите пароль'),
          ),
          const SizedBox(height: 32),
          AnimatedBuilder(
            animation: _shakeCtrl,
            builder: (_, child) {
              final dx = math.sin(_shakeCtrl.value * math.pi * 5) *
                  8 *
                  (1 - _shakeCtrl.value);
              return Transform.translate(
                offset: Offset(dx, 0),
                child: child,
              );
            },
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_error) setState(() => _error = false);
              },
              decoration: InputDecoration(
                hintText: 'Пароль',
                filled: true,
                fillColor: cs.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: _error ? cs.error : cs.primary,
                    width: 1.5,
                  ),
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: (_busy || _success) ? null : _submit,
              child: const Text('Войти'),
            ),
          ),
        ],
      ),
        ),
        if (_success)
          Positioned.fill(
            child: LockSuccessOverlay(
              onCompleted: () => AppLockService.instance.unlock(),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared numeric keypad
// ─────────────────────────────────────────────────────────────────────────────

class _Keypad extends StatelessWidget {
  final void Function(int) onDigit;
  final VoidCallback onBackspace;

  const _Keypad({required this.onDigit, required this.onBackspace});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget key(int d) => _KeyButton(
          label: '$d',
          onTap: () => onDigit(d),
        );
    Widget row(List<Widget> children) =>
        Row(mainAxisAlignment: MainAxisAlignment.center, children: children);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([key(1), key(2), key(3)]),
        row([key(4), key(5), key(6)]),
        row([key(7), key(8), key(9)]),
        row([
          const SizedBox(width: 74, height: 74),
          key(0),
          _KeyButton(
            onTap: onBackspace,
            child: Icon(Icons.backspace_outlined,
                size: 22, color: cs.onSurfaceVariant),
          ),
        ]),
      ],
    );
  }
}

class _KeyButton extends StatefulWidget {
  final String? label;
  final VoidCallback? onTap;
  final Widget? child;

  const _KeyButton({this.label, this.onTap, this.child});

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap?.call();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.90 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: SizedBox(
          width: 74,
          height: 74,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: _pressed
                    ? cs.primary.withValues(alpha: 0.15)
                    : cs.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: widget.child ??
                    Text(
                      widget.label ?? '',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w400,
                        color: cs.onSurface,
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
