import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderMetaData;
import 'package:flutter/services.dart';
import '../../l10n/app_l10n.dart';

/// Наблюдаемое состояние одного жеста «удержание → запись». Общее для кнопки
/// записи и строки записи в поле ввода (таймер, «Влево, отмена», «Отмена»…).
class RecordGesture extends ChangeNotifier {
  /// Дистанция вверх (px), после которой запись закрепляется.
  static const lockDistance = 80.0;

  /// Дистанция влево (px), после которой запись отменяется (палец).
  static const cancelDistance = 110.0;

  bool holding = false;
  bool locked = false;

  /// Жест начат мышью → тексты и отмена как на ПК (по «выходу за поле»).
  bool mouse = false;

  /// Мышь: курсор сейчас вне поля ввода (отпустить = отмена).
  bool outside = false;

  /// Смещение пальца/курсора от точки нажатия.
  Offset drag = Offset.zero;

  double get lockProgress => (-drag.dy / lockDistance).clamp(0.0, 1.0);
  double get cancelProgress => (-drag.dx / cancelDistance).clamp(0.0, 1.0);

  void begin({required bool mouse}) {
    holding = true;
    locked = false;
    this.mouse = mouse;
    outside = false;
    drag = Offset.zero;
    notifyListeners();
  }

  void moved(Offset d, {bool? outside}) {
    drag = d;
    if (outside != null) this.outside = outside;
    notifyListeners();
  }

  void lock() {
    locked = true;
    outside = false;
    drag = Offset.zero;
    notifyListeners();
  }

  void reset() {
    if (!holding && !locked && drag == Offset.zero && !outside) return;
    holding = false;
    locked = false;
    outside = false;
    drag = Offset.zero;
    notifyListeners();
  }
}

class _RecordKeepTag {
  const _RecordKeepTag();
}

const _keep = _RecordKeepTag();

/// Всё, что обёрнуто в [RecordKeep], считается «внутри поля»: на ПК отпустить
/// курсор / нажать за его пределами = отмена записи.
class RecordKeep extends StatelessWidget {
  final Widget child;
  const RecordKeep({super.key, required this.child});

  @override
  Widget build(BuildContext context) => MetaData(
        metaData: _keep,
        behavior: HitTestBehavior.translucent,
        child: child,
      );
}

bool _insideRecordField(BuildContext context, Offset pos) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, pos, View.of(context).viewId);
  return result.path.any((e) =>
      e.target is RenderMetaData &&
      (e.target as RenderMetaData).metaData == _keep);
}

/// Как в Telegram: короткое нажатие переключает голос ↔ быстрое видео;
/// удержание — запись, отпускание — отправка; вверх — закрепить (над кнопкой
/// появляется пауза); влево — отмена. На ПК отмена — отпустить/нажать вне поля.
class TelegramMediaRecordButton extends StatefulWidget {
  final RecordGesture gesture;
  final bool isSending;
  final bool isRecording;
  final bool isHoldVideoStarting;
  final ColorScheme colorScheme;
  final VoidCallback onVoiceHoldStart;
  final Future<void> Function() onVideoHoldStart;
  final Future<void> Function() onHoldReleaseSend;
  final Future<void> Function() onHoldCancelDiscard;

  /// Вызывается при закреплении (и для голоса, и для видео).
  final void Function(bool locked)? onHoldLockChanged;

  /// Пауза/продолжение записи видео (только в закреплённом режиме).
  final Future<void> Function()? onLockedVideoPauseToggle;
  final ValueListenable<bool>? lockedVideoPausedListenable;

  /// Пауза/продолжение записи голоса (только в закреплённом режиме).
  final Future<void> Function()? onLockedVoicePauseToggle;
  final ValueListenable<bool>? lockedVoicePausedListenable;

  const TelegramMediaRecordButton({
    super.key,
    required this.gesture,
    required this.isSending,
    required this.isRecording,
    required this.isHoldVideoStarting,
    required this.colorScheme,
    required this.onVoiceHoldStart,
    required this.onVideoHoldStart,
    required this.onHoldReleaseSend,
    required this.onHoldCancelDiscard,
    this.onHoldLockChanged,
    this.onLockedVideoPauseToggle,
    this.lockedVideoPausedListenable,
    this.onLockedVoicePauseToggle,
    this.lockedVoicePausedListenable,
  });

  @override
  State<TelegramMediaRecordButton> createState() =>
      _TelegramMediaRecordButtonState();
}

