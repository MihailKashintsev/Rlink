import 'package:flutter/material.dart';

/// Вертикальная позиция глобального [AudioQueueMiniPlayer]: верхний край в логических px.
///
/// Экраны с особой шапкой (чат, список чатов с фильтрами) задают [barTop] через якорь
/// или [setBarTopBelowAppBar]. Остальные маршруты оставляют null — в [main] подставляется
/// отступ под стандартный [AppBar].
class AudioQueueMiniPlayerLayout {
  AudioQueueMiniPlayerLayout._();
  static final instance = AudioQueueMiniPlayerLayout._();

  final ValueNotifier<double?> barTop = ValueNotifier<double?>(null);

  /// Screens that show their own player (the music add-on, the full-screen
  /// player) hide the floating bar — two players for one track is just noise.
  ///
  /// A counter, not a flag: these screens nest, and with a plain bool the
  /// inner screen's dispose un-hid the bar while the outer one was still up.
  final ValueNotifier<bool> suppressed = ValueNotifier<bool>(false);
  int _suppressCount = 0;

  void pushSuppression() {
    _suppressCount++;
    _syncSuppressed();
  }

  void popSuppression() {
    if (_suppressCount > 0) _suppressCount--;
    _syncSuppressed();
  }

  void _syncSuppressed() {
    final v = _suppressCount > 0;
    if (suppressed.value == v) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      suppressed.value = v;
    });
  }

  void setBarTop(double? top) {
    if (barTop.value == top) return;
    // Use addPostFrameCallback to avoid setState during dispose
    WidgetsBinding.instance.addPostFrameCallback((_) {
      barTop.value = top;
    });
  }

  void clearBarTop() {
    // Use addPostFrameCallback to avoid setState during dispose
    WidgetsBinding.instance.addPostFrameCallback((_) {
      barTop.value = null;
    });
  }

  /// Сразу под системной плашкой и типовым [AppBar] (56dp).
  void setBarTopBelowAppBar(BuildContext context) {
    final mq = MediaQuery.of(context);
    setBarTop(mq.padding.top + kToolbarHeight);
  }

  static double defaultBarTop(BuildContext context) {
    final mq = MediaQuery.of(context);
    return mq.padding.top + kToolbarHeight;
  }

  /// [key] — виджет нулевой высоты сразу под зоной, над которой должен быть плеер.
  void scheduleBarTopFromAnchor(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return;
      setBarTop(box.localToGlobal(Offset.zero).dy);
    });
  }
}
