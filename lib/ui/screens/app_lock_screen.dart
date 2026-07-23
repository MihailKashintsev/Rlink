import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_lock_service.dart';

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
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _successScale =
      Tween<double>(begin: 0.6, end: 1.0).animate(CurvedAnimation(
          parent: _successCtrl,
          curve: const Interval(0, 0.5, curve: Curves.easeOutBack)));
  late final Animation<double> _starRotation =
      Tween<double>(begin: 0, end: 2 * math.pi)
          .animate(CurvedAnimation(parent: _successCtrl, curve: Curves.easeIn));
  late final Animation<double> _checkOpacity =
      Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
          parent: _successCtrl, curve: const Interval(0.5, 0.8)));
  late final Animation<double> _blurAnim =
      Tween<double>(begin: 0, end: 18).animate(CurvedAnimation(
          parent: _successCtrl,
          curve: const Interval(0.7, 1.0, curve: Curves.easeIn)));

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
        // AppLockService.locked flips to false → overlay disappears
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
                Icon(Icons.lock_outline_rounded, size: 42, color: cs.primary),
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
                              ? Colors.green
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
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 44),
                _Keypad(onDigit: _onDigit, onBackspace: _backspace),
              ],
            ),
            // Success overlay: stars + checkmark + blur
            if (isSuccess)
              _SuccessOverlay(
                rotation: _starRotation.value,
                checkOpacity: _checkOpacity.value,
                scale: _successScale.value,
                blur: _blurAnim.value,
              ),
          ],
        );
      },
    );
  }
}

enum _Pin4State { idle, error, success }

// Animated success overlay
class _SuccessOverlay extends StatelessWidget {
  final double rotation;
  final double checkOpacity;
  final double scale;
  final double blur;

  const _SuccessOverlay({
    required this.rotation,
    required this.checkOpacity,
    required this.scale,
    required this.blur,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.green.withValues(alpha: 0.08),
        child: Center(
          child: Transform.scale(
            scale: scale,
            child: SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 4 stars rotating
                  for (var i = 0; i < 4; i++)
                    Transform.rotate(
                      angle: rotation + i * math.pi / 2,
                      child: Transform.translate(
                        offset: const Offset(0, -50),
                        child: const Icon(Icons.star_rounded,
                            color: Colors.green, size: 22),
                      ),
                    ),
                  // Checkmark
                  Opacity(
                    opacity: checkOpacity,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.green.withValues(alpha: 0.4),
                            blurRadius: 20,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.check_rounded,
                          color: Colors.white, size: 40),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
    if (_busy) return;
    setState(() {
      _pattern.clear();
      _error = false;
      _currentDrag = d.localPosition;
    });
    _hitTest(d.localPosition, size);
  }

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    if (_busy) return;
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
    if (_busy || _pattern.length < 4) {
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
    if (!ok) {
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
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.lock_outline_rounded, size: 42, color: cs.primary),
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
    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    // Draw lines between connected dots
    for (var i = 0; i < pattern.length - 1; i++) {
      canvas.drawLine(
        _dotPos(pattern[i], size),
        _dotPos(pattern[i + 1], size),
        linePaint,
      );
    }
    // Line from last dot to current finger position
    if (pattern.isNotEmpty && currentDrag != null) {
      canvas.drawLine(_dotPos(pattern.last, size), currentDrag!, linePaint);
    }

    // Draw dots
    for (var i = 0; i < 9; i++) {
      final pos = _dotPos(i, size);
      final selected = pattern.contains(i);
      final dotPaint = Paint()
        ..color = selected ? color : outlineColor.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill;
      final ringPaint = Paint()
        ..color = selected ? color.withValues(alpha: 0.25) : outlineColor.withValues(alpha: 0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(pos, selected ? 14 : 10, dotPaint);
      canvas.drawCircle(pos, 22, ringPaint);
    }
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
    if (_busy || _ctrl.text.isEmpty) return;
    _busy = true;
    final ok = await AppLockService.instance.verify(_ctrl.text);
    if (!mounted) return;
    if (!ok) {
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline_rounded, size: 42, color: cs.primary),
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
              onPressed: _busy ? null : _submit,
              child: const Text('Войти'),
            ),
          ),
        ],
      ),
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