class _TelegramMediaRecordButtonState extends State<TelegramMediaRecordButton> {
  static const _holdMs = 260;

  bool _videoMode = false;
  bool _holdFired = false;
  int? _pointer;
  Offset _down = Offset.zero;
  Timer? _holdTimer;
  final _link = LayerLink();
  OverlayEntry? _hint;
  OverlayEntry? _pause;
  bool _routeAdded = false;

  RecordGesture get g => widget.gesture;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _removeHint();
    _removePause();
    _removeRoute();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TelegramMediaRecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRecording && !widget.isRecording) {
      // Recording ended by itself (max length, error, cancelled from the bar).
      _holdTimer?.cancel();
      _pointer = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _removeHint();
        _removePause();
        _removeRoute();
        g.reset();
      });
    }
  }

  // ── overlays ────────────────────────────────────────────────────────────

  void _removeHint() {
    _hint?.remove();
    _hint = null;
  }

  void _removePause() {
    _pause?.remove();
    _pause = null;
  }

  void _showHint() {
    if (_hint != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final cs = widget.colorScheme;
    // Align loosens the overlay's tight constraints so the hint keeps its size.
    _hint = OverlayEntry(
      builder: (_) => Align(
        alignment: Alignment.topLeft,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -12),
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: g,
              builder: (_, __) => _LockHint(progress: g.lockProgress, cs: cs),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_hint!);
  }

  bool get _canPause => _videoMode
      ? widget.onLockedVideoPauseToggle != null &&
          widget.lockedVideoPausedListenable != null
      : widget.onLockedVoicePauseToggle != null &&
          widget.lockedVoicePausedListenable != null;

  void _showPause() {
    if (_pause != null || !_canPause) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final cs = widget.colorScheme;
    final paused = _videoMode
        ? widget.lockedVideoPausedListenable!
        : widget.lockedVoicePausedListenable!;
    final toggle = _videoMode
        ? widget.onLockedVideoPauseToggle!
        : widget.onLockedVoicePauseToggle!;
    _pause = OverlayEntry(
      builder: (_) => Align(
        alignment: Alignment.topLeft,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -10),
          child: RecordKeep(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.6, end: 1),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutBack,
              builder: (_, v, child) => Transform.scale(
                scale: v,
                child: Opacity(opacity: v.clamp(0.0, 1.0), child: child),
              ),
              child: ValueListenableBuilder<bool>(
                valueListenable: paused,
                builder: (_, isPaused, __) => Material(
                  color: cs.surfaceContainerHighest,
                  elevation: 4,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => unawaited(toggle()),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(
                        isPaused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_pause!);
  }

  // ── desktop: click outside the field cancels a locked recording ─────────

  void _addRoute() {
    if (_routeAdded) return;
    _routeAdded = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
  }

  void _removeRoute() {
    if (!_routeAdded) return;
    _routeAdded = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
  }

  void _onGlobalPointer(PointerEvent e) {
    if (e is! PointerDownEvent || !g.locked || !g.mouse || !mounted) return;
    if (_insideRecordField(context, e.position)) return;
    _cancel();
  }

  // ── gesture ─────────────────────────────────────────────────────────────

  void _onHoldFire() {
    if (!mounted || widget.isSending) return;
    _holdFired = true;
    g.begin(mouse: _mouseDown);
    _showHint();
    HapticFeedback.selectionClick();
    if (_videoMode) {
      unawaited(widget.onVideoHoldStart());
    } else {
      widget.onVoiceHoldStart();
    }
  }

  bool _mouseDown = false;

  void _onPointerDown(PointerDownEvent e) {
    if (widget.isSending || widget.isHoldVideoStarting) return;
    if (widget.isRecording && g.locked) return; // taps handled by onTap
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryButton)
      return;
    _holdFired = false;
    _pointer = e.pointer;
    _down = e.position;
    _mouseDown = e.kind == PointerDeviceKind.mouse;
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(milliseconds: _holdMs), _onHoldFire);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _pointer || !g.holding || g.locked) return;
    final d = e.position - _down;
    g.moved(d,
        outside: g.mouse ? !_insideRecordField(context, e.position) : null);
    if (-d.dy >= RecordGesture.lockDistance) {
      _lock();
    } else if (!g.mouse && -d.dx >= RecordGesture.cancelDistance) {
      HapticFeedback.mediumImpact();
      _cancel();
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _holdTimer?.cancel();
    if (!_holdFired) {
      // Short tap: switch voice ↔ video.
      if (!widget.isRecording && !widget.isHoldVideoStarting) {
        setState(() => _videoMode = !_videoMode);
      }
      return;
    }
    if (g.locked) return; // finger lifted after locking — keep recording
    final outside = g.mouse && !_insideRecordField(context, e.position);
    if (outside) {
      _cancel();
    } else {
      unawaited(_sendWhenReady());
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _holdTimer?.cancel();
    if (_holdFired && !g.locked) _cancel();
  }

  void _lock() {
    HapticFeedback.mediumImpact();
    g.lock();
    widget.onHoldLockChanged?.call(true);
    _removeHint();
    _showPause();
    if (g.mouse) _addRoute();
  }

  void _endGesture() {
    _holdTimer?.cancel();
    _removeHint();
    _removePause();
    _removeRoute();
    g.reset();
  }

  void _cancel() {
    _endGesture();
    unawaited(widget.onHoldCancelDiscard());
  }

  Future<void> _sendWhenReady() async {
    _endGesture();
    // Recording may still be starting (camera init / mic permission).
    final maxTicks = widget.isHoldVideoStarting ? 125 : 25;
    for (var i = 0; i < maxTicks; i++) {
      if (!mounted) return;
      if (widget.isRecording && !widget.isHoldVideoStarting) break;
      await Future.delayed(const Duration(milliseconds: 40));
    }
    if (!mounted) return;
    if (widget.isHoldVideoStarting && !widget.isRecording) {
      await widget.onHoldCancelDiscard();
      return;
    }
    if (!widget.isRecording) return;
    await widget.onHoldReleaseSend();
  }

  void _onTap() {
    if (!g.locked || !widget.isRecording) return;
    unawaited(_sendWhenReady());
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.colorScheme;
    final busy = widget.isHoldVideoStarting;

    return Tooltip(
      message: _videoMode
          ? AppL10n.t(
              'Короткое нажатие — голос; удерживайте для быстрого видео')
          : AppL10n.t('Короткое нажатие — видео; удерживайте для голоса'),
      triggerMode: TooltipTriggerMode.manual,
      child: CompositedTransformTarget(
        link: _link,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: SizedBox(
              width: 44,
              height: 44,
              child: ListenableBuilder(
                listenable: g,
                builder: (_, __) {
                  final active = g.holding || g.locked || widget.isRecording;
                  final follow = g.holding && !g.locked
                      ? Offset(g.drag.dx.clamp(-140.0, 0.0),
                          g.drag.dy.clamp(-90.0, 0.0))
                      : Offset.zero;
                  final IconData icon = g.locked
                      ? Icons.arrow_upward_rounded
                      : (_videoMode
                          ? Icons.videocam_rounded
                          : Icons.mic_rounded);
                  return Transform.translate(
                    offset: follow,
                    child: AnimatedScale(
                      scale: g.holding && !g.locked ? 1.35 : 1.0,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          color: active ? Colors.redAccent : cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: busy
                            ? Padding(
                                padding: const EdgeInsets.all(11),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: cs.onPrimary,
                                ),
                              )
                            : Icon(icon, color: cs.onPrimary, size: 22),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// «Замочек» над кнопкой: подсказывает, куда тянуть. Чем ближе палец к закрепу,
/// тем ниже он уходит и тем прозрачнее становится.
class _LockHint extends StatefulWidget {
  final double progress;
  final ColorScheme cs;
  const _LockHint({required this.progress, required this.cs});

  @override
  State<_LockHint> createState() => _LockHintState();
}

class _LockHintState extends State<_LockHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.cs;
    final p = widget.progress;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (_, appear, child) => Opacity(
        opacity: (appear * (1 - p)).clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - appear) * 14 + p * 56),
          child: child,
        ),
      ),
      child: Container(
        width: 40,
        height: 78,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              p > 0.6 ? Icons.lock_rounded : Icons.lock_open_rounded,
              size: 20,
              color: cs.onSurface,
            ),
            const SizedBox(height: 4),
            AnimatedBuilder(
              animation: _bob,
              builder: (_, __) => Transform.translate(
                offset: Offset(0, -5 * _bob.value),
                child: Opacity(
                  opacity: 0.45 + 0.4 * _bob.value,
                  child: Icon(Icons.keyboard_arrow_up_rounded,
                      size: 22, color: cs.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
