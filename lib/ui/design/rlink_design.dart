import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show StandardMessageCodec;

import '../../services/app_settings.dart';
import '../app_palettes.dart';

/// Дизайн-токены «нового дизайна» Rlink (эстетика интро-анимации: градиент
/// акцента + мягкое свечение + крупные скругления). Полная инструкция —
/// DESIGN.md в корне репозитория.
///
/// Всё гейтится [on] — при выключенном тумблере экраны обязаны показывать
/// старый вид (старые ветки кода не удаляем).
class RlinkDesign {
  RlinkDesign._();

  /// Единственный гейт нового дизайна.
  static bool get on => AppSettings.instance.newDesign;

  /// Backdrop of a plain (non-aurora) screen. Classic look = fixed greys;
  /// minimalism = the theme's own paper, so light mode is really paper-white
  /// instead of a grey tint.
  static Color screenBg(BuildContext context, bool isDark) =>
      AppSettings.instance.minimalist
          ? Theme.of(context).colorScheme.surface
          : (isDark ? const Color(0xFF0F0F0F) : const Color(0xFFE8E8E8));

  /// Same for app bars / bars that sit on [screenBg].
  static Color barBg(BuildContext context, bool isDark) =>
      AppSettings.instance.minimalist
          ? Theme.of(context).colorScheme.surface
          : (isDark ? const Color(0xFF121212) : const Color(0xFFF2F2F2));

  /// Градиент акцента текущей палитры (как бейджи в интро).
  static LinearGradient accentGradient(ColorScheme cs) {
    final g = paletteFor(AppSettings.instance.appPalette).gradient;
    final a = g.isNotEmpty ? g[0] : cs.primary;
    final b = g.length > 1 ? g[1] : cs.primary;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [a, Color.lerp(a, b, 0.75) ?? b],
    );
  }

  static Color accent(ColorScheme cs) =>
      paletteFor(AppSettings.instance.appPalette).accentColor;

  /// Контрастный цвет текста поверх градиента акцента.
  static Color onAccent(ColorScheme cs) =>
      accent(cs).computeLuminance() > 0.55
          ? const Color(0xFF0A0A0A)
          : Colors.white;

  /// Исходящий пузырь: градиент акцента + мягкое свечение.
  static BoxDecoration bubbleOut(ColorScheme cs, BorderRadius radius) =>
      BoxDecoration(
        gradient: accentGradient(cs),
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: accent(cs).withValues(alpha: 0.30),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      );

  /// Входящий пузырь: поверхность + волосяная обводка акцента.
  static BoxDecoration bubbleIn(ColorScheme cs, BorderRadius radius) =>
      BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: radius,
        border: Border.all(
          color: accent(cs).withValues(alpha: 0.10),
          width: 1,
        ),
      );

  /// «Плавающая» карточка (пост канала, плитка): поверхность + hairline +
  /// свечение акцента — как карточки в интро.
  static BoxDecoration floatCard(ColorScheme cs, {double radius = 22}) =>
      BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: accent(cs).withValues(alpha: 0.18),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: accent(cs).withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      );

  /// Матовое стекло: размытие фона + полупрозрачная заливка + волосяная
  /// обводка. Хром (аппбар, нав-бар) на нём «плавает» над авророй — как в интро.
  /// [fill] — непрозрачность заливки, [blur] — сигма размытия.
  static Widget frosted({
    required BuildContext context,
    Widget? child,
    double blur = 20,
    double fill = 0.52,
    BorderRadius borderRadius = BorderRadius.zero,
    Border? border,
    List<BoxShadow>? shadows,
  }) {
    final cs = Theme.of(context).colorScheme;
    // «Жидкое стекло» (размытие фона) — самый дорогой эффект: BackdropFilter над
    // прокручиваемым/анимированным контентом пере-считывается каждый кадр и
    // роняет FPS на Android. Когда стекло выключено — рисуем ту же панель более
    // плотной заливкой БЕЗ BackdropFilter (визуально почти то же, но дёшево).
    final glass = AppSettings.instance.liquidGlass;
    // Real iOS 26+ Liquid Glass (falls back to UIBlurEffect on older iOS,
    // natively) instead of our own BackdropFilter approximation. The native
    // view is only the material — content stays Flutter, drawn on top, so
    // localisation/badges/taps all keep working normally.
    if (glass && Platform.isIOS) {
      return _nativeGlass(
        borderRadius: borderRadius,
        border: border,
        shadows: shadows,
        child: child,
      );
    }
    final panel = DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: glass ? fill : (fill + 0.4).clamp(0.0, 1.0)),
        borderRadius: borderRadius,
        border: border,
        boxShadow: shadows,
      ),
      child: child,
    );
    if (!glass) {
      return ClipRRect(borderRadius: borderRadius, child: panel);
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: panel,
      ),
    );
  }

  static Widget _nativeGlass({
    required BorderRadius borderRadius,
    Border? border,
    List<BoxShadow>? shadows,
    Widget? child,
  }) {
    // The native corner-radius API takes one value — every call site here
    // uses a uniform radius (pill/circle/rounded-rect), so topLeft stands in.
    final radius = borderRadius.topLeft.x;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: border,
        boxShadow: shadows,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          children: [
            Positioned.fill(
              child: UiKitView(
                viewType: 'rlink/liquid_glass_view',
                creationParams: {'radius': radius},
                creationParamsCodec: const StandardMessageCodec(),
              ),
            ),
            if (child != null) child,
          ],
        ),
      ),
    );
  }

  /// Полупрозрачная «стеклянная» карточка (для плиток на авроре): заливка
  /// поверхности с прозрачностью + hairline акцента + мягкое свечение.
  static BoxDecoration glassCard(ColorScheme cs, {double radius = 22}) =>
      BoxDecoration(
        color: cs.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: accent(cs).withValues(alpha: 0.16),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: accent(cs).withValues(alpha: 0.10),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      );

  /// Аватар в градиентном кольце (как сторис/бейджи интро).
  static Widget gradientRing({
    required Widget child,
    required ColorScheme cs,
    double width = 2,
    double padding = 2,
  }) =>
      Container(
        padding: EdgeInsets.all(width),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: accentGradient(cs),
        ),
        child: Container(
          padding: EdgeInsets.all(padding),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.surface,
          ),
          child: child,
        ),
      );
}
