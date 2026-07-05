import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_lock_service.dart';

/// Оверлей блокировки: показывается поверх всего приложения, пока
/// [AppLockService.locked] == true.
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

/// Экран ввода кода-пароля.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  String _entered = '';
  bool _error = false;
  bool _busy = false;

  Future<void> _onDigit(int d) async {
    final len = AppLockService.instance.codeLength;
    if (_busy || _entered.length >= len) return;
    setState(() {
      _entered += '$d';
      _error = false;
    });
    if (_entered.length == len) {
      _busy = true;
      final ok = await AppLockService.instance.verify(_entered);
      if (!ok) {
        HapticFeedback.mediumImpact();
        if (mounted) {
          setState(() {
            _error = true;
            _entered = '';
          });
        }
      }
      _busy = false;
      // on success the overlay hides via locked=false
    }
  }

  void _backspace() {
    if (_entered.isEmpty) return;
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _error = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final len = AppLockService.instance.codeLength;
    return Material(
      color: cs.surface,
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 44, color: cs.primary),
            const SizedBox(height: 16),
            Text('Rlink заблокирован',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              _error ? 'Неверный код' : 'Введите код-пароль',
              style: TextStyle(
                  color: _error ? cs.error : cs.onSurfaceVariant),
            ),
            const SizedBox(height: 26),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < len; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _entered.length
                            ? cs.primary
                            : Colors.transparent,
                        border: Border.all(color: cs.outline, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 40),
            _keypad(cs),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _key(ColorScheme cs, {String? label, VoidCallback? onTap, Widget? child}) {
    return SizedBox(
      width: 74,
      height: 74,
      child: (label == null && child == null)
          ? const SizedBox.shrink()
          : InkResponse(
              onTap: onTap,
              radius: 40,
              child: Center(
                child: child ??
                    Text(label!,
                        style: const TextStyle(
                            fontSize: 26, fontWeight: FontWeight.w400)),
              ),
            ),
    );
  }

  Widget _keypad(ColorScheme cs) {
    Widget digit(int d) => _key(cs, label: '$d', onTap: () => _onDigit(d));
    Widget row(List<Widget> ch) =>
        Row(mainAxisAlignment: MainAxisAlignment.center, children: ch);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([digit(1), digit(2), digit(3)]),
        row([digit(4), digit(5), digit(6)]),
        row([digit(7), digit(8), digit(9)]),
        row([
          _key(cs),
          digit(0),
          _key(cs,
              onTap: _backspace,
              child: Icon(Icons.backspace_outlined,
                  color: cs.onSurfaceVariant)),
        ]),
      ],
    );
  }
}
